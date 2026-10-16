import Foundation

/// Tunable weights for the hybrid retrieval score.
public struct RetrievalWeights: Sendable, Equatable {
    public var keyword: Double
    public var recency: Double
    public var kind: Double
    public var confidence: Double
    public var importance: Double
    public var access: Double
    public var semantic: Double

    public init(keyword: Double = 0.42, recency: Double = 0.16, kind: Double = 0.14,
                confidence: Double = 0.10, importance: Double = 0.10, access: Double = 0.04,
                semantic: Double = 0.04) {
        self.keyword = keyword; self.recency = recency; self.kind = kind
        self.confidence = confidence; self.importance = importance; self.access = access
        self.semantic = semantic
    }

    public static let `default` = RetrievalWeights()
}

/// Half-life (in days) of the recency component. Old facts decay in *ranking*
/// but are never deleted implicitly.
public struct RetrievalConfig: Sendable {
    public var weights: RetrievalWeights
    public var recencyHalfLifeDays: Double
    public var minimumScore: Double
    public var alwaysIncludePinned: Bool

    public init(weights: RetrievalWeights = .default, recencyHalfLifeDays: Double = 30,
                minimumScore: Double = 0.12, alwaysIncludePinned: Bool = true) {
        self.weights = weights
        self.recencyHalfLifeDays = recencyHalfLifeDays
        self.minimumScore = minimumScore
        self.alwaysIncludePinned = alwaysIncludePinned
    }

    public static let `default` = RetrievalConfig()
}

/// A memory plus its retrieval explanation (kept for transparency/debugging).
public struct ScoredMemory: Sendable, Equatable {
    public let record: MemoryRecord
    public let score: Double
    public let keywordScore: Double
    public let reasons: [String]
}

/// Optional semantic layer. The default implementation is a deterministic,
/// dependency-free hashing embedder (zero cost, no model download). A real
/// embedding provider can be plugged in without touching retrieval logic.
public protocol EmbeddingProvider: AnyObject {
    var dimensions: Int { get }
    var identifier: String { get }
    func embed(_ text: String) -> [Float]?
}

/// Deterministic bag-of-tokens hashing embedder (feature-hashing trick).
/// Not a neural embedding: it captures lexical overlap only, and is honestly
/// documented as such. It exists so semantic scoring is *optional* and free.
public final class HashingEmbedder: EmbeddingProvider {
    public let dimensions: Int
    public var identifier: String { "hashing-\(dimensions)" }

    public init(dimensions: Int = 256) { self.dimensions = dimensions }

    public func embed(_ text: String) -> [Float]? {
        let tokens = TextNormalizer.tokenList(text)
        guard !tokens.isEmpty else { return nil }
        var vector = [Float](repeating: 0, count: dimensions)
        for token in tokens {
            let stemmed = TextNormalizer.stem(token)
            var hash = UInt64(1469598103934665603)   // FNV-1a
            for byte in stemmed.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1099511628211
            }
            let index = Int(hash % UInt64(dimensions))
            vector[index] += 1
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
}

/// Hybrid retrieval: keyword (BM25/LIKE) + freshness + record-type weight +
/// confidence + usage. Deterministic and explainable.
public final class MemoryRetriever {
    private let store: MemoryStore
    private let config: RetrievalConfig
    private let embedder: EmbeddingProvider?

    public init(store: MemoryStore, config: RetrievalConfig = .default, embedder: EmbeddingProvider? = nil) {
        self.store = store
        self.config = config
        self.embedder = embedder
    }

    /// Retrieves and ranks memories for a natural-language query.
    public func retrieve(_ query: String, now: Date, limit: Int = 8) throws -> [ScoredMemory] {
        var candidates: [String: (MemoryRecord, Double)] = [:]
        for (record, score) in try store.keywordSearch(query, limit: max(limit * 4, 24)) {
            candidates[record.id] = (record, score)
        }

        // Pinned instruction records are always considered, even without a keyword hit.
        if config.alwaysIncludePinned {
            for record in try store.records(matching: MemoryQuery(kinds: [.instruction], limit: 50)) where record.isActive {
                if candidates[record.id] == nil { candidates[record.id] = (record, 0.0) }
            }
        }

        // Subject/tag boost: exact subject mention in the query text.
        let queryTokens = TextNormalizer.tokens(query)
        var queryVector: [Float]?
        if let embedder { queryVector = embedder.embed(query) }

        var scored: [ScoredMemory] = []
        for (record, keywordScore) in candidates.values {
            if record.isExpired(at: now) { continue }
            var reasons: [String] = []
            var score = config.weights.keyword * keywordScore
            if keywordScore > 0 { reasons.append(String(format: "keyword %.2f", keywordScore)) }

            // Recency
            let ageDays = max(0, now.timeIntervalSince(record.updatedAt) / 86_400)
            let recency = pow(0.5, ageDays / max(1, config.recencyHalfLifeDays))
            score += config.weights.recency * recency
            if recency > 0.8 { reasons.append("fresh") }

            // Kind weight — instructions dominate inferences.
            score += config.weights.kind * record.kind.baseWeight
            if record.kind == .instruction { reasons.append("explicit instruction") }

            score += config.weights.confidence * record.confidence
            score += config.weights.importance * record.importance

            let usage = min(1.0, Double(record.accessCount) / 10.0)
            score += config.weights.access * usage

            if let subject = record.subject, queryTokens.contains(TextNormalizer.stem(subject.lowercased())) {
                score += 0.06
                reasons.append("subject match")
            }

            var semantic = 0.0
            if let embedder, let queryVector, let vector = embedder.embed(record.text) {
                semantic = Self.cosine(queryVector, vector)
                score += config.weights.semantic * semantic
            }

            // Untrusted externals are slightly demoted: they inform, they do not lead.
            if record.source.isUntrusted { score *= 0.9; reasons.append("external content") }

            guard score >= config.minimumScore else { continue }
            scored.append(ScoredMemory(record: record, score: score, keywordScore: keywordScore, reasons: reasons))
            _ = semantic
        }

        return scored.sorted {
            $0.score == $1.score ? $0.record.updatedAt > $1.record.updatedAt : $0.score > $1.score
        }.prefix(limit).map { $0 }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return Double(max(0, dot))
    }
}
