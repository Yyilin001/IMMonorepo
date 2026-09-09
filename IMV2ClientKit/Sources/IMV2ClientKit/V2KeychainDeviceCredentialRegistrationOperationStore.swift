import Foundation
#if canImport(Security)
import Security
#endif

#if canImport(Security)
/// 在单个 Keychain 项中持久化待完成设备注册及其取消证明。
///
/// 缺少取消证明的旧记录解码失败后保留，交由显式恢复处理；此适配器不轮换由其他所有者管理的设备身份。
/// 新项目采用设备限定的首次解锁后保护级别，既有项目更新只替换数据。
public actor V2KeychainDeviceCredentialRegistrationOperationStore: V2DeviceCredentialRegistrationOperationStore {
    /// 待注册记录的 Keychain 服务命名空间。
    private let service: String
    /// 命名空间内唯一的待注册记录键。
    private let account: String

    /// 保存服务名与记录键，不触发存储访问。
    ///
    /// - Parameters:
    ///   - service: Keychain 服务命名空间。
    ///   - account: 记录键，默认为 pending-device-credential-registration。
    ///
    /// 同一命名空间与记录键的操作应由统一的注册流程协调。
    public init(service: String, account: String = "pending-device-credential-registration") {
        self.service = service
        self.account = account
    }

    /// 读取并解码完整待注册记录，不存在时返回 nil。
    ///
    /// - Throws: Keychain 访问错误，或数据类型、JSON 模型不匹配对应的 malformedRecord。
    ///
    /// 读取失败不会自动删除或替换原记录，也不会生成新的操作身份或取消证明。
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

    /// 编码并替换完整待注册记录，匹配项不存在时插入。
    ///
    /// - Parameter registration: 包含稳定操作身份及取消证明的注册状态。
    /// - Throws: 编码失败对应的 malformedRecord，或 Keychain 更新、插入错误。
    ///
    /// 插入时设置首次解锁后且仅限本设备可访问；更新时只修改数据，不重新设置既有保护级别。
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

    /// 删除匹配的待注册记录，不存在视为成功；不在此撤销远端注册或更换设备身份。
    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    /// 使用通用密码类别、服务名与账户键定位待注册记录。
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 将不可访问映射为 unavailable，解码失败映射为 malformedRecord，认证失败映射为 permanentlyInvalidated，其余保留原始状态码。
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
/// 无 Security 支持的平台占位实现，保留注册存储接口，但不提供文件或偏好设置替代存储。
public actor V2KeychainDeviceCredentialRegistrationOperationStore: V2DeviceCredentialRegistrationOperationStore {
    /// 保留跨平台构造接口，不使用参数或访问存储。
    public init(service _: String, account _: String = "pending-device-credential-registration") {}
    /// 当前平台不支持该 Keychain 存储，始终抛出 unavailable。
    public func load() throws -> V2PendingDeviceCredentialRegistration? {
        throw V2DeviceCredentialRegistrationOperationStoreError.unavailable
    }
    /// 当前平台不支持该 Keychain 存储，不保存输入并抛出 unavailable。
    public func save(_: V2PendingDeviceCredentialRegistration) throws {
        throw V2DeviceCredentialRegistrationOperationStoreError.unavailable
    }
    /// 当前平台不支持该 Keychain 存储，始终抛出 unavailable。
    public func delete() throws {
        throw V2DeviceCredentialRegistrationOperationStoreError.unavailable
    }
}
#endif
