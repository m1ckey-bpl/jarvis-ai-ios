import Foundation

/// Asks the provider what models the user's own key can actually use.
///
/// This exists because hard-coded model names rot: providers rename, retire and
/// re-price models constantly, and a free tier that included a model last month may
/// exclude it today. Listing from the API answers the only question that matters —
/// "what does *this key* have?" — and turns a confusing 404 into a picker.
public struct DiscoveredModel: Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A plain-language account of what the app tried and what came back.
///
/// Deliberately never contains the API key — only a fingerprint the user can compare
/// with what their provider dashboard shows ("…4f2a · 39 characters").
public struct ProviderDiagnostics: Sendable, Equatable {
    public var providerName: String
    public var providerID: String
    public var model: String
    public var endpointHost: String
    public var requestPath: String
    public var keyFingerprint: String
    public var httpStatus: Int?
    public var providerMessage: String?
    public var outcome: String

    public init(providerName: String, providerID: String, model: String, endpointHost: String,
                requestPath: String, keyFingerprint: String, httpStatus: Int? = nil,
                providerMessage: String? = nil, outcome: String) {
        self.providerName = providerName; self.providerID = providerID; self.model = model
        self.endpointHost = endpointHost; self.requestPath = requestPath
        self.keyFingerprint = keyFingerprint; self.httpStatus = httpStatus
        self.providerMessage = providerMessage; self.outcome = outcome
    }

    /// The block the user can copy and send along — or paste back to the developer.
    public func report() -> String {
        var lines: [String] = []
        lines.append("JARVIS provider diagnostics")
        lines.append("provider: \(providerName) (\(providerID))")
        lines.append("model: \(model)")
        lines.append("endpoint: \(endpointHost)\(requestPath)")
        lines.append("key: \(keyFingerprint)")
        if let httpStatus { lines.append("http status: \(httpStatus)") }
        if let providerMessage, !providerMessage.isEmpty {
            lines.append("provider said: \(providerMessage)")
        }
        lines.append("result: \(outcome)")
        return lines.joined(separator: "\n")
    }
}

public enum ProviderModelDiscovery {

    /// Non-chat endpoints that some providers list alongside their chat models.
    private static let excludedFragments = [
        "whisper", "transcribe", "tts", "speech", "embed", "embedding", "rerank",
        "moderation", "guard", "aqa", "imagen", "veo", "image", "audio", "realtime",
        "dall-e", "davinci", "babbage", "clip", "codex-mini", "search-",
    ]

    public static func isChatModel(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        if excludedFragments.contains(where: { lowered.contains($0) }) { return false }
        return !identifier.isEmpty
    }

    /// What a live listing actually returned — including the exact HTTP status and the
    /// provider's own wording, so the Settings screen can show the user why a key failed
    /// instead of a generic "could not connect".
    public struct Outcome: Sendable {
        public var models: [DiscoveredModel]
        public var httpStatus: Int?
        public var providerMessage: String?
        public var error: JarvisError?

        public init(models: [DiscoveredModel] = [], httpStatus: Int? = nil,
                    providerMessage: String? = nil, error: JarvisError? = nil) {
            self.models = models; self.httpStatus = httpStatus
            self.providerMessage = providerMessage; self.error = error
        }

        public var isSuccess: Bool { error == nil }
    }

    /// Live list of usable chat models, ranked. Throws on failure — use `probe` when the
    /// failure itself is the interesting part.
    public static func list(entry: ProviderCatalogEntry, apiKey: String,
                            baseURL: String? = nil, transport: HTTPTransport) async throws -> [DiscoveredModel] {
        let outcome = await probe(entry: entry, apiKey: apiKey, baseURL: baseURL, transport: transport)
        if let error = outcome.error { throw error }
        return outcome.models
    }

    /// Never throws: reports status, provider message and models together.
    public static func probe(entry: ProviderCatalogEntry, apiKey: String,
                             baseURL: String? = nil, transport: HTTPTransport) async -> Outcome {
        let resolvedBase = baseURL ?? entry.baseURL
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = entry.kind == .gemini
            ? "\(entry.baseURL)/models?key=\(key)&pageSize=200"
            : "\(resolvedBase)/models"
        guard let url = URL(string: urlString) else {
            return Outcome(error: .providerNotConfigured)
        }
        var headers = ["Accept": "application/json"]
        if entry.kind == .gemini {
            // Both mechanisms are accepted by Google; sending the header as well costs
            // nothing and covers keys restricted to header auth.
            headers["x-goog-api-key"] = key
        } else if !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }
        let request = HTTPRequestSpec(url: url, method: "GET", headers: headers, timeout: 20,
                                      label: "list-models:\(entry.id)")
        do {
            let payload = try await transport.send(request)
            let message = URLSessionTransport.providerMessage(from: payload.text)
            guard (200..<300).contains(payload.statusCode) else {
                let error = URLSessionTransport.mapStatus(payload.statusCode, body: payload.text,
                                                          headers: payload.headers)
                return Outcome(httpStatus: payload.statusCode, providerMessage: message, error: error)
            }
            let models = entry.kind == .gemini
                ? rank(parseGemini(payload.text), preferring: ["flash"])
                : rank(parseOpenAICompatible(payload.text), preferring: ["gpt-oss", "llama", "qwen"])
            return Outcome(models: models, httpStatus: payload.statusCode, providerMessage: message)
        } catch let error as JarvisError {
            return Outcome(error: error)
        } catch {
            return Outcome(error: .network(error.localizedDescription))
        }
    }

    // MARK: Parsing

    static func parseGemini(_ text: String) -> [DiscoveredModel] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        var found: [DiscoveredModel] = []
        for model in models {
            guard let rawName = model["name"] as? String else { continue }
            let identifier = rawName.hasPrefix("models/") ? String(rawName.dropFirst(7)) : rawName
            let methods = (model["supportedGenerationMethods"] as? [String]) ?? []
            guard methods.contains("generateContent") else { continue }
            guard isChatModel(identifier) else { continue }
            let display = (model["displayName"] as? String) ?? identifier
            found.append(DiscoveredModel(id: identifier, displayName: display))
        }
        return found
    }

    static func parseOpenAICompatible(_ text: String) -> [DiscoveredModel] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let raw = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        var found: [DiscoveredModel] = []
        for model in raw {
            guard let identifier = (model["id"] as? String) ?? (model["name"] as? String),
                  isChatModel(identifier) else { continue }
            found.append(DiscoveredModel(id: identifier, displayName: identifier))
        }
        return found
    }

    /// Stable ordering: models matching a preferred family first, then the rest
    /// alphabetically. Deterministic so tests can assert on it.
    static func rank(_ models: [DiscoveredModel], preferring families: [String]) -> [DiscoveredModel] {
        func score(_ model: DiscoveredModel) -> Int {
            let lowered = model.id.lowercased()
            for (index, family) in families.enumerated() where lowered.contains(family) {
                return index
            }
            return families.count
        }
        return models.sorted { lhs, rhs in
            let left = score(lhs), right = score(rhs)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    // MARK: Diagnostics

    /// A fingerprint that identifies *which* key is stored without revealing it.
    public static func fingerprint(of key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "no key stored" }
        let suffix = trimmed.count > 4 ? String(trimmed.suffix(4)) : ""
        return "…\(suffix) · \(trimmed.count) characters"
    }

    public static func endpointHost(of url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// Never returns the key, even if one was pasted into the path by accident.
    public static func redactedPath(_ path: String) -> String {
        var result = path
        if let range = result.range(of: "key=") {
            let tail = result[range.upperBound...]
            let marker = tail.firstIndex(of: "&") ?? tail.endIndex
            result = String(result[..<range.upperBound]) + "<redacted>" + String(tail[marker...])
        }
        return result
    }
}
