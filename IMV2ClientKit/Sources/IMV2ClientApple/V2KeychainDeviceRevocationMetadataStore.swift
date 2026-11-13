import IMV2ClientRuntime
import IMV2ClientNetwork
import IMV2ClientPlatform
import IMV2Core
import Foundation
#if canImport(Security)
import Security
#endif
/// Dedicated security metadata; contains no access/refresh/revocation credential.
public struct V2KeychainRemoteDeviceRevocationMetadataStore: V2RemoteDeviceRevocationMetadataStoring {
    private let service: String
    private let account: String
    public init(installationBinding: V2LocalInstallationBinding, accountID: UserID, currentDeviceID: DeviceID) {
        service = "im.v2.remote-device-revocations." + installationBinding.value.uuidString
        account = accountID.rawValue + ":" + currentDeviceID.rawValue
    }
    #if canImport(Security)
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false] }
    public func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne; q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw V2RemoteDeviceRevocationJournalError.corrupt }; return data
    }
    public func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(q as CFDictionary, nil))
        } else { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        if status == errSecSuccess { return }
        if status == errSecInteractionNotAllowed { throw V2RemoteDeviceRevocationJournalError.locked }
        throw V2RemoteDeviceRevocationJournalError.unavailable
    }
    #else
    public func read() throws -> Data? { throw V2RemoteDeviceRevocationJournalError.unavailable }
    public func write(_ data: Data) throws { throw V2RemoteDeviceRevocationJournalError.unavailable }
    #endif
}
