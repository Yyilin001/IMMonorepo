import Foundation
import IMV2Core
#if canImport(Security)
import Security
#endif

public enum V2DeviceIdentityStoreError: Error, Equatable, Sendable {
    case unavailable
    case malformedRecord
    case permanentlyInvalidated
    case unexpectedStatus(Int32)
}

/// Generates one opaque V2 device ID per physical installation and keeps it in
/// the device-only Keychain. This is an identifier rather than a credential;
/// device registration still requires a fresh account-factor assertion.
#if canImport(Security)
public actor V2KeychainDeviceIdentityProvider: V2DeviceIdentityProvider {
    private let service: String
    private let account: String
    private let makeUUID: @Sendable () -> UUID

    public init(
        service: String,
        account: String = "v2-device-identity",
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.service = service
        self.account = account
        self.makeUUID = makeUUID
    }

    public func deviceID() throws -> DeviceID {
        if let existing = try load() { return existing }
        let generated = try DeviceID(makeUUID().uuidString)
        let data = Data(generated.rawValue.utf8)
        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecSuccess { return generated }
        if status == errSecDuplicateItem, let raced = try load() { return raced }
        throw map(status)
    }

    private func load() throws -> DeviceID? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data,
              let rawValue = String(data: data, encoding: .utf8),
              let deviceID = try? DeviceID(rawValue)
        else { throw V2DeviceIdentityStoreError.malformedRecord }
        return deviceID
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func map(_ status: OSStatus) -> V2DeviceIdentityStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
}
#else
/// No UserDefaults/file fallback exists: a platform without Keychain cannot
/// silently manufacture a persistent V2 device identity.
public actor V2KeychainDeviceIdentityProvider: V2DeviceIdentityProvider {
    public init(service _: String, account _: String = "v2-device-identity", makeUUID _: @escaping @Sendable () -> UUID = { UUID() }) {}
    public func deviceID() throws -> DeviceID { throw V2DeviceIdentityStoreError.unavailable }
}
#endif
