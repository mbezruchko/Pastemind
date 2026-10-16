import AppKit
import AVFoundation
import Foundation
import PDFKit
import PastemindKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// What's in copied files, as the model takes it: their text (documents, code, PDFs, scans by OCR), pictures (a picture,
/// three frames of a video, a scan with no text OCR reads by its first page, any other document's Quick Look preview)
/// and sound (an audio file's first 30 s). Read once, off the main thread, as they're copied; none of it is kept but
/// the vector. Files that only live in iCloud aren't read (that would download them), nor keys, certificates and
/// password stores (`CopiedFiles`).
public enum CopiedFileReader {
    public struct Contents: Sendable {
        public let prompt: String
        public let media: [LlamaEmbedder.Media]
        /// What went in, for the log: "3 pictures, 420 characters".
        public let summary: String
    }

    /// Nil when nothing in them reads but their names. `pictures`, `sound`: whether the image and audio encoders are
    /// there (else only text is read).
    public static func read(_ urls: [URL], pictures: Bool, sound: Bool, budget: Int) async -> Contents? {
        var texts: [String] = []
        var images: [CGImage] = []
        var heard: [Float]?
        for url in urls.prefix(12) {
            let room = CopiedFiles.maxPictures - images.count
            guard let part = await part(of: url, pictures: pictures && room > 0, sound: sound && urls.count == 1) else {
                continue
            }
            switch part {
            case .text(let text): texts.append(urls.count > 1 ? "\(url.lastPathComponent): \(text)" : text)
            case .pictures(let found): images += found.prefix(room)
            case .sound(let samples): heard = samples
            }
        }
        let media: [LlamaEmbedder.Media] = heard.map { [.sound($0)] }
            ?? images.compactMap { ImagePixels(image: $0, budget: budget) }.map { .picture($0) }
        // Four pictures and the names leave room for about 600 characters in the model's 1,024 tokens.
        let limit = media.count >= 3 ? CopiedFiles.textCharacters / 2 : CopiedFiles.textCharacters
        let text = String(texts.joined(separator: "\n").prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !media.isEmpty || !text.isEmpty else { return nil }
        let prompt = Prompts.files(title: CopiedFiles.title(of: urls),
                                   markers: Array(repeating: LlamaEmbedder.marker, count: media.count),
                                   text: text.isEmpty ? nil : text)
        var summary: [String] = []
        if heard != nil { summary.append("sound") }
        if heard == nil, !media.isEmpty { summary.append(media.count == 1 ? "1 picture" : "\(media.count) pictures") }
        if !text.isEmpty { summary.append("\(text.count) characters") }
        return Contents(prompt: prompt, media: media, summary: summary.joined(separator: ", "))
    }

    /// A long document's text past what `read` takes, in pieces (`CopiedFiles.pieces`), each a prompt for a vector of
    /// its own under the file's name; a scan's by OCR. Empty for a short one, or a kind without pieces.
    public static func pieces(of url: URL) -> [String] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]
        guard CopiedFiles.hasPieces(url), !CopiedFiles.isPrivate(url), let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory != true,
              values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current else { return [] }
        let reach = CopiedFiles.piecesReach
        let ext = url.pathExtension.lowercased()
        let text: String? = switch ext {
        case "pdf": PDFDocument(url: url).map { document in
            let found = pdfText(document, upTo: reach)
            return found.count >= Clip.pictureTextMinimum ? found : scanText(url, pages: document.pageCount, upTo: reach) ?? ""
        }
        case "html", "htm": pageText(url, bytes: 4 << 20)
        case "txt", "text", "md", "markdown": plainText(url, bytes: reach * 4)
        default: documentTypes[ext].flatMap { documentText(url, type: $0, size: values.fileSize) }
        }
        let title = url.lastPathComponent
        return CopiedFiles.pieces(of: text ?? "").map { Prompts.files(title: title, markers: [], text: $0) }
    }

    private enum Part {
        case text(String)
        case pictures([CGImage])
        case sound([Float])
    }

    private static func part(of url: URL, pictures: Bool, sound: Bool) async -> Part? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .fileSizeKey,
                                         .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }   // gone since
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return nil }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        // A Keynote deck is a ".key" too.
        guard type.identifier.hasPrefix("com.apple.iwork") || !CopiedFiles.isPrivate(url) else { return nil }
        let ext = url.pathExtension.lowercased()
        if values.isDirectory == true, values.isPackage != true { return folder(url) }
        if type.conforms(to: .application) || type.conforms(to: .bundle) || type.conforms(to: .framework) { return nil }
        if type.conforms(to: .image) { return pictures ? image(url) : nil }
        if type.conforms(to: .pdf) { return pdf(url, pictures: pictures) }
        if type.conforms(to: .audio) { return sound ? audio(url) : nil }
        if type.conforms(to: .audiovisualContent) { return pictures ? await frames(url) : nil }
        if let documentType = documentTypes[ext] { return document(url, type: documentType, size: values.fileSize) }
        if ext == "html" || ext == "htm" || type.conforms(to: .html) { return html(url) }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) { return plain(url) }
        return pictures ? await preview(url) : nil
    }

    // MARK: Text

    private static let documentTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "rtfd": .rtfd, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument,
        "wordml": .wordML,
    ]

    /// The start of a text file: code, Markdown, CSV, JSON, logs. Nil when it's binary after all.
    private static func plain(_ url: URL) -> Part? {
        plainText(url, bytes: 64 << 10).flatMap(text)
    }

    private static func plainText(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        try? handle.close()
        guard data.prefix(4096).filter({ $0 == 0 }).count < 8 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Word, RTF and OpenDocument files, by AppKit's readers (not HTML's, which wants the main thread).
    private static func document(_ url: URL, type: NSAttributedString.DocumentType, size: Int?) -> Part? {
        documentText(url, type: type, size: size).flatMap(text)
    }

    private static func documentText(_ url: URL, type: NSAttributedString.DocumentType, size: Int?) -> String? {
        guard (size ?? 0) < 20 << 20 else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        return (try? NSAttributedString(url: url, options: options, documentAttributes: nil))?.string
    }

    /// A web page's words, its markup stripped.
    private static func html(_ url: URL) -> Part? {
        pageText(url, bytes: 256 << 10).flatMap(text)
    }

    private static func pageText(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: bytes) else { return nil }
        try? handle.close()
        var page = String(decoding: data, as: UTF8.self)
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            page = page.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            page = page.replacingOccurrences(of: entity, with: character)
        }
        return page
    }

    /// Text with its runs of blank space closed up, cut to what goes into a vector; nil when there's nothing in it.
    private static func text(_ raw: String) -> Part? {
        let words = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count >= 3 else { return nil }
        return .text(String(words.prefix(CopiedFiles.textCharacters)))
    }

    /// A folder: the names in it.
    private static func folder(_ url: URL) -> Part? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        let shown = names.filter { !$0.hasPrefix(".") }.sorted().prefix(40)
        guard !shown.isEmpty else { return nil }
        return .text("contains " + shown.joined(separator: ", "))
    }

    /// A PDF's text, from its first pages; a scan's (no text) by OCR, else (none in it either) its first page's picture.
    private static func pdf(_ url: URL, pictures: Bool) -> Part? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        let found = pdfText(document, upTo: CopiedFiles.textCharacters, pages: 5)
        if let read = text(found), found.count >= Clip.pictureTextMinimum { return read }
        if let scanned = scanText(url, pages: document.pageCount, upTo: CopiedFiles.textCharacters),
           scanned.count >= Clip.pictureTextMinimum, let read = text(scanned) { return read }
        guard pictures, let page = document.page(at: 0),
              let picture = page.thumbnail(of: NSSize(width: 1024, height: 1024), for: .mediaBox)
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return .pictures([picture])
    }

    /// Its pages' text, in order, till there's `limit` characters of it (or `pages` pages).
    private static func pdfText(_ document: PDFDocument, upTo limit: Int, pages: Int = .max) -> String {
        var found = ""
        for index in 0..<min(document.pageCount, pages) where found.count < limit {
            found += (document.page(at: index)?.string ?? "") + "\n"
        }
        return found
    }

    /// The last scan OCR read: its pieces go on from the pages its vector's text came from (`read` then `pieces`).
    private struct Scan {
        let path: String
        let modified: Date?
        var pages: [String]
        var characters: Int { pages.reduce(0) { $0 + $1.count } }
    }

    nonisolated(unsafe) private static var lastScan: Scan?
    private static let scanLock = NSLock()

    /// A scan's text by OCR (`TextRecognition`), from its first page till there's `characters` of it (no more than
    /// `CopiedFiles.scanPages` pages of its `pages`). Nil when it couldn't be read.
    private static func scanText(_ url: URL, pages: Int, upTo characters: Int) -> String? {
        guard TextRecognition.available else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        scanLock.lock()
        let last = lastScan
        scanLock.unlock()
        var scan = last.flatMap { $0.path == url.path && $0.modified == modified ? $0 : nil }
            ?? Scan(path: url.path, modified: modified, pages: [])
        let pages = min(pages, CopiedFiles.scanPages)
        if scan.characters < characters, scan.pages.count < pages {
            guard let more = TextRecognition.pages(of: url, first: scan.pages.count, pages: pages - scan.pages.count,
                                                   characters: characters - scan.characters) else {
                return scan.pages.isEmpty ? nil : scan.pages.joined(separator: "\n")
            }
            scan.pages += more
            scanLock.lock()
            lastScan = scan
            scanLock.unlock()
        }
        return scan.pages.joined(separator: "\n")
    }

    // MARK: Pictures

    private static func image(_ url: URL) -> Part? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return .pictures([picture])
    }

    /// Three frames, at a sixth, half and five sixths of the way: the video's start, middle and end.
    private static func frames(_ url: URL) async -> Part? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        let tolerance = CMTime(seconds: max(duration.seconds / 20, 0.1), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var found: [CGImage] = []
        for fraction in [1.0 / 6, 0.5, 5.0 / 6] {
            let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            if let frame = try? await generator.image(at: time).image { found.append(frame) }
        }
        return found.isEmpty ? nil : .pictures(found)
    }

    /// What Quick Look shows of anything else (Pages, Keynote, Sketch…), when it draws the contents, not an icon.
    private static func preview(_ url: URL) async -> Part? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1024, height: 1024), scale: 1,
                                                   representationTypes: .thumbnail)
        guard let preview = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return .pictures([preview.cgImage])
    }

    // MARK: Sound

    /// The first 30 seconds, mono at the model's 16 kHz.
    private static func audio(_ url: URL) -> Part? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let input = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), CopiedFiles.soundSeconds * input.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames),
              (try? file.read(into: buffer, frameCount: frames)) != nil,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(LlamaEmbedder.soundSampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / input.sampleRate) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var given = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { (_: AVAudioPacketCount, state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
            if given {
                state.pointee = .endOfStream
                return nil
            }
            given = true
            state.pointee = .haveData
            return buffer
        }
        guard status != AVAudioConverterOutputStatus.error, let channel = converted.floatChannelData, converted.frameLength > 0 else { return nil }
        return .sound(Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))))
    }
}
