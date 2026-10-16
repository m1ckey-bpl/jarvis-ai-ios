import Foundation

/// Recognises user memory commands so the assistant responds deterministically
/// instead of hoping the model notices.
///
/// Supported: "remember that …", "note that …", "my X is Y" (explicit fact),
/// "what do you remember about …", "show me the decisions from last week",
/// "forget …", "correct that …", "export my memory", "clear my memory".
public struct MemoryCommandParser {

    public enum Command: Equatable, Sendable {
        case remember(text: String, asInstruction: Bool)
        case recall(query: String)
        case recallByDate(kind: MemoryKind, since: Date?)
        case forget(query: String, confirmed: Bool)
        case correct(newText: String)
        case exportMemory
        case wipe(confirmed: Bool)
    }

    public init() {}

    /// Returns a command when the utterance is clearly a memory operation.
    public func parse(_ input: String, now: Date, timeZone: TimeZone = .current) -> Command? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        // --- Writes -------------------------------------------------------
        for prefix in ["remember that ", "remember: ", "please remember that ", "please remember ", "keep in mind that ", "note that ", "make a note that "] {
            if lower.hasPrefix(prefix) {
                let body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard body.count >= 2 else { return nil }
                let asInstruction = Self.looksLikeInstruction(body)
                return .remember(text: body, asInstruction: asInstruction)
            }
        }
        // "my preferred language is English" → explicit fact
        if let fact = Self.extractExplicitFact(lower: lower, original: text) {
            return .remember(text: fact, asInstruction: false)
        }

        // --- Reads --------------------------------------------------------
        if lower.contains("what do you remember") || lower.contains("what do you know about")
            || lower.contains("recall ") && lower.contains("about") {
            let query = Self.topic(after: ["what do you remember about", "what do you remember", "what do you know about", "recall"], in: text)
            return .recall(query: query.isEmpty ? "user" : query)
        }
        if lower.contains("decisions") && (lower.contains("show") || lower.contains("what") || lower.contains("last")) {
            let since = Self.relativeWindow(lower: lower, now: now, timeZone: timeZone)
            return .recallByDate(kind: .decision, since: since)
        }

        // --- Deletes / corrections ----------------------------------------
        if lower.hasPrefix("forget ") || lower.hasPrefix("please forget ") || lower.hasPrefix("delete my memory of ") {
            let query = Self.topic(after: ["forget ", "please forget ", "delete my memory of "], in: text)
            // Destructive: require an explicit confirmation word unless it is a single item lookup.
            let confirmed = lower.contains("confirm") || lower.contains("yes, ")
            return .forget(query: query, confirmed: confirmed)
        }
        if lower.contains("correct") && (lower.contains("that") || lower.contains("memory")) {
            let detailStart = text.range(of: "correct", options: .caseInsensitive)?.upperBound
            let remainder = detailStart.map { String(text[$0...]) } ?? ""
            let cleaned = remainder.replacingOccurrences(of: "that", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .correct(newText: cleaned.isEmpty ? text : cleaned)
        }
        if lower.contains("export my memory") || lower.contains("export memory") || lower.contains("download my memory") {
            return .exportMemory
        }
        if lower.contains("clear my memory") || lower.contains("delete all my memories") || lower.contains("wipe my memory") {
            return .wipe(confirmed: lower.contains("confirm") || lower.contains("i'm sure") || lower.contains("yes"))
        }
        return nil
    }

    /// True when a statement reads as a rule for the assistant rather than a fact.
    static func looksLikeInstruction(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = ["always", "never", "do not", "don't", "prefer", "call me", "address me",
                       "answer in", "reply in", "use ", "keep answers", "be concise", "no emoji"]
        return markers.contains { lower.contains($0) }
    }

    /// Extracts a canonical fact from statements like "my X is Y".
    static func extractExplicitFact(lower: String, original: String) -> String? {
        guard lower.hasPrefix("my ") else { return nil }
        guard let splitRange = original.range(of: " is ", options: [.caseInsensitive]) else { return nil }
        let subjectPart = String(original[original.index(original.startIndex, offsetBy: 3)..<splitRange.lowerBound])
        let valuePart = String(original[splitRange.upperBound...])
        guard valuePart.count >= 1, valuePart.count <= 200, subjectPart.count >= 2, subjectPart.count <= 60 else { return nil }
        // Avoid capturing questions ("my X is Y?") — those are not statements.
        if lower.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return nil }
        return original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guesses a subject key from a memory statement ("language", "timezone"…).
    public static func subjectKey(for text: String) -> String? {
        let lower = text.lowercased()
        let candidates: [(String, String)] = [
            ("language", "user.language"), ("time zone", "user.timezone"), ("timezone", "user.timezone"),
            ("name is", "user.name"), ("call me", "user.displayName"), ("live in", "user.location"),
            ("based in", "user.location"), ("work at", "user.employer"), ("job", "user.occupation"),
            ("birthday", "user.birthday"), ("anniversary", "user.anniversary"),
            ("allerg", "user.allergy"), ("prefer", "user.preference"), ("wake up", "user.routine.wake"),
            ("project", "user.project"), ("goal", "user.goal"), ("deadline", "user.deadline")
        ]
        for (marker, key) in candidates where lower.contains(marker) { return key }
        return nil
    }

    static func topic(after prefixes: [String], in text: String) -> String {
        let lower = text.lowercased()
        for prefix in prefixes where lower.contains(prefix) {
            if let range = lower.range(of: prefix) {
                let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                return String(text[start...]).trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
            }
        }
        return ""
    }

    static func relativeWindow(lower: String, now: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if lower.contains("last week") { return calendar.date(byAdding: .day, value: -7, to: now) }
        if lower.contains("last month") { return calendar.date(byAdding: .month, value: -1, to: now) }
        if lower.contains("today") { return calendar.startOfDay(for: now) }
        if lower.contains("yesterday") { return calendar.date(byAdding: .day, value: -1, to: now) }
        return nil
    }
}
