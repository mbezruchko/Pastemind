import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum ClipKind: String, Sendable, CaseIterable {
    case text, link, code, color, image, file

    /// A query that starts with a kind and a colon ("Image:", "files: invoice", any case): that kind only, and the
    /// words after it searched among them. Anything else ("https://…", "note: call") is all words.
    public static func filter(in query: String) -> (kinds: Set<ClipKind>?, words: String) {
        guard let colon = query.firstIndex(of: ":") else { return (nil, query) }
        let head = query[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let kind = ClipKind(rawValue: head) ?? (head.hasSuffix("s") ? ClipKind(rawValue: String(head.dropLast())) : nil)
        guard let kind else { return (nil, query) }
        return ([kind], query[query.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
}

/// One entry of the clipboard history. Copying the same thing again doesn't add an entry: it bumps `lastCopied` and
/// `copies` of the one that's there.
public struct Clip: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var kind: ClipKind
    /// What's pasted for text; the text Vision read for an image; the paths, one a line, for files.
    public var text: String
    public var appID: String?
    public var appName: String?
    public var firstCopied: Date
    public var lastCopied: Date
    public var copies: Int
    public var pinned: Bool
    /// The picture's file name in `AppPaths.images`.
    public var image: String?
    public var width: Int?
    public var height: Int?
    /// The picture's file size.
    public var bytes: Int?
    /// The pasteboard type of the rich version (RTF or HTML), kept in the store and read only when pasting.
    public var richType: String?
    public var embedded: Bool
    /// The vector was made from what's in it: a picture by the image encoder, files by their contents (not only their
    /// text, or names).
    public var contentVector: Bool

    public init(id: Int64, kind: ClipKind, text: String, appID: String? = nil, appName: String? = nil,
                firstCopied: Date = Date(), lastCopied: Date = Date(), copies: Int = 1, pinned: Bool = false,
                image: String? = nil, width: Int? = nil, height: Int? = nil,
                bytes: Int? = nil, richType: String? = nil, embedded: Bool = false, contentVector: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.appID = appID
        self.appName = appName
        self.firstCopied = firstCopied
        self.lastCopied = lastCopied
        self.copies = copies
        self.pinned = pinned
        self.image = image
        self.width = width
        self.height = height
        self.bytes = bytes
        self.richType = richType
        self.embedded = embedded
        self.contentVector = contentVector
    }

    /// The first line with something on it, for the list; for a picture, what it is: "Image: 1400×820 (14 KB)", a
    /// picture file too (its name until it's measured).
    public var title: String {
        switch kind {
        case .image:
            return pictureTitle ?? typeName
        case .file:
            let paths = text.split(separator: "\n")
            let first = paths.first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "File"
            if isPictureFile { return pictureTitle ?? "\(typeName): \(first)" }
            return paths.count > 1 ? "\(first) + \(paths.count - 1) more" : first
        default:
            return Self.firstLine(of: text)
        }
    }

    private var pictureTitle: String? {
        let size = width.flatMap { w in height.map { h in "\(w)×\(h)" } }
        let weight = bytes.map { "(\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))" }
        let details = [size, weight].compactMap { $0 }.joined(separator: " ")
        return details.isEmpty ? nil : "\(typeName): \(details)"
    }

    /// What it is, in a word, for the list: "Image", "Text", "3 files". Every picture is an image, screenshots too.
    public var typeName: String {
        switch kind {
        case .text: return "Text"
        case .link: return "Link"
        case .code: return "Code"
        case .color: return "Color"
        case .image: return "Image"
        case .file:
            if isPictureFile { return "Image" }
            let count = text.split(separator: "\n").count
            return count > 1 ? "\(count) files" : "File"
        }
    }

    /// One copied file that's a picture (a photo, a screenshot, a GIF): an image as much as a copied picture is,
    /// shown, found and kept to by "image:" as one, while it still pastes and drags as the file.
    public var isPictureFile: Bool {
        kind == .file && !text.contains("\n") && Self.isPicture(path: text)
    }

    public static func isPicture(path: String) -> Bool {
        UTType(filenameExtension: (path as NSString).pathExtension)?.conforms(to: .image) == true
    }

    /// A kind filter ("image:", "files:") keeps it: of its kind, or a picture file wanted as an image.
    public func isKept(by kinds: Set<ClipKind>) -> Bool {
        kinds.contains(kind) || (kinds.contains(.image) && isPictureFile)
    }

    /// Where its files were copied from: what to show as where each one is.
    public var copiedURLs: [URL] {
        guard kind == .file else { return [] }
        return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Its files to paste, drag and show: each where it was copied from while it's there, else Pastemind's copy of it
    /// (`KeptFiles`).
    public var fileURLs: [URL] { fileURLs(keptIn: AppPaths.keptFiles) }

    public func fileURLs(keptIn folder: URL) -> [URL] {
        copiedURLs.enumerated().map { index, url in
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let kept = KeptFiles.url(clip: id, index: index, name: url.lastPathComponent, in: folder)
            return FileManager.default.fileExists(atPath: kept.path) ? kept : url
        }
    }

    /// Text that goes to the model: the start of it is enough to know what it's about, and keeps embedding fast.
    public var embeddingText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case .file:
            return copiedURLs.map { $0.lastPathComponent }.joined(separator: ", ")
        case .image:
            return "screenshot with text: " + String(trimmed.prefix(Self.embeddingCharacters))
        default:
            return String(trimmed.prefix(Self.embeddingCharacters))
        }
    }

    /// About 400 tokens: a clip's opening says what it is, and longer inputs embed slower without ranking better.
    public static let embeddingCharacters = 1600

    /// The text Vision read in a picture, to go into its vector with it: when there's enough of it to say something
    /// (a photo's few stray letters, "8ball", only blurred where its vector landed).
    public var textBesidePicture: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .image, trimmed.count >= Self.pictureTextMinimum else { return nil }
        return String(trimmed.prefix(Self.embeddingCharacters))
    }

    public static let pictureTextMinimum = 40

    /// Line by line from the top, only as far as the first one with something on it: lists ask for it on every
    /// redraw, and splitting a long paste into all its lines first cost milliseconds a row (measured 2026-10-14).
    public static func firstLine(of text: String) -> String {
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let trimmed = text[start..<end].prefix(600).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
            start = end < text.endIndex ? text.index(after: end) : end
        }
        return ""
    }
}

/// What a copied string is: a link, a color, code or plain text.
public enum ClipClassifier {
    public static func kind(of text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLink(trimmed) { return .link }
        if isColor(trimmed) { return .color }
        if looksLikeCode(text) { return .code }
        return .text
    }

    public static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < 4096, !text.contains(where: \.isWhitespace) else { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("www."), text.contains(".") { return true }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "ftp": return url.host?.isEmpty == false
        case "mailto", "tel": return true
        default: return false
        }
    }

    public static func isColor(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(") || lower.hasPrefix("hsl(") || lower.hasPrefix("hsla(") {
            return lower.hasSuffix(")") && lower.count < 40
        }
        let hex = lower.hasPrefix("#") ? lower.dropFirst() : lower[...]
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return false }
        // "#abc" is a color; a bare "add" or "1234567" is more likely a word or a number.
        return lower.hasPrefix("#") || (hex.count >= 6 && hex.contains(where: \.isLetter) && hex.contains(where: \.isNumber))
    }

    /// Several lines with the marks of code: braces, semicolons, keywords, consistent indentation.
    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).prefix(60)
        guard lines.count >= 2 else {
            // One line: a shell command or a call, by its shape.
            let line = text.trimmingCharacters(in: .whitespaces)
            let command = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return line.hasPrefix("$ ") || (line.contains(" ") && commands.contains(command))
                || (line.hasSuffix(");") && line.contains("("))
        }
        var score = 0
        let markers = ["{", "}", ";", "=>", "->", "()", "==", "!=", "&&", "||", "</", "/>", "#include", "import ",
                       "func ", "def ", "class ", "return ", "const ", "let ", "var ", "fn ", "public ", "private "]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("    ") || line.hasPrefix("\t") { score += 1 }
            if markers.contains(where: { trimmed.contains($0) }) { score += 2 }
            if trimmed.hasSuffix(".") && trimmed.split(separator: " ").count > 6 { score -= 2 }   // prose
        }
        return score >= lines.count * 2
    }

    /// Shell commands a one-line copy may start with.
    static let commands: Set<String> = [
        "sudo", "git", "npm", "npx", "pnpm", "yarn", "brew", "cd", "ls", "cat", "ssh", "scp", "rsync", "curl", "wget",
        "docker", "kubectl", "helm", "make", "cargo", "swift", "xcodebuild", "python", "python3", "pip", "pip3", "uv",
        "node", "go", "export", "echo", "grep", "rg", "find", "chmod", "chown", "mkdir", "rm", "mv", "cp", "tar", "gh",
        "gcloud", "aws", "terraform", "psql", "mysql", "redis-cli", "ffmpeg", "open", "defaults", "launchctl",
    ]

    public static func hash(kind: ClipKind, text: String) -> String {
        let prefix = switch kind {
        case .image: "image"
        case .file: "file"
        default: "text"   // the same words are one clip, whatever they were classified as
        }
        return hash(Data("\(prefix):\(text)".utf8))
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// The model's prompts, as the model card gives them.
/// The same text copied again a little longer or shorter, the selection redone: it takes the place of the copy before.
public enum RedoneCopy {
    /// Only right after: the copy before was made at most this long ago.
    public static let window: TimeInterval = 5 * 60

    /// `next` starts as `previous` does (one runs on past the other), spaces before them aside.
    public static func redoes(_ previous: String, with next: String) -> Bool {
        let a = previous.drop { $0.isWhitespace }, b = next.drop { $0.isWhitespace }
        guard !a.isEmpty, !b.isEmpty, a != b else { return false }
        return a.count < b.count ? b.hasPrefix(a) : a.hasPrefix(b)
    }
}

public enum Prompts {
    public static func query(_ text: String) -> String { "task: search result | query: \(text)" }
    /// What people look for in a clipboard history, in any language: their vectors' mean is the typical
    /// query (`ClipIndex.typicalQuery`). None of them is one of the evaluation's queries.
    public static let typicalQueries: [String] = [
        "the link I copied", "that address", "password", "code snippet", "error message", "meeting time",
        "quote from the article", "shopping list", "screenshot of the chart", "terminal command", "json config",
        "budget numbers", "a long paragraph", "his name", "the date", "translation", "list of tasks",
        "photo of a document", "price", "song lyrics",
        "ссылка которую скопировал", "тот адрес", "пароль", "кусок кода", "текст ошибки", "время встречи",
        "цитата из статьи", "список покупок", "скриншот графика", "команда для терминала", "настройки json",
        "цифры бюджета", "длинный абзац", "его имя", "дата", "перевод", "список задач", "фото документа", "цена",
        "текст песни",
    ]
    /// The same for a query of one word, which comes closer to short clips than a phrase does: their vectors' mean is
    /// the typical one-word query (`ClipIndex.typicalWord`).
    public static let typicalWords: [String] = [
        "password", "link", "address", "code", "error", "price", "date", "meeting", "file", "picture", "command",
        "email", "number", "name", "list", "photo", "quote", "config", "screenshot", "message",
        "пароль", "ссылка", "адрес", "код", "ошибка", "цена", "дата", "встреча", "файл", "картинка", "команда", "почта",
        "номер", "имя", "список", "фото", "цитата", "настройки", "скриншот", "сообщение",
    ]
    public static func document(_ text: String) -> String { "title: none | text: \(text)" }
    /// A picture, at `marker`: alone (the model takes pictures without a prompt), or a document with its text.
    public static func picture(marker: String, text: String?) -> String {
        text.map { document(marker + "\n" + $0) } ?? marker
    }
    /// Copied files: their names as the title, then their pictures or sound (one `marker` each) and text.
    public static func files(title: String, markers: [String], text: String?) -> String {
        let content = (markers.joined(separator: " ") + "\n" + (text ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return "title: \(title) | text: \(content)"
    }
}
