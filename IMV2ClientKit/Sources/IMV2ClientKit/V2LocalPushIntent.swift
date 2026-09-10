import Foundation
import IMV2Core

/// 本地推送意图错误。
public enum V2LocalPushIntentError: Error, Equatable, Sendable {
    /// 作用域字段不合法。
    case invalidScope
    /// 作用域与记录不匹配。
    case scopeMismatch
    /// 记录属于已经退出的旧所有者。
    case staleOwner
    /// 当前状态不允许该操作。
    case invalidState
    /// 版本号已耗尽。
    case versionExhausted
}

/// 推送意图的作用域。
public struct V2PushIntentScope: Equatable, Sendable {
    /// 目标用户。
    public let userID: UserID
    /// 目标设备。
    public let deviceID: DeviceID
    /// 本地安装绑定。
    public let installation: V2LocalInstallationBinding

    /// 校验并保存作用域。
    ///
    /// - Parameters:
    ///   - userID: 目标用户，需可解析为 UUID。
    ///   - deviceID: 目标设备，需可解析为 UUID。
    ///   - installation: 本地安装绑定。
    /// - Throws: 用户或设备标识非法时抛出
    ///   ``V2LocalPushIntentError/invalidScope``。
    public init(userID: UserID, deviceID: DeviceID, installation: V2LocalInstallationBinding) throws {
        guard userID.uuidValue != nil, deviceID.uuidValue != nil else { throw V2LocalPushIntentError.invalidScope }
        self.userID = userID; self.deviceID = deviceID; self.installation = installation
    }
}

/// 推送意图的暂停原因。
public enum V2PushIntentPauseReason: String, Sendable {
    /// 会话已过期。
    case staleSession
    /// 存在冲突意图。
    case conflictingIntent
    /// 授权已失效。
    case authorization
}

/// 不含令牌明文的本地推送意图状态。
///
/// `tokenReference` 只与内存中的系统推送令牌相关联；激活新所有者会清除它并占用更新的修订。
public struct V2LocalPushIntent: Equatable, Sendable {
    /// 作用域。
    public let scope: V2PushIntentScope
    /// 当前所有者标识。
    public internal(set) var ownerID: UUID
    /// 用户偏好是否开启推送。
    public internal(set) var preferenceEnabled: Bool
    /// 期望的推送开关状态。
    public internal(set) var desiredEnabled: Bool
    /// 当前修订。
    public internal(set) var revision: UInt64
    /// 服务端已确认的修订。
    public internal(set) var acknowledgedRevision: UInt64
    /// 内存令牌引用；不包含令牌明文。
    public internal(set) var tokenReference: UUID?
    /// 当前会话声明。
    public internal(set) var claim: V2PushIntentSessionClaim?
    /// 会话代次。
    public internal(set) var epoch: UInt64?
    /// 已尝试次数。
    public internal(set) var attemptCount: Int
    /// 下次尝试时刻。
    public internal(set) var nextAttemptAt: Date
    /// 暂停原因。
    public internal(set) var pauseReason: V2PushIntentPauseReason?

    /// 是否存在尚未被服务端确认的修订。
    public var pending: Bool { acknowledgedRevision < revision }
    /// 是否在期望开启推送但尚未取得令牌。
    public var waitingForToken: Bool { desiredEnabled && tokenReference == nil }
    /// 当前版本；缺少代次时为空。
    public var version: V2PushIntentVersion? {
        guard let epoch else { return nil }
        return try? .init(epoch: epoch, revision: revision)
    }
}

/// 本地推送意图存储能力。
public protocol V2LocalPushIntentStoring: Sendable {
    /// 读取指定作用域的推送意图。
    ///
    /// - Parameter scope: 目标作用域。
    /// - Returns: 现有意图；不存在时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func inspectPushIntent(scope: V2PushIntentScope) async throws -> V2LocalPushIntent?

    /// 激活新的推送所有者并占用更新修订。
    ///
    /// - Parameters:
    ///   - scope: 目标作用域。
    ///   - ownerID: 新所有者标识。
    ///   - initialPreference: 初始偏好。
    ///   - replacing: 被替换的既有意图。
    /// - Returns: 激活后的意图。
    /// - Throws: 状态或作用域不匹配时抛出。
    func activatePushIntent(scope: V2PushIntentScope, ownerID: UUID, initialPreference: Bool, replacing: V2LocalPushIntent?) async throws -> V2LocalPushIntent

    /// 读取指定所有者的推送意图。
    ///
    /// - Parameters:
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 当前意图。
    /// - Throws: 记录缺失或所有者已过期时抛出。
    func pushIntent(scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent

    /// 设置推送开关并占用新的修订。
    ///
    /// - Parameters:
    ///   - enabled: 目标开关状态。
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 更新后的意图。
    /// - Throws: 状态或所有者不匹配时抛出。
    func setPushIntentEnabled(_ enabled: Bool, scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent

    /// 暂存内存令牌引用。
    ///
    /// - Parameters:
    ///   - reference: 令牌引用。
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 更新后的意图。
    /// - Throws: 状态或所有者不匹配时抛出。
    func stagePushToken(reference: UUID, scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent

    /// 准备登出并清理本地推送状态。
    ///
    /// - Parameters:
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 更新后的意图。
    /// - Throws: 状态或所有者不匹配时抛出。
    func preparePushSignOut(scope: V2PushIntentScope, ownerID: UUID) async throws -> V2LocalPushIntent

    /// 以期望值做条件保存推送输入。
    ///
    /// - Parameters:
    ///   - preferenceEnabled: 用户偏好开关。
    ///   - desiredEnabled: 期望推送开关。
    ///   - tokenReference: 内存令牌引用。
    ///   - expected: 期望的当前意图。
    /// - Returns: 保存生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func savePushInput(preferenceEnabled: Bool, desiredEnabled: Bool, tokenReference: UUID?, expected: V2LocalPushIntent) async throws -> Bool
    /// 以期望值做条件保存会话声明。
    ///
    /// - Parameters:
    ///   - claim: 待保存的会话声明。
    ///   - expected: 期望的当前意图。
    /// - Returns: 保存生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func savePushClaim(_ claim: V2PushIntentSessionClaim, expected: V2LocalPushIntent) async throws -> Bool

    /// 以指定代次完成当前会话声明。
    ///
    /// - Parameters:
    ///   - epoch: 会话代次。
    ///   - expected: 期望的当前意图。
    /// - Returns: 完成生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func completePushClaim(epoch: UInt64, expected: V2LocalPushIntent) async throws -> Bool

    /// 重启推送会话并占用新的代次。
    ///
    /// - Parameter expected: 期望的当前意图。
    /// - Returns: 重启生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func restartPushIntentSession(expected: V2LocalPushIntent) async throws -> Bool

    /// 确认已同步到服务端的修订。
    ///
    /// - Parameter expected: 期望的当前意图。
    /// - Returns: 确认生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func acknowledgePushIntent(_ expected: V2LocalPushIntent) async throws -> Bool

    /// 安排下一次重试时刻。
    ///
    /// - Parameters:
    ///   - at: 下次尝试时刻。
    ///   - expected: 期望的当前意图。
    /// - Returns: 更新生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func retryPushIntent(at: Date, expected: V2LocalPushIntent) async throws -> Bool

    /// 暂停推送意图并记录原因。
    ///
    /// - Parameters:
    ///   - reason: 暂停原因。
    ///   - expected: 期望的当前意图。
    /// - Returns: 更新生效时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func pausePushIntent(_ reason: V2PushIntentPauseReason, expected: V2LocalPushIntent) async throws -> Bool
}
