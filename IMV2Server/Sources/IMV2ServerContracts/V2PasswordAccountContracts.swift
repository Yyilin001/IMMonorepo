import Foundation
import IMV2Core

/// 密码账号存储错误。
public enum V2PasswordAccountStoreError: Error, Equatable, Sendable {
    /// 账号标识不符合规范化规则。
    case invalidAccountHandle
    /// 公开身份字段不合法。
    case invalidPublicIdentity
    /// 账号标识已被占用。
    case accountAlreadyExists
    /// 公开账号名已被占用。
    case publicHandleAlreadyExists
    /// 存储或哈希参数当前不可用。
    case unavailable
}

/// 已持久化的密码凭据。
public struct V2PasswordCredential: Equatable, Sendable {
    /// 凭据所属用户。
    public let userID: UserID
    /// 符合部署策略的密码哈希串。
    public let passwordHash: String
    public let revision: Int64

    /// 保存密码凭据。
    ///
    /// - Parameters:
    ///   - userID: 凭据所属用户。
    ///   - passwordHash: 已完成的密码哈希串。
    public init(userID: UserID, passwordHash: String, revision: Int64 = 1) {
        self.userID = userID
        self.passwordHash = passwordHash
        self.revision = revision
    }
}

/// 密码备选登录的持久化边界。
///
/// 明文密码校验由有界的应用工作器线程池负责；本能力只接受已完成的密码摘要，
/// 并返回领域身份或凭据。
public protocol V2PasswordAccountStoring: Sendable {
    /// 注册一个新的密码账号。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识，需符合规范化规则。
    ///   - passwordHash: 已完成的密码哈希串。
    ///   - publicHandle: 公开账号名。
    ///   - displayName: 展示名称。
    ///   - deviceID: 发起注册的设备，用于审计。
    /// - Returns: 新账号的用户标识。
    /// - Throws: 标识非法、已被占用或存储不可用时抛出。
    func register(
        accountHandle: String,
        passwordHash: String,
        publicHandle: String,
        displayName: String,
        deviceID: DeviceID
    ) async throws -> UserID
    /// 读取账号对应的密码凭据。
    ///
    /// - Parameter accountHandle: 账号标识。
    /// - Returns: 可用账号的凭据；账号不存在或已停用时返回 `nil`。
    /// - Throws: 标识非法或存储不可用时抛出。
    func passwordCredential(for accountHandle: String) async throws -> V2PasswordCredential?

    /// 在 KDF 计算完成后复核密码凭据，并一次性提交成功审计与失败窗口重置。
    ///
    /// 复核要求凭据的用户与哈希串都与预期完全一致，且账号未被停用；若期间窗口已被并发重置，
    /// 以并发结果为准，本次调用不会覆盖它。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - expected: KDF 计算前读取到的凭据。
    ///   - deviceID: 发起登录的设备，用于审计。
    /// - Returns: 复核通过并完成提交时为 `true`。
    /// - Throws: 标识非法或存储不可用时抛出。
    func completeAuthentication(accountHandle: String, expected: V2PasswordCredential, deviceID: DeviceID) async throws -> Bool
}

/// 规范化账号标识。
///
/// 统一转为小写并要求长度为 3 至 64 个字符，字符集限定为数字、小写字母及 `_`、`-`。
///
/// - Parameter value: 原始账号标识。
/// - Returns: 规范化后的账号标识。
/// - Throws: 长度或字符集不满足要求时抛出
///   ``V2PasswordAccountStoreError/invalidAccountHandle``。
public func canonicalAccountHandle(_ value: String) throws -> String {
    let normalized = value.lowercased()
    let scalars = normalized.unicodeScalars
    guard (3 ... 64).contains(scalars.count), scalars.allSatisfy({ scalar in
        (48 ... 57).contains(scalar.value) ||
        (97 ... 122).contains(scalar.value) ||
        scalar == "_" || scalar == "-"
    }) else { throw V2PasswordAccountStoreError.invalidAccountHandle }
    return normalized
}
