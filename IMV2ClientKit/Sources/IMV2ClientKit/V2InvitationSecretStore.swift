import Foundation
import IMV2Core
#if canImport(Security)
import Security
#endif

public enum V2InvitationSecretStoreError:Error,Equatable,Sendable { case unavailable,locked,missing,invalidReference,invalidSecret }
public protocol V2InvitationSecretStoring:Sendable {
    func save(_ authorization:V2GroupInvitationSecretAuthorization,reference:UUID,accountID:UserID) throws
    func load(reference:UUID,accountID:UserID) throws -> V2GroupInvitationSecretAuthorization
    func remove(reference:UUID,accountID:UserID) throws
}
/// Bearers never enter SQLite; installation/account/ref bind a device-only unlocked item.
public struct V2KeychainInvitationSecretStore:V2InvitationSecretStoring {
    private let service:String
    public init(installationBinding:V2LocalInstallationBinding) { service="im.v2.invitation-bearers."+installationBinding.value.uuidString }
    #if canImport(Security)
    private func query(reference:UUID,accountID:UserID) throws -> [String:Any] {
        guard accountID.uuidValue != nil else {throw V2InvitationSecretStoreError.invalidReference}
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:accountID.rawValue+":"+reference.uuidString,kSecAttrSynchronizable as String:false]
    }
    public func save(_ authorization:V2GroupInvitationSecretAuthorization,reference:UUID,accountID:UserID) throws {
        var q=try query(reference:reference,accountID:accountID)
        q[kSecValueData as String]=Data(authorization.rawValue.utf8)
        q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status=SecItemAdd(q as CFDictionary,nil)
        if status==errSecDuplicateItem {
            // A durable reference cannot be rebound to another bearer.
            guard try load(reference:reference,accountID:accountID)==authorization else {throw V2InvitationSecretStoreError.invalidSecret};return
        }
        try check(status)
    }
    public func load(reference:UUID,accountID:UserID) throws -> V2GroupInvitationSecretAuthorization {
        var q=try query(reference:reference,accountID:accountID);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne;q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail
        var result:CFTypeRef?;try check(SecItemCopyMatching(q as CFDictionary,&result))
        guard let bytes=result as? Data,let value=String(data:bytes,encoding:.utf8),let secret=try? V2GroupInviteSecret(value) else {throw V2InvitationSecretStoreError.invalidSecret}
        return .init(secret:secret)
    }
    public func remove(reference:UUID,accountID:UserID) throws {
        let status=SecItemDelete(try query(reference:reference,accountID:accountID) as CFDictionary)
        if status != errSecItemNotFound {try check(status)}
    }
    private func check(_ status:OSStatus) throws {
        if status==errSecSuccess {return}
        if status==errSecInteractionNotAllowed {throw V2InvitationSecretStoreError.locked}
        if status==errSecItemNotFound {throw V2InvitationSecretStoreError.missing}
        throw V2InvitationSecretStoreError.unavailable
    }
    #else
    public func save(_ authorization:V2GroupInvitationSecretAuthorization,reference:UUID,accountID:UserID) throws {throw V2InvitationSecretStoreError.unavailable}
    public func load(reference:UUID,accountID:UserID) throws -> V2GroupInvitationSecretAuthorization {throw V2InvitationSecretStoreError.unavailable}
    public func remove(reference:UUID,accountID:UserID) throws {throw V2InvitationSecretStoreError.unavailable}
    #endif
}
