import IMV2ClientRuntime
import IMV2ClientNetwork
import IMV2ClientPlatform
import IMV2Core
import Foundation
#if canImport(Security)
import Security
#endif
private struct V2KeychainDeviceRevocationPersistence: V2DeviceRevocationPersisting {
    /// 隔离撤销账本的 Keychain 服务名。
    let service: String
#if canImport(Security)
    /// 以服务名及固定账户 device-revocation-outbox-v1 定位通用密码项。
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "device-revocation-outbox-v1"]
    }
    /// 读取唯一匹配项并要求结果为 Data；缺失返回 nil，状态错误或类型错误明确抛出。
    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2DeviceRevocationStoreError.malformedRecord }
        return data
    }
    /// 先更新既有项，仅在不存在时插入；同时设置设备限定的首次解锁后保护级别。
    func save(_ data: Data) throws {
        // This item contains only revocation authority, never login authority.
        // Device-only availability after first unlock permits deferred cleanup.
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        let inserted = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw error(inserted) }
    }
    /// 删除匹配项，将不存在视为成功，其余系统错误映射为存储错误。
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    /// 将不可访问状态映射为 unavailable、解码错误映射为 malformedRecord，其余保留原始状态码。
    private func error(_ status: OSStatus) -> V2DeviceRevocationStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        default: .unexpectedStatus(status)
        }
    }
#else
    func load() throws -> Data? { throw V2DeviceRevocationStoreError.unavailable }
    func save(_: Data) throws { throw V2DeviceRevocationStoreError.unavailable }
    func delete() throws { throw V2DeviceRevocationStoreError.unavailable }
#endif
}

extension V2DeviceRevocationStore {
    public init(service: String) { self.init(persistence: V2KeychainDeviceRevocationPersistence(service: service)) }
}
