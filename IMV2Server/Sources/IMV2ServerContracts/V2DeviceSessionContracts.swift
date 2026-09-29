import Foundation
import IMV2Core

/// 可安全展示的活跃账号会话描述。
///
/// 不透明的设备标识只返回给其所属账号，且绝不写入日志。
public struct V2DeviceSession: Equatable, Sendable {
    /// 设备标识。
    public let deviceID: DeviceID
    /// 设备展示名称。
    public let displayName: String
    /// 设备平台。
    public let platform: String
    /// 会话创建时刻。
    public let createdAt: Date
    /// 最近活跃时刻。
    public let lastActiveAt: Date

    /// 保存会话描述。
    ///
    /// - Parameters:
    ///   - deviceID: 设备标识。
    ///   - displayName: 展示名称。
    ///   - platform: 设备平台。
    ///   - createdAt: 会话创建时刻。
    ///   - lastActiveAt: 最近活跃时刻。
    public init(deviceID: DeviceID, displayName: String, platform: String, createdAt: Date, lastActiveAt: Date) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }
}

/// 会话列表分页。
public struct V2DeviceSessionPage: Equatable, Sendable {
    /// 本页会话。
    public let sessions: [V2DeviceSession]
    /// 下一页游标；为空表示已到末尾。
    public let nextCursor: String?

    /// 保存会话分页。
    ///
    /// - Parameters:
    ///   - sessions: 本页会话。
    ///   - nextCursor: 下一页游标。
    public init(sessions: [V2DeviceSession], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

/// 会话变更结果。
public enum V2DeviceSessionMutationOutcome: Equatable, Sendable {
    /// 本次调用实际执行了变更。
    case applied
    /// 同一操作此前已执行。
    case idempotent
    /// 目标设备不存在或不属于该账号。
    case targetUnavailable
}

/// 设备会话服务错误。
public enum V2DeviceSessionServiceError: Error, Equatable, Sendable {
    case authorizationDenied
    /// 请求参数不满足约束。
    case invalidRequest
    /// 持久化记录缺失或字段无法解码。
    case malformedPersistence
    /// 存储或时刻当前不可用。
    case unavailable
}

/// 设备吊销凭据兑换结果。
public enum V2DeviceRevocationCapabilityOutcome: Equatable, Sendable {
    /// 本次调用实际完成了兑换。
    case applied
    /// 同一操作此前已兑换。
    case idempotent
    /// 凭据不合法。
    case invalidCredential
    /// 凭据已过期。
    case expired
    /// 同一操作标识已被不同载荷占用。
    case operationConflict
}

/// 设备吊销凭据兑换能力。
public protocol V2DeviceRevocationCapabilityRedeeming: Sendable {
    /// 兑换一份设备吊销凭据。
    ///
    /// - Parameters:
    ///   - credential: 待兑换的吊销凭据。
    ///   - operationID: 本次兑换的幂等操作标识。
    /// - Returns: 兑换结果。
    /// - Throws: 凭据非法或持久化失败时抛出。
    func redeem(_ credential: V2DeviceRevocationCredential, operationID: UUID) async throws -> V2DeviceRevocationCapabilityOutcome
}

/// 账号边缘的会话管理能力。
///
/// 变更会持有与凭据签发/刷新相同的账号咨询锁，在单个事务内吊销该设备的全部凭据，
/// 并为每个网关追加一条持久化吊销事件。
public protocol V2DeviceSessionManaging: V2RemoteDeviceRevocationManaging {
    /// 分页读取账号的活跃会话。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数。
    /// - Returns: 会话分页。
    /// - Throws: 无权限或持久化失败时抛出。
    func sessions(for userID: UserID, cursor: String?, pageSize: Int) async throws -> V2DeviceSessionPage

    /// 吊销当前设备。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - currentDeviceID: 当前设备。
    ///   - operationID: 幂等操作标识。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
    func revokeCurrentDevice(actorUserID: UserID, currentDeviceID: DeviceID, operationID: UUID) async throws -> V2DeviceSessionMutationOutcome


}

/// Online remote device safety is separate from the self-revocation capability journal.
public protocol V2RemoteDeviceRevocationManaging: Sendable {
    func remoteRevocationBaseline(actorUserID:UserID,currentDeviceID:DeviceID) async throws -> V2RemoteDeviceRevocationBaseline
    func submitRemoteRevocation(_ command:V2RemoteDeviceRevocationCommand) async throws -> V2RemoteDeviceRevocationResult
    func recoverRemoteRevocation(_ request:V2RemoteDeviceRevocationRecoveryRequest) async throws -> V2RemoteDeviceRevocationResult
}
