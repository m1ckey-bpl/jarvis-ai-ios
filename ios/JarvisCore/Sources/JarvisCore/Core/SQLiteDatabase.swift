import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

/// A value that can be bound to / read from a SQLite statement.
public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .text(let s): return Double(s)
        default: return nil
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, safe wrapper over the SQLite C API.
///
/// Deliberately dependency-free (decision D7): works identically on iOS (system
/// libsqlite3) and Linux (system libsqlite3 via the `CSQLite` shim), which is what
/// makes the memory engine unit-testable off-device.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "ai.jarvis.sqlite")
    public let path: String

    /// True when this build of SQLite supports FTS5 (full-text search).
    public private(set) var supportsFTS5 = false

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var flags: Int32 = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        flags |= SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(handle)
            handle = nil
            throw JarvisError.storage("cannot open database at \(path): \(msg)")
        }
        sqlite3_busy_timeout(handle, 4_000)
        try execute("PRAGMA foreign_keys = ON;")
        if !readOnly {
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
        }
        supportsFTS5 = SQLiteDatabase.probeFTS5(handle)
    }

    /// Detects FTS5 support at runtime so retrieval can degrade to LIKE matching
    /// instead of failing on a SQLite build compiled without FTS5.
    private static func probeFTS5(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        let sql = "CREATE VIRTUAL TABLE IF NOT EXISTS temp.__fts_probe USING fts5(x);"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        let step = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        sqlite3_exec(handle, "DROP TABLE IF EXISTS temp.__fts_probe;", nil, nil, nil)
        return step == SQLITE_DONE
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: Execution

    public func execute(_ sql: String) throws {
        try queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "sqlite error \(rc)"
                sqlite3_free(err)
                throw JarvisError.storage("\(message) [sql: \(sql.prefix(120))]")
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try queue.sync {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, params)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw stepError(rc) }
            return Int(sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try queue.sync {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, params)
            var rows: [[String: SQLValue]] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw stepError(rc) }
                var row: [String: SQLValue] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    row[name] = columnValue(stmt, i)
                }
                rows.append(row)
            }
            return rows
        }
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        try query(sql, params).first?.values.first?.int ?? 0
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: Internals

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw JarvisError.storage("\(msg) [sql: \(sql.prefix(120))]")
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue]) throws {
        for (index, value) in params.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, i)
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .double(let v): sqlite3_bind_double(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
    }

    private func columnValue(_ stmt: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, i))
            guard count > 0, let ptr = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
            return .blob(Data(bytes: ptr, count: count))
        default: return .null
        }
    }

    private func stepError(_ rc: Int32) -> JarvisError {
        let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed"
        if rc == SQLITE_BUSY { return .storage("database busy: \(msg)") }
        return .storage(msg)
    }
}

/// Ordered, idempotent schema migrations.
public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let statements: [String]
    public init(version: Int, name: String, statements: [String]) {
        self.version = version; self.name = name; self.statements = statements
    }
}

public enum Migrator {
    /// Applies only the migrations newer than the stored `PRAGMA user_version`.
    public static func migrate(_ db: SQLiteDatabase, migrations: [Migration]) throws {
        let current = Int(try db.scalarInt("PRAGMA user_version;"))
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            try db.transaction {
                for statement in migration.statements { try db.execute(statement) }
                try db.execute("PRAGMA user_version = \(migration.version);")
            }
            JarvisLog.shared.info("storage", "migrated to v\(migration.version) (\(migration.name))")
        }
    }
}
