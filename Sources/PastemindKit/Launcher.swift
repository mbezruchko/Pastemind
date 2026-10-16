import CoreServices
import Foundation

/// Something the launcher opens: an app, a System Settings pane, a file or a folder.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case app, setting, folder, file
        /// Something search offers to do (turn on finding files by what's in them).
        case action
    }

    public let kind: Kind
    /// What the list shows: the app's name as Finder shows it, the pane's name, the file's name.
    public let name: String
    /// Other names it answers to: the app's own (unlocalized) name, the file name without its extension.
    public let aliases: [String]
    /// The bundle or file (for a pane, its extension bundle: that's where its icon is).
    public let path: String
    /// What opening it opens: the file, or the pane's x-apple.systempreferences URL.
    public let url: URL
    /// When you last opened it, as Spotlight knows (apps and files).
    public var lastUsed: Date?
    /// What the list shows under the name instead of the path (an action's).
    public var detail: String?

    public var id: String { url.absoluteString }

    public init(kind: Kind, name: String, aliases: [String] = [], path: String, url: URL, lastUsed: Date? = nil,
                detail: String? = nil) {
        self.kind = kind
        self.name = name
        self.aliases = aliases
        self.path = path
        self.url = url
        self.lastUsed = lastUsed
        self.detail = detail
    }

    /// The path with ~ for the home folder, or "System Settings → Appearance" for a pane.
    public var subtitle: String {
        if let detail { return detail }
        if kind == .setting { return "System Settings → \(name)" }
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

public struct LaunchResult: Identifiable, Hashable, Sendable {
    public let item: LaunchItem
    public internal(set) var score: Double
    /// How well the name alone matched.
    let match: Double
    /// Found by what's in it, not its name (the list says so).
    public internal(set) var byContent = false
    public var id: String { item.id }
}

/// What was opened from the launcher before: after typing these letters (a launch counts for every prefix of what was
/// typed), and at all.
public struct LaunchHistory: Sendable, Equatable {
    public struct Pick: Sendable, Equatable {
        public let count: Int
        public let last: Date

        public init(count: Int, last: Date) {
            self.count = count
            self.last = last
        }
    }

    /// Per item: how often, and when last, it was opened after typing these letters.
    public var picks: [String: Pick]
    /// Per item: when it was last opened, whatever was typed.
    public var opened: [String: Date]

    public init(picks: [String: Pick] = [:], opened: [String: Date] = [:]) {
        self.picks = picks
        self.opened = opened
    }
}

// MARK: Matching names

/// How well typed letters name something: the whole name, its start, the start of one of its
/// words ("store" → App Store), its initials ("vsc" → Visual Studio Code), anywhere in it, or its letters in order.
public enum Fuzzy {
    public static func score(_ query: String, _ name: String) -> Double {
        let q = normalize(query)
        let n = normalize(name)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if n == q { return 1 }
        let compactQuery = q.filter { $0.isLetter || $0.isNumber }
        let compactName = n.filter { $0.isLetter || $0.isNumber }
        if compactName == compactQuery, !compactQuery.isEmpty { return 0.97 }   // "wifi" → "Wi‑Fi"
        let shortness = Double(q.count) / Double(max(n.count, 1))
        if n.hasPrefix(q) { return 0.88 + 0.08 * shortness }
        let words = Self.words(name)
        let queryWords = q.split(separator: " ").map(String.init)
        if queryWords.count > 1 {
            // Every typed word starts one of the name's words: "goo chr" → Google Chrome.
            var remaining = words
            var matched = true
            for word in queryWords {
                guard let index = remaining.firstIndex(where: { $0.hasPrefix(word) }) else {
                    matched = false
                    break
                }
                remaining.remove(at: index)
            }
            if matched { return 0.82 }
        }
        if let index = words.firstIndex(where: { $0.hasPrefix(q) }) {
            return 0.8 + 0.06 * shortness - 0.01 * Double(min(index, 5))
        }
        if compactName.hasPrefix(compactQuery), compactQuery.count >= 2 { return 0.84 }   // "appst" → "App Store"
        if q.count >= 2, String(words.compactMap(\.first)).hasPrefix(q) { return 0.76 }
        if n.contains(q) { return 0.6 + 0.1 * shortness }
        // "sfr" → "Safari": letters in order, better the closer together they are.
        let scattered = subsequenceSpread(q, n).map { 0.3 + 0.25 * Double(q.count) / Double($0) } ?? 0
        return max(scattered, misspelled(compactQuery, compactName, words) ?? 0)
    }

    /// "salck" → Slack, "safri" → Safari, "stuido" → Visual Studio Code: the start of the name, or of one of its words,
    /// with a letter wrong, missing, extra or swapped with the next (two from 8 letters typed). From 4 letters, and the
    /// first one right (or swapped with the second): fewer than that matched too much. Below every match as typed.
    static func misspelled(_ query: String, _ name: String, _ words: [String]) -> Double? {
        let q = Array(query)
        guard q.count >= 4 else { return nil }
        let allowed = q.count >= 8 ? 2 : 1
        func distance(to text: String) -> Int? {
            let t = Array(text)
            guard let first = t.first, first == q[0] || (t.count > 1 && first == q[1] && t[1] == q[0]) else { return nil }
            // Against the start as long as what's typed, a letter either side (one missing, or extra).
            let (shortest, longest) = (max(q.count - allowed, 1), min(q.count + allowed, t.count))
            guard shortest <= longest else { return nil }   // a name too short for it ("TV" for "mail")
            return (shortest...longest).map { editDistance(q, Array(t.prefix($0))) }.min()
        }
        if let edits = distance(to: name), edits <= allowed { return 0.62 - 0.08 * Double(edits - 1) }
        let wordEdits = words.compactMap { distance(to: $0.filter { $0.isLetter || $0.isNumber }) }.min()
        if let edits = wordEdits, edits <= allowed { return 0.58 - 0.08 * Double(edits - 1) }
        return nil
    }

    /// Letters to change, add, drop, or swap with the next, to make one into the other.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var before = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], before[j - 2] + 1)
                }
            }
            (before, previous, current) = (previous, current, before)
        }
        return previous[b.count]
    }

    /// Lowercased, accents and width folded, dashes made plain (macOS writes "Wi‑Fi" with a non-breaking hyphen).
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "AppCleaner" → app, cleaner; "Visual Studio Code" → visual, studio, code; "iTerm2" → i, term2.
    static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if !(character.isLetter || character.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, let previous, previous.isLowercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map(normalize)
    }

    /// How many characters of `name` the letters of `query` span when found in order, starting at the start of a word
    /// and not spread over more than about twice their number ("sfr" → Safari, not "meet" → Game Center). Nil when
    /// they aren't.
    static func subsequenceSpread(_ query: String, _ name: String) -> Int? {
        let q = Array(query.filter { $0 != " " })
        guard !q.isEmpty else { return nil }
        let n = Array(name)
        var best: Int?
        for start in n.indices where n[start] == q[0] && (start == 0 || !(n[start - 1].isLetter || n[start - 1].isNumber)) {
            var position = start
            var matched = 1
            var index = start + 1
            while matched < q.count, index < n.count {
                if n[index] == q[matched] {
                    matched += 1
                    position = index
                }
                index += 1
            }
            if matched == q.count {
                let spread = position - start + 1
                if spread <= 2 * q.count { best = min(best ?? spread, spread) }
            }
        }
        return best
    }
}

// MARK: Apps and System Settings

/// The apps in the usual places and the panes of System Settings, read in about 100 ms.
public enum LaunchCatalog {
    static let appFolders = [
        "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
        "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications",
    ]
    /// Apps outside those folders that people open by name.
    static let extraApps = ["/System/Library/CoreServices/Finder.app"]
    static let settingsExtensions = "/System/Library/ExtensionKit/Extensions"

    public static func load() -> [LaunchItem] {
        var items: [LaunchItem] = []
        var seen: Set<String> = []
        var bundles: [URL] = []
        for folder in appFolders { bundles += apps(in: URL(fileURLWithPath: folder), depth: 3) }
        bundles += extraApps.map { URL(fileURLWithPath: $0) }
        for url in bundles {
            guard let item = app(at: url) else { continue }
            let key = Bundle(url: url)?.bundleIdentifier ?? url.path
            guard seen.insert(key).inserted else { continue }
            items.append(item)
        }
        items += settingsPanes()
        return items
    }

    /// .app bundles in a folder and its plain subfolders (Utilities, Setapp…), never inside another bundle.
    static func apps(in folder: URL, depth: Int) -> [URL] {
        // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink flagged hidden (Safari lives in a cryptex), and
        // Finder shows it anyway.
        guard depth > 0, let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var found: [URL] = []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            if entry.pathExtension == "app" {
                found.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !["bundle", "framework", "plugin", "appex"].contains(entry.pathExtension) {
                found += apps(in: entry, depth: depth - 1)
            }
        }
        return found
    }

    static func app(at url: URL) -> LaunchItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let display = FileManager.default.displayName(atPath: url.path)
        let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        var aliases: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let alias = info[key] as? String, alias != name, !aliases.contains(alias) { aliases.append(alias) }
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        if fileName != name, !aliases.contains(fileName) { aliases.append(fileName) }
        return LaunchItem(kind: .app, name: name, aliases: aliases, path: url.path, url: url,
                          lastUsed: lastUsed(url))
    }

    /// The panes System Settings shows, by their localized names, opened through x-apple.systempreferences.
    static func settingsPanes() -> [LaunchItem] {
        let folder = URL(fileURLWithPath: settingsExtensions)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        var panes: [LaunchItem] = []
        for url in entries where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  let info = bundle.infoDictionary,
                  let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                  attributes["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  (attributes["SettingsExtensionAttributes"] as? [String: Any])?["allowsXAppleSystemPreferencesURLScheme"]
                    as? Bool == true,
                  let paneURL = URL(string: "x-apple.systempreferences:\(identifier)") else { continue }
            let localized = bundle.localizedInfoDictionary ?? [:]
            var name = (localized["CFBundleDisplayName"] ?? localized["CFBundleName"]
                        ?? info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String ?? ""
            name = paneNames[name] ?? name
            // Panes that only show up with some hardware or setup carry their internal names: left out.
            guard !name.isEmpty, !name.hasSuffix("Extension"), !name.hasSuffix("Preferences"), name != "FollowUps"
            else { continue }
            panes.append(LaunchItem(kind: .setting, name: name, aliases: paneAliases[name] ?? [], path: url.path,
                                    url: paneURL))
        }
        return panes
    }

    /// Internal names whose pane goes by another one.
    static let paneNames = ["PowerPreferences": "Battery"]
    /// What people type for a pane that's named otherwise.
    static let paneAliases: [String: [String]] = [
        "Desktop & Dock": ["Dock", "Mission Control", "Hot Corners"], "Wallpaper": ["Background"],
        "Privacy & Security": ["Security", "Permissions", "FileVault"], "Displays": ["Monitor", "Resolution", "Night Shift"],
        "Keyboard": ["Shortcuts", "Input Sources"], "General": ["About"], "Battery": ["Energy", "Power"],
        "Lock Screen": ["Screen Saver"], "Users & Groups": ["Accounts"], "Network": ["Ethernet", "Firewall"],
    ]

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

// MARK: Files

/// Files and folders in the home folder by name, from the Spotlight index (no crawling of our own). Spotlight doesn't
/// rank, so this does: what you've opened before comes first, and build output, dependencies and hidden folders are
/// left out unless you've opened something there.
public enum SpotlightFiles {
    /// Path components that mean "made by a tool": thousands of files nobody looks for by name.
    static let noise: Set<String> = [
        "node_modules", ".git", ".build", "build", "DerivedData", "target", "Pods", "dist", "__pycache__", ".venv",
        "venv", "site-packages", "vendor", "Vendor", ".next", ".cache", "Caches", "tmp", ".Trash", "Library",
        "third_party", "third-party", "thirdparty", "external", "deps", "_deps", "bower_components", "coverage",
    ]

    public static func search(_ query: String, limit: Int = 40) -> [LaunchItem] {
        let words = Fuzzy.normalize(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let name = words.map { "kMDItemFSName == \"\(escape($0))*\"cdw" }.joined(separator: " && ")
        let notApps = "kMDItemContentType != \"com.apple.application-bundle\""
        // Opened before (few, and the ones you mean), then everything that matches (many, mostly noise).
        let used = run("\(name) && kMDItemLastUsedDate == \"*\" && \(notApps)", limit: 60)
        let all = run("\(name) && \(notApps)", limit: 200)
        var seen: Set<String> = []
        var items: [LaunchItem] = []
        for item in used + all where seen.insert(item.path).inserted {
            if item.lastUsed == nil, isNoise(item.path) { continue }
            items.append(item)
        }
        return Array(items.prefix(limit))
    }

    static func isNoise(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let relative = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        return relative.split(separator: "/").dropLast().contains { component in
            component.hasPrefix(".") || noise.contains(String(component)) || component.hasSuffix(".app")
        }
    }

    /// Spotlight's query language: a backslash before quotes, stars and backslashes.
    static func escape(_ word: String) -> String {
        var escaped = ""
        for character in word {
            if character == "\"" || character == "*" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// Type and last use are fetched with the query (kMDItemPath can't be): reading them item by item afterwards took
    /// 200+ ms for 300 results, this way ~1 ms (2026-10-13).
    static func run(_ text: String, limit: Int) -> [LaunchItem] {
        let attributes = [kMDItemContentType, kMDItemLastUsedDate] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, attributes, nil) else { return [] }
        // `$PASTEMIND_FILE_SCOPE` keeps a debug run's search to the folders it names (`RecentFiles.scopes`).
        let scope = ProcessInfo.processInfo.environment["PASTEMIND_FILE_SCOPE"] != nil
            ? RecentFiles.scopes.map(\.path) : [NSHomeDirectory()]
        MDQuerySetSearchScope(query, scope as CFArray, 0)
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        func value(_ attribute: CFString, _ index: Int) -> Any? {
            MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index).map {
                Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue()
            }
        }
        var items: [LaunchItem] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let isFolder = value(kMDItemContentType, index) as? String == "public.folder"
            let url = URL(fileURLWithPath: path, isDirectory: isFolder)
            let fileName = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            items.append(LaunchItem(kind: isFolder ? .folder : .file, name: fileName,
                                    aliases: stem != fileName ? [stem] : [], path: path, url: url,
                                    lastUsed: value(kMDItemLastUsedDate, index) as? Date))
        }
        return items
    }
}

// MARK: Ranking

/// What was typed: a leading ' or space, or "open " / "find ", searches files only; otherwise apps, panes and a few
/// files.
public struct LaunchQuery: Sendable, Equatable {
    public let text: String
    public let filesOnly: Bool

    public init(text: String, filesOnly: Bool) {
        self.text = text
        self.filesOnly = filesOnly
    }

    public init(_ typed: String) {
        let lower = typed.lowercased()
        if typed.hasPrefix("'") || typed.hasPrefix(" ") {
            text = typed.drop { $0 == "'" || $0 == " " }.trimmingCharacters(in: .whitespaces)
            filesOnly = true
        } else if let prefix = ["open ", "find "].first(where: { lower.hasPrefix($0) }) {
            text = String(typed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            filesOnly = true
        } else {
            text = typed.trimmingCharacters(in: .whitespaces)
            filesOnly = false
        }
    }
}

/// Puts apps, panes and files in one list: name match first, then what you opened from here before (the last one
/// picked for these letters first), then how recently you used it.
public enum LaunchRanker {
    static let kindWeight: [LaunchItem.Kind: Double] = [.app: 1, .setting: 0.93, .folder: 0.86, .file: 0.82]
    /// The last one picked for these letters: above any other match (Terminal picked often once, iTerm since).
    static let lastPickBonus = 0.6
    /// Nothing picked for these letters yet: the last one opened from here, if it starts the name or one of its words
    /// (iTerm for "ter", opened with "it"), above a better match.
    static let lastOpenedBonus = 0.3
    static let strongMatch = 0.75

    /// Files among apps and panes: only the few best, and only a good match or one you've opened.
    public static let filesAmongApps = 5

    /// Apps and panes with up to `filesAmongApps` files, or (for a files-only query) files alone.
    public static func merge(_ query: LaunchQuery, catalog: [LaunchItem], files: [LaunchItem],
                             history: LaunchHistory = LaunchHistory(), limit: Int = 30) -> [LaunchResult] {
        if query.filesOnly { return favorLastOpened(rank(query.text, items: files, history: history), history, limit) }
        let apps = rank(query.text, items: catalog, history: history)
        let strongFiles = rank(query.text, items: files, history: history)
            .filter { $0.score >= strongMatch || $0.item.lastUsed != nil || history.picks[$0.id] != nil }
            .prefix(filesAmongApps)
        return favorLastOpened(apps + strongFiles, history, limit)
    }

    /// A name matched well: what was meant is likely among them already (no need to ask the model).
    public static func hasStrongMatch(_ results: [LaunchResult]) -> Bool {
        results.contains { $0.match >= strongMatch }
    }

    /// Where files found by what's in them go: under the good name matches (a file's good name match scores 0.62 and
    /// up), above the weak ones.
    static let meaningScore = 0.6

    /// Files found by what's in them, best first, among the results; the ones already there by name stay as they are.
    public static func addMeaning(_ results: [LaunchResult], files: [LaunchItem], limit: Int = 30) -> [LaunchResult] {
        let present = Set(results.map(\.id))
        let added = files.filter { !present.contains($0.id) }.enumerated().map { offset, item in
            LaunchResult(item: item, score: meaningScore - 0.001 * Double(offset), match: 0, byContent: true)
        }
        return sorted(results + added, limit)
    }

    /// An action at the end of the results (search offering to find files by what's in them).
    public static func addAction(_ results: [LaunchResult], _ item: LaunchItem) -> [LaunchResult] {
        results + [LaunchResult(item: item, score: 0, match: 0)]
    }

    /// Ranked by the name, what was picked for these letters, and use; `merge` adds the last one opened.
    public static func rank(_ query: String, items: [LaunchItem], history: LaunchHistory = LaunchHistory(),
                            limit: Int = 30, now: Date = Date()) -> [LaunchResult] {
        let lastPick = history.picks.max { $0.value.last < $1.value.last }?.key
        var results: [LaunchResult] = []
        for item in items {
            let match = ([item.name] + item.aliases).map { Fuzzy.score(query, $0) }.max() ?? 0
            guard match >= 0.3 else { continue }
            var score = match * (kindWeight[item.kind] ?? 1)
            if let pick = history.picks[item.id], pick.count > 0 {
                score += min(0.3, 0.15 * log2(1 + Double(pick.count)))
                if item.id == lastPick { score += lastPickBonus }
            }
            if let lastUsed = item.lastUsed {
                score += 0.08 * exp(-max(now.timeIntervalSince(lastUsed), 0) / (14 * 86_400))
            }
            if (item.kind == .file || item.kind == .folder), item.lastUsed == nil {
                // Deep down in folders, and never opened: less likely the one you mean.
                score -= min(0.12, 0.012 * Double(max(item.path.split(separator: "/").count - 3, 0)))
            }
            results.append(LaunchResult(item: item, score: score, match: match))
        }
        return sorted(results, limit)
    }

    /// With nothing picked for these letters yet, the one last opened among the good matches goes up.
    static func favorLastOpened(_ results: [LaunchResult], _ history: LaunchHistory, _ limit: Int) -> [LaunchResult] {
        var results = results
        let picked = results.contains { history.picks[$0.id] != nil }
        let last = results.indices
            .filter { results[$0].match >= strongMatch && history.opened[results[$0].id] != nil }
            .max { history.opened[results[$0].id]! < history.opened[results[$1].id]! }
        if !picked, let last { results[last].score += lastOpenedBonus }
        return sorted(results, limit)
    }

    private static func sorted(_ results: [LaunchResult], _ limit: Int) -> [LaunchResult] {
        let sorted = results.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.item.name.count < $1.item.name.count
        }
        return Array(sorted.prefix(limit))
    }
}
