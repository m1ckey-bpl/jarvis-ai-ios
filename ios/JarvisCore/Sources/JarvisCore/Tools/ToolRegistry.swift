import Foundation

/// Holds every tool the assistant may propose, and the policy used to authorize it.
public final class ToolRegistry {
    private var tools: [String: JarvisTool] = [:]
    private let lock = NSLock()
    public let capabilities: CapabilityRegistry
    /// Permission states supplied by the app layer (microphone, calendar, …).
    public var permissionStates: [String: CapabilityState] = [:]

    public init(capabilities: CapabilityRegistry = CapabilityRegistry()) {
        self.capabilities = capabilities
    }

    public func register(_ tool: JarvisTool) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.definition.name] = tool
    }

    public func register(contentsOf collection: [JarvisTool]) {
        for tool in collection { register(tool) }
    }

    public func tool(named name: String) -> JarvisTool? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    public var definitions: [ToolDefinition] {
        lock.lock(); defer { lock.unlock() }
        return tools.values.map { $0.definition }.sorted { $0.name < $1.name }
    }

    /// Definitions whose capability requirements are currently satisfied.
    public func availableDefinitions(context: ToolExecutionContext) -> [ToolDefinition] {
        definitions.filter { definition in
            guard !definition.requiresBackend || capabilities.capability(id: CapabilityID.backend)?.state.isUsable == true else { return false }
            for capabilityID in definition.requiredCapabilities {
                guard capabilities.capability(id: capabilityID)?.state.isUsable == true else { return false }
            }
            for permission in definition.requiredPermissions {
                guard permissionStates[permission]?.isUsable == true else { return false }
            }
            return true
        }
    }

    /// Human-readable reason a tool cannot run — used for honest UI states.
    public func blockingReason(for definition: ToolDefinition, context: ToolExecutionContext) -> String? {
        if definition.requiresBackend, capabilities.capability(id: CapabilityID.backend)?.state.isUsable != true {
            return "This action needs the JARVIS companion backend, which is not configured."
        }
        for capabilityID in definition.requiredCapabilities {
            if let capability = capabilities.capability(id: capabilityID), !capability.state.isUsable {
                return "\(capability.name): \(capability.state.explanation)"
            }
        }
        for permission in definition.requiredPermissions where permissionStates[permission]?.isUsable != true {
            return "\(permission): permission not granted."
        }
        return nil
    }

    public func providerSchemas(context: ToolExecutionContext) -> [JSONValue] {
        availableDefinitions(context: context).map { $0.providerSchema }
    }
}

/// Persistent audit trail of every tool invocation (spec §9: report the real outcome).
public final class ToolExecutionLog {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var toolName: String
        public var argumentsJSON: String
        public var summary: String
        public var success: Bool
        public var verified: Bool
        public var risk: RiskClass
        public var confirmedByUser: Bool
        public var startedAt: Date
        public var durationSeconds: Double
        public var errorMessage: String?

        public init(id: String = UUID().uuidString, toolName: String, argumentsJSON: String, summary: String,
                    success: Bool, verified: Bool, risk: RiskClass, confirmedByUser: Bool,
                    startedAt: Date, durationSeconds: Double, errorMessage: String? = nil) {
            self.id = id; self.toolName = toolName; self.argumentsJSON = argumentsJSON
            self.summary = summary; self.success = success; self.verified = verified; self.risk = risk
            self.confirmedByUser = confirmedByUser; self.startedAt = startedAt
            self.durationSeconds = durationSeconds; self.errorMessage = errorMessage
        }
    }

    private let db: SQLiteDatabase
    private let redactor: Redactor

    public init(path: String, redactor: Redactor = Redactor()) throws {
        self.db = try SQLiteDatabase(path: path)
        self.redactor = redactor
        try Migrator.migrate(db, migrations: ToolExecutionLog.migrations)
    }

    public static let migrations: [Migration] = [
        Migration(version: 1, name: "tool log schema", statements: [
            """
            CREATE TABLE IF NOT EXISTS tool_runs (
                id TEXT PRIMARY KEY, tool_name TEXT NOT NULL, arguments TEXT NOT NULL, summary TEXT NOT NULL,
                success INTEGER NOT NULL, verified INTEGER NOT NULL, risk TEXT NOT NULL,
                confirmed INTEGER NOT NULL, started_at REAL NOT NULL, duration REAL NOT NULL, error TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_tool_runs_time ON tool_runs(started_at DESC);"
        ])
    ]

    public func append(_ entry: Entry) throws {
        try db.run("""
            INSERT INTO tool_runs (id, tool_name, arguments, summary, success, verified, risk, confirmed, started_at, duration, error)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .text(entry.id), .text(entry.toolName),
                // Arguments are redacted before storage: an argument may contain a token.
                .text(redactor.redact(entry.argumentsJSON, truncateTo: 2_000)),
                .text(entry.summary), .int(entry.success ? 1 : 0), .int(entry.verified ? 1 : 0),
                .text(entry.risk.rawValue), .int(entry.confirmedByUser ? 1 : 0),
                .double(entry.startedAt.timeIntervalSince1970), .double(entry.durationSeconds),
                entry.errorMessage.map { SQLValue.text(redactor.redact($0, truncateTo: 500)) } ?? .null
            ])
    }

    public func recent(limit: Int = 100) throws -> [Entry] {
        try db.query("SELECT * FROM tool_runs ORDER BY started_at DESC LIMIT ?;", [.int(Int64(limit))]).compactMap { row in
            guard let id = row["id"]?.string, let name = row["tool_name"]?.string,
                  let arguments = row["arguments"]?.string, let summary = row["summary"]?.string,
                  let riskRaw = row["risk"]?.string, let risk = RiskClass(rawValue: riskRaw),
                  let started = row["started_at"]?.double, let duration = row["duration"]?.double else { return nil }
            return Entry(id: id, toolName: name, argumentsJSON: arguments, summary: summary,
                         success: (row["success"]?.int ?? 0) != 0, verified: (row["verified"]?.int ?? 0) != 0,
                         risk: risk, confirmedByUser: (row["confirmed"]?.int ?? 0) != 0,
                         startedAt: Date(timeIntervalSince1970: started), durationSeconds: duration,
                         errorMessage: row["error"]?.string)
        }
    }

    public func deleteAll() throws { try db.run("DELETE FROM tool_runs;") }
}
