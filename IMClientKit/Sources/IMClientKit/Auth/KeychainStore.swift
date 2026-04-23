import Foundation
import Security

public protocol TokenStore: Sendable {
    func save(_ value: String, for key: String) throws
    func readString(for key: String) throws -> String?
    func delete(_ key: String)
}

public struct TokenStoreHandler: Sendable {
    public let saveValue: @Sendable (String, String) throws -> Void
    public let readValue: @Sendable (String) throws -> String?
    public let deleteValue: @Sendable (String) -> Void

    public init<Store: TokenStore>(_ store: Store) {
        saveValue = { value, key in
            try store.save(value, for: key)
        }
        readValue = { key in
            try store.readString(for: key)
        }
        deleteValue = { key in
            store.delete(key)
        }
    }

    public func save(_ value: String, for key: String) throws {
        try saveValue(value, key)
    }

    public func readString(for key: String) throws -> String? {
        try readValue(key)
    }

    public func delete(_ key: String) {
        deleteValue(key)
    }
}

public struct KeychainStore: TokenStore, Sendable {
    private let service: String
    private static let refreshTokenAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    public init(service: String = "com.codex.imapp.auth") {
        self.service = service
    }

    public func save(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Refresh token needs to survive lock-screen background access, but should remain bound to this device.
        attributes[kSecAttrAccessible as String] = Self.refreshTokenAccessibility

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    public func readString(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    public func delete(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

public enum KeychainError: LocalizedError, Sendable {
    case unhandled(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "钥匙串错误：\(status)"
        }
    }
}
