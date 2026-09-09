import Foundation
import IMV2Core
#if canImport(Security)
import Security
#endif

/// 设备身份存储的访问、格式与失效错误分类。
public enum V2DeviceIdentityStoreError: Error, Equatable, Sendable {
    /// Keychain 当前不可访问，不代表设备身份不存在。
    case unavailable
    /// 存储结果不是合法 UTF-8 设备标识。
    case malformedRecord
    /// 系统报告身份项认证失败，需要上层显式处理。
    case permanentlyInvalidated
    /// 未分类的 Keychain 状态码。
    case unexpectedStatus(Int32)
}

#if canImport(Security)
/// 在设备限定的 Keychain 项中读取或创建稳定、不透明的设备标识。
///
/// 标识不是凭证，设备注册仍需账户因子。只在项目确实不存在时生成 UUID，读取失败不能触发身份替换。
/// 身份生命周期由 Keychain 项决定，本实现不检测应用重新安装，也不提供主动轮换或删除入口。
public actor V2KeychainDeviceIdentityProvider: V2DeviceIdentityProvider {
    /// Keychain 服务命名空间。
    private let service: String
    /// 稳定设备身份的项目键。
    private let account: String
    /// 首次创建标识的可注入 UUID 工厂。
    private let makeUUID: @Sendable () -> UUID

    /// 保存服务名、项目键与 UUID 工厂，默认键为 v2-device-identity；不立即访问 Keychain。
    public init(
        service: String,
        account: String = "v2-device-identity",
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.service = service
        self.account = account
        self.makeUUID = makeUUID
    }

    /// 读取既有身份，缺失时生成 UUID 并插入设备限定、首次解锁后可访问的项目。
    ///
    /// - Returns: 已保存的设备身份；并发插入遇到重复项时重新读取胜出的身份。
    /// - Throws: 读取、编码模型或插入状态错误，失败不会返回未持久化的新身份。
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

    /// 读取唯一项目并校验 Data、UTF-8 与 DeviceID 构造；不额外要求既有值为 UUID，不存在返回 nil。
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

    /// 以通用密码类别、service 和 account 定位身份项。
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 将不可访问、解码及认证失败分别映射为 unavailable、malformedRecord、permanentlyInvalidated，其余保留状态码。
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
/// 无 Security 支持的平台占位实现，不以文件或偏好设置替代设备身份存储。
public actor V2KeychainDeviceIdentityProvider: V2DeviceIdentityProvider {
    /// 保留跨平台初始化接口，不保存或生成身份。
    public init(service _: String, account _: String = "v2-device-identity", makeUUID _: @escaping @Sendable () -> UUID = { UUID() }) {}
    /// 当前平台无法访问 Keychain，始终抛出 unavailable。
    public func deviceID() throws -> DeviceID { throw V2DeviceIdentityStoreError.unavailable }
}
#endif
