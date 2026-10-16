import Foundation
import SQLite3   // the system's

/// The store's SQLite connection, used from one thread. Each SQL text is compiled the first time it runs and kept for
/// the next; a query binds its values in order, hands the caller each result row, and resets the statement.
public final class Database {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private let connection: OpaquePointer
    private var compiled: [String: OpaquePointer] = [:]

    public init(path: String) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard let opened else { throw Failure(description: "can't open \(path) (SQLite \(status))") }
        guard status == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(opened))
            sqlite3_close_v2(opened)
            throw Failure(description: "can't open \(path): \(reason)")
        }
        connection = opened
        sqlite3_busy_timeout(connection, 3000)
        // Write-ahead logging: reading never waits for a write; NORMAL sync is durable enough for a clipboard history.
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA temp_store = MEMORY;")
    }

    deinit {
        for statement in compiled.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(connection)
    }

    /// SQL with nothing to bind and no rows to read, several statements at once (the schema, pragmas).
    public func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure(in: sql) }
    }

    /// `sql` with `values` bound to its `?`s in order; `row` is called for each result row.
    public func query(_ sql: String, _ values: [SQLValue] = [], row: (Row) throws -> Void = { _ in }) throws {
        let statement = try statement(for: sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            guard value.bind(to: statement, at: Int32(offset + 1)) == SQLITE_OK else { throw failure(in: sql) }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw failure(in: sql)
            }
        }
    }

    /// `sql` for its effect.
    public func run(_ sql: String, _ values: [SQLValue] = []) throws {
        try query(sql, values)
    }

    /// `body`'s statements all at once, or (when it throws) none of them.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        let result: T
        do {
            result = try body()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        try execute("COMMIT")
        return result
    }

    /// The row id the last INSERT made.
    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(connection) }

    /// How many rows the last statement changed.
    public var changes: Int { Int(sqlite3_changes(connection)) }

    private func statement(for sql: String) throws -> OpaquePointer {
        if let ready = compiled[sql] { return ready }
        var made: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &made, nil) == SQLITE_OK, let made else { throw failure(in: sql) }
        compiled[sql] = made
        return made
    }

    private func failure(in sql: String) -> Failure {
        Failure(description: "\(String(cString: sqlite3_errmsg(connection))) (in: \(sql.prefix(120)))")
    }
}

/// A value bound to a statement's `?`.
public enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null

    static func optional(_ text: String?) -> SQLValue { text.map(SQLValue.text) ?? .null }
    static func optional(_ data: Data?) -> SQLValue { data.map(SQLValue.blob) ?? .null }
    static func optional(_ number: Int?) -> SQLValue { number.map { .int(Int64($0)) } ?? .null }

    /// SQLite's status. Text and blobs are copied by SQLite (SQLITE_TRANSIENT): Swift's buffers needn't outlive the call.
    fileprivate func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch self {
        case .int(let number): return sqlite3_bind_int64(statement, index, number)
        case .double(let number): return sqlite3_bind_double(statement, index, number)
        case .text(let text): return sqlite3_bind_text(statement, index, text, -1, copy)
        case .blob(let data):
            return data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), copy)
            }
        case .null: return sqlite3_bind_null(statement, index)
        }
    }
}

/// One result row, readable only inside the `query` callback that's handed it. Columns count from 0.
public struct Row {
    fileprivate let statement: OpaquePointer

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    public func text(_ column: Int32) -> String? {
        guard let characters = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: characters)
    }

    /// The bytes first, then their count (SQLite's order: asking for the count first can give a stale one).
    public func blob(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
