import Foundation

/// The compact "context package" handed to the model on every turn.
///
/// The engine never sends the whole conversation. It sends: standing user
/// instructions, retrieved long-term memories, a rolling summary, the recent
/// turns, the active task, and the tool catalogue — all inside a token budget.
public struct ContextPackage: Sendable {
    public var systemPrompt: String
    public var standingInstructions: [MemoryRecord]
    public var retrievedMemories: [ScoredMemory]
    public var summary: ConversationSummarizer.Summary?
    public var recentMessages: [ConversationMessage]
    public var activeTask: String?
    public var toolNames: [String]
    public var estimatedTokens: Int
    public var compactionNote: String?
    /// External content blocks (already sanitised + delimited) to include as data.
    public var untrustedBlocks: [String]

    public init(systemPrompt: String, standingInstructions: [MemoryRecord], retrievedMemories: [ScoredMemory],
                summary: ConversationSummarizer.Summary?, recentMessages: [ConversationMessage],
                activeTask: String?, toolNames: [String], estimatedTokens: Int,
                compactionNote: String? = nil, untrustedBlocks: [String] = []) {
        self.systemPrompt = systemPrompt
        self.standingInstructions = standingInstructions
        self.retrievedMemories = retrievedMemories
        self.summary = summary
        self.recentMessages = recentMessages
        self.activeTask = activeTask
        self.toolNames = toolNames
        self.estimatedTokens = estimatedTokens
        self.compactionNote = compactionNote
        self.untrustedBlocks = untrustedBlocks
    }

    /// Messages ready to be sent to a provider.
    public func chatMessages(currentUserText: String? = nil, untrustedBlocks: [String] = []) -> [ChatMessage] {
        var messages: [ChatMessage] = [.system(systemPrompt)]

        var memoryBlock = ""
        if !standingInstructions.isEmpty {
            memoryBlock += "### Standing user instructions (highest priority)\n"
            memoryBlock += standingInstructions.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        }
        if !retrievedMemories.isEmpty {
            memoryBlock += "\n### Relevant remembered details\n"
            memoryBlock += retrievedMemories.map { memory in
                let age = memory.record.updatedAt.relativeDescription()
                let trust = memory.record.source.isUntrusted ? " [from external content]" : ""
                return "- \(memory.record.text)  _(\(memory.record.kind.rawValue), updated \(age)\(trust))_"
            }.joined(separator: "\n") + "\n"
        }
        if let summary {
            memoryBlock += "\n### Earlier in this conversation (summary)\n\(summary.text)\n"
            if !summary.constraints.isEmpty {
                memoryBlock += "\nConstraints stated earlier:\n" + summary.constraints.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if !summary.decidedItems.isEmpty {
                memoryBlock += "\nDecisions already taken:\n" + summary.decidedItems.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if !summary.openQuestions.isEmpty {
                memoryBlock += "\nUnresolved questions:\n" + summary.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
        }
        if let activeTask {
            memoryBlock += "\n### Active task\n\(activeTask)\n"
        }
        if !memoryBlock.isEmpty { messages.append(.system(memoryBlock)) }

        for message in recentMessages where message.role != .system {
            switch message.role {
            case .user: messages.append(.user(message.text))
            case .assistant: messages.append(.assistant(message.text))
            case .tool: messages.append(ChatMessage(role: .tool, content: message.text))
            case .system: break
            }
        }

        for block in untrustedBlocks { messages.append(.system(block)) }
        if let currentUserText { messages.append(.user(currentUserText)) }
        return messages
    }
}

public struct ContextConfig: Sendable {
    /// Total budget for the dynamic part of the context (memories + summary + turns).
    public var tokenBudget: Int
    public var reservedForResponse: Int
    public var maxRecentTurns: Int
    public var maxMemories: Int
    /// When the transcript exceeds this many estimated tokens, compact it.
    public var compactionThreshold: Int

    public init(tokenBudget: Int = 12_000, reservedForResponse: Int = 1_500, maxRecentTurns: Int = 12,
                maxMemories: Int = 8, compactionThreshold: Int = 6_000) {
        self.tokenBudget = tokenBudget
        self.reservedForResponse = reservedForResponse
        self.maxRecentTurns = maxRecentTurns
        self.maxMemories = maxMemories
        self.compactionThreshold = compactionThreshold
    }

    public static let `default` = ContextConfig()
}

/// Assembles model input and performs compaction — the "never lose the thread" logic.
public final class ContextManager {
    private let memory: MemoryEngine
    private let conversations: ConversationStore
    public let summarizer: ConversationSummarizer
    private let injectionGuard = PromptInjectionGuard()
    public var config: ContextConfig
    private let systemPromptBuilder: SystemPromptBuilder

    public init(memory: MemoryEngine, conversations: ConversationStore, summarizer: ConversationSummarizer,
                config: ContextConfig = .default, systemPromptBuilder: SystemPromptBuilder = SystemPromptBuilder()) {
        self.memory = memory
        self.conversations = conversations
        self.summarizer = summarizer
        self.config = config
        self.systemPromptBuilder = systemPromptBuilder
    }

    /// Builds the package for the next turn.
    public func buildPackage(sessionID: String, userText: String, tools: [ToolDefinition],
                             now: Date = Date(), extraInstruction: String? = nil,
                             untrustedBlocks: [String] = []) throws -> ContextPackage {
        let standing = try memory.standingInstructions()
        let retrieved = try memory.retrieve(userText, limit: config.maxMemories)
        let stored = try summarizer.latestSummary(sessionID: sessionID)

        // Compaction works on the whole session transcript: capping the window first
        // would silently drop older decisions instead of summarising them.
        let keepCount = max(4, config.maxRecentTurns * 2)
        let transcript = try conversations.messages(sessionID: sessionID, limit: 1_000)
        var recent = Array(transcript.suffix(keepCount))
        var summary: ConversationSummarizer.Summary?
        var compactionNote: String?

        if let stored {
            summary = ConversationSummarizer.Summary(text: stored.text)
        }

        let transcriptTokens = TokenEstimator.estimate(messages: transcript)
        if transcriptTokens > config.compactionThreshold, transcript.count > keepCount + 2 {
            let compactable = Array(transcript.dropLast(keepCount))
            let produced = summarizer.summarize(compactable)
            if let existing = summary {
                // Merge so earlier decisions survive repeated compactions.
                summary = ConversationSummarizer.Summary(
                    text: existing.text + "\n" + produced.text,
                    decidedItems: Array(Set(existing.decidedItems + produced.decidedItems)),
                    openQuestions: Array(Set(existing.openQuestions + produced.openQuestions)),
                    constraints: Array(Set(existing.constraints + produced.constraints)),
                    activeTask: produced.activeTask ?? existing.activeTask,
                    coveredMessageIDs: existing.coveredMessageIDs + produced.coveredMessageIDs
                )
            } else {
                summary = produced
            }
            recent = Array(transcript.suffix(keepCount))
            compactionNote = "Earlier turns were compacted into a summary; decisions and constraints were preserved."
            try? summarizer.persist(summary!, sessionID: sessionID)
        }

        let systemPrompt = systemPromptBuilder.build(now: now, timeZone: TimeZone.current,
                                                     memoryCount: try memory.count(),
                                                     toolNames: tools.map { $0.name },
                                                     extraInstruction: extraInstruction)

        // Trim memories/summary until we fit the budget.
        var memories = retrieved
        var summaryText = summary
        func totalEstimate() -> Int {
            var tokens = TokenEstimator.estimate(systemPrompt)
            tokens += TokenEstimator.estimate(memories.map { $0.record.text }.joined(separator: "\n"))
            tokens += TokenEstimator.estimate(summaryText?.text ?? "")
            tokens += TokenEstimator.estimate(messages: recent)
            tokens += untrustedBlocks.reduce(0) { $0 + TokenEstimator.estimate($1) }
            return tokens
        }
        var droppedMemories = 0
        while totalEstimate() > (config.tokenBudget - config.reservedForResponse), !memories.isEmpty {
            memories.removeLast()
            droppedMemories += 1
        }
        while totalEstimate() > (config.tokenBudget - config.reservedForResponse), recent.count > 2 {
            recent.removeFirst()
        }
        if totalEstimate() > (config.tokenBudget - config.reservedForResponse), summaryText != nil {
            summaryText = ConversationSummarizer.Summary(text: String((summaryText?.text ?? "").prefix(600)),
                                                         constraints: summaryText?.constraints ?? [],
                                                         activeTask: summaryText?.activeTask)
        }
        if droppedMemories > 0 {
            compactionNote = (compactionNote.map { $0 + " " } ?? "") + "\(droppedMemories) lower-ranked memories were omitted to respect the context budget."
        }

        // Untrusted blocks are sanitised and clearly delimited.
        let cleanUntrusted: [String] = untrustedBlocks.map { block in
            injectionGuard.wrapAsUntrusted(block, label: "external")
        }

        return ContextPackage(
            systemPrompt: systemPrompt,
            standingInstructions: standing,
            retrievedMemories: memories,
            summary: summaryText,
            recentMessages: recent,
            activeTask: summaryText?.activeTask,
            toolNames: tools.map { $0.name },
            estimatedTokens: totalEstimate(),
            compactionNote: compactionNote, untrustedBlocks: cleanUntrusted)
    }

    public func makeSummary(sessionID: String) throws -> ConversationSummarizer.Summary {
        let messages = try conversations.messages(sessionID: sessionID)
        return summarizer.summarize(messages)
    }
}
