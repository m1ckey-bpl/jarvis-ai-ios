import Foundation

/// Query filter for listing/searching memories.
public struct MemoryQuery: Sendable {
    public var kinds: [MemoryKind]
    public var statuses: [MemoryStatus]
    public var subject: String?
    public var tags: [String]
    public var createdAfter: Date?
    public var createdBefore: Date?
    public var textContains: String?
    public var limit: Int

    public init(
        kinds: [MemoryKind] = [],
        statuses: [MemoryStatus] = [.active],
        subject: String? = nil,
        tags: [String] = [],
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        textContains: String? = nil,
        limit: Int = 200
    ) {
        self.kinds = kinds
        self.statuses = statuses
        self.subject = subject
        self.tags = tags
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.textContains = textContains
        self.limit = limit
    }
}

/// Persistence contract for the runtime memory system.
public protocol MemoryStore: AnyObject {
    func upsert(_ record: MemoryRecord) throws
    func record(id: String) throws -> MemoryRecord?
    func records(matching query: MemoryQuery) throws -> [MemoryRecord]
    /// Full-text candidate search. Returns (record, keywordScore 0…1).
    func keywordSearch(_ text: String, limit: Int) throws -> [(record: MemoryRecord, score: Double)]
    func delete(id: String) throws
    func deleteAll() throws
    func touch(ids: [String], at date: Date) throws
    func count(statuses: [MemoryStatus]) throws -> Int
}

/// SQLite-backed memory store with FTS5 (BM25) search and a LIKE fallback.
public final class SQLiteMemoryStore: MemoryStore {
    private let db: SQLiteDatabase
    private let fts: Bool

    public init(path: String) throws {
        self.db = try SQLiteDatabase(path: path)
        try Migrator.migrate(db, migrations: SQLiteMemoryStore.migrations)
        self.fts = db.supportsFTS5
        if !fts { JarvisLog.shared.warn("memory", "FTS5 unavailable — falling back to LIKE keyword matching") }
    }

    public static let migrations: [Migration] = [
        Migration(version: 1, name: "initial memory schema", statements: [
            """
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                subject TEXT,
                tags TEXT NOT NULL DEFAULT '',
                source TEXT NOT NULL,
                confidence REAL NOT NULL,
                importance REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_accessed_at REAL,
                access_count INTEGER NOT NULL DEFAULT 0,
                expires_at REAL,
                status TEXT NOT NULL,
                superseded_by TEXT,
                locked INTEGER NOT NULL DEFAULT 0,
                provenance TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_memories_kind ON memories(kind);",
            "CREATE INDEX IF NOT EXISTS idx_memories_status ON memories(status);",
            "CREATE INDEX IF NOT EXISTS idx_memories_subject ON memories(subject);",
            "CREATE INDEX IF NOT EXISTS idx_memories_updated ON memories(updated_at DESC);"
        ]),
        Migration(version: 2, name: "memory full-text index", statements: [
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
                text, subject, tags, content='memories', content_rowid='rowid', tokenize='porter unicode61'
            );
            """,
            """
            CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
                INSERT INTO memory_fts(rowid, text, subject, tags)
                VALUES (new.rowid, new.text, ifnull(new.subject,''), new.tags);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text, subject, tags)
                VALUES ('delete', old.rowid, old.text, ifnull(old.subject,''), old.tags);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text, subject, tags)
                VALUES ('delete', old.rowid, old.text, ifnull(old.subject,''), old.tags);
                INSERT INTO memory_fts(rowid, text, subject, tags)
                VALUES (new.rowid, new.text, ifnull(new.subject,''), new.tags);
            END;
            """
        ])
    ]

    // MARK: MemoryStore

    public func upsert(_ record: MemoryRecord) throws {
        // FTS triggers keep the index in sync; harmless when FTS5 is absent
        // (the virtual table simply does not exist and no trigger fires).
        try db.run(
            """
            INSERT INTO memories (id, kind, text, subject, tags, source, confidence, importance,
                                  created_at, updated_at, last_accessed_at, access_count, expires_at,
                                  status, superseded_by, locked, provenance)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                kind=excluded.kind, text=excluded.text, subject=excluded.subject, tags=excluded.tags,
                source=excluded.source, confidence=excluded.confidence, importance=excluded.importance,
                updated_at=excluded.updated_at, last_accessed_at=excluded.last_accessed_at,
                access_count=excluded.access_count, expires_at=excluded.expires_at, status=excluded.status,
                superseded_by=excluded.superseded_by, locked=excluded.locked, provenance=excluded.provenance
            """,
            [
                .text(record.id), .text(record.kind.rawValue), .text(record.text),
                record.subject.map { SQLValue.text($0) } ?? .null,
                .text(record.tags.joined(separator: ",")), .text(record.source.rawValue),
                .double(record.confidence), .double(record.importance),
                .double(record.createdAt.timeIntervalSince1970), .double(record.updatedAt.timeIntervalSince1970),
                record.lastAccessedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                .int(Int64(record.accessCount)),
                record.expiresAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                .text(record.status.rawValue),
                record.supersededBy.map { SQLValue.text($0) } ?? .null,
                .int(record.locked ? 1 : 0),
                record.provenance.flatMap { try? JSONEncoder.jarvis.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }.map { SQLValue.text($0) } ?? .null
            ]
        )
    }

    public func record(id: String) throws -> MemoryRecord? {
        try db.query("SELECT * FROM memories WHERE id = ? LIMIT 1;", [.text(id)]).first.flatMap(Self.decode)
    }

    public func records(matching query: MemoryQuery) throws -> [MemoryRecord] {
        var sql = "SELECT * FROM memories WHERE 1=1"
        var params: [SQLValue] = []
        if !query.statuses.isEmpty {
            let placeholders = Array(repeating: "?", count: query.statuses.count).joined(separator: ",")
            sql += " AND status IN (\(placeholders))"
            params.append(contentsOf: query.statuses.map { .text($0.rawValue) })
        }
        if !query.kinds.isEmpty {
            let placeholders = Array(repeating: "?", count: query.kinds.count).joined(separator: ",")
            sql += " AND kind IN (\(placeholders))"
            params.append(contentsOf: query.kinds.map { .text($0.rawValue) })
        }
        if let subject = query.subject { sql += " AND subject = ?"; params.append(.text(subject)) }
        for tag in query.tags { sql += " AND (',' || tags || ',') LIKE ?"; params.append(.text("%,\(tag),%")) }
        if let after = query.createdAfter { sql += " AND created_at >= ?"; params.append(.double(after.timeIntervalSince1970)) }
        if let before = query.createdBefore { sql += " AND created_at <= ?"; params.append(.double(before.timeIntervalSince1970)) }
        if let contains = query.textContains {
            sql += " AND (text LIKE ? OR ifnull(subject,'') LIKE ? OR tags LIKE ?)"
            let pattern = "%\(contains)%"
            params.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern)])
        }
        sql += " ORDER BY updated_at DESC LIMIT ?"
        params.append(.int(Int64(max(1, query.limit))))
        return try db.query(sql, params).compactMap(Self.decode)
    }

    public func keywordSearch(_ text: String, limit: Int) throws -> [(record: MemoryRecord, score: Double)] {
        let terms = TextNormalizer.searchTerms(text)
        // A query made only of stopwords ("what about my day") must not match everything.
        guard !terms.isEmpty else { return [] }
        if fts {
            let matchExpression = terms.map { "\($0)*" }.joined(separator: " OR ")
            let sql = """
            SELECT m.*, bm25(memory_fts) AS rank FROM memory_fts
            JOIN memories m ON m.rowid = memory_fts.rowid
            WHERE memory_fts MATCH ? AND m.status = 'active'
            ORDER BY rank LIMIT ?;
            """
            if let rows = try? db.query(sql, [.text(matchExpression), .int(Int64(limit))]) {
                return rows.compactMap { row in
                    guard let record = Self.decode(row) else { return nil }
                    // bm25 returns lower == better; convert to a 0…1 score.
                    let rank = row["rank"]?.double ?? 0
                    let score = 1.0 / (1.0 + max(0, rank))
                    return (record, score)
                }
            }
            // MATCH syntax errors (rare, odd tokens) fall through to LIKE.
        }
        return try likeSearch(terms: terms, limit: limit)
    }

    /// Dependency-free fallback used when FTS5 is unavailable.
    private func likeSearch(terms: [String], limit: Int) throws -> [(record: MemoryRecord, score: Double)] {
        let clause = terms.map { _ in "(text LIKE ? OR ifnull(subject,'') LIKE ? OR tags LIKE ?)" }.joined(separator: " AND ")
        var params: [SQLValue] = []
        for term in terms {
            let pattern = "%\(term)%"
            params.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern)])
        }
        params.append(.int(Int64(limit)))
        let rows = try db.query("SELECT * FROM memories WHERE status='active' AND \(clause) ORDER BY updated_at DESC LIMIT ?;", params)
        return rows.compactMap { row in
            guard let record = Self.decode(row) else { return nil }
            let haystack = "\(record.text) \(record.subject ?? "") \(record.tags.joined(separator: " "))".lowercased()
            let hits = terms.filter { haystack.contains($0) }.count
            return (record, Double(hits) / Double(terms.count))
        }
    }

    public func delete(id: String) throws { try db.run("DELETE FROM memories WHERE id = ?;", [.text(id)]) }

    public func deleteAll() throws { try db.run("DELETE FROM memories;") }

    public func touch(ids: [String], at date: Date) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try db.run("UPDATE memories SET last_accessed_at = ?, access_count = access_count + 1 WHERE id = ?;",
                       [.double(date.timeIntervalSince1970), .text(id)])
        }
    }

    public func count(statuses: [MemoryStatus] = [.active]) throws -> Int {
        guard !statuses.isEmpty else { return Int(try db.scalarInt("SELECT COUNT(*) FROM memories;")) }
        let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ",")
        return Int(try db.scalarInt("SELECT COUNT(*) FROM memories WHERE status IN (\(placeholders));",
                                    statuses.map { .text($0.rawValue) }))
    }

    // MARK: Row decoding

    private static func decode(_ row: [String: SQLValue]) -> MemoryRecord? {
        guard let id = row["id"]?.string,
              let kindRaw = row["kind"]?.string, let kind = MemoryKind(rawValue: kindRaw),
              let text = row["text"]?.string,
              let sourceRaw = row["source"]?.string, let source = MemorySource(rawValue: sourceRaw),
              let statusRaw = row["status"]?.string, let status = MemoryStatus(rawValue: statusRaw),
              let createdAt = row["created_at"]?.double,
              let updatedAt = row["updated_at"]?.double
        else { return nil }

        let tags = (row["tags"]?.string ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let provenance: Provenance? = row["provenance"]?.string
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder.jarvis.decode(Provenance.self, from: $0) }

        return MemoryRecord(
            id: id,
            kind: kind,
            text: text,
            subject: row["subject"]?.string,
            tags: tags,
            source: source,
            confidence: row["confidence"]?.double ?? 0.5,
            importance: row["importance"]?.double ?? 0.5,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            lastAccessedAt: row["last_accessed_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            accessCount: Int(row["access_count"]?.int ?? 0),
            expiresAt: row["expires_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            status: status,
            supersededBy: row["superseded_by"]?.string,
            locked: (row["locked"]?.int ?? 0) != 0,
            provenance: provenance
        )
    }
}
