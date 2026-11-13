import IMV2ClientRuntime
import IMV2ClientNetwork
import IMV2ClientPlatform
import IMV2Core
import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Security)
/// 使用独立 Keychain 项保存安装绑定，新项目设置设备限定的首次解锁后保护级别；凭证轮换不应更改此标记。
public actor V2KeychainInstallationBindingStore: V2InstallationBindingStore {
    /// 绑定存储的服务命名空间。
    private let service: String
    /// 绑定项键，默认 local-installation-binding。
    private let account: String

    /// 保存项目定位参数，不立即加载或创建绑定。
    public init(service: String, account: String = "local-installation-binding") {
        self.service = service
        self.account = account
    }

    /// 读取完整 JSON 绑定，不存在返回 nil，类型或解码错误报告 malformedRecord。
    public func load() throws -> V2LocalInstallationBinding? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data else { throw V2InstallationBindingStoreError.malformedRecord }
        do {
            return try JSONDecoder().decode(V2LocalInstallationBinding.self, from: data)
        } catch {
            throw V2InstallationBindingStoreError.malformedRecord
        }
    }

    /// 编码并更新绑定数据，不存在时插入并设置设备限定保护级别；更新不修改既有可访问属性。
    public func save(_ binding: V2LocalInstallationBinding) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(binding)
        } catch {
            throw V2InstallationBindingStoreError.malformedRecord
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

    /// 删除匹配绑定项，不存在视为成功，其他系统错误传播。
    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    /// 以通用密码类别、服务名与账户键定位绑定项。
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 映射不可访问、解码和认证失败状态，其他状态作为 unexpectedStatus 保留。
    private func map(_ status: OSStatus) -> V2InstallationBindingStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
}
#else
/// 非 Security 平台占位实现，明确返回绑定不可用，不模拟设备限定的 Keychain。
public actor V2KeychainInstallationBindingStore: V2InstallationBindingStore {
    /// 保留跨平台构造接口，不创建绑定。
    public init(service _: String, account _: String = "local-installation-binding") {}

    /// 当前平台无法读取 Keychain，始终抛出 unavailable。
    public func load() throws -> V2LocalInstallationBinding? {
        throw V2InstallationBindingStoreError.unavailable
    }

    /// 当前平台无法保存 Keychain，始终抛出 unavailable。
    public func save(_: V2LocalInstallationBinding) throws {
        throw V2InstallationBindingStoreError.unavailable
    }

    /// 当前平台无法删除 Keychain，始终抛出 unavailable。
    public func delete() throws {
        throw V2InstallationBindingStoreError.unavailable
    }
}
#endif
