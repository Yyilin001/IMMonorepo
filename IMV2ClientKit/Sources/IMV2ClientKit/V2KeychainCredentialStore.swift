import Foundation
#if canImport(Security)
import Security
#endif

#if canImport(Security)
/// 完整设备凭证记录的 Keychain 存储，使用仅限当前设备、解锁时可访问的保护级别。
///
/// 刷新凭证与待轮换身份作为同一 JSON 记录保存到单个项目中。读取既有记录时也更新保护级别。
/// 后台流程遇到受保护数据不可用应等待恢复；本存储不放宽长期凭证的可访问条件。
/// 同一命名空间的业务写入应由同一个认证会话串行协调。
public actor V2KeychainCredentialStore: V2CredentialStore {
    /// Keychain 通用密码项的服务命名空间。
    private let service: String
    /// 服务命名空间内的凭证记录键。
    private let account: String

    /// 保存 Keychain 服务名与记录键，默认键为 device-credentials；初始化不读取或写入凭证。
    public init(service: String, account: String = "device-credentials") {
        self.service = service
        self.account = account
    }

    /// 读取完整凭证记录，并将既有项保护级别更新为解锁时可访问且仅限本设备。
    ///
    /// - Returns: 解码后的原子凭证记录；项目不存在时返回 nil。
    /// - Throws: Keychain 读取或保护级别更新错误；数据类型或 JSON 解码失败报告 malformedRecord。
    ///
    /// 解码不调用凭证的普通构造器，也不在此校验当前有效期；认证与恢复决策由会话所有者负责。
    public func load() throws -> V2AuthCredentialRecord? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw map(status) }
        guard let data = result as? Data else { throw V2CredentialStoreError.malformedRecord }
        let hardeningStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [
                kSecAttrAccessible as String:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
        guard hardeningStatus == errSecSuccess else { throw map(hardeningStatus) }
        do {
            return try JSONDecoder().decode(V2AuthCredentialRecord.self, from: data)
        } catch {
            throw V2CredentialStoreError.malformedRecord
        }
    }

    /// 将完整记录编码为 JSON 后更新单个 Keychain 项，不存在时插入。
    ///
    /// - Parameter record: 凭证与待处理刷新、撤销身份的一致快照。
    /// - Throws: 编码失败报告 malformedRecord；系统写入失败按状态映射。
    ///
    /// 更新和插入均明确设置设备限定的解锁时保护级别，方法返回成功才代表写入成功。
    public func save(_ record: V2AuthCredentialRecord) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw V2CredentialStoreError.malformedRecord
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw map(updateStatus) }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw map(insertStatus) }
    }

    /// 删除匹配凭证项，不存在视为成功；不执行远端撤销，其余系统状态映射为存储错误。
    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }

    /// 用通用密码类别、service 与 account 精确定位完整凭证项。
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 将不可访问状态映射为 unavailable，解码失败映射为 malformedRecord，认证失败映射为 permanentlyInvalidated，其余保留状态码。
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
/// 不支持 Security 的平台占位实现，保留相同接口，但所有读写均报告 unavailable，不提供替代凭证存储。
public actor V2KeychainCredentialStore: V2CredentialStore {
    /// 保留跨平台初始化接口，不保存参数或访问存储。
    public init(service _: String, account _: String = "device-credentials") {}

    /// 当前平台不提供 Keychain，始终抛出 unavailable。
    public func load() throws -> V2AuthCredentialRecord? {
        throw V2CredentialStoreError.unavailable
    }

    /// 当前平台不提供 Keychain，始终抛出 unavailable，不持久化输入记录。
    public func save(_: V2AuthCredentialRecord) throws {
        throw V2CredentialStoreError.unavailable
    }

    /// 当前平台不提供 Keychain，始终抛出 unavailable。
    public func delete() throws {
        throw V2CredentialStoreError.unavailable
    }
}
#endif
