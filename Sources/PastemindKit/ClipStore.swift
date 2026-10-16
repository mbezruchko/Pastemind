import Foundation

/// The history on disk: one SQLite file, a row per clip with its vector (768 × float16) once it has one. Pictures are
/// files in `AppPaths.images`. Used from one thread.
public final class ClipStore {
    let db: Database

    public init(path: URL = AppPaths.database) throws {
        db = try Database(path: path.path)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS clips(
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                hash TEXT NOT NULL UNIQUE,
                app_id TEXT,
                app_name TEXT,
                first_copied REAL NOT NULL,
                last_copied REAL NOT NULL,
                copies INTEGER NOT NULL DEFAULT 1,
                pinned INTEGER NOT NULL DEFAULT 0,
                image TEXT,
                width INTEGER,
                height INTEGER,
                rich BLOB,
                rich_type TEXT,
                vector BLOB,
                vector_version INTEGER
            );
            CREATE INDEX IF NOT EXISTS clips_last ON clips(last_copied);
            CREATE TABLE IF NOT EXISTS launches(
                query TEXT NOT NULL,
                item TEXT NOT NULL,
                count INTEGER NOT NULL DEFAULT 0,
                last REAL NOT NULL,
                PRIMARY KEY(query, item)
            );
            """)
        // A store from before screenshots stopped being told apart keeps its "screenshot" column, unread. The
        // pictures' sizes came later: NULL until looked at.
        var columns: Set<String> = []
        try db.query("PRAGMA table_info(clips)") { if let name = $0.text(1) { columns.insert(name) } }
        if !columns.contains("bytes") { try db.execute("ALTER TABLE clips ADD COLUMN bytes INTEGER") }
        // Pictures' and files' vectors came from their text and names alone until the encoders: made again from what's in them.
        if !columns.contains("content_vector") {
            try db.execute("ALTER TABLE clips ADD COLUMN content_vector INTEGER NOT NULL DEFAULT 0")
        }
        // Several copied files: a vector of each too, besides the one of them all (float16s, one after another).
        if !columns.contains("parts") {
            try db.execute("ALTER TABLE clips ADD COLUMN parts BLOB; ALTER TABLE clips ADD COLUMN parts_version INTEGER;")
        }
        // Recent files search reads by what's in them (`FileIndexer`): a vector, or none when nothing in one reads.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                modified REAL NOT NULL,
                used REAL,
                vector BLOB,
                vector_version INTEGER
            );
            """)
        // A long document's pieces' vectors (`CopiedFiles.pieces`), shortened as `FileIndex` keeps them; their version
        // NULL until they're read (documents read before pieces are read again).
        var fileColumns: Set<String> = []
        try db.query("PRAGMA table_info(files)") { if let name = $0.text(1) { fileColumns.insert(name) } }
        if !fileColumns.contains("parts") {
            try db.execute("ALTER TABLE files ADD COLUMN parts BLOB; ALTER TABLE files ADD COLUMN parts_version INTEGER;")
        }
        // What the reader read them by (`CopiedFiles.readerVersion`): NULL, before scans were read by OCR.
        if !fileColumns.contains("reader") { try db.execute("ALTER TABLE files ADD COLUMN reader INTEGER") }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS snippets(
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                text TEXT NOT NULL,
                created REAL NOT NULL,
                last_used REAL,
                uses INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS snippet_folders(
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                created REAL NOT NULL
            );
            """)
        // Folders came later: snippets from before are in none.
        var snippetColumns: Set<String> = []
        try db.query("PRAGMA table_info(snippets)") { if let name = $0.text(1) { snippetColumns.insert(name) } }
        if !snippetColumns.contains("folder") { try db.execute("ALTER TABLE snippets ADD COLUMN folder INTEGER") }
        // Their order came later, dragged by hand: until then the snippets used last came first (then the newest),
        // the folders by name. Kept so, as their first order.
        if !snippetColumns.contains("position") {
            try db.execute("ALTER TABLE snippets ADD COLUMN position REAL NOT NULL DEFAULT 0")
            var ids: [Int64] = []
            try db.query("SELECT id FROM snippets ORDER BY COALESCE(last_used, 0) DESC, created DESC") { ids.append($0.int(0)) }
            try db.transaction {
                for (index, id) in ids.enumerated() {
                    try db.run("UPDATE snippets SET position = ? WHERE id = ?", [.double(Double(index)), .int(id)])
                }
            }
        }
        var folderColumns: Set<String> = []
        try db.query("PRAGMA table_info(snippet_folders)") { if let name = $0.text(1) { folderColumns.insert(name) } }
        if !folderColumns.contains("position") {
            try db.execute("ALTER TABLE snippet_folders ADD COLUMN position REAL NOT NULL DEFAULT 0")
            var folders: [(Int64, String)] = []
            try db.query("SELECT id, name FROM snippet_folders") { folders.append(($0.int(0), $0.text(1) ?? "")) }
            let byName = folders.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            try db.transaction {
                for (index, folder) in byName.enumerated() {
                    try db.run("UPDATE snippet_folders SET position = ? WHERE id = ?", [.double(Double(index)), .int(folder.0)])
                }
            }
        }
    }

    private static let columns = """
        id, kind, text, app_id, app_name, first_copied, last_copied, copies, pinned, image, width, height, rich_type,
        vector IS NOT NULL AND vector_version = \(ModelFiles.vectorVersion), bytes, content_vector
        """

    private func clip(_ row: Row) -> Clip {
        Clip(id: row.int(0), kind: ClipKind(rawValue: row.text(1) ?? "") ?? .text, text: row.text(2) ?? "",
             appID: row.text(3), appName: row.text(4),
             firstCopied: Date(timeIntervalSince1970: row.double(5)),
             lastCopied: Date(timeIntervalSince1970: row.double(6)),
             copies: Int(row.int(7)), pinned: row.int(8) != 0, image: row.text(9),
             width: row.isNull(10) ? nil : Int(row.int(10)), height: row.isNull(11) ? nil : Int(row.int(11)),
             bytes: row.isNull(14) ? nil : Int(row.int(14)), richType: row.text(12), embedded: row.int(13) != 0,
             contentVector: row.int(13) != 0 && row.int(15) != 0)
    }

    /// Every clip, the most recently copied first.
    public func all() throws -> [Clip] {
        var clips: [Clip] = []
        try db.query("SELECT \(Self.columns) FROM clips ORDER BY last_copied DESC") { clips.append(clip($0)) }
        return clips
    }

    public func clip(id: Int64) throws -> Clip? {
        var found: Clip?
        try db.query("SELECT \(Self.columns) FROM clips WHERE id = ?", [.int(id)]) { found = clip($0) }
        return found
    }

    /// Vectors made by the current model and prompts.
    public func vectors() throws -> [(id: Int64, vector: [Float])] {
        var rows: [(Int64, [Float])] = []
        try db.query("SELECT id, vector FROM clips WHERE vector IS NOT NULL AND vector_version = ?",
                     [.int(Int64(ModelFiles.vectorVersion))]) { row in
            guard let data = row.blob(1), data.count == ModelFiles.dimension * 2 else { return }
            rows.append((row.int(0), Self.floats(data)))
        }
        return rows
    }

    /// Each copied file's vector, for clips of several files, or a long document's pieces' (none: it has none), made
    /// by the current model and prompts.
    public func parts() throws -> [(id: Int64, parts: [[Float]])] {
        var rows: [(Int64, [[Float]])] = []
        let size = ModelFiles.dimension * 2
        try db.query("SELECT id, parts FROM clips WHERE parts_version = ?", [.int(Int64(ModelFiles.vectorVersion))]) { row in
            let data = row.blob(1) ?? Data()
            guard data.count % size == 0 else { return }
            rows.append((row.int(0), Self.vectors(in: data, size: size)))
        }
        return rows
    }

    private static func vectors(in data: Data, size: Int) -> [[Float]] {
        stride(from: 0, to: data.count, by: size).map { Self.floats(Data(data[$0..<($0 + size)])) }
    }

    public func setParts(id: Int64, _ parts: [[Float]]) throws {
        try db.run("UPDATE clips SET parts = ?, parts_version = ? WHERE id = ?",
                   [.blob(parts.map(Self.halves).reduce(Data(), +)), .int(Int64(ModelFiles.vectorVersion)), .int(id)])
    }

    public struct Recorded: Sendable {
        public let clip: Clip
        public let isNew: Bool
    }

    /// A copy: a new clip, or the one with the same content moved to the top.
    @discardableResult
    public func record(kind: ClipKind, text: String, hash: String, appID: String?, appName: String?,
                       image: String? = nil, width: Int? = nil, height: Int? = nil, bytes: Int? = nil,
                       rich: Data? = nil, richType: String? = nil, at date: Date = Date()) throws -> Recorded {
        try db.transaction {
            var existing: Int64?
            try db.query("SELECT id FROM clips WHERE hash = ?", [.text(hash)]) { existing = $0.int(0) }
            if let id = existing {
                try db.run("""
                    UPDATE clips SET last_copied = ?, copies = copies + 1, app_id = coalesce(?, app_id),
                    app_name = coalesce(?, app_name), rich = coalesce(?, rich), rich_type = coalesce(?, rich_type)
                    WHERE id = ?
                    """, [.double(date.timeIntervalSince1970), .optional(appID), .optional(appName), .optional(rich),
                          .optional(richType), .int(id)])
                return Recorded(clip: try clip(id: id)!, isNew: false)
            }
            try db.run("""
                INSERT INTO clips(kind, text, hash, app_id, app_name, first_copied, last_copied, image, width, height,
                bytes, rich, rich_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(kind.rawValue), .text(text), .text(hash), .optional(appID), .optional(appName),
                      .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970), .optional(image),
                      .optional(width), .optional(height), .optional(bytes), .optional(rich), .optional(richType)])
            return Recorded(clip: try clip(id: db.lastInsertID)!, isNew: true)
        }
    }

    /// Pasted from Pastemind: it goes to the top, as if copied again.
    public func touch(id: Int64, at date: Date = Date()) throws {
        try db.run("UPDATE clips SET last_copied = ?, copies = copies + 1 WHERE id = ?",
                   [.double(date.timeIntervalSince1970), .int(id)])
    }

    /// An image's text, once Vision has read it. Its vector goes: it's made with the text.
    public func setText(id: Int64, text: String) throws {
        try db.run("UPDATE clips SET text = ?, vector = NULL, content_vector = 0 WHERE id = ?", [.text(text), .int(id)])
    }

    /// `fromContent`: made from what's in it (the picture, the files' contents), not only its text or names.
    public func setVector(id: Int64, vector: [Float], fromContent: Bool = false) throws {
        try db.run("UPDATE clips SET vector = ?, vector_version = ?, content_vector = ? WHERE id = ?",
                   [.blob(Self.halves(vector)), .int(Int64(ModelFiles.vectorVersion)), .int(fromContent ? 1 : 0),
                    .int(id)])
    }

    // MARK: Recent files

    /// Every recent file read so far, with its vector (nil: nothing in it read, or made by another model or prompt,
    /// `current` false then: read again), its pieces' (`piecesRead` false: not read yet, or by another model), and the
    /// reader's version that read it (`CopiedFiles.readAgain`).
    public func indexedFiles() throws -> [(file: IndexedFile, vector: [Float]?, current: Bool, pieces: [[Float]],
                                          piecesRead: Bool, reader: Int)] {
        var rows: [(IndexedFile, [Float]?, Bool, [[Float]], Bool, Int)] = []
        let version = Int64(ModelFiles.vectorVersion)
        let size = FileIndex.dimension * 2
        try db.query("SELECT id, path, modified, used, vector, vector_version, parts, parts_version, reader FROM files") { row in
            let file = IndexedFile(id: row.int(0), path: row.text(1) ?? "", modified: Date(timeIntervalSince1970: row.double(2)),
                                   lastUsed: row.isNull(3) ? nil : Date(timeIntervalSince1970: row.double(3)))
            let current = row.isNull(5) || row.int(5) == version
            let vector = row.blob(4).flatMap { $0.count == ModelFiles.dimension * 2 ? Self.floats($0) : nil }
            let piecesRead = !row.isNull(7) && row.int(7) == version
            let data = piecesRead ? row.blob(6) ?? Data() : Data()
            let pieces = data.count % size == 0 ? Self.vectors(in: data, size: size) : []
            rows.append((file, current ? vector : nil, current, pieces, piecesRead, row.isNull(8) ? 1 : Int(row.int(8))))
        }
        return rows
    }

    /// A recent file as read: its vector, or nil when nothing in it reads (it isn't read again till it changes), and
    /// its pieces' (nil: they're still to come).
    @discardableResult
    public func saveFile(path: String, modified: Date, used: Date?, vector: [Float]?,
                         pieces: [[Float]]? = []) throws -> IndexedFile {
        let version = Int64(ModelFiles.vectorVersion)
        let parts = pieces.map { $0.map { Self.halves(FileIndex.shortened($0)) }.reduce(Data(), +) }
        try db.run("""
            INSERT INTO files(path, modified, used, vector, vector_version, parts, parts_version, reader)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET modified = excluded.modified, used = excluded.used, vector = excluded.vector,
            vector_version = excluded.vector_version, parts = excluded.parts, parts_version = excluded.parts_version,
            reader = excluded.reader
            """, [.text(path), .double(modified.timeIntervalSince1970), used.map { .double($0.timeIntervalSince1970) } ?? .null,
                  vector.map { .blob(Self.halves($0)) } ?? .null, .int(version),
                  parts.flatMap { $0.isEmpty ? nil : .blob($0) } ?? .null, pieces == nil ? .null : .int(version),
                  .int(Int64(CopiedFiles.readerVersion))])
        var id: Int64 = 0
        try db.query("SELECT id FROM files WHERE path = ?", [.text(path)]) { id = $0.int(0) }
        return IndexedFile(id: id, path: path, modified: modified, lastUsed: used)
    }

    /// Files no longer recent, or gone.
    public func deleteFiles(ids: [Int64]) throws {
        try db.transaction {
            for id in ids { try db.run("DELETE FROM files WHERE id = ?", [.int(id)]) }
        }
    }

    /// Pictures saved before their sizes were kept, to measure once.
    public func imagesWithoutBytes() throws -> [(id: Int64, image: String)] {
        var rows: [(Int64, String)] = []
        try db.query("SELECT id, image FROM clips WHERE image IS NOT NULL AND bytes IS NULL") { row in
            if let image = row.text(1) { rows.append((row.int(0), image)) }
        }
        return rows
    }

    public func setBytes(id: Int64, _ bytes: Int) throws {
        try db.run("UPDATE clips SET bytes = ? WHERE id = ?", [.int(Int64(bytes)), .int(id)])
    }

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try db.run("UPDATE clips SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .int(id)])
    }

    /// The rich version (RTF or HTML) and its pasteboard type, for pasting with formatting.
    public func rich(id: Int64) throws -> (data: Data, type: String)? {
        var found: (Data, String)?
        try db.query("SELECT rich, rich_type FROM clips WHERE id = ? AND rich IS NOT NULL", [.int(id)]) { row in
            if let data = row.blob(0), let type = row.text(1) { found = (data, type) }
        }
        return found
    }

    /// Deletes clips; returns the picture files that belonged to them, for the caller to remove.
    @discardableResult
    public func delete(ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        var images: [String] = []
        try db.transaction {
            for id in ids {
                try db.query("SELECT image FROM clips WHERE id = ?", [.int(id)]) { row in
                    if let image = row.text(0) { images.append(image) }
                }
                try db.run("DELETE FROM clips WHERE id = ?", [.int(id)])
            }
        }
        return images
    }

    /// Unpinned clips last copied before `date`, or beyond the newest `keep`: the history's limits.
    public func expired(before date: Date, keep: Int) throws -> [Int64] {
        var ids: [Int64] = []
        try db.query("""
            SELECT id FROM clips WHERE pinned = 0 AND (last_copied < ? OR id NOT IN
                (SELECT id FROM clips ORDER BY last_copied DESC LIMIT ?))
            """, [.double(date.timeIntervalSince1970), .int(Int64(keep))]) { ids.append($0.int(0)) }
        return ids
    }

    public func deleteAll(keepPinned: Bool) throws -> [String] {
        var images: [String] = []
        try db.query("SELECT image FROM clips WHERE image IS NOT NULL" + (keepPinned ? " AND pinned = 0" : "")) {
            if let image = $0.text(0) { images.append(image) }
        }
        try db.run("DELETE FROM clips" + (keepPinned ? " WHERE pinned = 0" : ""))
        return images
    }

    // MARK: Launcher learning

    /// The launcher opened `item` after `query` was typed: it counts for every prefix of the query too, so "s", "sa"
    /// and "saf" all learn that Safari is the one.
    public func recordLaunch(query: String, item: String, at date: Date = Date()) throws {
        let typed = Fuzzy.normalize(query)
        guard !typed.isEmpty else { return }
        try db.transaction {
            for length in 1...min(typed.count, 24) {
                try db.run("""
                    INSERT INTO launches(query, item, count, last) VALUES (?, ?, 1, ?)
                    ON CONFLICT(query, item) DO UPDATE SET count = count + 1, last = excluded.last
                    """, [.text(String(typed.prefix(length))), .text(item), .double(date.timeIntervalSince1970)])
            }
        }
    }

    /// How often, and when last, each item was opened after typing exactly this.
    public func picks(for query: String) throws -> [String: LaunchHistory.Pick] {
        var picks: [String: LaunchHistory.Pick] = [:]
        try db.query("SELECT item, count, last FROM launches WHERE query = ?", [.text(Fuzzy.normalize(query))]) { row in
            if let item = row.text(0) {
                picks[item] = LaunchHistory.Pick(count: Int(row.int(1)), last: Date(timeIntervalSince1970: row.double(2)))
            }
        }
        return picks
    }

    /// When each item was last opened from the launcher, whatever was typed.
    public func lastOpened() throws -> [String: Date] {
        var opened: [String: Date] = [:]
        try db.query("SELECT item, MAX(last) FROM launches GROUP BY item") { row in
            if let item = row.text(0) { opened[item] = Date(timeIntervalSince1970: row.double(1)) }
        }
        return opened
    }

    // MARK: Vectors as float16

    static func halves(_ vector: [Float]) -> Data {
        vector.map { Float16($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map { Float($0) } }
    }
}
