import Foundation
#if canImport(Security)
import Security
#endif

/// Device-only Keychain persistence for the complete V2 credential record.
/// `AfterFirstUnlockThisDeviceOnly` allows bounded background sync after the
/// device has first been unlocked while preventing backup/restore migration.
#if canImport(Security)
public actor V2KeychainCredentialStore: V2CredentialStore {
    private let service: String
    private let account: String

    public init(service: String, account: String = "device-credentials") {
        self.service = service
        self.account = account
    }

    public func load() throws -> V2AuthCredentialRecord? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data else { throw V2CredentialStoreError.malformedRecord }
        do {
            return try JSONDecoder().decode(V2AuthCredentialRecord.self, from: data)
        } catch {
            throw V2CredentialStoreError.malformedRecord
        }
    }

    public func save(_ record: V2AuthCredentialRecord) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw V2CredentialStoreError.malformedRecord
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw map(updateStatus) }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw map(insertStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func map(_ status: OSStatus) -> V2CredentialStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
}
#else
/// Keychain is deliberately unavailable outside Apple platforms. Keeping the
/// same type makes the package buildable for protocol/database regression
/// tests while ensuring a Linux caller cannot accidentally persist credentials
/// in a weaker substitute store.
public actor V2KeychainCredentialStore: V2CredentialStore {
    public init(service _: String, account _: String = "device-credentials") {}

    public func load() throws -> V2AuthCredentialRecord? {
        throw V2CredentialStoreError.unavailable
    }

    public func save(_: V2AuthCredentialRecord) throws {
        throw V2CredentialStoreError.unavailable
    }

    public func delete() throws {
        throw V2CredentialStoreError.unavailable
    }
}
#endif
