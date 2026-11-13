import IMV2ClientRuntime
import IMV2ClientNetwork
import IMV2ClientPlatform
import IMV2Core
import Foundation
#if canImport(Security)
import Security
#endif
private struct V2KeychainIssuedCredentialRecoveryPersistence: V2IssuedCredentialRecoveryPersisting {
    /// 恢复账本所属的 Keychain 服务名。
    let service: String
#if canImport(Security)
    /// 以服务名及固定账户 received-device-credentials-v1 定位恢复账本。
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "received-device-credentials-v1"]
    }
    /// 读取唯一匹配项目并要求结果为 Data，不存在返回 nil，类型或系统错误明确抛出。
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2IssuedCredentialRecoveryError.malformedRecord }
        return data
    }
    /// 先更新既有项目，仅在不存在时插入，同时设置设备限定的首次解锁后保护级别。
    func save(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        let added = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw error(added) }
    }
    /// 删除匹配项，不存在视为成功，其他系统错误按恢复存储错误映射。
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    /// 将 Keychain 不可访问状态映射为 unavailable，解码失败映射为 malformedRecord，其余保留状态码。
    private func error(_ status: OSStatus) -> V2IssuedCredentialRecoveryError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        default: .unexpectedStatus(status)
        }
    }
#else
    /// 当前平台没有 Security 支持，始终抛出 unavailable。
    func load() throws -> Data? { throw V2IssuedCredentialRecoveryError.unavailable }
    /// 当前平台没有 Security 支持，不保存输入并抛出 unavailable。
    func save(_: Data) throws { throw V2IssuedCredentialRecoveryError.unavailable }
    /// 当前平台没有 Security 支持，始终抛出 unavailable。
    func delete() throws { throw V2IssuedCredentialRecoveryError.unavailable }
#endif
}

extension V2IssuedCredentialRecoveryStore {
    public init(service: String, revocations: V2DeviceRevocationStore) { self.init(persistence: V2KeychainIssuedCredentialRecoveryPersistence(service: service), revocations: revocations) }
}
