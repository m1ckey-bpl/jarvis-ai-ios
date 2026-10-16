import Foundation

/// High-level memory operations used by the agent, the UI and the tool engine.
///
/// Responsibilities:
///  * decide **what is worth remembering** (not every utterance),
///  * keep records typed, dated and provenance-tracked,
///  * resolve conflicts (newer/corrected beats older; locked instructions never yield),
///  * answer retrieval questions and honour "forget/export/correct" commands.
public final class MemoryEngine {
    private let store: MemoryStore
    private let clock: Clock
    private let retriever: MemoryRetriever
    public let summarizer: ConversationSummarizer

    public init(store: MemoryStore, clock: Clock = SystemClock(), embedder: EmbeddingProvider? = nil,
                retrievalConfig: RetrievalConfig = .default) {
        self.store = store
        self.clock = clock
        self.retriever = MemoryRetriever(store: store, config: retrievalConfig, embedder: embedder)
        self.summarizer = ConversationSummarizer(store: store, clock: clock)
    }

    // MARK: Writing

    /// Stores a memory, merging near-duplicates and superseding conflicting ones.
    @discardableResult
    public func remember(
        _ text: String,
        kind: MemoryKind = .fact,
        source: MemorySource = .userStated,
        confidence: Double = 0.85,
        importance: Double = 0.5,
        subject: String? = nil,
        tags: [String] = [],
        ttl: TimeInterval? = nil,
        provenance: Provenance? = nil
    ) throws -> MemoryRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw JarvisError.invalidArguments("memory text is too short") }

        let now = clock.now
        let locked = (kind == .instruction)
        let expiresAt = ttl.map { now.addingTimeInterval($0) }

        // 1. Near-duplicate merge (same kind, high lexical overlap).
        if let existing = try findNearDuplicate(of: trimmed, kind: kind) {
            var updated = existing
            // A locked record is never silently rewritten by a weaker source.
            if existing.locked && source != .userCorrected && source != .userStated {
                return existing
            }
            updated.text = trimmed
            updated.confidence = max(existing.confidence, confidence)
            updated.importance = max(existing.importance, importance)
            updated.updatedAt = now
            updated.expiresAt = expiresAt ?? existing.expiresAt
            updated.tags = Array(Set(existing.tags + tags)).sorted()
            updated.provenance = provenance ?? existing.provenance
            updated.source = source
            try store.upsert(updated)
            JarvisLog.shared.debug("memory", "merged near-duplicate memory \(updated.id)")
            return updated
        }

        // 2. Insert new record.
        let record = MemoryRecord(
            kind: kind, text: trimmed, subject: subject, tags: tags, source: source,
            confidence: confidence, importance: importance, createdAt: now, updatedAt: now,
            expiresAt: expiresAt, locked: locked, provenance: provenance
        )
        try store.upsert(record)

        // 3. Conflict resolution against existing records on the same subject.
        if let subject, !subject.isEmpty {
            try supersedeOlderRecords(subject: subject, keeping: record, at: now)
        }
        JarvisLog.shared.debug("memory", "stored \(kind.rawValue) memory \(record.id)")
        return record
    }

    private func findNearDuplicate(of text: String, kind: MemoryKind) throws -> MemoryRecord? {
        let candidates = try store.records(matching: MemoryQuery(kinds: [kind], limit: 60))
        var best: (MemoryRecord, Double)?
        for candidate in candidates {
            let similarity = TextNormalizer.similarity(candidate.text, text)
            if similarity >= 0.72, best == nil || similarity > best!.1 {
                best = (candidate, similarity)
            }
        }
        return best?.0
    }

    private func supersedeOlderRecords(subject: String, keeping record: MemoryRecord, at now: Date) throws {
        let siblings = try store.records(matching: MemoryQuery(statuses: [.active], subject: subject, limit: 40))
        for sibling in siblings where sibling.id != record.id {
            // Locked instructions are only superseded by another explicit instruction.
            if sibling.locked && record.kind != .instruction { continue }
            if sibling.kind == .instruction && record.kind != .instruction { continue }
            var updated = sibling
            updated.status = .superseded
            updated.supersededBy = record.id
            updated.updatedAt = now
            try store.upsert(updated)
        }
    }

    /// Records an explicit user correction of an existing memory.
    @discardableResult
    public func correct(id: String, newText: String, provenance: Provenance? = nil) throws -> MemoryRecord {
        guard let original = try store.record(id: id) else {
            throw JarvisError.invalidArguments("no memory with id \(id)")
        }
        let now = clock.now
        var superseded = original
        superseded.status = .superseded
        superseded.updatedAt = now
        let correction = try remember(
            newText,
            kind: original.kind == .inference ? .fact : original.kind,
            source: .userCorrected,
            confidence: 0.98,
            importance: max(original.importance, 0.6),
            subject: original.subject,
            tags: original.tags,
            provenance: provenance ?? original.provenance
        )
        superseded.supersededBy = correction.id
        try store.upsert(superseded)
        return correction
    }

    // MARK: Reading

    public func retrieve(_ query: String, limit: Int = 8) throws -> [ScoredMemory] {
        let results = try retriever.retrieve(query, now: clock.now, limit: limit)
        try? store.touch(ids: results.map { $0.record.id }, at: clock.now)
        return results
    }

    public func all(includeInactive: Bool = false) throws -> [MemoryRecord] {
        try store.records(matching: MemoryQuery(statuses: includeInactive ? MemoryStatus.allCases : [.active], limit: 1000))
    }

    public func record(id: String) throws -> MemoryRecord? { try store.record(id: id) }

    public func count() throws -> Int { try store.count(statuses: [.active]) }

    public func instructionRecords() throws -> [MemoryRecord] {
        try store.records(matching: MemoryQuery(kinds: [.instruction], limit: 100))
    }

    /// Pinned (always-injected) memory block used by the context builder.
    public func standingInstructions() throws -> [MemoryRecord] {
        try instructionRecords().filter { $0.isActive && $0.locked }
    }

    // MARK: Deleting / retention

    public func forget(id: String) throws {
        try store.delete(id: id)
    }

    /// Removes records matching a natural-language description; returns what was removed.
    @discardableResult
    public func forget(matching query: String, dryRun: Bool = false) throws -> [MemoryRecord] {
        let matches = try retriever.retrieve(query, now: clock.now, limit: 25).map { $0.record }
        if !dryRun { for record in matches { try store.delete(id: record.id) } }
        return matches
    }

    public func forgetAll() throws { try store.deleteAll() }

    /// Marks records whose retention date has passed. Called on app launch and
    /// before context construction; never deletes user statements implicitly.
    @discardableResult
    public func expireStale() throws -> Int {
        let now = clock.now
        var expired = 0
        for record in try store.records(matching: MemoryQuery(statuses: [.active], limit: 2000)) where record.isExpired(at: now) {
            var updated = record
            updated.status = .expired
            updated.updatedAt = now
            try store.upsert(updated)
            expired += 1
        }
        return expired
    }

    // MARK: Portability

    public enum ExportFormat: String, Sendable { case json, markdown, csv }

    public func export(format: ExportFormat = .json, includeInactive: Bool = false) throws -> String {
        let records = try all(includeInactive: includeInactive).sorted { $0.createdAt < $1.createdAt }
        switch format {
        case .json:
            let data = try JSONEncoder.jarvis.encode(records)
            return String(data: data, encoding: .utf8) ?? "[]"
        case .markdown:
            var out = "# JARVIS Memory Export\n\n_Generated \(clock.now.iso8601) — \(records.count) records_\n\n"
            for kind in MemoryKind.allCases {
                let group = records.filter { $0.kind == kind }
                guard !group.isEmpty else { continue }
                out += "## \(kind.rawValue.capitalized)\n\n"
                for record in group {
                    let flags = [record.locked ? "locked" : nil, record.status != .active ? record.status.rawValue : nil]
                        .compactMap { $0 }.joined(separator: ", ")
                    out += "- \(record.text)  \n  _updated \(record.updatedAt.iso8601)\(flags.isEmpty ? "" : " · \(flags)")_\n"
                }
                out += "\n"
            }
            return out
        case .csv:
            var out = "id,kind,text,subject,tags,confidence,importance,created_at,updated_at,status\n"
            for record in records {
                let escaped = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                out += [record.id, record.kind.rawValue, escaped(record.text), escaped(record.subject ?? ""),
                        escaped(record.tags.joined(separator: "|")), String(format: "%.2f", record.confidence),
                        String(format: "%.2f", record.importance), record.createdAt.iso8601,
                        record.updatedAt.iso8601, record.status.rawValue].joined(separator: ",") + "\n"
            }
            return out
        }
    }
}
