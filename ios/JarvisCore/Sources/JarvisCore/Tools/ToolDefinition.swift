import Foundation

/// How consequential a tool is. Drives the confirmation policy (D10).
public enum RiskClass: String, Codable, CaseIterable, Sendable, Comparable {
    /// Reads local state; no external side effects.
    case safe
    /// Creates/updates reversible local or remote data.
    case modifying
    /// Sends something to another human (email, message, post) — cannot be recalled.
    case communicating
    /// Deletes content or performs an action that cannot be undone.
    case irreversible

    public var severity: Int {
        switch self { case .safe: return 0; case .modifying: return 1; case .communicating: return 2; case .irreversible: return 3 }
    }
    public static func < (l: RiskClass, r: RiskClass) -> Bool { l.severity < r.severity }
}

/// When the engine must ask the user before running a tool.
public enum ConfirmationPolicy: String, Codable, Sendable {
    /// Never ask (read-only, safe).
    case never
    /// Ask when risk >= .modifying.
    case onRisk
    /// Always ask, regardless of arguments.
    case always
}

/// Declarative parameter specification used to validate model-supplied arguments.
public struct ToolParameter: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case string, integer, number, boolean, dateISO8601, stringArray, enumeration
    }
    public var name: String
    public var kind: Kind
    public var required: Bool
    public var description: String
    /// Inclusive bounds for numbers / max length for strings.
    public var minimum: Double?
    public var maximum: Double?
    public var allowedValues: [String]
    public var defaultValue: JSONValue?

    public init(name: String, kind: Kind, required: Bool = false, description: String = "",
                minimum: Double? = nil, maximum: Double? = nil,
                allowedValues: [String] = [], defaultValue: JSONValue? = nil) {
        self.name = name; self.kind = kind; self.required = required; self.description = description
        self.minimum = minimum; self.maximum = maximum; self.allowedValues = allowedValues
        self.defaultValue = defaultValue
    }

    /// JSON-schema fragment shared with providers that support tool calling.
    public var jsonSchema: JSONValue {
        var schema: [String: JSONValue] = ["description": .string(description)]
        switch kind {
        case .string: schema["type"] = .string("string")
        case .integer: schema["type"] = .string("integer")
        case .number: schema["type"] = .string("number")
        case .boolean: schema["type"] = .string("boolean")
        case .dateISO8601: schema["type"] = .string("string"); schema["format"] = .string("date-time")
        case .stringArray: schema["type"] = .string("array"); schema["items"] = .obj(("type", .string("string")))
        case .enumeration: schema["type"] = .string("string"); schema["enum"] = .array(allowedValues.map { .string($0) })
        }
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }
}

/// Where a tool runs. Used for auditing and for explaining behaviour to the user.
public enum ExecutionEnvironment: String, Codable, Sendable {
    case onDevice
    case backend
    case externalService
}

/// A complete declaration of one capability the agent may invoke.
public struct ToolDefinition: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var summary: String
    public var parameters: [ToolParameter]
    public var environment: ExecutionEnvironment
    public var risk: RiskClass
    public var confirmation: ConfirmationPolicy
    /// Hard timeout. The executor cancels the tool and reports the timeout.
    public var timeoutSeconds: Double
    /// Capability IDs that must be `.ready` before the tool may run.
    public var requiredCapabilities: [String]
    /// Permission keys the OS must have granted (microphone, calendar, notifications…).
    public var requiredPermissions: [String]
    /// True when the tool requires the optional companion backend.
    public var requiresBackend: Bool
    /// Human-readable note shown on the confirmation sheet.
    public var confirmationPrompt: String

    public var id: String { name }

    public init(name: String, summary: String, parameters: [ToolParameter] = [],
                environment: ExecutionEnvironment = .onDevice, risk: RiskClass = .safe,
                confirmation: ConfirmationPolicy = .never, timeoutSeconds: Double = 20,
                requiredCapabilities: [String] = [], requiredPermissions: [String] = [],
                requiresBackend: Bool = false, confirmationPrompt: String = "") {
        self.name = name; self.summary = summary; self.parameters = parameters
        self.environment = environment; self.risk = risk; self.confirmation = confirmation
        self.timeoutSeconds = timeoutSeconds; self.requiredCapabilities = requiredCapabilities
        self.requiredPermissions = requiredPermissions; self.requiresBackend = requiresBackend
        self.confirmationPrompt = confirmationPrompt
    }

    /// Provider-facing schema (OpenAI-compatible `tools` array element).
    public var providerSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters { properties[parameter.name] = parameter.jsonSchema }
        return .obj(
            ("type", .string("function")),
            ("function", .obj(
                ("name", .string(name)),
                ("description", .string(summary)),
                ("parameters", .obj(
                    ("type", .string("object")),
                    ("properties", .object(properties)),
                    ("required", .array(parameters.filter { $0.required }.map { .string($0.name) })),
                    ("additionalProperties", .bool(false))
                ))
            ))
        )
    }

    /// Whether this declaration demands confirmation for the given arguments.
    public func requiresConfirmation(for arguments: JSONValue) -> Bool {
        switch confirmation {
        case .never: return risk >= .communicating
        case .onRisk: return risk >= .modifying
        case .always: return true
        }
    }
}

/// An approval the engine must obtain before executing a tool.
public struct PendingConfirmation: Equatable, Identifiable, Sendable {
    public var id: String
    public var toolName: String
    public var arguments: JSONValue
    public var risk: RiskClass
    public var prompt: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, toolName: String, arguments: JSONValue,
                risk: RiskClass, prompt: String, createdAt: Date = Date()) {
        self.id = id; self.toolName = toolName; self.arguments = arguments
        self.risk = risk; self.prompt = prompt; self.createdAt = createdAt
    }
}

/// Normalised tool result. `verified` states whether the outcome was confirmed
/// by the underlying service (e.g. Gmail returned a message id) rather than assumed.
public struct ToolResult: Equatable, Sendable {
    public var toolName: String
    public var success: Bool
    public var summary: String
    public var payload: JSONValue?
    public var verified: Bool
    public var durationSeconds: Double
    public var error: JarvisError?

    public init(toolName: String, success: Bool, summary: String, payload: JSONValue? = nil,
                verified: Bool = false, durationSeconds: Double = 0, error: JarvisError? = nil) {
        self.toolName = toolName; self.success = success; self.summary = summary
        self.payload = payload; self.verified = verified; self.durationSeconds = durationSeconds; self.error = error
    }

    public static func failure(_ tool: String, _ error: JarvisError) -> ToolResult {
        ToolResult(toolName: tool, success: false, summary: error.userMessage, verified: false, error: error)
    }
}

/// Everything a tool needs at execution time. Tools receive only what policy allows.
public struct ToolExecutionContext: Sendable {
    public var clock: Clock
    public var memory: MemoryEngine?
    public var reminders: ReminderEngine?
    public var integrations: IntegrationHub?
    public var transport: HTTPTransport
    public var secrets: SecretStore
    public var sessionID: String?
    /// Content fetched from an external service is untrusted by definition.
    public var untrustedContent: Bool

    public init(clock: Clock = SystemClock(), memory: MemoryEngine? = nil, reminders: ReminderEngine? = nil,
                integrations: IntegrationHub? = nil, transport: HTTPTransport = URLSessionTransport(),
                secrets: SecretStore = InMemorySecretStore(), sessionID: String? = nil,
                untrustedContent: Bool = false) {
        self.clock = clock; self.memory = memory; self.reminders = reminders
        self.integrations = integrations; self.transport = transport; self.secrets = secrets
        self.sessionID = sessionID; self.untrustedContent = untrustedContent
    }
}

/// The unit of work a tool implements.
public protocol JarvisTool: AnyObject {
    var definition: ToolDefinition { get }
    func execute(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult
    /// Optional capability probe used to render honest states in the UI.
    func capabilityState(context: ToolExecutionContext) -> CapabilityState
}

public extension JarvisTool {
    func capabilityState(context: ToolExecutionContext) -> CapabilityState { .ready }
}
