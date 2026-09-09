import Foundation
#if canImport(Security)
import Security
#endif

/// Device-local persistence for the registration and its cancellation proof.
/// Legacy records without a proof fail closed and are retained for explicit
/// recovery; this adapter cannot rotate its separately owned device identity.
#if canImport(Security)
public actor V2KeychainDeviceCredentialRegistrationOperationStore: V2DeviceCredentialRegistrationOperationStore {
    private let service: String
    private let account: String

    public init(service: String, account: String = "pending-device-credential-registration") {
        self.service = service
        self.account = account
    }

    public func load() throws -> V2PendingDeviceCredentialRegistration? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        do {
            return try JSONDecoder().decode(V2PendingDeviceCredentialRegistration.self, from: data)
        } catch {
            throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord
        }
    }

    public func save(_ registration: V2PendingDeviceCredentialRegistration) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(registration)
        } catch {
            throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord
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

    private func map(_ status: OSStatus) -> V2DeviceCredentialRegistrationOperationStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
}
#else
/// No weaker file or preferences fallback exists on non-Apple platforms.
public actor V2KeychainDeviceCredentialRegistrationOperationStore: V2DeviceCredentialRegistrationOperationStore {
    public init(service _: String, account _: String = "pending-device-credential-registration") {}
    public func load() throws -> V2PendingDeviceCredentialRegistration? {
        throw V2DeviceCredentialRegistrationOperationStoreError.unavailable
    }
    public func save(_: V2PendingDeviceCredentialRegistration) throws {
        throw V2DeviceCredentialRegistrationOperationStoreError.unavailable
    }
    public func delete() throws {
        throw V2DeviceCredentialRegistrationOperationStoreError.unavailable
    }
}
#endif
