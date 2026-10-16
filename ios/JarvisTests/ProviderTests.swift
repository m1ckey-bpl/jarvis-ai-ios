import XCTest
@testable import JarvisCore

final class ProviderTests: XCTestCase {

    private func chatChunk(_ content: String, finish: String? = nil) -> String {
        var payload: [String: JSONValue] = [
            "model": .string("mock-model"),
            "choices": .array([.obj(("index", .int(0)), ("delta", .obj(("content", .string(content)))) )])
        ]
        if let finish {
            payload["choices"] = .array([.obj(("index", .int(0)), ("delta", .object([:])), ("finish_reason", .string(finish)))])
        }
        return "data: " + JSONValue.object(payload).jsonString + "\n"
    }

    func testSSEParserHandlesMultiLineEventsAndComments() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: ": keep-alive"))
        XCTAssertNil(parser.consume(line: "event: message"))
        XCTAssertNil(parser.consume(line: "data: {\"a\":"))
        XCTAssertNil(parser.consume(line: "data: 1}"))
        let event = parser.consume(line: "")
        XCTAssertEqual(event?.event, "message")
        XCTAssertEqual(event?.data, "{\"a\":\n1}")
    }

    func testStreamingCompletesWithTextAndUsage() async throws {
        let transport = MockTransport(streams: [[
            chatChunk("Hello"), "",
            chatChunk(" there"), "",
            chatChunk("", finish: "stop"), "",
            "data: [DONE]", ""
        ]])
        let provider = OpenAICompatibleProvider(entry: TestFixtures.entry(), apiKey: "test-key",
                                                baseURL: "https://mock.local/v1", transport: transport)
        var text = ""
        var finished: ChatResponse?
        for try await event in provider.stream(ChatRequest(messages: [.user("hi")])) {
            switch event {
            case .textDelta(let delta): text += delta
            case .completed(let response): finished = response
            default: break
            }
        }
        XCTAssertEqual(text, "Hello there")
        XCTAssertEqual(finished?.finishReason, "stop")
    }

    func testStreamingToolCallsAreAssembled() async throws {
        let toolCallLine = "data: " + JSONValue.object([
            "choices": .array([.obj(("index", .int(0)), ("delta", .obj((
                "tool_calls", .array([.obj(
                    ("index", .int(0)),
                    ("id", .string("call_1")),
                    ("function", .obj(("name", .string("reminder.create")),
                                      ("arguments", .string("{\"request\":\"tomorrow at 9am\"}"))))
                )])
            ))))])
        ]).jsonString
        let transport = MockTransport(streams: [[toolCallLine, "", chatChunk("", finish: "tool_calls"), ""]])
        let provider = OpenAICompatibleProvider(entry: TestFixtures.entry(), apiKey: "k",
                                                baseURL: "https://mock.local/v1", transport: transport)
        var calls: [ToolCallRequest] = []
        for try await event in provider.stream(ChatRequest(messages: [.user("remind me")])) {
            if case .completed(let response) = event { calls = response.toolCalls }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "reminder.create")
        XCTAssertEqual(calls[0].arguments["request"]?.stringValue, "tomorrow at 9am")
    }

    func testUnauthorizedMapsToActionableError() async throws {
        let transport = MockTransport(streams: [])
        transport.errorToThrow = .providerUnauthorized("the provider rejected the credential (HTTP 401)")
        let provider = OpenAICompatibleProvider(entry: TestFixtures.entry(), apiKey: "bad",
                                                baseURL: "https://mock.local/v1", transport: transport)
        do {
            for try await _ in provider.stream(ChatRequest(messages: [.user("hi")])) {}
            XCTFail("expected an error")
        } catch let error as JarvisError {
            XCTAssertEqual(error, .providerUnauthorized("the provider rejected the credential (HTTP 401)"))
            XCTAssertFalse(error.isRetryable)
            XCTAssertTrue(error.userMessage.contains("Re-enter"))
        }
    }

    func testRateLimitIsRetryableWithRetryAfter() async throws {
        let transport = MockTransport(responses: [])
        transport.errorToThrow = .providerQuotaExceeded(retryAfterSeconds: 5)
        let provider = OpenAICompatibleProvider(entry: TestFixtures.entry(), apiKey: "k",
                                                baseURL: "https://mock.local/v1", transport: transport)
        let response = HTTPResponsePayload(statusCode: 429, headers: ["retry-after": "5"])
        XCTAssertEqual(URLSessionTransport.mapStatus(429, body: "", headers: response.headers),
                       .providerQuotaExceeded(retryAfterSeconds: 5))
        XCTAssertTrue(JarvisError.providerQuotaExceeded(retryAfterSeconds: 5).isRetryable)
        XCTAssertTrue(JarvisError.providerQuotaExceeded(retryAfterSeconds: nil).isRetryable)
        // A long retry-after is refused by the policy rather than by the error itself.
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: false)
        var attempts = 0
        do {
            _ = try await policy.run { () -> Int in
                attempts += 1
                throw JarvisError.providerQuotaExceeded(retryAfterSeconds: 3600)
            }
        } catch {}
        XCTAssertEqual(attempts, 1, "a quota reset an hour away must not be hammered")
        _ = provider
    }

    func testHTTPStatusMapping() {
        XCTAssertEqual(URLSessionTransport.mapStatus(401, body: "", headers: [:]), .providerUnauthorized("the provider rejected the credential (HTTP 401)"))
        XCTAssertEqual(URLSessionTransport.mapStatus(403, body: "", headers: [:]), .providerUnauthorized("the provider rejected the credential (HTTP 403)"))
        if case .network = URLSessionTransport.mapStatus(503, body: "", headers: [:]) {} else { XCTFail("5xx must be retryable network trouble") }
    }

    func testRetryPolicyBackoffIsBoundedAndJittered() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 5, jitter: false)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 5, "delay is capped by maxDelay")
        let jittered = RetryPolicy(maxAttempts: 3, baseDelay: 2, maxDelay: 10, jitter: true)
        let value = jittered.delay(forAttempt: 1)
        XCTAssertTrue(value >= 1.4 && value <= 2.6, "jitter stays within ±30%")
    }

    func testRetryPolicyStopsAtMaxAttempts() async throws {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0.01, maxDelay: 0.02, jitter: false)
        var attempts = 0
        do {
            _ = try await policy.run { () -> Int in
                attempts += 1
                throw JarvisError.network("flaky")
            }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(attempts, 2)
        }
    }

    func testRetryPolicyDoesNotRetryNonRetryableErrors() async throws {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.02, jitter: false)
        var attempts = 0
        do {
            _ = try await policy.run { () -> Int in
                attempts += 1
                throw JarvisError.providerUnauthorized("nope")
            }
        } catch {}
        XCTAssertEqual(attempts, 1, "a 401 must not be retried")
    }

    func testProviderReportsUnconfiguredWithoutKey() async {
        let provider = OpenAICompatibleProvider(entry: TestFixtures.entry(  ), apiKey: "",
                                                baseURL: "https://mock.local/v1", transport: MockTransport())
        let state = await provider.state()
        if case .requiresConfiguration(let detail) = state {
            XCTAssertTrue(detail.contains("Settings"))
        } else { XCTFail("expected requiresConfiguration") }
    }

    func testProviderRegistryReturnsNilWhenNoKeyStored() throws {
        let secrets = InMemorySecretStore()
        let settings = ProviderSettingsStore(defaults: UserDefaults(suiteName: "ai.jarvis.tests.\(UUID().uuidString)")!)
        try settings.save(ProviderSettings(providerID: "groq", model: "openai/gpt-oss-120b"))
        let registry = ProviderRegistry(secrets: secrets, transport: MockTransport(), settingsStore: settings)
        XCTAssertNil(try registry.activeProvider(), "without a key there is no active provider — never a fake one")

        try secrets.setSecret("test-key", for: SecretKey.apiKey(for: "groq"))
        registry.invalidate()
        let provider = try registry.activeProvider()
        XCTAssertEqual(provider?.id, "groq")
    }

    func testGeminiPayloadShapeAndParsing() async throws {
        let body: JSONValue = .obj(
            ("candidates", .array([
                .obj(("content", .obj(("parts", .array([.obj(("text", .string("Hello from Gemini")))])))),
                     ("finishReason", .string("STOP")))
            ])),
            ("usageMetadata", .obj(("promptTokenCount", .int(7)), ("candidatesTokenCount", .int(3))))
        )
        let transport = MockTransport(responses: [HTTPResponsePayload(statusCode: 200, data: try JSONEncoder.jarvis.encode(body))])
        let entry = ProviderCatalog.entry(id: "google-ai-studio")!
        let provider = GeminiProvider(entry: entry, apiKey: "key", transport: transport)
        let response = try await provider.complete(ChatRequest(messages: [.system("be brief"), .user("hi")]))
        XCTAssertEqual(response.text, "Hello from Gemini")
        XCTAssertEqual(response.promptTokens, 7)
        XCTAssertEqual(response.completionTokens, 3)

        let sentBody = try XCTUnwrap(transport.recorded.first?.body)
        let json = try JSONDecoder.jarvis.decode(JSONValue.self, from: sentBody)
        XCTAssertNotNil(json["systemInstruction"], "system prompts map to systemInstruction")
        XCTAssertEqual(json["contents"]?.arrayValue?.first?["role"]?.stringValue, "user")
    }

    func testCatalogEntriesHaveHonestFreeTierNotes() {
        for entry in ProviderCatalog.entries {
            XCTAssertFalse(entry.displayName.isEmpty)
            if entry.hasFreeTier {
                XCTAssertFalse(entry.freeTierNote.isEmpty, "\(entry.id) claims a free tier without documenting its limits")
            }
        }
        XCTAssertEqual(ProviderCatalog.entry(id: "groq")?.kind, .openAICompatible)
        XCTAssertEqual(ProviderCatalog.entry(id: "google-ai-studio")?.kind, .gemini)
    }
}
