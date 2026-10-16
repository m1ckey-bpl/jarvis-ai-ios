import Foundation

/// A single, fully-executed assistant turn (what actually happened).
public struct AgentTurn: Sendable, Equatable {
    public var sessionID: String
    public var userText: String
    public var assistantText: String
    public var toolResults: [String]
    public var usedMemories: [String]
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var providerIdentifier: String
    public var handledLocally: Bool
}

/// Events streamed to the UI while a turn runs.
public enum AgentEvent: Sendable {
    case state(AssistantState)
    case memoryContext([ScoredMemory])
    case textDelta(String)
    case toolProposed(ToolCallRequest)
    case toolFinished(ToolResult)
    case confirmationRequired(PendingConfirmation)
    case memorySaved(MemoryRecord)
    case completed(AgentTurn)
    case failed(JarvisError)
}

public struct AgentConfiguration: Sendable {
    /// Maximum tool round-trips inside a single user turn.
    public var maxToolIterations: Int
    /// Hard ceiling on a whole turn.
    public var turnTimeoutSeconds: Double
    /// Automatically persist candidate memories after each user message.
    public var autoRemember: Bool
    /// Summarise the transcript once it exceeds this many messages.
    public var autoSummarizeAfterMessages: Int

    public init(maxToolIterations: Int = 4, turnTimeoutSeconds: Double = 180,
                autoRemember: Bool = true, autoSummarizeAfterMessages: Int = 30) {
        self.maxToolIterations = maxToolIterations
        self.turnTimeoutSeconds = turnTimeoutSeconds
        self.autoRemember = autoRemember
        self.autoSummarizeAfterMessages = autoSummarizeAfterMessages
    }

    public static let `default` = AgentConfiguration()
}

/// Handles intents that must work even with no AI provider configured.
///
/// This is what keeps memory, reminders and the clock useful on a brand-new
/// install (zero-cost, offline-tolerant), while the model handles everything else.
public struct LocalIntentRouter {
    private let parser = MemoryCommandParser()

    public init() {}

    public enum Resolution: Sendable {
        case reply(String, toolResults: [String])
        case notHandled
    }

    public func route(_ input: String, memory: MemoryEngine, reminders: ReminderEngine?,
                      clock: Clock, sessionID: String?) async -> Resolution {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // --- Memory commands -------------------------------------------------
        if let command = parser.parse(text, now: clock.now, timeZone: clock.timeZone) {
            do {
                switch command {
                case .remember(let body, let asInstruction):
                    let record = try memory.remember(
                        body,
                        kind: asInstruction ? .instruction : .fact,
                        source: .userStated,
                        confidence: asInstruction ? 0.95 : 0.9,
                        importance: asInstruction ? 0.95 : 0.6,
                        subject: MemoryCommandParser.subjectKey(for: body),
                        provenance: Provenance(conversationID: sessionID)
                    )
                    return .reply("Saved. I'll remember that \(record.text.prefix(1).lowercased() + record.text.dropFirst())",
                                  toolResults: ["memory.remember → \(record.id)"])
                case .recall(let query):
                    let results = try memory.retrieve(query, limit: 6)
                    guard !results.isEmpty else {
                        return .reply("I don't have anything stored about “\(query)” yet.", toolResults: ["memory.search → 0 results"])
                    }
                    let lines = results.map { "• \($0.record.text)  _(\($0.record.updatedAt.relativeDescription(from: clock.now)))_" }
                    return .reply("Here's what I have about “\(query)”:\n" + lines.joined(separator: "\n"),
                                  toolResults: ["memory.search → \(results.count) results"])
                case .recallByDate(let kind, let since):
                    let records = try memory.all().filter { $0.kind == kind && (since == nil || $0.createdAt >= since!) }
                    guard !records.isEmpty else { return .reply("No \(kind.rawValue) records found for that period.", toolResults: []) }
                    let lines = records.prefix(10).map { "• \($0.text)  _(\($0.createdAt.iso8601))_" }
                    return .reply("Recorded \(kind.rawValue)s:\n" + lines.joined(separator: "\n"),
                                  toolResults: ["memory.search → \(records.count)"])
                case .forget(let query, let confirmed):
                    if !confirmed {
                        let matches = try memory.forget(matching: query, dryRun: true)
                        guard !matches.isEmpty else { return .reply("Nothing stored matches “\(query)”.", toolResults: []) }
                        return .reply("I'll delete:\n" + matches.map { "• \($0.text)" }.joined(separator: "\n") + "\n\nSay “forget \(query), confirm” to delete them.",
                                      toolResults: ["memory.forget → dry run"])
                    }
                    let deleted = try memory.forget(matching: query, dryRun: false)
                    return .reply("Deleted \(deleted.count) item(s) from memory.", toolResults: ["memory.forget → \(deleted.count)"])
                case .correct(let newText):
                    let recent = try memory.all().first
                    guard let recent else { return .reply("There's nothing stored that I could correct yet.", toolResults: []) }
                    let corrected = try memory.correct(id: recent.id, newText: newText)
                    return .reply("Updated. I now remember: \(corrected.text)", toolResults: ["memory.correct → \(corrected.id)"])
                case .exportMemory:
                    let export = try memory.export(format: .markdown)
                    return .reply("Here is everything I remember:\n\n\(export)", toolResults: ["memory.export → markdown"])
                case .wipe(let confirmed):
                    guard confirmed else { return .reply("That deletes every memory on this device. Say “clear my memory, confirm” to proceed.", toolResults: []) }
                    try memory.forgetAll()
                    return .reply("All memories have been deleted from this device.", toolResults: ["memory.forgetAll"])
                }
            } catch let error as JarvisError {
                return .reply(error.userMessage, toolResults: [])
            } catch {
                return .reply("I couldn't complete that memory operation.", toolResults: [])
            }
        }

        // --- Time ------------------------------------------------------------
        if ["what time is it", "what's the time", "whats the time", "current time", "what's today's date", "what is the date"].contains(where: { lower.contains($0) }) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = clock.timeZone
            formatter.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"
            return .reply("It's \(formatter.string(from: clock.now)) (\(clock.timeZone.identifier)).", toolResults: ["time.now"])
        }

        // --- Reminders (deterministic path when no model is configured) -------
        if let reminders {
            if lower.hasPrefix("remind me") || lower.hasPrefix("set a reminder") || lower.hasPrefix("add a reminder") {
                do {
                    let receipt = try await reminders.create(fromNaturalLanguage: text)
                    return .reply("\(receipt.reminder.title) — \(receipt.reminder.describe()). \(receipt.note)",
                                  toolResults: ["reminder.create → \(receipt.reminder.id)"])
                } catch let error as JarvisError {
                    return .reply(error.userMessage, toolResults: ["reminder.create → failed"])
                } catch {
                    return .reply("I couldn't schedule that reminder.", toolResults: [])
                }
            }
            if lower.contains("show my reminders") || lower.contains("my reminders") || lower.contains("what are my reminders") {
                let items = (try? reminders.upcoming(limit: 10)) ?? []
                guard !items.isEmpty else { return .reply("You have no open reminders.", toolResults: ["reminder.list → 0"]) }
                return .reply("Upcoming reminders:\n" + items.map { "• \($0.title) — \($0.describe())" }.joined(separator: "\n"),
                              toolResults: ["reminder.list → \(items.count)"])
            }
            if lower.hasPrefix("cancel my") && lower.contains("reminder") {
                let cancelled = (try? await reminders.cancel(matching: text)) ?? []
                guard !cancelled.isEmpty else { return .reply("I couldn't find an open reminder matching that.", toolResults: []) }
                return .reply("Cancelled: " + cancelled.map { $0.title }.joined(separator: ", "), toolResults: ["reminder.cancel → \(cancelled.count)"])
            }
        }

        return .notHandled
    }
}

/// The agent. Owns the turn pipeline: context → provider → tools → memory → persistence.
public final class AgentOrchestrator {
    // Dependencies
    public let memory: MemoryEngine
    public let conversations: ConversationStore
    public let contextManager: ContextManager
    public let registry: ToolRegistry
    public let executor: ToolExecutor
    public let providerRegistry: ProviderRegistry
    public let capabilities: CapabilityRegistry
    public let clock: Clock
    public let confirmations = ConfirmationBroker()
    public var configuration: AgentConfiguration
    /// Optional integrations (GitHub, Gmail, …). Nil means the tools report "not configured".
    public var integrations: IntegrationHub?
    public var transport: HTTPTransport
    public var secrets: SecretStore
    /// The reminder engine, when the app wired one up. Held strongly: a silently-nil
    /// weak reference would make reminder tools fail with a confusing "unavailable".
    public var reminderEngine: ReminderEngine?
    private let extractor = MemoryExtractor()
    private let localRouter = LocalIntentRouter()
    private let settingsStore: ProviderSettingsStore
    /// Optional hook so the UI can open deep links produced by tools.
    public var onDeepLink: (@Sendable (URL) -> Void)?

    private var currentTask: Task<Void, Never>?
    private let lock = NSLock()

    public init(memory: MemoryEngine,
                conversations: ConversationStore,
                contextManager: ContextManager,
                registry: ToolRegistry,
                executor: ToolExecutor,
                providerRegistry: ProviderRegistry,
                settingsStore: ProviderSettingsStore,
                capabilities: CapabilityRegistry,
                clock: Clock = SystemClock(),
                configuration: AgentConfiguration = .default,
                integrations: IntegrationHub? = nil,
                transport: HTTPTransport = URLSessionTransport(),
                secrets: SecretStore = InMemorySecretStore()) {
        self.memory = memory
        self.conversations = conversations
        self.contextManager = contextManager
        self.registry = registry
        self.executor = executor
        self.providerRegistry = providerRegistry
        self.settingsStore = settingsStore
        self.capabilities = capabilities
        self.clock = clock
        self.configuration = configuration
        self.integrations = integrations
        self.transport = transport
        self.secrets = secrets

        // The engine decides; the broker asks the human.
        executor.confirmationHandler = { [weak confirmer = confirmations] confirmation in
            guard let confirmer else { return false }
            return await confirmer.request(confirmation)
        }
    }

    // MARK: Session helpers

    public func ensureSession(preferred: String?) throws -> ConversationSession {
        if let preferred, let session = try conversations.session(id: preferred) { return session }
        return try conversations.createSession(title: "New conversation", at: clock.now)
    }

    /// Cancels any in-flight turn (user pressed stop, or a new turn started).
    public func cancelCurrentTurn() {
        lock.lock()
        let task = currentTask
        currentTask = nil
        lock.unlock()
        task?.cancel()
    }

    public var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentTask != nil
    }

    // MARK: The pipeline

    /// Runs one user turn, streaming events until it completes or fails.
    public func send(_ userText: String, sessionID: String?) -> AsyncThrowingStream<AgentEvent, Error> {
        cancelCurrentTurn()
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await self.runTurn(userText: userText, sessionID: sessionID) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch let error as JarvisError {
                    continuation.yield(.failed(error))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(.unexpected(error.localizedDescription)))
                    continuation.finish()
                }
            }
            lock.lock(); currentTask = task; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.lock.lock(); self?.currentTask = nil; self?.lock.unlock()
            }
        }
    }

    private func runTurn(userText: String, sessionID: String?, emit: @escaping @Sendable (AgentEvent) -> Void) async throws {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JarvisError.invalidArguments("empty message") }

        let session = try ensureSession(preferred: sessionID)
        try conversations.append(ConversationMessage(sessionID: session.id, role: .user, text: trimmed, createdAt: clock.now))

        // Keep history tidy for very long sessions.
        let count = try conversations.messageCount(sessionID: session.id)
        if count > configuration.autoSummarizeAfterMessages {
            let summary = try contextManager.makeSummary(sessionID: session.id)
            try? contextManager.summarizer.persist(summary, sessionID: session.id)
            emit(.state(.thinking(detail: "Compacting earlier conversation…")))
        }

        // --- 1. Local, deterministic intents (work with no provider) ---------
        let local = await localRouter.route(trimmed, memory: memory, reminders: reminderEngine,
                                            clock: clock, sessionID: session.id)
        if case .reply(let text, let toolResults) = local {
            try conversations.append(ConversationMessage(sessionID: session.id, role: .assistant, text: text,
                                                         createdAt: clock.now, toolCallSummary: toolResults.joined(separator: ", ")))
            emit(.state(.idle))
            emit(.completed(AgentTurn(sessionID: session.id, userText: trimmed, assistantText: text,
                                      toolResults: toolResults, usedMemories: [],
                                      providerIdentifier: "local-rules", handledLocally: true)))
            return
        }

        // --- 2. Provider must exist for anything else ------------------------
        guard let provider = try providerRegistry.activeProvider() else {
            let message = "I can't reach a language model yet. Open Settings ▸ AI Providers and add a free provider key (Groq or Google AI Studio both have free tiers) — memory and reminders keep working in the meantime."
            try conversations.append(ConversationMessage(sessionID: session.id, role: .assistant, text: message, createdAt: clock.now))
            emit(.state(.failed(message: "No provider configured")))
            emit(.completed(AgentTurn(sessionID: session.id, userText: trimmed, assistantText: message,
                                      toolResults: [], usedMemories: [], providerIdentifier: "none", handledLocally: true)))
            return
        }

        let settings = try settingsStore.settings() ?? ProviderSettings(providerID: provider.id, model: provider.defaultModel)

        // --- 3. Build context -------------------------------------------------
        let definitions = registry.availableDefinitions(context: makeToolContext(sessionID: session.id))
        let package = try contextManager.buildPackage(sessionID: session.id, userText: trimmed, tools: definitions, now: clock.now)
        emit(.memoryContext(package.retrievedMemories))
        if let note = package.compactionNote { emit(.state(.thinking(detail: note))) }

        // The executor asks the broker; the broker asks the user through this stream.
        confirmations.onRequest = { pending in
            emit(.state(.awaitingConfirmation(tool: pending.toolName)))
            emit(.confirmationRequired(pending))
        }
        defer { confirmations.onRequest = nil }

        var messages = package.chatMessages(currentUserText: trimmed, untrustedBlocks: package.untrustedBlocks)
        var assistantText = ""
        var toolSummaries: [String] = []
        var iterations = 0
        var lastUsage: (Int?, Int?) = (nil, nil)

        // --- 4. Model ↔ tool loop --------------------------------------------
        while iterations < configuration.maxToolIterations {
            iterations += 1
            emit(.state(.thinking(detail: iterations == 1 ? nil : "Using what I learned…")))

            let request = ChatRequest(messages: messages, tools: definitions,
                                      temperature: settings.temperature,
                                      maxOutputTokens: settings.maxOutputTokens,
                                      model: settings.model,
                                      toolChoice: definitions.isEmpty ? .none : .auto)

            var streamedText = ""
            var toolCalls: [ToolCallRequest] = []
            var failure: JarvisError?

            for try await event in provider.stream(request) {
                if Task.isCancelled { throw JarvisError.cancelled }
                switch event {
                case .started: break
                case .textDelta(let delta):
                    streamedText += delta
                    emit(.textDelta(delta))
                case .toolCallStarted(let name):
                    emit(.state(.executing(tool: name, detail: "Preparing request…")))
                case .toolCallArgumentsDelta: break
                case .completed(let response):
                    toolCalls = response.toolCalls
                    lastUsage = (response.promptTokens ?? lastUsage.0, response.completionTokens ?? lastUsage.1)
                case .failed(let error):
                    failure = error
                }
            }
            if let failure { throw failure }

            assistantText = streamedText
            if toolCalls.isEmpty {
                messages.append(.assistant(streamedText))
                break
            }

            // The model proposed tools. The engine decides whether they may run.
            messages.append(ChatMessage(role: .assistant, content: streamedText, toolCalls: toolCalls))
            for call in toolCalls {
                emit(.toolProposed(call))
                emit(.state(.executing(tool: call.name, detail: "Running…")))
                let context = makeToolContext(sessionID: session.id)
                let outcome = await executor.execute(name: call.name, arguments: call.arguments, context: context)
                switch outcome {
                case .success(let summary, _):
                    toolSummaries.append(summary)
                    let result = ToolResult(toolName: call.name, success: true, summary: summary, verified: true)
                    emit(.toolFinished(result))
                    messages.append(ChatMessage(role: .tool, content: summary, toolCallID: call.id))
                case .needsConfirmation(let pending):
                    emit(.state(.awaitingConfirmation(tool: call.name)))
                    emit(.confirmationRequired(pending))
                    let approved = await confirmations.request(pending)
                    if approved {
                        let retry = await executor.execute(name: call.name, arguments: call.arguments,
                                                           context: makeToolContext(sessionID: session.id),
                                                           options: .init(userApproved: true))
                        switch retry {
                        case .success(let summary, _):
                            toolSummaries.append(summary)
                            emit(.toolFinished(ToolResult(toolName: call.name, success: true, summary: summary, verified: true)))
                            messages.append(ChatMessage(role: .tool, content: summary, toolCallID: call.id))
                        case .failed(let error):
                            emit(.toolFinished(.failure(call.name, error)))
                            messages.append(ChatMessage(role: .tool, content: "Tool \(call.name) failed: \(error.userMessage)", toolCallID: call.id))
                        case .cancelled, .needsConfirmation:
                            messages.append(ChatMessage(role: .tool, content: "Tool \(call.name) was not executed.", toolCallID: call.id))
                        }
                    } else {
                        emit(.toolFinished(ToolResult(toolName: call.name, success: false,
                                                      summary: "The user declined to run \(call.name).", verified: false,
                                                      error: .policyBlocked("declined by user"))))
                        messages.append(ChatMessage(role: .tool, content: "The user declined this action. Do not retry it; acknowledge and continue.", toolCallID: call.id))
                    }
                case .failed(let error):
                    emit(.toolFinished(.failure(call.name, error)))
                    messages.append(ChatMessage(role: .tool, content: "Tool \(call.name) failed: \(error.userMessage)", toolCallID: call.id))
                case .cancelled:
                    // The turn itself may have been cancelled, or the user declined.
                    if Task.isCancelled { throw JarvisError.cancelled }
                    let declined = ToolResult(toolName: call.name, success: false,
                                              summary: "The user declined to run \(call.name).", verified: false,
                                              error: .policyBlocked("declined by user"))
                    emit(.toolFinished(declined))
                    messages.append(ChatMessage(role: .tool,
                                                content: "The user declined this action. Do not retry it; acknowledge briefly and continue.",
                                                toolCallID: call.id))
                }
            }

            if iterations >= configuration.maxToolIterations {
                assistantText += "\n\n_(I stopped after \(iterations) tool steps to avoid looping.)_"
                break
            }
        }

        // --- 5. Persist, remember, speak --------------------------------------
        let finalText = assistantText.isEmpty
            ? (toolSummaries.isEmpty ? "I didn't produce a response. Please try again." : toolSummaries.joined(separator: "\n"))
            : assistantText

        try conversations.append(ConversationMessage(sessionID: session.id, role: .assistant, text: finalText,
                                                     createdAt: clock.now,
                                                     toolCallSummary: toolSummaries.isEmpty ? nil : toolSummaries.joined(separator: " | "),
                                                     promptTokens: lastUsage.0, completionTokens: lastUsage.1))

        if configuration.autoRemember {
            let newlyStored = (try? extractor.persist(trimmed, memory: memory, sessionID: session.id)) ?? []
            for record in newlyStored { emit(.memorySaved(record)) }
        }

        // Title the session from the first user message (cheap, local).
        if (try? conversations.messageCount(sessionID: session.id)) == 2 {
            try? conversations.rename(sessionID: session.id, title: String(trimmed.prefix(60)), at: clock.now)
        }

        emit(.state(.idle))
        emit(.completed(AgentTurn(sessionID: session.id, userText: trimmed, assistantText: finalText,
                                  toolResults: toolSummaries, usedMemories: package.retrievedMemories.map { $0.record.text },
                                  promptTokens: lastUsage.0, completionTokens: lastUsage.1,
                                  providerIdentifier: provider.id, handledLocally: false)))
    }

    // MARK: Helpers

    private func makeToolContext(sessionID: String?) -> ToolExecutionContext {
        ToolExecutionContext(clock: clock, memory: memory, reminders: reminderEngine,
                             integrations: integrations, transport: transport, secrets: secrets,
                             sessionID: sessionID)
    }

    /// Convenience for the UI: stream a turn and return the final text.
    public func completeTurn(_ text: String, sessionID: String?) async throws -> AgentTurn {
        var turn: AgentTurn?
        var failure: JarvisError?
        for try await event in send(text, sessionID: sessionID) {
            switch event {
            case .completed(let finished): turn = finished
            case .failed(let error): failure = error
            default: break
            }
        }
        if let turn { return turn }
        throw failure ?? JarvisError.unexpected("the turn ended without a result")
    }
}
