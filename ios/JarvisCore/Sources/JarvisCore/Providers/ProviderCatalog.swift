import Foundation

/// A known provider endpoint. Deliberately data-driven so users can add any
/// OpenAI-compatible endpoint (including a local llama.cpp / Ollama server).
public struct ProviderCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case openAICompatible, gemini }

    public var id: String
    public var displayName: String
    public var kind: Kind
    public var baseURL: String
    public var defaultModel: String
    public var models: [String]
    /// True when the provider has a documented zero-cost tier (verified date noted).
    public var hasFreeTier: Bool
    public var freeTierNote: String
    public var keyInstructions: String
    public var signupURL: String
    /// Requires the user to supply a key (all hosted providers do).
    public var requiresKey: Bool

    public init(id: String, displayName: String, kind: Kind, baseURL: String, defaultModel: String,
                models: [String], hasFreeTier: Bool, freeTierNote: String, keyInstructions: String,
                signupURL: String, requiresKey: Bool = true) {
        self.id = id; self.displayName = displayName; self.kind = kind; self.baseURL = baseURL
        self.defaultModel = defaultModel; self.models = models; self.hasFreeTier = hasFreeTier
        self.freeTierNote = freeTierNote; self.keyInstructions = keyInstructions
        self.signupURL = signupURL; self.requiresKey = requiresKey
    }
}

/// Curated, verified-at-build-time provider list. Limits change: the app shows the
/// date of verification and never promises a quota it cannot check.
public enum ProviderCatalog {
    /// Date the free-tier notes below were last verified.
    public static let verificationDate = "2026-10-16"

    public static let entries: [ProviderCatalogEntry] = [
        ProviderCatalogEntry(
            id: "groq",
            displayName: "Groq",
            kind: .openAICompatible,
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "openai/gpt-oss-120b",
            models: ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3-32b"],
            hasFreeTier: true,
            freeTierNote: "Free tier, no credit card: roughly 30 requests/min and 1,000 requests/day per model, with a daily token cap that is the real limit. Llama models left the free plan in August 2026 — gpt-oss and qwen are the free families now. Press “List models” for your key's own list.",
            keyInstructions: "Create a free account at console.groq.com, open API Keys, create a key, then paste it here. No credit card is required.",
            signupURL: "https://console.groq.com/keys"
        ),
        ProviderCatalogEntry(
            id: "google-ai-studio",
            displayName: "Google AI Studio (Gemini)",
            kind: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            defaultModel: "gemini-2.5-flash",
            models: ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash"],
            hasFreeTier: true,
            freeTierNote: "Free tier, no credit card: Flash and Flash-Lite families only — Pro models became paid-only in 2026 and are deliberately not offered here. Google publishes the live numbers in AI Studio and changes them; press “List models” to see exactly what your key can use. Free-tier prompts may be used to improve Google products outside the EEA/UK/CH — do not send sensitive content.",
            keyInstructions: "Sign in at aistudio.google.com, click “Get API key”, create a key in a project, then paste it here. No credit card is required.",
            signupURL: "https://aistudio.google.com/app/apikey"
        ),
        ProviderCatalogEntry(
            id: "openrouter",
            displayName: "OpenRouter (free models)",
            kind: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openrouter/auto",
            models: ["openrouter/auto", "meta-llama/llama-3.3-70b-instruct:free", "google/gemma-2-9b-it:free"],
            hasFreeTier: true,
            freeTierNote: "Models whose id ends in ':free' cost nothing. Free tier is limited to ~20 requests/min and ~50 requests/day (higher after a one-time $10 credit purchase, which is optional and NOT required).",
            keyInstructions: "Create a free account at openrouter.ai, open Keys, create a key, then paste it here. No credit card is required for the free models.",
            signupURL: "https://openrouter.ai/keys"
        ),
        ProviderCatalogEntry(
            id: "ollama-local",
            displayName: "Local model (Ollama / llama.cpp)",
            kind: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            defaultModel: "llama3.2",
            models: ["llama3.2", "qwen2.5", "gemma2"],
            hasFreeTier: true,
            freeTierNote: "Runs entirely on your own computer at no cost. Your iPhone can reach it only while both are on the same network and the server is running (or through a tunnel you control).",
            keyInstructions: "Install Ollama on your Mac/PC, run `ollama serve`, then set the base URL to your computer's LAN address (for example http://192.168.1.20:11434/v1). No key is required; leave the key field empty.",
            signupURL: "https://ollama.com/download",
            requiresKey: false
        ),
        ProviderCatalogEntry(
            id: "custom-openai-compatible",
            displayName: "Custom OpenAI-compatible endpoint",
            kind: .openAICompatible,
            baseURL: "https://",
            defaultModel: "your-model",
            models: [],
            hasFreeTier: false,
            freeTierNote: "Any endpoint that speaks the OpenAI Chat Completions API works here (Cerebras, NVIDIA NIM, Together, vLLM, LM Studio, a self-hosted gateway…). Availability depends on the service you choose.",
            keyInstructions: "Enter the base URL (ending in /v1), a model name, and a key if the service requires one.",
            signupURL: ""
        )
    ]

    public static func entry(id: String) -> ProviderCatalogEntry? {
        entries.first { $0.id == id }
    }
}

/// Builds live providers from catalog entries + user settings + Keychain secrets.
public final class ProviderRegistry {
    private let secrets: SecretStore
    private let transport: HTTPTransport
    private let settingsStore: ProviderSettingsStore
    private var cache: [String: LLMProvider] = [:]

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(),
                settingsStore: ProviderSettingsStore) {
        self.secrets = secrets; self.transport = transport; self.settingsStore = settingsStore
    }

    /// The provider selected by the user, or `.none` when nothing is configured.
    public func activeProvider() throws -> LLMProvider? {
        guard let settings = try settingsStore.settings() else { return nil }
        return try provider(settings: settings)
    }

    public func provider(settings: ProviderSettings) throws -> LLMProvider? {
        guard let entry = ProviderCatalog.entry(id: settings.providerID) else { return nil }
        let key = try secrets.secret(for: SecretKey.apiKey(for: entry.id))
        if entry.requiresKey && (key ?? "").isEmpty { return nil }

        let cacheKey = "\(entry.id)|\(settings.baseURLOverride ?? entry.baseURL)|\(key?.count ?? 0)"
        if let cached = cache[cacheKey] { return cached }

        let provider: LLMProvider
        switch entry.kind {
        case .openAICompatible:
            provider = OpenAICompatibleProvider(
                entry: entry,
                apiKey: key ?? "",
                baseURL: settings.baseURLOverride ?? entry.baseURL,
                transport: transport
            )
        case .gemini:
            provider = GeminiProvider(entry: entry, apiKey: key ?? "", transport: transport)
        }
        cache[cacheKey] = provider
        return provider
    }

    public func invalidate() { cache.removeAll() }
}

/// Persists provider choice/model. Contains **no** secrets.
public final class ProviderSettingsStore {
    private let defaults: UserDefaults
    private let key = "ai.jarvis.provider.settings"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func settings() throws -> ProviderSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder.jarvis.decode(ProviderSettings.self, from: data)
    }

    public func save(_ settings: ProviderSettings) throws {
        defaults.set(try JSONEncoder.jarvis.encode(settings), forKey: key)
    }

    public func clear() { defaults.removeObject(forKey: key) }
}
