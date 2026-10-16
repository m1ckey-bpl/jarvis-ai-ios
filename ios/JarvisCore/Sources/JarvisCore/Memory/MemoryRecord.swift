import Foundation

/// What kind of thing is remembered. Drives retention, conflict resolution and
/// how the record is presented to the model.
public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    /// Stable, verifiable fact about the user or their world ("lives in Shimla").
    case fact
    /// Preference ("prefers concise answers", "uses dark mode").
    case preference
    /// Long-term objective ("ship the beta by December").
    case goal
    /// Date-anchored item ("anniversary is 12 March").
    case importantDate
    /// A decision taken during work ("chose SQLite over SwiftData").
    case decision
    /// An open task that is *not* a scheduled reminder.
    case task
    /// Explicit user instruction that must be obeyed ("always answer in English",
    /// "never email without asking"). Always highest priority.
    case instruction
    /// Something the assistant inferred rather than being told. Lower confidence.
    case inference
    /// A correction that supersedes an earlier record.
    case correction
    /// Compacted conversation summary (bounded lifetime).
    case summary

    /// Base retrieval weight — user instructions outrank weak inferences
    /// (spec §7: "Store explicit user instructions with higher priority than
    /// weakly inferred preferences").
    public var baseWeight: Double {
        switch self {
        case .instruction: return 1.00
        case .correction: return 0.98
        case .preference: return 0.92
        case .fact: return 0.90
        case .goal: return 0.85
        case .decision: return 0.84
        case .importantDate: return 0.82
        case .task: return 0.80
        case .summary: return 0.55
        case .inference: return 0.45
        }
    }

    /// Kinds whose records are always injected into context when active.
    public var isPinnedToContext: Bool { self == .instruction }
}

/// Where the record came from. External content is never trusted as instruction.
public enum MemorySource: String, Codable, Sendable {
    case userStated          // user said it explicitly
    case userCorrected       // user corrected a previously stored item
    case conversationSummary // produced by the summarizer from a dialogue
    case inferred            // model/engine inference
    case importedExternal    // email, web page, document — UNTRUSTED
    case systemDerived       // e.g. schedule metadata

    /// Untrusted provenance: must be wrapped as data, never obeyed as instruction.
    public var isUntrusted: Bool { self == .importedExternal }
}

public enum MemoryStatus: String, Codable, CaseIterable, Sendable {
    case active
    case superseded   // replaced by a newer record
    case expired      // passed its retention date
    case archived
}

/// Optional pointer back to what produced the memory (auditability).
public struct Provenance: Codable, Equatable, Sendable {
    public var conversationID: String?
    public var messageID: String?
    public var externalLabel: String?   // "Gmail: invoice thread", "github:repo#42"
    public var note: String?

    public init(conversationID: String? = nil, messageID: String? = nil, externalLabel: String? = nil, note: String? = nil) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.externalLabel = externalLabel
        self.note = note
    }
}

/// A single durable memory record.
public struct MemoryRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: MemoryKind
    public var text: String
    /// Normalised topic key used for conflict detection ("user.timezone").
    public var subject: String?
    public var tags: [String]
    public var source: MemorySource
    /// 0…1 — how sure the engine is that this is true.
    public var confidence: Double
    /// 0…1 — how much it matters to the user.
    public var importance: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var lastAccessedAt: Date?
    public var accessCount: Int
    /// Retention: when this record stops being true/relevant.
    public var expiresAt: Date?
    public var status: MemoryStatus
    public var supersededBy: String?
    /// True for explicit user instructions: never auto-overwritten.
    public var locked: Bool
    public var provenance: Provenance?

    public init(
        id: String = UUID().uuidString,
        kind: MemoryKind,
        text: String,
        subject: String? = nil,
        tags: [String] = [],
        source: MemorySource,
        confidence: Double = 0.8,
        importance: Double = 0.5,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        lastAccessedAt: Date? = nil,
        accessCount: Int = 0,
        expiresAt: Date? = nil,
        status: MemoryStatus = .active,
        supersededBy: String? = nil,
        locked: Bool = false,
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.subject = subject
        self.tags = tags
        self.source = source
        self.confidence = confidence
        self.importance = importance
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
        self.expiresAt = expiresAt
        self.status = status
        self.supersededBy = supersededBy
        self.locked = locked
        self.provenance = provenance
    }

    public var isActive: Bool { status == .active }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }

    /// Normalised token set used for near-duplicate detection.
    public var tokenSet: Set<String> { TextNormalizer.tokens(text) }
}

/// Text normalisation shared by memory, search and parsing.
public enum TextNormalizer {
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be", "been",
        "to", "of", "in", "on", "at", "for", "with", "that", "this", "it", "i", "my", "me"
    ]

    public static func tokens(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        let parts = lower.components(separatedBy: separators).filter { !$0.isEmpty }
        var set = Set<String>()
        for part in parts where part.count > 1 && !stopWords.contains(part) {
            set.insert(stem(part))
        }
        return set
    }

    /// True when a token carries no search signal on its own.
    public static func isStopWord(_ token: String) -> Bool { stopWords.contains(token.lowercased()) || token.count < 2 }

    /// Terms used for search matching: stemmed, stopword-free. Without this,
    /// "my pet iguana" would match any record containing the word "my".
    public static func searchTerms(_ text: String) -> [String] {
        var seen = Set<String>()
        return tokenList(text)
            .filter { !isStopWord($0) }
            .map { stem($0) }
            .filter { seen.insert($0).inserted }
    }

    public static func tokenList(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Extremely light stemmer (suffix folding) — good enough for dedupe/FTS hints.
    public static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "edly", "ed", "es", "s"] where w.count > 4 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count))
            break
        }
        return w
    }

    /// Jaccard similarity of token sets — the near-duplicate test.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        if ta.isEmpty || tb.isEmpty { return a.lowercased() == b.lowercased() ? 1 : 0 }
        let intersection = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Double(intersection) / Double(union)
    }
}
