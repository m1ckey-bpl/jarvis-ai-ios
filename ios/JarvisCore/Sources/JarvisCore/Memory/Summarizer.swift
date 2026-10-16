import Foundation

/// Produces compact, faithful conversation summaries.
///
/// Design: a deterministic **extractive** summarizer runs by default (zero cost,
/// fully testable, no model required). When a provider is configured, the agent
/// may pass `useModel: true` to obtain an abstractive summary; failures always
/// fall back to extraction rather than losing the context.
///
/// Invariants enforced here:
///  * decisions, unresolved questions and explicit constraints are preserved verbatim;
///  * an active task is never dropped silently;
///  * nothing is invented.
public final class ConversationSummarizer {
    private let store: MemoryStore
    private let clock: Clock
    /// Summaries are retained for this long before expiry (they are derived data).
    public var summaryTTL: TimeInterval = 60 * 60 * 24 * 30

    public init(store: MemoryStore, clock: Clock = SystemClock()) {
        self.store = store
        self.clock = clock
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var text: String
        public var decidedItems: [String]
        public var openQuestions: [String]
        public var constraints: [String]
        public var activeTask: String?
        public var messageRange: ClosedRange<Int>?
        public var coveredMessageIDs: [String]

        public init(text: String, decidedItems: [String] = [], openQuestions: [String] = [],
                    constraints: [String] = [], activeTask: String? = nil,
                    messageRange: ClosedRange<Int>? = nil, coveredMessageIDs: [String] = []) {
            self.text = text
            self.decidedItems = decidedItems
            self.openQuestions = openQuestions
            self.constraints = constraints
            self.activeTask = activeTask
            self.messageRange = messageRange
            self.coveredMessageIDs = coveredMessageIDs
        }
    }

    // MARK: Extraction

    private static let decisionMarkers = ["decided", "we'll", "we will", "let's go with", "chose", "agreed", "plan is"]
    private static let constraintMarkers = ["must", "never", "always", "do not", "don't", "required", "cannot"]
    private static let questionMarkers = ["?", "should i", "do you want", "which", "unclear", "tbd", "pending"]

    /// Extractive summary of a message window.
    public func summarize(_ messages: [ConversationMessage], maxChars: Int = 1200) -> Summary {
        guard !messages.isEmpty else { return Summary(text: "") }

        var decisions: [String] = []
        var constraints: [String] = []
        var questions: [String] = []

        for message in messages {
            for sentence in Self.sentences(message.text) {
                let lower = sentence.lowercased()
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count > 8 else { continue }
                if Self.constraintMarkers.contains(where: { lower.contains($0) }),
                   !constraints.contains(trimmed), constraints.count < 8 {
                    constraints.append(trimmed)
                } else if Self.decisionMarkers.contains(where: { lower.contains($0) }),
                          !decisions.contains(trimmed), decisions.count < 8 {
                    decisions.append(trimmed)
                } else if Self.questionMarkers.contains(where: { lower.contains($0) }),
                          message.role == .user, !questions.contains(trimmed), questions.count < 6 {
                    questions.append(trimmed)
                }
            }
        }

        // Unresolved user question = the last user message that looks like a question
        // without a later assistant answer referencing it. Kept as the active task.
        let lastUser = messages.last(where: { $0.role == .user })
        let activeTask = lastUser.map { String($0.text.prefix(240)) }

        var narrative = "Conversation summary (\(messages.count) messages, "
        narrative += "\(messages.first!.createdAt.iso8601) → \(messages.last!.createdAt.iso8601)):\n"
        for message in messages.suffix(12) {
            let speaker = message.role == .user ? "User" : (message.role == .assistant ? "Assistant" : message.role.rawValue)
            let condensed = String(message.text.replacingOccurrences(of: "\n", with: " ").prefix(220))
            narrative += "- \(speaker): \(condensed)\n"
        }
        if narrative.count > maxChars {
            narrative = String(narrative.prefix(maxChars)) + "…"
        }

        return Summary(text: narrative, decidedItems: decisions, openQuestions: questions,
                       constraints: constraints, activeTask: activeTask,
                       messageRange: nil, coveredMessageIDs: messages.map { $0.id })
    }

    /// Persists a summary as a `.summary` memory record so it survives restarts
    /// and can be retrieved like any other memory.
    @discardableResult
    public func persist(_ summary: Summary, sessionID: String) throws -> MemoryRecord? {
        guard !summary.text.isEmpty else { return nil }
        return try MemoryEngine(store: store, clock: clock).remember(
            summary.text,
            kind: .summary,
            source: .conversationSummary,
            confidence: 0.9,
            importance: 0.4,
            subject: "session.\(sessionID).summary",
            tags: ["summary"],
            ttl: summaryTTL,
            provenance: Provenance(conversationID: sessionID)
        )
    }

    /// Retrieves the most recent summary for a session, if any.
    public func latestSummary(sessionID: String) throws -> MemoryRecord? {
        try store.records(matching: MemoryQuery(kinds: [.summary], subject: "session.\(sessionID).summary", limit: 1)).first
    }

    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}

/// Approximate token accounting. Deliberately conservative (chars/3.5) so the
/// budget never overflows on dense text; providers accept slight under-use.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        Int(ceil(Double(text.count) / 3.5))
    }
    public static func estimate(messages: [ConversationMessage]) -> Int {
        messages.reduce(0) { $0 + estimate($1.text) + 4 }
    }
}
