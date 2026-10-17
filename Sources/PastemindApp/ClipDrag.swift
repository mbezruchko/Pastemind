import AppKit
import PastemindKit
import SwiftUI
import UniformTypeIdentifiers

/// A clip dragged out of the panel (its row, or its preview): what other apps take from it, as a paste gives them, and
/// in Finder a file. Files go as themselves (copied, never moved); a picture as a file named after its size (what a
/// browser's upload field or a chat takes) with its data beside it; a link as its address (Finder makes a .webloc);
/// text, code and colours as their text, and in Finder a .txt named after the first line.
enum ClipDrag {
    static func writers(for clip: Clip) -> [NSPasteboardWriting] {
        switch clip.kind {
        case .file:
            return clip.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0 as NSURL }
        case .image:
            return PictureFiles.item(for: clip).map { [$0] } ?? []
        case .link:
            let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), url.scheme != nil else { return [PromisedFile(clip: clip, picture: nil)] }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .URL)
            item.setString(text, forType: .string)
            return [item]
        default:
            return [PromisedFile(clip: clip, picture: nil)]
        }
    }

    /// A snippet: its text, and in Finder a file named after it (.txt, or code's own extension when it's code).
    static func writers(for snippet: Snippet) -> [NSPasteboardWriting] {
        let code = ClipClassifier.kind(of: snippet.text) == .code
        let ext = code ? codeExtension(snippet.text, appID: nil) : nil
        let name = snippet.title.isEmpty ? Clip.firstLine(of: snippet.text) : snippet.title
        return [PromisedFile(text: snippet.text, picture: nil,
                             name: TextFileName.make(name, extension: ext ?? "txt", code: code && snippet.title.isEmpty))]
    }

    /// Code's file extension by its language ("swift", "py"); nil when that isn't known well enough.
    nonisolated static func codeExtension(_ text: String, appID: String?) -> String? {
        CodeHighlighter.shared.language(text, appID: appID).flatMap { SyntaxHighlight.fileExtension(for: $0, text: text) }
    }

    /// One file of a clip's (its row in the preview, or its cover).
    static func writers(forFile url: URL) -> [NSPasteboardWriting] {
        FileManager.default.fileExists(atPath: url.path) ? [url as NSURL] : []
    }

    /// Only ever a copy: Finder moves a dragged file within its disk unless told otherwise.
    static let operations: NSDragOperation = .copy

    /// The image dragged under the pointer: `image` no bigger than `side`, centered on `point` (in the view's
    /// coordinates), the first item carrying it.
    static func items(_ writers: [NSPasteboardWriting], image: NSImage, at point: NSPoint,
                      side: CGFloat = 160) -> [NSDraggingItem] {
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
                           height: size.height)
        return writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return item
        }
    }
}

/// A picture clip as a file of its own, named as a drop into Finder names it ("Image 1400×820.png"), for apps that take
/// files rather than a picture's data (a browser's upload field, a chat, Finder pasting): a copy in the user's temporary
/// folder (a clone on APFS: no time, no space), a TIFF made PNG, which more of them take. Emptied at launch.
enum PictureFiles {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pastemind Pictures",
                                                                                     isDirectory: true)

    static func file(for clip: Clip) -> URL? {
        guard clip.kind == .image, let name = clip.image else { return nil }
        let stored = AppPaths.images.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: stored.path) else { return nil }
        let tiff = ["tiff", "tif"].contains(stored.pathExtension.lowercased())
        var fileName = PromisedFile.fileName(for: clip, picture: stored)
        if tiff { fileName = (fileName as NSString).deletingPathExtension + ".png" }
        let folder = folder.appendingPathComponent("\(clip.id)", isDirectory: true)
        let url = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if tiff {
                guard let png = NSBitmapImageRep(data: try Data(contentsOf: stored))?
                    .representation(using: .png, properties: [:]) else { return nil }
                try png.write(to: url, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: stored, to: url)
            }
            return url
        } catch {
            return nil
        }
    }

    /// The picture's data (as stored: PNG, JPEG, GIF…), then its file: an app that takes pictures pastes the picture,
    /// one that takes files (Finder, an upload field) the file.
    static func item(for clip: Clip) -> NSPasteboardItem? {
        guard clip.kind == .image, let name = clip.image,
              let data = try? Data(contentsOf: AppPaths.images.appendingPathComponent(name)) else { return nil }
        let item = NSPasteboardItem()
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .png
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        if let file = file(for: clip) { item.setString(file.absoluteString, forType: .fileURL) }
        return item
    }
}

/// A file Finder (or any app that takes files) makes when the clip is dropped there, written only then; for the rest
/// the clip's text, or its picture's data, on the same item.
nonisolated final class PromisedFile: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let text: String
    private let picture: URL?
    private let name: String
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(text: String, picture: URL?, name: String) {
        self.text = text
        self.picture = picture
        self.name = name
        super.init()
        let ext = picture?.pathExtension ?? (name as NSString).pathExtension
        fileType = (UTType(filenameExtension: ext) ?? (picture == nil ? .plainText : .png)).identifier
        delegate = self
    }

    convenience init(clip: Clip, picture: URL?) {
        self.init(text: clip.text, picture: picture, name: Self.fileName(for: clip, picture: picture))
    }

    /// "Image 1400×820.png"; "notes from the sync.txt"; code by its language: "func embed texts String.swift",
    /// "git rebase -i HEAD~3.sh" (the first line, without what file names can't have).
    static func fileName(for clip: Clip, picture: URL?) -> String {
        if let picture {
            let size = clip.width.flatMap { width in clip.height.map { " \(width)×\($0)" } } ?? ""
            return "Image\(size).\(picture.pathExtension.isEmpty ? "png" : picture.pathExtension)"
        }
        let code = clip.kind == .code
        let ext = code ? ClipDrag.codeExtension(clip.text, appID: clip.appID) : nil
        return TextFileName.make(Clip.firstLine(of: clip.text), extension: ext ?? "txt", code: code)
    }

    // Written with the item, not promised: promised, they read back empty.
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + (picture == nil ? [.string] : [.png])
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .string:
            return text
        case .png:
            guard let picture else { return nil }
            if picture.pathExtension.lowercased() == "png" { return try? Data(contentsOf: picture) }
            return NSImage(contentsOf: picture)
                .flatMap { $0.tiffRepresentation }
                .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        default:
            return super.pasteboardPropertyList(forType: type)
        }
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            if let picture {
                try FileManager.default.copyItem(at: picture, to: url)
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { Self.queue }
}

/// What's under it drags out (a picture, a file, a colour, a link) once the pointer moves a few points with the button
/// down; a click without that is `onClick`.
struct DragSource: NSViewRepresentable {
    let writers: () -> [NSPasteboardWriting]
    let image: () -> NSImage?
    var onClick: (() -> Void)?
    var began: () -> Void = {}
    var ended: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.source = self
        view.window?.invalidateCursorRects(for: view)
    }

    final class DragView: NSView, NSDraggingSource {
        var source: DragSource?
        private var pressed: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if source?.onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
        }

        override func mouseDown(with event: NSEvent) { pressed = event }

        override func mouseDragged(with event: NSEvent) {
            guard let pressed, let source else { return }
            let from = pressed.locationInWindow, to = event.locationInWindow
            guard hypot(to.x - from.x, to.y - from.y) > 3 else { return }
            self.pressed = nil
            let writers = source.writers()
            guard !writers.isEmpty else { return }
            let image = source.image() ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
            source.began()
            beginDraggingSession(with: ClipDrag.items(writers, image: image, at: convert(from, from: nil)),
                                 event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            guard pressed != nil else { return }
            pressed = nil
            source?.onClick?()
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            ClipDrag.operations
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            source?.ended(operation != [])
        }
    }
}
