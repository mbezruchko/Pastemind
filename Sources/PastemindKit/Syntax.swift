import Foundation

/// Code coloured by its language: what each run of the text is (a keyword, a string, a comment…), as ranges of it.
public struct SyntaxHighlight: Sendable, Equatable {
    /// highlight.js's name for it ("swift", "bash").
    public let language: String
    /// Outer runs before the ones inside them: colouring them in this order leaves each character the innermost's.
    public let spans: [SyntaxSpan]

    public init(language: String, spans: [SyntaxSpan]) {
        self.language = language
        self.spans = spans
    }

    /// A file of code in `language` (highlight.js's name) takes: "swift", "py", "sh"; HTML is "html", other markup
    /// "xml"; nil for a language without one of its own.
    public static func fileExtension(for language: String, text: String) -> String? {
        if language == "xml" {
            let start = text.prefix(600).lowercased()
            let html = ["<!doctype html", "<html", "<div", "<span", "<a ", "<p>", "<p ", "<body", "<head", "<script",
                        "<style", "<ul", "<li", "<img", "<button", "<input", "<form", "<section", "<table"]
            return html.contains { start.contains($0) } ? "html" : "xml"
        }
        return extensions[language]
    }

    static let extensions: [String: String] = [
        "bash": "sh", "shell": "sh", "c": "c", "cpp": "cpp", "csharp": "cs", "css": "css", "diff": "diff", "go": "go",
        "ini": "ini", "java": "java", "javascript": "js", "json": "json", "kotlin": "kt", "makefile": "mk",
        "markdown": "md", "objectivec": "m", "php": "php", "python": "py", "ruby": "rb", "rust": "rs", "scss": "scss",
        "sql": "sql", "swift": "swift", "typescript": "ts", "yaml": "yaml",
    ]

    /// For people: "Swift", "Shell", "C++".
    public var languageName: String { Self.names[language] ?? language.prefix(1).uppercased() + language.dropFirst() }

    static let names: [String: String] = [
        "bash": "Shell", "shell": "Shell", "c": "C", "cpp": "C++", "csharp": "C#", "css": "CSS", "diff": "Diff",
        "go": "Go", "ini": "INI", "java": "Java", "javascript": "JavaScript", "json": "JSON", "kotlin": "Kotlin",
        "makefile": "Makefile", "markdown": "Markdown", "objectivec": "Objective-C", "php": "PHP", "python": "Python",
        "ruby": "Ruby", "rust": "Rust", "scss": "SCSS", "sql": "SQL", "swift": "Swift", "typescript": "TypeScript",
        "xml": "HTML", "yaml": "YAML",
    ]
}

public struct SyntaxSpan: Sendable, Equatable {
    /// In the text's UTF-16 units (as NSString and NSAttributedString count).
    public let location: Int
    public let length: Int
    /// highlight.js's scope, without its prefix: "keyword", "title.function_", "string".
    public let scope: String

    public init(location: Int, length: Int, scope: String) {
        self.location = location
        self.length = length
        self.scope = scope
    }
}

/// highlight.js's output (the code, escaped, in `<span class="hljs-…">` runs) read back into the text and its runs.
public enum SyntaxMarkup {
    /// Nil when the markup's text isn't `text` (it always is, unless highlight.js changed it).
    public static func spans(fromHTML html: String, text: String) -> [SyntaxSpan]? {
        var plain: [UInt16] = []
        plain.reserveCapacity(text.utf16.count)
        var open: [(start: Int, scope: String?)] = []
        var spans: [(order: Int, span: SyntaxSpan)] = []
        let characters = Array(html.utf16)
        var index = 0
        func starts(_ prefix: String, at position: Int) -> Bool {
            let units = Array(prefix.utf16)
            guard position + units.count <= characters.count else { return false }
            return Array(characters[position..<(position + units.count)]) == units
        }
        while index < characters.count {
            let unit = characters[index]
            if unit == 0x3C {   // <
                guard let close = characters[index...].firstIndex(of: 0x3E) else { return nil }
                let tag = String(utf16CodeUnits: Array(characters[(index + 1)..<close]), count: close - index - 1)
                if tag.hasPrefix("/") {
                    guard let last = open.popLast() else { return nil }
                    if let scope = last.scope, plain.count > last.start {
                        spans.append((order: last.start * 1000 + open.count,
                                      span: SyntaxSpan(location: last.start, length: plain.count - last.start,
                                                       scope: scope)))
                    }
                } else {
                    open.append((plain.count, scope(ofTag: tag)))
                }
                index = close + 1
            } else if unit == 0x26 {   // &
                let entities: [(String, UInt16)] = [("&amp;", 0x26), ("&lt;", 0x3C), ("&gt;", 0x3E), ("&quot;", 0x22),
                                                    ("&#x27;", 0x27), ("&#39;", 0x27)]
                guard let (entity, value) = entities.first(where: { starts($0.0, at: index) }) else { return nil }
                plain.append(value)
                index += entity.utf16.count
            } else {
                plain.append(unit)
                index += 1
            }
        }
        guard open.isEmpty, plain == Array(text.utf16) else { return nil }
        // Outer before inner: by start, then the one opened first (fewer open around it) first.
        return spans.sorted { $0.span.location != $1.span.location ? $0.span.location < $1.span.location
                                                                     : $0.order < $1.order }.map(\.span)
    }

    /// `span class="hljs-title function_"` → "title.function_"; nil for a span without a class.
    static func scope(ofTag tag: String) -> String? {
        guard let start = tag.range(of: "class=\"")?.upperBound,
              let end = tag[start...].firstIndex(of: "\"") else { return nil }
        let classes = tag[start..<end].split(separator: " ").map { $0.hasPrefix("hljs-") ? $0.dropFirst(5) : $0 }
        return classes.isEmpty ? nil : classes.joined(separator: ".")
    }
}

/// What a file made of a clip's text is called: its first line (or a name given), without what file names can't have
/// (and, for code, without its brackets and punctuation), cut short.
public enum TextFileName {
    public static func make(_ line: String, extension ext: String = "txt", code: Bool = false) -> String {
        var cleaned = line
        if code {
            let punctuation = CharacterSet(charactersIn: "{}[]()<>;:/\"'`*?|\\,=!&$#@^%+")
            cleaned = String(cleaned.unicodeScalars.map { punctuation.contains($0) ? " " : Character($0) })
            // Words only: "->" and "_" on their own go, and a word's own trailing ones.
            cleaned = cleaned.split(separator: " ")
                .map { word in String(word.reversed().drop { "-_.".contains($0) }.reversed()) }
                .filter { $0.contains { $0.isLetter || $0.isNumber } }
                .joined(separator: " ")
        } else {
            cleaned = cleaned.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-_")))
        var base = cleaned.isEmpty ? (code ? "Code" : "Text") : String(cleaned.prefix(code ? 48 : 60))
        base = base.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-_")))
        return base + "." + ext
    }
}

