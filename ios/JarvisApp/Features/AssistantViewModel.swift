import Foundation
import SwiftUI

/// One line in the conversation transcript.
public struct TranscriptItem: Identifiable, Equatable {
    public enum Role { case user, assistant, system, tool }
    public var id: String = UUID().uuidString
    public var role: Role
    public var text: String
    public var createdAt: Date
    public var isStreaming: Bool = false
    public var caption: String?

    public init(role: Role, text: String, createdAt: Date = Date(), isStreaming: Bool = false, caption: String? = nil) {
        self.role = role; self.text = text; self.createdAt = createdAt
        self.isStreaming = isStreaming; self.caption = caption
    }
}

/// Drives the assistant screen. Owns no business logic: it translates engine
/// events into view state and sends user intents back to the orchestrator.
@MainActor
public final class AssistantViewModel: ObservableObject {

    @Published public private(set) var transcript: [TranscriptItem] = []
    @Published public private(set) var state: AssistantState = .idle
    @Published public var composerText: String = ""
    @Published public private(set) var pendingConfirmation: PendingConfirmation?
    @Published public private(set) var memoriesUsed: [ScoredMemory] = []
    @Published public private(set) var toolActivity: [String] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var sessionID: String?
    @Published public private(set) var isDictating = false
    @Published public private(set) var memoryCount = 0

    /// Persisted preference: should replies be spoken?
    @Published public var speaksReplies: Bool {
        didSet { UserDefaults.standard.set(speaksReplies, forKey: Self.speakKey) }
    }
    private static let speakKey = "ai.jarvis.speaksReplies"

    private let environment: AppEnvironment
    private var streamTask: Task<Void, Never>?
    private var didStart = false

    public init(environment: AppEnvironment) {
        self.environment = environment
        self.speaksReplies = UserDefaults.standard.bool(forKey: Self.speakKey)

        environment.speechRecognizer.onFinalTranscript = { [weak self] text in
            guard let self else { return }
            self.isDictating = false
            self.composerText = text
            Task { await self.send() }
        }
        environment.speechSynthesizer.onFinish = { [weak self] in
            guard let self else { return }
            if case .speaking = self.state { self.state = .idle }
        }
    }

    // MARK: Lifecycle

    public func start() async {
        guard !didStart else { return }
        didStart = true
        await environment.refreshCapabilities()
        await refreshMemoryCount()
        await loadLatestSession()
        await greetIfNeeded()
    }

    private func loadLatestSession() async {
        guard let conversations = environment.conversations else { return }
        guard let latest = try? conversations.sessions(limit: 1).first else { return }
        sessionID = latest.id
        let messages = (try? conversations.messages(sessionID: latest.id, limit: 60)) ?? []
        transcript = messages.map { message in
            switch message.role {
            case .user: return TranscriptItem(role: .user, text: message.text, createdAt: message.createdAt)
            case .assistant: return TranscriptItem(role: .assistant, text: message.text,
                                                   createdAt: message.createdAt,
                                                   caption: message.toolCallSummary)
            case .tool: return TranscriptItem(role: .tool, text: message.text, createdAt: message.createdAt)
            case .system: return TranscriptItem(role: .system, text: message.text, createdAt: message.createdAt)
            }
        }
    }

    /// A greeting grounded in real state — time of day, memory count, provider.
    private func greetIfNeeded() async {
        guard transcript.isEmpty else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let partOfDay: String
        switch hour {
        case 5..<12: partOfDay = "Good morning"
        case 12..<17: partOfDay = "Good afternoon"
        case 17..<22: partOfDay = "Good evening"
        default: partOfDay = "Late night"
        }
        var lines = ["\(partOfDay). I'm ready."]
        if memoryCount > 0 {
            lines.append("I remember \(memoryCount) thing\(memoryCount == 1 ? "" : "s") about you — ask me anything, or say “what do you remember”.")
        }
        if !environment.providerState.isUsable {
            lines.append(environment.providerState.explanation)
        }
        transcript = [TranscriptItem(role: .system, text: lines.joined(separator: "\n\n"))]
    }

    public func refreshMemoryCount() async {
        memoryCount = (try? environment.memory?.count()) ?? 0
    }

    // MARK: Conversation

    public func send() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let orchestrator = environment.orchestrator else { return }
        composerText = ""
        lastError = nil
        toolActivity = []
        transcript.append(TranscriptItem(role: .user, text: text))

        var assistantIndex: Int?
        var assistantText = ""

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in orchestrator.send(text, sessionID: self.sessionID) {
                    switch event {
                    case .state(let newState):
                        withAnimation(JarvisTheme.Motion.smooth) { self.state = newState }
                    case .memoryContext(let memories):
                        self.memoriesUsed = memories
                    case .textDelta(let delta):
                        assistantText += delta
                        if let index = assistantIndex {
                            self.transcript[index].text = assistantText
                        } else {
                            self.transcript.append(TranscriptItem(role: .assistant, text: assistantText, isStreaming: true))
                            assistantIndex = self.transcript.count - 1
                        }
                    case .memorySaved(let record):
                        self.transcript.append(TranscriptItem(role: .system, text: "Remembered: \(record.text)",
                                                              caption: record.kind.rawValue))
                        await self.refreshMemoryCount()
                    case .toolProposed(let call):
                        self.toolActivity.append("\(call.name)")
                    case .toolFinished(let result):
                        self.transcript.append(TranscriptItem(role: .tool,
                                                              text: result.summary,
                                                              caption: result.success ? (result.verified ? "verified" : "reported") : "failed"))
                    case .confirmationRequired(let pending):
                        self.pendingConfirmation = pending
                        Haptics.warning()
                    case .completed(let turn):
                        if let index = assistantIndex {
                            self.transcript[index].isStreaming = false
                        } else if !turn.assistantText.isEmpty {
                            self.transcript.append(TranscriptItem(role: .assistant, text: turn.assistantText))
                            assistantIndex = self.transcript.count - 1
                        }
                        self.sessionID = turn.sessionID
                        self.state = .idle
                        await self.refreshMemoryCount()
                        if self.speaksReplies, !turn.assistantText.isEmpty {
                            self.state = .speaking
                            self.environment.speechSynthesizer.speak(turn.assistantText)
                        }
                    case .failed(let error):
                        self.lastError = error.userMessage
                        self.state = .failed(message: error.userMessage)
                        Haptics.error()
                    }
                }
            } catch {
                self.lastError = JarvisError.unexpected(error.localizedDescription).userMessage
                self.state = .failed(message: self.lastError ?? "Something went wrong.")
            }
        }
        await streamTask?.value
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
        environment.orchestrator?.cancelCurrentTurn()
        environment.orchestrator?.confirmations.declineAll(reason: "turn cancelled")
        environment.speechSynthesizer.stop()
        state = .idle
    }

    // MARK: Confirmation

    public func approveConfirmation() {
        guard let pending = pendingConfirmation, let orchestrator = environment.orchestrator else { return }
        Haptics.success()
        orchestrator.confirmations.resolve(id: pending.id, approved: true, reason: "approved in UI")
        pendingConfirmation = nil
    }

    public func declineConfirmation() {
        guard let pending = pendingConfirmation, let orchestrator = environment.orchestrator else { return }
        Haptics.tap()
        orchestrator.confirmations.resolve(id: pending.id, approved: false, reason: "declined in UI")
        pendingConfirmation = nil
    }

    // MARK: Voice

    public func toggleDictation() async {
        if isDictating {
            environment.speechRecognizer.stop()
            isDictating = false
            return
        }
        do {
            try await environment.speechRecognizer.start()
            isDictating = true
            state = .listening
            Haptics.tap()
        } catch let error as JarvisError {
            lastError = error.userMessage
            state = .failed(message: error.userMessage)
            isDictating = false
        } catch {
            lastError = error.localizedDescription
            isDictating = false
        }
    }

    public func stopSpeaking() {
        environment.speechSynthesizer.stop()
        if case .speaking = state { state = .idle }
    }

    public func startNewConversation() async {
        cancel()
        guard let conversations = environment.conversations else { return }
        let session = try? conversations.createSession(title: "New conversation")
        sessionID = session?.id
        transcript = []
        memoriesUsed = []
        await greetIfNeeded()
    }

    /// Live microphone level, or the synthesiser envelope while speaking.
    public var orbLevel: Double {
        if isDictating { return environment.speechRecognizer.level }
        if case .speaking = state { return environment.speechSynthesizer.level }
        return 0
    }

    public var waveformLevels: [Double] {
        if isDictating { return environment.speechRecognizer.levels }
        if case .speaking = state { return environment.speechSynthesizer.levels }
        return Array(repeating: 0, count: 28)
    }
}
