import Foundation

/// Decides **what is worth remembering** — the guard against hoarding every sentence.
///
/// Rules (constitution §"memory quality"):
///  * explicit instructions and stable facts are stored with high confidence;
///  * questions, hypotheticals, transient chatter and third-party small talk are not;
///  * everything carries provenance so the user can audit and correct it.
public struct MemoryExtractor {
    public struct Candidate: Equatable, Sendable {
        public var text: String
        public var kind: MemoryKind
        public var confidence: Double
        public var subject: String?
        public var reason: String
    }

    public init() {}

    public func candidates(from userText: String) -> [Candidate] {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6, text.count <= 600 else { return [] }
        let lower = text.lowercased()

        // Never learn from questions, hypotheticals or quoted third-party speech.
        if lower.hasSuffix("?") { return [] }
        if lower.contains("if i ") || lower.contains("what if") || lower.contains("suppose ") { return [] }
        if lower.contains("he said") || lower.contains("she said") || lower.contains("they said") { return [] }

        var results: [Candidate] = []
        let subject = MemoryCommandParser.subjectKey(for: text)

        // Explicit instruction — highest priority.
        if ["always ", "never ", "from now on", "remember to", "make sure you", "don't ever", "do not ever"].contains(where: { lower.contains($0) }) {
            results.append(Candidate(text: text, kind: .instruction, confidence: 0.95, subject: subject,
                                     reason: "explicit instruction"))
        }

        // First-person stable facts.
        let factMarkers = ["i live in", "i am based in", "my name is", "i work at", "i work as",
                           "i study", "my birthday", "my anniversary", "i use ", "i speak", "i have a ",
                           "i drive", "i own", "my email is", "my number is"]
        if factMarkers.contains(where: { lower.contains($0) }) {
            results.append(Candidate(text: text, kind: .fact, confidence: 0.88, subject: subject,
                                     reason: "stable first-person fact"))
        }

        // Preferences.
        let preferenceMarkers = ["i prefer", "i like", "i don't like", "i hate", "i love", "my favourite", "my favorite",
                                 "i'd rather", "i would rather", "works better for me"]
        if preferenceMarkers.contains(where: { lower.contains($0) }) {
            results.append(Candidate(text: text, kind: .preference, confidence: 0.82, subject: subject,
                                     reason: "stated preference"))
        }

        // Goals and decisions.
        if ["my goal is", "i want to ", "i'm planning to", "i am planning to", "i plan to", "by the end of"].contains(where: { lower.contains($0) }) {
            results.append(Candidate(text: text, kind: .goal, confidence: 0.75, subject: subject, reason: "stated goal"))
        }
        if ["i decided", "we decided", "i've decided", "i chose", "we chose", "let's go with"].contains(where: { lower.contains($0) }) {
            results.append(Candidate(text: text, kind: .decision, confidence: 0.88, subject: subject, reason: "decision"))
        }

        // Important dates (explicit).
        if ["birthday is", "anniversary is", "due on", "deadline is", "exam on", "exam is"].contains(where: { lower.contains($0) }) {
            results.append(Candidate(text: text, kind: .importantDate, confidence: 0.85, subject: subject, reason: "dated item"))
        }

        // De-duplicate within this utterance, keeping the strongest.
        var seen = Set<String>()
        return results.filter { candidate in
            let key = candidate.kind.rawValue + TextNormalizer.tokens(candidate.text).sorted().joined()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    /// Applies candidates to memory, skipping ones the engine considers duplicates.
    @discardableResult
    public func persist(_ text: String, memory: MemoryEngine, sessionID: String?) throws -> [MemoryRecord] {
        var stored: [MemoryRecord] = []
        for candidate in candidates(from: text) {
            let record = try memory.remember(
                candidate.text,
                kind: candidate.kind,
                source: .userStated,
                confidence: candidate.confidence,
                importance: candidate.kind == .instruction ? 0.95 : 0.55,
                subject: candidate.subject,
                provenance: Provenance(conversationID: sessionID, note: candidate.reason)
            )
            stored.append(record)
        }
        return stored
    }
}
