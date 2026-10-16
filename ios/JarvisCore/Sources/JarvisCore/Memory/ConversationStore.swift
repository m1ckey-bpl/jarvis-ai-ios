import Foundation

public enum MessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// One turn in a conversation. Persisted so history survives restarts.
public struct ConversationMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    /// Tool invocations attached to an assistant turn (audit trail).
    public var toolCallSummary: String?
    /// Provider-reported usage, when available.
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// True when this message is a synthetic compaction summary.
    public var isCompactionSummary: Bool

    public init(id: String = UUID().uuidString, sessionID: String, role: MessageRole, text: String,
                createdAt: Date = Date(), toolCallSummary: String? = nil,
                promptTokens: Int? = nil, completionTokens: Int? = nil, isCompactionSummary: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.toolCallSummary = toolCallSummary
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.isCompactionSummary = isCompactionSummary
    }
}

public struct ConversationSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: String = UUID().uuidString, title: String = "New conversation",
                createdAt: Date = Date(), updatedAt: Date = Date(), messageCount: Int = 0) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.messageCount = messageCount
    }
}

/// Durable conversation history (sessions + messages).
public final class ConversationStore {
    private let db: SQLiteDatabase

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Migrator.migrate(db, migrations: ConversationStore.migrations)
    }

    public static let migrations: [Migration] = [
        Migration(version: 1, name: "conversation schema", statements: [
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                created_at REAL NOT NULL,
                tool_call_summary TEXT,
                prompt_tokens INTEGER,
                completion_tokens INTEGER,
                is_compaction INTEGER NOT NULL DEFAULT 0
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, created_at);"
        ])
    ]

    @discardableResult
    public func createSession(title: String = "New conversation", at date: Date = Date()) throws -> ConversationSession {
        let session = ConversationSession(title: title, createdAt: date, updatedAt: date)
        try db.run("INSERT INTO sessions (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                   [.text(session.id), .text(session.title), .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)])
        return session
    }

    public func session(id: String) throws -> ConversationSession? {
        try db.query("SELECT * FROM sessions WHERE id = ?;", [.text(id)]).first.flatMap(Self.decodeSession)
    }

    public func sessions(limit: Int = 100) throws -> [ConversationSession] {
        try db.query("SELECT * FROM sessions ORDER BY updated_at DESC LIMIT ?;", [.int(Int64(limit))]).compactMap(Self.decodeSession)
    }

    public func rename(sessionID: String, title: String, at date: Date = Date()) throws {
        try db.run("UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?;",
                   [.text(title), .double(date.timeIntervalSince1970), .text(sessionID)])
    }

    public func delete(sessionID: String) throws {
        try db.run("DELETE FROM messages WHERE session_id = ?;", [.text(sessionID)])
        try db.run("DELETE FROM sessions WHERE id = ?;", [.text(sessionID)])
    }

    public func append(_ message: ConversationMessage) throws {
        try db.run("""
            INSERT INTO messages (id, session_id, role, text, created_at, tool_call_summary, prompt_tokens, completion_tokens, is_compaction)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [
                .text(message.id), .text(message.sessionID), .text(message.role.rawValue), .text(message.text),
                .double(message.createdAt.timeIntervalSince1970),
                message.toolCallSummary.map { SQLValue.text($0) } ?? .null,
                message.promptTokens.map { SQLValue.int(Int64($0)) } ?? .null,
                message.completionTokens.map { SQLValue.int(Int64($0)) } ?? .null,
                .int(message.isCompactionSummary ? 1 : 0)
            ])
        try db.run("UPDATE sessions SET updated_at = ? WHERE id = ?;",
                   [.double(message.createdAt.timeIntervalSince1970), .text(message.sessionID)])
    }

    public func messages(sessionID: String, limit: Int = 500) throws -> [ConversationMessage] {
        try db.query("SELECT * FROM messages WHERE session_id = ? ORDER BY created_at ASC LIMIT ?;",
                     [.text(sessionID), .int(Int64(limit))]).compactMap(Self.decodeMessage)
    }

    public func recentMessages(sessionID: String, limit: Int) throws -> [ConversationMessage] {
        let all = try db.query("SELECT * FROM messages WHERE session_id = ? ORDER BY created_at DESC LIMIT ?;",
                               [.text(sessionID), .int(Int64(limit))]).compactMap(Self.decodeMessage)
        return all.reversed()
    }

    public func messageCount(sessionID: String) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM messages WHERE session_id = ?;", [.text(sessionID)]))
    }

    /// Full-text-ish search across history (LIKE based; conversations are small).
    public func search(_ text: String, limit: Int = 40) throws -> [ConversationMessage] {
        try db.query("SELECT * FROM messages WHERE text LIKE ? ORDER BY created_at DESC LIMIT ?;",
                     [.text("%\(text)%"), .int(Int64(limit))]).compactMap(Self.decodeMessage)
    }

    public func deleteAll() throws {
        try db.run("DELETE FROM messages;")
        try db.run("DELETE FROM sessions;")
    }

    private static func decodeSession(_ row: [String: SQLValue]) -> ConversationSession? {
        guard let id = row["id"]?.string, let title = row["title"]?.string,
              let created = row["created_at"]?.double, let updated = row["updated_at"]?.double else { return nil }
        return ConversationSession(id: id, title: title,
                                   createdAt: Date(timeIntervalSince1970: created),
                                   updatedAt: Date(timeIntervalSince1970: updated))
    }

    private static func decodeMessage(_ row: [String: SQLValue]) -> ConversationMessage? {
        guard let id = row["id"]?.string, let session = row["session_id"]?.string,
              let roleRaw = row["role"]?.string, let role = MessageRole(rawValue: roleRaw),
              let text = row["text"]?.string, let created = row["created_at"]?.double else { return nil }
        return ConversationMessage(
            id: id, sessionID: session, role: role, text: text,
            createdAt: Date(timeIntervalSince1970: created),
            toolCallSummary: row["tool_call_summary"]?.string,
            promptTokens: row["prompt_tokens"]?.int.map(Int.init),
            completionTokens: row["completion_tokens"]?.int.map(Int.init),
            isCompactionSummary: (row["is_compaction"]?.int ?? 0) != 0
        )
    }
}
