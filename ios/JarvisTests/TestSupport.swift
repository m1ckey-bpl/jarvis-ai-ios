import Foundation
import XCTest
@testable import JarvisCore

/// Deterministic transport: no sockets, no flakiness. Records everything sent so
/// tests can assert on headers/body (and prove secrets are handled correctly).
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?
        var label: String
    }

    private(set) var recorded: [Recorded] = []
    /// Responses returned in order; the last one repeats.
    var responses: [HTTPResponsePayload] = []
    /// Optional line streams keyed by call index (for SSE tests).
    var streams: [[String]] = []
    var errorToThrow: JarvisError?
    private let lock = NSLock()
    private var callIndex = 0

    init(responses: [HTTPResponsePayload] = [], streams: [[String]] = [], errorToThrow: JarvisError? = nil) {
        self.responses = responses
        self.streams = streams
        self.errorToThrow = errorToThrow
    }

    func send(_ request: HTTPRequestSpec) async throws -> HTTPResponsePayload {
        lock.lock()
        recorded.append(Recorded(url: request.url, method: request.method, headers: request.headers,
                                 body: request.body, label: request.label))
        let index = callIndex
        callIndex += 1
        lock.unlock()

        if let errorToThrow { throw errorToThrow }
        guard !responses.isEmpty else {
            return HTTPResponsePayload(statusCode: 200, data: Data("{}".utf8))
        }
        return responses[min(index, responses.count - 1)]
    }

    func stream(_ request: HTTPRequestSpec) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                lock.lock()
                recorded.append(Recorded(url: request.url, method: request.method, headers: request.headers,
                                         body: request.body, label: request.label))
                let index = callIndex
                callIndex += 1
                let error = errorToThrow
                lock.unlock()
                if let error { continuation.finish(throwing: error); return }
                lock.lock()
                let lines = index < streams.count ? streams[index] : (streams.last ?? [])
                lock.unlock()
                for line in lines {
                    if Task.isCancelled { break }
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum TestFixtures {
    typealias Stack = (memory: MemoryEngine, store: SQLiteMemoryStore, conversations: ConversationStore,
                       context: ContextManager, registry: ToolRegistry, executor: ToolExecutor,
                       clock: TestClock, log: ToolExecutionLog)

    static func entry(id: String = "mock-openai", kind: ProviderCatalogEntry.Kind = .openAICompatible)
        -> ProviderCatalogEntry {
        ProviderCatalogEntry(id: id, displayName: "Mock", kind: kind,
                             baseURL: "https://mock.local/v1", defaultModel: "mock-model",
                             models: ["mock-model"], hasFreeTier: true, freeTierNote: "test",
                             keyInstructions: "test", signupURL: "https://example.com")
    }

    static func makeStack(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Stack {
        let clock = TestClock(now: now, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        let store = try SQLiteMemoryStore(path: ":memory:")
        let memory = MemoryEngine(store: store, clock: clock)
        let conversations = try ConversationStore(path: ":memory:")
        let summarizer = ConversationSummarizer(store: store, clock: clock)
        let context = ContextManager(memory: memory, conversations: conversations, summarizer: summarizer)
        let capabilities = CapabilityRegistry()
        let registry = ToolRegistry(capabilities: capabilities)
        let log = try ToolExecutionLog(path: ":memory:")
        let executor = ToolExecutor(registry: registry, log: log, clock: clock)
        return (memory, store, conversations, context, registry, executor, clock, log)
    }

    /// A provider that answers with a scripted sequence of stream events.
    static func scriptedProvider(_ script: [[ChatStreamEvent]], id: String = "mock-openai") -> LLMProvider {
        ScriptedProvider(script: script, id: id)
    }
}

final class ScriptedProvider: LLMProvider {
    private var script: [[ChatStreamEvent]]
    let id: String
    init(script: [[ChatStreamEvent]], id: String) { self.script = script; self.id = id }
    var displayName: String { "Scripted" }
    var defaultModel: String { "mock-model" }
    var availableModels: [String] { ["mock-model"] }
    var setupHint: String { "n/a" }
    func state() async -> CapabilityState { .ready }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        var text = ""
        var calls: [ToolCallRequest] = []
        for event in script.first ?? [] {
            if case .textDelta(let delta) = event { text += delta }
            if case .completed(let response) = event { calls = response.toolCalls }
        }
        return ChatResponse(text: text, toolCalls: calls, model: "mock-model")
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let events = script.isEmpty ? [] : script.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Reminder engine backed by an in-memory recorder (no notification centre needed).
func makeReminderStack(now: Date, timeZone: String = "Asia/Kolkata")
    -> (engine: ReminderEngine, scheduler: RecordingReminderScheduler, clock: TestClock) {
    let clock = TestClock(now: now, timeZone: TimeZone(identifier: timeZone)!)
    let store = try! ReminderStore(path: ":memory:")
    let scheduler = RecordingReminderScheduler()
    let engine = ReminderEngine(store: store, scheduler: scheduler, clock: clock)
    return (engine, scheduler, clock)
}
