import Foundation

/// Storage abstraction for credentials.
///
/// On iOS this is backed by the Keychain (see `JarvisApp/Support/KeychainSecretStore.swift`).
/// In tests and on the backend it uses memory / environment variables.
/// R15: secrets never live in source, preferences, or the IPA bundle.
public protocol SecretStore: AnyObject {
    func secret(for key: String) throws -> String?
    func setSecret(_ value: String?, for key: String) throws
    func allKeys() throws -> [String]
}

/// Well-known credential identifiers (non-secret names only).
public enum SecretKey {
    public static let llmAPIKeyPrefix = "provider."          // provider.<id>.apiKey
    public static let githubToken = "integration.github.token"
    public static let gmailAccessToken = "integration.gmail.accessToken"
    public static let gmailRefreshToken = "integration.gmail.refreshToken"
    public static let googleOAuthClientID = "integration.gmail.clientId"
    public static let instagramAccessToken = "integration.instagram.accessToken"
    public static let backendToken = "backend.authToken"

    public static func apiKey(for providerID: String) -> String { "\(llmAPIKeyPrefix)\(providerID).apiKey" }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()
    public init(seed: [String: String] = [:]) { storage = seed }
    public func secret(for key: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return storage[key] }
    public func setSecret(_ value: String?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { storage[key] = value } else { storage.removeValue(forKey: key) }
    }
    public func allKeys() throws -> [String] { lock.lock(); defer { lock.unlock() }; return Array(storage.keys).sorted() }
}

/// Reads secrets from the process environment (backend / CI usage).
public final class EnvironmentSecretStore: SecretStore {
    public init() {}
    public func secret(for key: String) throws -> String? {
        let env = key.uppercased().replacingOccurrences(of: ".", with: "_")
        return ProcessInfo.processInfo.environment[env]
    }
    public func setSecret(_ value: String?, for key: String) throws {
        throw JarvisError.policyBlocked("environment secrets are read-only")
    }
    public func allKeys() throws -> [String] { [] }
}
