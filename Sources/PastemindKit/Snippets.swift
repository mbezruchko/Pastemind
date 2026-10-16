import Foundation

/// Text kept to paste again and again (an address, an email, a reply): named, edited by hand, out of the history's
/// way. Pasting one doesn't add it to the history.
public struct Snippet: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var title: String
    public var text: String
    public var created: Date
    public var lastUsed: Date?
    public var uses: Int
    /// The folder it's in; nil: at the top, with the folders.
    public var folder: Int64?
    /// Where it is among the snippets beside it (lower first), as dragged there; a new one goes first.
    public var position: Double

    public init(id: Int64, title: String, text: String, created: Date = Date(), lastUsed: Date? = nil, uses: Int = 0,
                folder: Int64? = nil, position: Double = 0) {
        self.id = id
        self.title = title
        self.text = text
        self.created = created
        self.lastUsed = lastUsed
        self.uses = uses
        self.folder = folder
        self.position = position
    }

    /// What a snippet made from a clip is called: its first line, cut short.
    public static func title(for text: String) -> String {
        let line = Clip.firstLine(of: text)
        return line.count > 48 ? String(line.prefix(47)) + "…" : (line.isEmpty ? "Snippet" : line)
    }

    /// In the order they were put in (dragged there; the newest first otherwise).
    static func ordered(_ snippets: [Snippet]) -> [Snippet] {
        snippets.sorted { ($0.position, $1.created) < ($1.position, $0.created) }
    }

    /// The snippets matching `query`, best first: the words in the title (at its start best), then in the text. With
    /// no query, all of them, in their order.
    public static func search(_ query: String, in snippets: [Snippet]) -> [Snippet] {
        let words = Fuzzy.normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ordered(snippets) }
        let scored = snippets.compactMap { snippet -> (Snippet, Int)? in
            let title = Fuzzy.normalize(snippet.title)
            let text = Fuzzy.normalize(snippet.text)
            var score = 0
            for word in words {
                if title.hasPrefix(word) {
                    score += 4
                } else if title.contains(" " + word) {
                    score += 3
                } else if title.contains(word) {
                    score += 2
                } else if text.contains(word) {
                    score += 1
                } else {
                    return nil   // every word somewhere
                }
            }
            return (snippet, score)
        }
        return scored.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.position < b.0.position }.map(\.0)
    }

    /// The snippets list for `query` in `folder`. At the top (nil) the folders, in their order, then the snippets in
    /// none; typed, the folders so named and the matching snippets of every folder. In a folder, its snippets alone.
    public static func rows(_ query: String, in folder: Int64?, snippets: [Snippet],
                            folders: [SnippetFolder]) -> [SnippetRow] {
        if let folder { return search(query, in: snippets.filter { $0.folder == folder }).map(SnippetRow.snippet) }
        let words = Fuzzy.normalize(query).split(separator: " ").map(String.init)
        let named = folders
            .filter { folder in words.allSatisfy { Fuzzy.normalize(folder.name).contains($0) } }
            .sorted { $0.position != $1.position ? $0.position < $1.position
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { folder in SnippetRow.folder(folder, count: snippets.filter { $0.folder == folder.id }.count) }
        let shown = words.isEmpty ? snippets.filter { $0.folder == nil } : snippets
        return named + search(query, in: shown).map(SnippetRow.snippet)
    }
}

/// Snippets kept together under a name (one level: no folders in folders).
public struct SnippetFolder: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var name: String
    public var created: Date
    /// Where it is among the folders (lower first), as dragged there; a new one goes first.
    public var position: Double

    public init(id: Int64, name: String, created: Date = Date(), position: Double = 0) {
        self.id = id
        self.name = name
        self.created = created
        self.position = position
    }
}

/// A row of the snippets list: a folder (↩ opens it), or a snippet.
public enum SnippetRow: Identifiable, Hashable, Sendable {
    case folder(SnippetFolder, count: Int)
    case snippet(Snippet)

    public enum ID: Hashable, Sendable {
        case folder(Int64)
        case snippet(Int64)
    }

    public var id: ID {
        switch self {
        case .folder(let folder, _): .folder(folder.id)
        case .snippet(let snippet): .snippet(snippet.id)
        }
    }

    public var snippet: Snippet? {
        if case .snippet(let snippet) = self { snippet } else { nil }
    }

    public var folder: SnippetFolder? {
        if case .folder(let folder, _) = self { folder } else { nil }
    }
}

extension ClipStore {
    public func snippets() throws -> [Snippet] {
        var snippets: [Snippet] = []
        try db.query("SELECT id, title, text, created, last_used, uses, folder, position FROM snippets") { row in
            snippets.append(Snippet(id: row.int(0), title: row.text(1) ?? "", text: row.text(2) ?? "",
                                    created: Date(timeIntervalSince1970: row.double(3)),
                                    lastUsed: row.isNull(4) ? nil : Date(timeIntervalSince1970: row.double(4)),
                                    uses: Int(row.int(5)), folder: row.isNull(6) ? nil : row.int(6),
                                    position: row.double(7)))
        }
        return snippets
    }

    /// First wherever it goes: before every snippet there is.
    @discardableResult
    public func addSnippet(title: String, text: String, folder: Int64? = nil, at date: Date = Date()) throws -> Snippet {
        let position = try firstPosition(in: "snippets")
        try db.run("INSERT INTO snippets(title, text, created, folder, position) VALUES (?, ?, ?, ?, ?)",
                   [.text(title), .text(text), .double(date.timeIntervalSince1970), folder.map { .int($0) } ?? .null,
                    .double(position)])
        return Snippet(id: db.lastInsertID, title: title, text: text, created: date, folder: folder, position: position)
    }

    public func updateSnippet(_ snippet: Snippet) throws {
        try db.run("UPDATE snippets SET title = ?, text = ?, folder = ?, position = ? WHERE id = ?",
                   [.text(snippet.title), .text(snippet.text), snippet.folder.map { .int($0) } ?? .null,
                    .double(snippet.position), .int(snippet.id)])
    }

    /// Dragged into a new order: these snippets (the ones side by side: a folder's, or the ones in none) in it.
    public func orderSnippets(_ ids: [Int64]) throws {
        try db.transaction {
            for (index, id) in ids.enumerated() {
                try db.run("UPDATE snippets SET position = ? WHERE id = ?", [.double(Double(index)), .int(id)])
            }
        }
    }

    /// Before everything in `table` now: where a new snippet or folder goes.
    private func firstPosition(in table: String) throws -> Double {
        var lowest = 0.0
        try db.query("SELECT MIN(position) FROM \(table)") { if !$0.isNull(0) { lowest = $0.double(0) } }
        return lowest - 1
    }

    public func snippetFolders() throws -> [SnippetFolder] {
        var folders: [SnippetFolder] = []
        try db.query("SELECT id, name, created, position FROM snippet_folders") { row in
            folders.append(SnippetFolder(id: row.int(0), name: row.text(1) ?? "",
                                         created: Date(timeIntervalSince1970: row.double(2)), position: row.double(3)))
        }
        return folders
    }

    /// First among the folders.
    @discardableResult
    public func addSnippetFolder(name: String, at date: Date = Date()) throws -> SnippetFolder {
        let position = try firstPosition(in: "snippet_folders")
        try db.run("INSERT INTO snippet_folders(name, created, position) VALUES (?, ?, ?)",
                   [.text(name), .double(date.timeIntervalSince1970), .double(position)])
        return SnippetFolder(id: db.lastInsertID, name: name, created: date, position: position)
    }

    /// Dragged into a new order: the folders in it.
    public func orderSnippetFolders(_ ids: [Int64]) throws {
        try db.transaction {
            for (index, id) in ids.enumerated() {
                try db.run("UPDATE snippet_folders SET position = ? WHERE id = ?", [.double(Double(index)), .int(id)])
            }
        }
    }

    public func renameSnippetFolder(id: Int64, name: String) throws {
        try db.run("UPDATE snippet_folders SET name = ? WHERE id = ?", [.text(name), .int(id)])
    }

    /// Its snippets stay, at the top.
    public func deleteSnippetFolder(id: Int64) throws {
        try db.transaction {
            try db.run("UPDATE snippets SET folder = NULL WHERE folder = ?", [.int(id)])
            try db.run("DELETE FROM snippet_folders WHERE id = ?", [.int(id)])
        }
    }

    /// Pasted: counted (it stays where it is in the list).
    public func useSnippet(id: Int64, at date: Date = Date()) throws {
        try db.run("UPDATE snippets SET last_used = ?, uses = uses + 1 WHERE id = ?",
                   [.double(date.timeIntervalSince1970), .int(id)])
    }

    public func deleteSnippet(id: Int64) throws {
        try db.run("DELETE FROM snippets WHERE id = ?", [.int(id)])
    }
}
