import XCTest
@testable import JarvisCore

final class OrchestratorTests: XCTestCase {

    /// Builds a full agent stack whose provider is the real OpenAI-compatible client
    /// talking to a mock transport — so the orchestration code path under test is the
    /// production one, only the socket is simulated.
    private func makeOrchestrator(streams: [[String]] = [],
                                  registered: [JarvisTool] = [],
                                  configuration: AgentConfiguration = .default)
        throws -> (AgentOrchestrator, TestFixtures.Stack, MockTransport, RecordingReminderScheduler, ProviderSettingsStore) {

        let stack = try TestFixtures.makeStack()
        let transport = MockTransport(streams: streams)
        let defaults = UserDefaults(suiteName: "ai.jarvis.tests.\(UUID().uuidString)")!
        let settings = ProviderSettingsStore(defaults: defaults)
        let secrets = InMemorySecretStore(seed: [SecretKey.apiKey(for: "custom-openai-compatible"): "test-key"])
        let registry = ProviderRegistry(secrets: secrets, transport: transport, settingsStore: settings)

        for tool in registered { stack.registry.register(tool) }
        // The reminder tool declares a notification-permission requirement; grant it here
        // so the test exercises the execution path rather than the permission gate.
        stack.registry.permissionStates["notifications"] = .ready
        let reminders = makeReminderStack(now: stack.clock.now)
        stack.registry.register(ReminderCreateTool())
        stack.registry.register(ReminderListTool())
        stack.registry.register(MemorySearchTool())

        let orchestrator = AgentOrchestrator(
            memory: stack.memory, conversations: stack.conversations, contextManager: stack.context,
            registry: stack.registry, executor: stack.executor, providerRegistry: registry,
            settingsStore: settings, capabilities: registry_capabilities(stack),
            clock: stack.clock, configuration: configuration, transport: transport, secrets: secrets)
        orchestrator.reminderEngine = reminders.engine
        return (orchestrator, stack, transport, reminders.scheduler, settings)
    }

    private func registry_capabilities(_ stack: TestFixtures.Stack) -> CapabilityRegistry {
        let capabilities = CapabilityRegistry()
        capabilities.register(Capability(id: CapabilityID.reminders, name: "Reminders", summary: "", state: .ready))
        return capabilities
    }

    private func textStream(_ text: String) -> [String] {
        ["data: " + JSONValue.object([
            "choices": .array([.obj(("index", .int(0)), ("delta", .obj(("content", .string(text)))))])
        ]).jsonString, "",
         "data: " + JSONValue.object([
            "choices": .array([.obj(("index", .int(0)), ("delta", .object([:])), ("finish_reason", .string("stop")))])
         ]).jsonString, "",
         "data: [DONE]", ""]
    }

    private func toolCallStream(tool: String, arguments: String, id: String = "call_1") -> [String] {
        ["data: " + JSONValue.object([
            "choices": .array([.obj(("index", .int(0)), ("delta", .obj((
                "tool_calls", .array([.obj(
                    ("index", .int(0)), ("id", .string(id)),
                    ("function", .obj(("name", .string(tool)), ("arguments", .string(arguments)))))])
            ))))])
         ]).jsonString, "",
         "data: " + JSONValue.object([
            "choices": .array([.obj(("index", .int(0)), ("delta", .object([:])), ("finish_reason", .string("tool_calls")))])
         ]).jsonString, ""]
    }

    // MARK: Local, provider-free behaviour

    func testMemoryCommandIsHandledDeterministicallyWithoutAProvider() async throws {
        let (orchestrator, stack, transport, _, _) = try makeOrchestrator()
        let turn = try await orchestrator.completeTurn("Remember that my preferred language is English", sessionID: nil)
        XCTAssertTrue(turn.handledLocally)
        XCTAssertTrue(turn.assistantText.contains("Saved"))
        XCTAssertEqual(try stack.memory.count(), 1)
        XCTAssertEqual(transport.recorded.count, 0, "no network call is needed for a memory command")
    }

    func testRecallUsesStoredMemoryAndReportsNothingWhenAbsent() async throws {
        let (orchestrator, _, _, _, _) = try makeOrchestrator()
        _ = try await orchestrator.completeTurn("Remember that my project is called Jarvis", sessionID: nil)
        let found = try await orchestrator.completeTurn("What do you remember about my project", sessionID: nil)
        XCTAssertTrue(found.assistantText.lowercased().contains("jarvis"))

        let missing = try await orchestrator.completeTurn("What do you remember about my pet iguana", sessionID: nil)
        XCTAssertTrue(missing.assistantText.contains("don't have anything stored"),
                      "an empty result must be disclosed, never invented")
    }

    func testForgetRequiresConfirmationThenDeletes() async throws {
        let (orchestrator, stack, _, _, _) = try makeOrchestrator()
        _ = try await orchestrator.completeTurn("Remember that my favourite colour is blue", sessionID: nil)
        let prompt = try await orchestrator.completeTurn("Forget my favourite colour", sessionID: nil)
        XCTAssertTrue(prompt.assistantText.contains("Say “forget"))
        XCTAssertEqual(try stack.memory.count(), 1, "nothing deleted until confirmed")
        let confirmed = try await orchestrator.completeTurn("Forget my favourite colour, confirm", sessionID: nil)
        XCTAssertTrue(confirmed.assistantText.contains("Deleted"))
        XCTAssertEqual(try stack.memory.count(), 0)
    }

    /// The deterministic router handles reminder phrasing without spending tokens;
    /// the model path is covered by the tool-call tests below.
    func testReminderCommandWorksLocally() async throws {
        let (orchestrator, _, _, scheduler, _) = try makeOrchestrator()
        let turn = try await orchestrator.completeTurn("Remind me tomorrow at 9am to study", sessionID: nil)
        XCTAssertTrue(turn.handledLocally)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertTrue(turn.assistantText.lowercased().contains("study"))
    }

    func testUnconfiguredProviderIsDisclosedHonestly() async throws {
        let stack = try TestFixtures.makeStack()
        let defaults = UserDefaults(suiteName: "ai.jarvis.tests.\(UUID().uuidString)")!
        let settings = ProviderSettingsStore(defaults: defaults)
        let secrets = InMemorySecretStore()   // deliberately empty
        let registry = ProviderRegistry(secrets: secrets, transport: MockTransport(), settingsStore: settings)
        let orchestrator = AgentOrchestrator(memory: stack.memory, conversations: stack.conversations,
                                             contextManager: stack.context, registry: stack.registry,
                                             executor: stack.executor, providerRegistry: registry,
                                             settingsStore: settings, capabilities: CapabilityRegistry(),
                                             clock: stack.clock, transport: MockTransport(), secrets: secrets)
        let turn = try await orchestrator.completeTurn("Explain quantum tunnelling", sessionID: nil)
        XCTAssertTrue(turn.handledLocally)
        XCTAssertTrue(turn.assistantText.contains("can't reach a language model"))
        XCTAssertTrue(turn.assistantText.contains("Settings"), "the user must be told exactly what to do")
    }

    // MARK: Provider-backed turns

    func testTurnWithProviderStreamsTextAndPersistsHistory() async throws {
        let (orchestrator, stack, transport, _, settings) = try makeOrchestrator(streams: [textStream("Your project is Jarvis.")])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        _ = try await stack.memory.remember("The user's project is called Jarvis", kind: .fact, subject: "user.project")

        var deltas = ""
        var final: AgentTurn?
        for try await event in orchestrator.send("what is my project?", sessionID: nil) {
            if case .textDelta(let delta) = event { deltas += delta }
            if case .completed(let turn) = event { final = turn }
        }
        XCTAssertEqual(deltas, "Your project is Jarvis.")
        XCTAssertEqual(final?.assistantText, "Your project is Jarvis.")
        XCTAssertFalse(final?.handledLocally ?? true)
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertTrue(transport.recorded[0].headers["Authorization"]?.hasPrefix("Bearer ") ?? false)
        XCTAssertEqual(transport.recorded[0].url.absoluteString, "https://mock.local/v1/chat/completions")

        let sessionID = try XCTUnwrap(final?.sessionID)
        let messages = try stack.conversations.messages(sessionID: sessionID)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.last?.role, .assistant)
    }

    func testRetrievedMemoriesAreReportedToTheUI() async throws {
        let (orchestrator, stack, _, _, settings) = try makeOrchestrator(streams: [textStream("ok")])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        _ = try await stack.memory.remember("The user's project is called Jarvis", kind: .fact, subject: "user.project")
        var used: [ScoredMemory] = []
        for try await event in orchestrator.send("tell me about my project", sessionID: nil) {
            if case .memoryContext(let memories) = event { used = memories }
        }
        XCTAssertFalse(used.isEmpty, "the UI must be able to show which memories were used")
    }

    func testToolCallIsExecutedAndResultFeedsTheNextModelTurn() async throws {
        let streams = [toolCallStream(tool: "reminder.create", arguments: "{\"request\":\"tomorrow at 9am to study\"}"),
                       textStream("Done — you're set for 9am tomorrow.")]
        let (orchestrator, _, transport, scheduler, settings) = try makeOrchestrator(streams: streams)
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))

        var toolResults: [ToolResult] = []
        var final: AgentTurn?
        for try await event in orchestrator.send("please schedule something for tomorrow at 9am to study", sessionID: nil) {
            switch event {
            case .toolFinished(let result): toolResults.append(result)
            case .completed(let turn): final = turn
            default: break
            }
        }
        XCTAssertEqual(scheduler.scheduled.count, 1, "the tool actually scheduled a reminder")
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertTrue(toolResults.first?.success ?? false)
        XCTAssertEqual(transport.recorded.count, 2, "a second model call follows the tool result")
        XCTAssertEqual(final?.toolResults.count, 1)
        XCTAssertTrue(final?.assistantText.contains("9am") ?? false)
    }

    func testToolFailureIsSurfacedToTheModelAndTheUser() async throws {
        let streams = [toolCallStream(tool: "reminder.create", arguments: "{\"request\":\"sometime maybe\"}"),
                       textStream("I couldn't work out when you meant — what time should I set?")]
        let (orchestrator, _, _, scheduler, settings) = try makeOrchestrator(streams: streams)
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        var failures: [ToolResult] = []
        for try await event in orchestrator.send("please schedule something for study sometime maybe", sessionID: nil) {
            if case .toolFinished(let result) = event, !result.success { failures.append(result) }
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(scheduler.scheduled.count, 0, "an unparseable time must not schedule anything")
        XCTAssertNotNil(failures.first?.error)
    }

    func testConfirmationDeclineStopsTheActionAndTellsTheModel() async throws {
        let tool = EchoTool()
        let streams = [toolCallStream(tool: "test.echo", arguments: "{\"message\":\"irreversible thing\"}"),
                       textStream("Understood — I won't do that.")]
        let (orchestrator, _, _, _, settings) = try makeOrchestrator(streams: streams, registered: [tool])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))

        var confirmation: PendingConfirmation?
        var declines: [ToolResult] = []
        let task = Task { () -> Void in
            for try await event in orchestrator.send("do the irreversible thing", sessionID: nil) {
                switch event {
                case .confirmationRequired(let pending):
                    confirmation = pending
                    orchestrator.confirmations.resolve(id: pending.id, approved: false)
                case .toolFinished(let result) where !result.success:
                    declines.append(result)
                default: break
                }
            }
        }
        _ = try await task.value
        XCTAssertNotNil(confirmation)
        XCTAssertEqual(declines.count, 1)
        XCTAssertNil(tool.lastArguments, "the declined tool never ran")
    }

    func testConfirmationApprovalExecutesTheAction() async throws {
        let tool = EchoTool()
        let streams = [toolCallStream(tool: "test.echo", arguments: "{\"message\":\"go ahead\"}"),
                       textStream("Done.")]
        let (orchestrator, _, _, _, settings) = try makeOrchestrator(streams: streams, registered: [tool])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        let task = Task { () -> Void in
            for try await event in orchestrator.send("do the thing", sessionID: nil) {
                if case .confirmationRequired(let pending) = event {
                    orchestrator.confirmations.resolve(id: pending.id, approved: true)
                }
            }
        }
        _ = try await task.value
        XCTAssertEqual(tool.lastArguments?["message"]?.stringValue, "go ahead")
    }

    func testAutoRememberStoresDurableUserStatements() async throws {
        let (orchestrator, stack, _, _, settings) = try makeOrchestrator(streams: [textStream("Noted.")])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        _ = try await orchestrator.completeTurn("I live in Shimla and I prefer concise answers", sessionID: nil)
        let remembered = try stack.memory.all()
        XCTAssertTrue(remembered.contains { $0.text.contains("Shimla") })
        XCTAssertTrue(remembered.contains { $0.kind == .preference })
    }

    func testQuestionsAndHypotheticalsAreNotRemembered() async throws {
        let (orchestrator, stack, _, _, settings) = try makeOrchestrator(streams: [textStream("Maybe.")])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        _ = try await orchestrator.completeTurn("Should I move to Shimla?", sessionID: nil)
        _ = try await orchestrator.completeTurn("If I lived in Shimla, I would hike more", sessionID: nil)
        XCTAssertEqual(try stack.memory.count(), 0, "transient questions and hypotheticals are not memories")
    }

    func testCancellationStopsAnInFlightTurn() async throws {
        let (orchestrator, _, _, _, settings) = try makeOrchestrator(streams: [textStream("partial")])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        let task = Task {
            for try await _ in orchestrator.send("hello", sessionID: nil) {}
        }
        orchestrator.cancelCurrentTurn()
        _ = await task.result
        XCTAssertFalse(orchestrator.isBusy)
    }

    func testSessionTitleIsDerivedFromFirstMessage() async throws {
        let (orchestrator, stack, _, _, settings) = try makeOrchestrator(streams: [textStream("hi")])
        try settings.save(ProviderSettings(providerID: "custom-openai-compatible", model: "mock-model",
                                           baseURLOverride: "https://mock.local/v1"))
        let turn = try await orchestrator.completeTurn("Plan my trip to Manali next month", sessionID: nil)
        let session = try XCTUnwrap(try stack.conversations.session(id: turn.sessionID))
        XCTAssertTrue(session.title.contains("Manali"))
    }
}
