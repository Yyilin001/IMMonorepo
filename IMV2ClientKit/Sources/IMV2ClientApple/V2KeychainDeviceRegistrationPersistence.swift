import IMV2ClientRuntime
import IMV2ClientNetwork
import IMV2ClientPlatform
import IMV2Core
import Foundation
#if canImport(Security)
import Security
#endif
private struct V2KeychainDeviceRegistrationPersistence: V2DeviceRegistrationPersisting {
    /// 账本 Keychain 服务命名空间。
    let service: String

    #if canImport(Security)
    /// 以通用密码类别、服务名与固定账户 device-registration-ledger-v1 定位项目。
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "device-registration-ledger-v1"]
    }

    /// 读取唯一匹配项并要求 Data 类型，不存在返回 nil，系统或类型错误明确报告。
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        return data
    }

    /// 先更新项目数据，仅在不存在时插入；插入设置首次解锁后且仅限本设备保护级别。
    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw error(added) }
    }

    /// 删除匹配项目，不存在视为成功。
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    /// 将不可访问、解码及认证失败分别映射为 unavailable、malformedRecord、permanentlyInvalidated，其余保留状态码。
    private func error(_ status: OSStatus) -> V2DeviceCredentialRegistrationOperationStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
    #else
    /// 当前平台不支持 Security，始终抛出 unavailable。
    func load() throws -> Data? { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    /// 当前平台不支持 Security，不保存输入并抛出 unavailable。
    func save(_: Data) throws { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    /// 当前平台不支持 Security，始终抛出 unavailable。
    func delete() throws { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    #endif
}

extension V2DeviceRegistrationStore {
    public init(service: String) { self.init(persistence: V2KeychainDeviceRegistrationPersistence(service: service)) }
}
