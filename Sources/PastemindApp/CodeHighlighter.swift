import AppKit
import JavaScriptCore
import PastemindKit

/// Code's language guessed and its syntax coloured, by highlight.js (bundled, BSD 3-Clause, see Acknowledgements) in
/// JavaScriptCore, on a queue of its own: ~5 ms for a usual snippet, the script loaded at the first one.
///
/// highlight.js guesses well from a few lines and badly from one ("git rebase -i HEAD~3" read as CSS), so: a line that
/// starts with a common command is shell; what only Swift or Go has is Swift or Go; the app it came from counts
/// (Xcode, a terminal); and a guess it isn't sure enough of colours nothing.
nonisolated final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()

    private let queue = DispatchQueue(label: "app.pastemind.highlight", qos: .userInitiated)
    /// Only on `queue`.
    private var hljs: JSValue?
    private var context: JSContext?
    private var loaded = false
    private var cache: [Int: SyntaxHighlight] = [:]
    private var cacheOrder: [Int] = []

    /// The languages it may guess: the usual ones (the rest of the bundle's, rare, were guessed for them).
    private static let usual = ["bash", "c", "cpp", "csharp", "css", "diff", "go", "ini", "java", "javascript", "json",
                                "kotlin", "makefile", "markdown", "objectivec", "php", "python", "ruby", "rust", "scss",
                                "shell", "sql", "swift", "typescript", "xml", "yaml"]
    /// highlight.js's relevance a guess needs (a keyword or two; a short line gets 0–3 whatever it is).
    private static let sureEnough: Int32 = 4
    /// Guessed from the start of long code: as good, and the rest only to colour.
    private static let guessedFrom = 8_000

    private static let commands: Set<String> = [
        "git", "docker", "docker-compose", "kubectl", "helm", "ssh", "scp", "rsync", "brew", "npm", "npx", "yarn",
        "pnpm", "bun", "pip", "pip3", "python", "python3", "node", "deno", "cd", "ls", "cat", "curl", "wget", "make",
        "cargo", "rustup", "go", "swift", "xcodebuild", "xcrun", "sudo", "chmod", "chown", "mkdir", "rm", "cp", "mv",
        "echo", "export", "open", "defaults", "launchctl", "ffmpeg", "grep", "rg", "find", "sed", "awk", "tar", "unzip",
        "zip", "gh", "code", "vim", "nano", "touch", "ps", "kill", "killall", "tail", "head", "which", "source", "env",
        "pod", "fastlane", "bundle", "gem", "rake", "terraform", "aws", "gcloud", "heroku", "mise", "uv", "poetry",
        "conda", "systemctl", "journalctl", "apt", "apt-get", "yum", "dnf", "pacman", "tmux", "screen", "ping",
        "traceroute", "dig", "nslookup", "chsh", "ln", "du", "df", "top", "htop", "man", "history", "alias",
    ]
    /// The language code from these apps usually is.
    private static let appLanguages: [String: String] = [
        "com.apple.dt.Xcode": "swift",
        "com.apple.Terminal": "bash", "com.googlecode.iterm2": "bash", "com.mitchellh.ghostty": "bash",
        "dev.warp.Warp-Stable": "bash", "org.alacritty": "bash", "net.kovidgoyal.kitty": "bash",
    ]
    private static let swiftOnly = try! NSRegularExpression(pattern:
        #"\bguard\b[^{\n]*\belse\s*\{|@(State|Binding|Published|Observable|MainActor|objc|available|escaping|Environment)\b|\bfunc\s+\w+\s*(<[^>]*>)?\([^)]*\)\s*(async\s+)?(throws\s+)?->|\bimport\s+(SwiftUI|Foundation|AppKit|UIKit|Combine)\b|\b(if|guard)\s+let\b"#)
    private static let goOnly = try! NSRegularExpression(pattern:
        #"\bfmt\.\w+\(|^\s*package\s+\w+\s*$|\w\s*:=\s*"#, options: [.anchorsMatchLines])

    /// Colours for `text` copied in `appID`; nil when its language isn't known well enough (or the script's missing).
    func highlight(_ text: String, appID: String?) async -> SyntaxHighlight? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.compute(text, appID: appID)) }
        }
    }

    /// The language of `text`, at once (a drag needs it as it starts): the preview's if it worked it out, else guessed
    /// now from its start (a few ms; the script loaded first, the first time).
    func language(_ text: String, appID: String?) -> String? {
        queue.sync {
            if let known = cache[Self.key(text, appID)] { return known.language }
            guard let hljs = load() else { return nil }
            return guess(text, appID: appID, hljs: hljs)
        }
    }

    /// The colours worked out already for `text`, if they were (Quick Look, opened on what the preview shows).
    func known(_ text: String, appID: String?) -> SyntaxHighlight? {
        queue.sync { cache[Self.key(text, appID)] }
    }

    private static func key(_ text: String, _ appID: String?) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(appID)
        return hasher.finalize()
    }

    private func compute(_ text: String, appID: String?) -> SyntaxHighlight? {
        let key = Self.key(text, appID)
        if let known = cache[key] { return known }
        guard let hljs = load(), let language = guess(text, appID: appID, hljs: hljs),
              let result = hljs.invokeMethod("highlight", withArguments: [text, ["language": language,
                                                                                   "ignoreIllegals": true]]),
              let html = result.objectForKeyedSubscript("value")?.toString(),
              var spans = SyntaxMarkup.spans(fromHTML: html, text: text) else { return nil }
        // highlight.js leaves a command line uncoloured ("git rebase -i HEAD~3"): its command, as a built-in.
        if language == "bash" { spans = Self.withCommands(spans, in: text) }
        let highlight = SyntaxHighlight(language: language, spans: spans)
        cache[key] = highlight
        cacheOrder.append(key)
        if cacheOrder.count > 32 { cache[cacheOrder.removeFirst()] = nil }
        return highlight
    }

    private func load() -> JSValue? {
        if loaded { return hljs }
        loaded = true
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else {
            log("highlight: no highlight.min.js in the app")
            return nil
        }
        context.evaluateScript(script)
        self.context = context
        hljs = context.objectForKeyedSubscript("hljs").flatMap { $0.isUndefined ? nil : $0 }
        return hljs
    }

    private func guess(_ text: String, appID: String?, hljs: JSValue) -> String? {
        let sample = String(text.prefix(Self.guessedFrom))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Commands: every line (a few at most) starts with one, after a prompt or sudo.
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if !lines.isEmpty, lines.count <= 6, lines.allSatisfy({ Self.isCommand($0) }) { return "bash" }
        let range = NSRange(sample.startIndex..., in: sample)
        if Self.swiftOnly.firstMatch(in: sample, range: range) != nil { return "swift" }
        if Self.goOnly.firstMatch(in: sample, range: range) != nil { return "go" }
        guard let auto = hljs.invokeMethod("highlightAuto", withArguments: [sample, Self.usual]) else { return nil }
        let best = auto.objectForKeyedSubscript("language").flatMap { $0.isUndefined ? nil : $0.toString() }
        let relevance = auto.objectForKeyedSubscript("relevance")?.toInt32() ?? 0
        if let appID, let usual = Self.appLanguages[appID], usual != best,
           let result = hljs.invokeMethod("highlight", withArguments: [sample, ["language": usual,
                                                                                 "ignoreIllegals": true]]),
           (result.objectForKeyedSubscript("relevance")?.toInt32() ?? 0) >= max(relevance - 2, 1) {
            return usual
        }
        return relevance >= Self.sureEnough ? best : nil
    }

    /// The command starting each line (after a prompt or sudo) that nothing else colours, as a built-in.
    private static func withCommands(_ spans: [SyntaxSpan], in text: String) -> [SyntaxSpan] {
        let string = text as NSString
        var added: [SyntaxSpan] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            var offset = 0
            for word in line.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                if word.isEmpty || word == "$" || word == "%" || word == "sudo" {
                    offset += (word as NSString).length + 1
                    continue
                }
                if commands.contains(word) {
                    let location = range.location + offset
                    let covered = spans.contains { $0.location <= location && location < $0.location + $0.length }
                    if !covered { added.append(SyntaxSpan(location: location, length: (word as NSString).length,
                                                          scope: "built_in")) }
                }
                break
            }
        }
        return (spans + added).sorted { $0.location < $1.location }
    }

    private static func isCommand(_ line: String) -> Bool {
        var words = line.split(separator: " ").map(String.init)
        if words.first == "$" || words.first == "%" { words.removeFirst() }
        if words.first == "sudo" { words.removeFirst() }
        guard let first = words.first else { return false }
        return commands.contains(first) || first.hasPrefix("./")
    }
}

/// The colours code's runs take, as Xcode's default themes have them, light and dark.
enum SyntaxColors {
    enum Role: String, CaseIterable {
        case keyword, string, comment, number, function, type, builtIn, attribute, meta, variable, tag, addition, deletion

        var light: UInt32 {
            switch self {
            case .keyword: 0x9B2393
            case .string: 0xC41A16
            case .comment: 0x5D6C79
            case .number: 0x1C00CF
            case .function: 0x326D74
            case .type: 0x0B4F79
            case .builtIn: 0x6C36A9
            case .attribute: 0x815F03
            case .meta: 0x643820
            case .variable: 0x326D74
            case .tag: 0x0B4F79
            case .addition: 0x1B7F37
            case .deletion: 0xC41A16
            }
        }

        var dark: UInt32 {
            switch self {
            case .keyword: 0xFF7AB2
            case .string: 0xFF8170
            case .comment: 0x7F8C98
            case .number: 0xD9C97C
            case .function: 0x67B7A4
            case .type: 0x5DD8FF
            case .builtIn: 0xD0A8FF
            case .attribute: 0xCC9768
            case .meta: 0xFD8F3F
            case .variable: 0x4EB0CC
            case .tag: 0x5DD8FF
            case .addition: 0x6CC24A
            case .deletion: 0xFF6A5C
            }
        }
    }

    static func role(for scope: String) -> Role? {
        let base = scope.split(separator: ".").first.map(String.init) ?? scope
        switch base {
        case "keyword", "literal", "selector-tag", "section", "bullet": return .keyword
        case "string", "regexp", "template-tag", "char": return .string
        case "comment", "quote", "doctag": return .comment
        case "number", "symbol": return .number
        case "title": return scope.contains("class_") || scope.contains("inherited__") ? .type : .function
        case "type", "class": return .type
        case "built_in": return .builtIn
        case "attr", "attribute", "property", "selector-attr", "selector-pseudo": return .attribute
        case "meta": return .meta
        case "variable", "template-variable", "params": return scope.contains("language_") ? .keyword : .variable
        case "tag", "name", "selector-class", "selector-id": return .tag
        case "addition": return .addition
        case "deletion": return .deletion
        default: return nil
        }
    }

    static func color(for scope: String) -> NSColor? { role(for: scope).flatMap { colors[$0] } }

    private static let colors: [Role: NSColor] = Dictionary(uniqueKeysWithValues: Role.allCases.map { role in
        (role, NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? role.dark : role.light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    })

    /// `text` as a web page in these colours, light or dark as the system is (Quick Look shows it so, following the
    /// theme as it changes: RTF kept the colours of the moment it was written, on its own background).
    static func html(_ text: String, _ spans: [SyntaxSpan]) -> String {
        let units = Array(text.utf16)
        var roles = [Role?](repeating: nil, count: units.count)
        for span in spans where span.location + span.length <= units.count {
            guard let role = role(for: span.scope) else { continue }
            for index in span.location..<(span.location + span.length) { roles[index] = role }
        }
        func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }
        var css = ":root{color-scheme:light dark}body{margin:0;padding:14px 16px;background:#FFFFFF;color:#1D1D1F}"
            + "pre{margin:0;font:12px/1.45 ui-monospace,'SF Mono',Menlo,monospace;white-space:pre-wrap;"
            + "overflow-wrap:anywhere}"
        css += Role.allCases.map { ".\($0.rawValue){color:\(hex($0.light))}" }.joined()
        css += "@media (prefers-color-scheme:dark){body{background:#1F1F24;color:#E6E6E6}"
            + Role.allCases.map { ".\($0.rawValue){color:\(hex($0.dark))}" }.joined() + "}"
        var body = ""
        var start = 0
        while start < units.count {
            var end = start + 1
            while end < units.count, roles[end] == roles[start] { end += 1 }
            let piece = String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            body += roles[start].map { "<span class=\"\($0.rawValue)\">\(piece)</span>" } ?? piece
            start = end
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head>"
            + "<body><pre>\(body)</pre></body></html>"
    }

    /// `spans` coloured into `text` (outer runs first, so each character takes its innermost run's colour).
    static func apply(_ spans: [SyntaxSpan], to text: NSMutableAttributedString) {
        let length = text.length
        for span in spans where span.location + span.length <= length {
            guard let color = color(for: span.scope) else { continue }
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: span.location, length: span.length))
        }
    }
}
