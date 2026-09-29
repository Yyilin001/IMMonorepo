import Foundation
import IMV2Core

/// 设置实时状态偏好后的结果。
public enum V2SetLiveActivityPreferencesOutcome: Equatable, Sendable {
    /// 本次调用实际更新了偏好。
    case updated(V2LiveActivityPreferences)
    /// 同一操作已提交过，返回其原有偏好。
    case idempotent(V2LiveActivityPreferences)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
}

/// 实时状态存储错误。
public enum V2LiveActivityStoreError: Error, Equatable, Sendable {
    /// 房间不存在。
    case roomNotFound
    /// 发起者不是房间成员。
    case actorNotMember
    /// 当前房间或两人关系不允许正在输入等提示。
    case typingNotAllowed
    /// 私聊拉黑。
    ///
    /// 该错误刻意与其他授权拒绝保持完全一致的外部表现，避免泄漏是哪一方发起了拉黑。
    case interactionBlocked
    /// 目标房间不是私聊房间。
    case notDirectRoom
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 由数据库支撑的授权与偏好边界。
///
/// 它授权的实时状态保存在网关注册表中，刻意不进入任何持久化的聊天或事件投影。
public protocol V2LiveActivityStore: Sendable {
    /// 设置当前用户的实时状态偏好。
    ///
    /// - Parameters:
    ///   - command: 偏好变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。

    /// 读取当前用户的实时状态偏好。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 生效偏好。
    /// - Throws: 持久化失败时抛出。
    func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences

    /// 读取房间对指定观察者可见的在线状态。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - viewerUserID: 发起观察的用户。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 当前在线状态。
    /// - Throws: 房间不存在、非成员或持久化失败时抛出。
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState

    /// 校验发起者是否可以在该房间发送正在输入提示。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起提示的用户。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 房间不存在、非成员、被拉黑或当前不允许提示时抛出。
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws

    /// 为瞬时事件重新校验投递授权。
    ///
    /// 该检查与订阅时校验分开，因为用户可能在连接已经订阅之后才拉黑对方。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - viewerUserID: 观察者。
    ///   - subjectUserID: 被观察的成员。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 房间不存在、任一方非成员、被拉黑或持久化失败时抛出。
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) async throws

    /// 查询用户的偏好是否允许展示在线状态。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 允许展示时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func allowsOnlinePresence(userID: UserID) async throws -> Bool
}

/// 连接租约的生命周期管理能力。
///
/// 连接生命周期负责租约，请求处理层负责房间授权；两个协议分开声明可以避免
/// 一个套接字因此获得数据库授权能力。
public protocol V2LivePresenceLeaseManaging: Sendable {
    func setPresencePublication(identity: V2AuthenticatedConnection, connectionID: UUID,
        suppressed: Bool, now: Date) async throws -> V2PresencePublicationLeaseObservation

    /// 以跨副本的设备与用户预算准入一条新的已认证连接。
    ///
    /// 该步骤与续租刻意分开，使常规心跳不会重复执行只有连接建立时才需要的加锁与聚合统计。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - connectionID: 连接标识。
    ///   - policy: 连接准入策略。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 租约结果。
    /// - Throws: 超出预算或持久化失败时抛出。
    func admitConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        publicationSuppressed: Bool,
        policy: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome
    /// 仅延长已存在、未过期且身份一致的租约。
    ///
    /// 缺失或已过期的记录会被拒绝，而不会绕过完整准入事务被重新激活。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - connectionID: 连接标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 租约结果。
    /// - Throws: 持久化失败时抛出。
    func renewConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome
    /// 续租一批相互独立的连接租约，并返回同一语句读到的隐私开关。
    ///
    /// 单一数据库支撑的实现应覆盖该方法，把心跳写入与偏好读取合并为一次往返，
    /// 同时不削弱任何一侧的校验栅栏。
    ///
    /// - Parameter requests: 待续租的连接列表。
    /// - Returns: 以连接标识为键的续租结果。
    /// - Throws: 持久化失败时抛出。
    func renewConnections(
        _ requests: [V2LivePresenceLeaseRenewalRequest]
    ) async throws -> [UUID: V2LivePresenceLeaseRefresh]
    /// 移除连接租约并返回该用户是否仍因其他未过期连接保持在线。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - connectionID: 连接标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 仍保持在线时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func removePresence(identity: V2AuthenticatedConnection, connectionID: UUID, now: Date) async throws -> Bool

    /// 查询用户的偏好是否允许展示在线状态。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 允许展示时为 `true`。
    /// - Throws: 持久化失败时抛出。
    func allowsOnlinePresence(userID: UserID) async throws -> Bool
}

/// 一条连接租约的续租请求。
public struct V2LivePresenceLeaseRenewalRequest: Sendable {
    /// 已认证连接身份。
    public let identity: V2AuthenticatedConnection
    /// 连接标识。
    public let connectionID: UUID
    /// 本次续租时刻。
    public let now: Date

    /// 保存续租请求。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - connectionID: 连接标识。
    ///   - now: 本次续租时刻。
    public init(identity: V2AuthenticatedConnection, connectionID: UUID, now: Date) {
        self.identity = identity
        self.connectionID = connectionID
        self.now = now
    }
}

/// 单条连接租约的续租结果。
public struct V2LivePresenceLeaseRefresh: Equatable, Sendable {
    /// 租约结果。
    public let outcome: V2AuthenticatedConnectionLeaseOutcome
    /// 该用户当前的在线状态展示开关。
    public let allowsOnlinePresence: Bool

    /// 保存续租结果。
    ///
    /// - Parameters:
    ///   - outcome: 租约结果。
    ///   - allowsOnlinePresence: 在线状态展示开关。
    public init(
        outcome: V2AuthenticatedConnectionLeaseOutcome,
        allowsOnlinePresence: Bool
    ) {
        self.outcome = outcome
        self.allowsOnlinePresence = allowsOnlinePresence
    }
}

public extension V2LivePresenceLeaseManaging {
    /// 内存实现与远程实现的兼容路径。
    ///
    /// PostgreSQL 实现为热路径提供了单语句覆盖版本。
    ///
    /// - Parameter requests: 待续租的连接列表。
    /// - Returns: 以连接标识为键的续租结果。
    /// - Throws: 续租或偏好读取失败时抛出。
    func renewConnections(
        _ requests: [V2LivePresenceLeaseRenewalRequest]
    ) async throws -> [UUID: V2LivePresenceLeaseRefresh] {
        var refreshed: [UUID: V2LivePresenceLeaseRefresh] = [:]
        refreshed.reserveCapacity(requests.count)
        for request in requests {
            let outcome = try await renewConnection(
                identity: request.identity,
                connectionID: request.connectionID,
                now: request.now
            )
            let allowsOnlinePresence = try await allowsOnlinePresence(
                userID: request.identity.userID
            )
            refreshed[request.connectionID] = .init(
                outcome: outcome,
                allowsOnlinePresence: allowsOnlinePresence
            )
        }
        return refreshed
    }
}

/// 注册表侧的尽力而为投递策略。
///
/// 注册表持有套接字，而由数据库支撑的服务仍是房间成员关系与私聊拉黑状态的权威。
public protocol V2LiveActivityObservationAuthorizing: Sendable {
    /// 为瞬时事件校验投递授权。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - viewerUserID: 观察者。
    ///   - subjectUserID: 被观察的成员。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 授权不通过或持久化失败时抛出。
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) async throws
}

public struct V2PresencePublicationLeaseObservation: Sendable {
    public let isOnline: Bool
    public let expiresAt: Date
    public init(isOnline: Bool, expiresAt: Date) { self.isOnline=isOnline;self.expiresAt=expiresAt }
}
