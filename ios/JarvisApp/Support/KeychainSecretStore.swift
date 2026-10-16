import Foundation
import Security

/// Keychain-backed secret storage (R15).
///
/// All credentials — inference keys, GitHub tokens, Gmail OAuth tokens — live here,
/// never in UserDefaults, source files, logs or the app bundle.
/// Items are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they
/// never travel in an iCloud/iTunes backup and cannot be read while locked.
public final class KeychainSecretStore: SecretStore {

    private let service: String
    private let queue = DispatchQueue(label: "ai.jarvis.keychain")

    public init(service: String = "ai.jarvis.credentials") {
        self.service = service
    }

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)
        case decoding

        public var errorDescription: String? {
            switch self {
            case .status(let code): return "Keychain error \(code)"
            case .decoding: return "Stored credential could not be decoded"
            }
        }
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    public func secret(for key: String) throws -> String? {
        try queue.sync {
            var query = query(for: key)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                    throw KeychainError.decoding
                }
                return value
            case errSecItemNotFound:
                return nil
            default:
                throw KeychainError.status(status)
            }
        }
    }

    public func setSecret(_ value: String?, for key: String) throws {
        try queue.sync {
            let base = query(for: key)
            guard let value, !value.isEmpty else {
                let status = SecItemDelete(base as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
                return
            }
            let data = Data(value.utf8)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
            var insert = base
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        }
    }

    public func allKeys() throws -> [String] {
        try queue.sync {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            var items: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &items)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            let array = items as? [[String: Any]] ?? []
            return array.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        }
    }

    /// Removes every credential this app owns (used by "Disconnect everything").
    public func removeAll() throws {
        try queue.sync {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        }
    }
}
