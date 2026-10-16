import Foundation

/// A message sent to a language model.
public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }
    public var role: Role
    public var content: String
    /// Set for assistant turns that requested tools.
    public var toolCalls: [ToolCallRequest]
    /// Set for `tool` role messages: which call this answers.
    public var toolCallID: String?
    /// Marks content that came from outside the trust boundary.
    public var untrusted: Bool

    public init(role: Role, content: String, toolCalls: [ToolCallRequest] = [],
                toolCallID: String? = nil, untrusted: Bool = false) {
        self.role = role; self.content = content; self.toolCalls = toolCalls
        self.toolCallID = toolCallID; self.untrusted = untrusted
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, content: text) }
}

/// A tool invocation *proposed* by the model. Never an authorization (D10).
public struct ToolCallRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = UUID().uuidString, name: String, arguments: JSONValue) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

/// A complete (non-streaming) request.
public struct ChatRequest: Sendable {
    public var messages: [ChatMessage]
    public var tools: [ToolDefinition]
    public var temperature: Double
    public var maxOutputTokens: Int?
    public var model: String?
    /// Ask the provider to prefer tool use when appropriate.
    public var toolChoice: ToolChoice

    public enum ToolChoice: String, Sendable { case auto, none, required }

    public init(messages: [ChatMessage], tools: [ToolDefinition] = [], temperature: Double = 0.4,
                maxOutputTokens: Int? = nil, model: String? = nil, toolChoice: ToolChoice = .auto) {
        self.messages = messages; self.tools = tools; self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens; self.model = model; self.toolChoice = toolChoice
    }
}

public struct ChatResponse: Sendable, Equatable {
    public var text: String
    public var toolCalls: [ToolCallRequest]
    public var finishReason: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var model: String

    public init(text: String, toolCalls: [ToolCallRequest] = [], finishReason: String? = nil,
                promptTokens: Int? = nil, completionTokens: Int? = nil, model: String = "") {
        self.text = text; self.toolCalls = toolCalls; self.finishReason = finishReason
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.model = model
    }
}

/// Normalised streaming events consumed by the agent and the UI.
public enum ChatStreamEvent: Sendable, Equatable {
    case started(model: String)
    case textDelta(String)
    case toolCallStarted(name: String)
    case toolCallArgumentsDelta(String)
    case completed(ChatResponse)
    case failed(JarvisError)
}

/// The provider abstraction (R4): any OpenAI-compatible endpoint or Gemini.
public protocol LLMProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var defaultModel: String { get }
    var availableModels: [String] { get }
    /// Non-secret description of what the user must supply and where to get it.
    var setupHint: String { get }
    var documentationURL: URL? { get }

    /// Whether a credential is present and the endpoint is usable right now.
    func state() async -> CapabilityState

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error>
    func complete(_ request: ChatRequest) async throws -> ChatResponse
}

public extension LLMProvider {
    var documentationURL: URL? { nil }
}

/// A provider plus user-adjustable configuration (stored in UserDefaults; the key
/// itself lives in the Keychain).
public struct ProviderSettings: Codable, Equatable, Sendable {
    public var providerID: String
    public var model: String
    public var temperature: Double
    public var maxOutputTokens: Int?
    /// Optional override for self-hosted OpenAI-compatible endpoints.
    public var baseURLOverride: String?

    public init(providerID: String, model: String, temperature: Double = 0.4,
                maxOutputTokens: Int? = nil, baseURLOverride: String? = nil) {
        self.providerID = providerID; self.model = model; self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens; self.baseURLOverride = baseURLOverride
    }
}
