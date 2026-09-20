import Foundation
import IMV2Core

/// 通过认证的成员变更请求。
public struct V2AuthenticatedMembershipChange: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起变更的用户。
    public let actorUserID: UserID
    /// 本次变更的幂等操作标识。
    public let operationID: MembershipOperationID
    /// 变更目标用户。
    public let targetUserID: UserID
    /// 需要执行的动作。
    public let action: V2RoomMembershipAction
    /// 客户端观察到的成员修订，用于并发冲突检测。
    public let expectedMembershipRevision: UInt64

    /// 保存已认证的成员变更请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起变更的用户。
    ///   - operationID: 幂等操作标识。
    ///   - targetUserID: 变更目标用户。
    ///   - action: 需要执行的动作。
    ///   - expectedMembershipRevision: 期望的成员修订。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
        self.expectedMembershipRevision = expectedMembershipRevision
    }
}

/// 成员变更的执行结果。
public enum V2RoomMembershipChangeOutcome: Equatable, Sendable {
    /// 本次调用实际提交了变更。
    case changed(V2RoomMembershipChange)
    /// 同一操作标识已提交过等价变更，返回其原有结果。
    case idempotent(V2RoomMembershipChange)
    /// 同一操作标识已被不同载荷的命令占用。
    case idempotencyConflict
    /// 成员修订与期望值不符，参数为当前修订。
    case revisionConflict(current: UInt64)
    /// 目标用户已经是成员。
    case targetAlreadyMember
    /// 目标用户不是成员。
    case targetNotMember
    /// 成员数量已达到房间上限。
    case memberLimitReached
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入当前不可用，附带不可用原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
}

/// 成员变更的持久化能力。
public protocol V2RoomMembershipStore: Sendable {
    /// 执行一次成员变更。
    ///
    /// - Parameters:
    ///   - command: 成员变更命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 归属变化、房间不存在、无权限或持久化失败时抛出。
    func change(
        command: V2ChangeRoomMembershipCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome
}

/// 成员变更命令的事件标识生成器。
public struct V2RoomMembershipIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    /// 注入 UUID 来源，默认使用系统实现。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包，测试可注入确定性实现。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成一个事件标识。
    ///
    /// - Returns: 本次命令使用的事件标识。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> EventID {
        try EventID(makeUUID().uuidString)
    }
}

/// 归属授权的加入/移出操作的领域入口。
///
/// 数据库加锁、历史目标冻结与来源事务都留在 ``V2RoomMembershipStore`` 之后，
/// 因此网关不会自行决定成员策略。
public struct V2RoomMembershipService: Sendable {
    private let store: any V2RoomMembershipStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2RoomMembershipIDFactory
    private let now: @Sendable () -> Date

    /// 组合成员变更存储与运行参数。
    ///
    /// - Parameters:
    ///   - store: 实际执行变更的存储实现。
    ///   - capacityProfile: 固定的容量档位。
    ///   - identifiers: 事件标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2RoomMembershipStore, capacityProfile: V2CapacityProfile, identifiers: V2RoomMembershipIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    /// 执行一次成员变更。
    ///
    /// - Parameter request: 已认证的成员变更请求。
    /// - Returns: 变更结果；标识与授时由本方法补齐。
    /// - Throws: 命令构造失败、标识生成失败，或存储判定无权限、修订冲突、持久化失败时抛出。
    public func change(_ request: V2AuthenticatedMembershipChange) async throws -> V2RoomMembershipChangeOutcome {
        let command = try V2ChangeRoomMembershipCommand(
            roomID: request.roomID,
            actorUserID: request.actorUserID,
            operationID: request.operationID,
            targetUserID: request.targetUserID,
            action: request.action,
            expectedMembershipRevision: request.expectedMembershipRevision
        )
        let eventID = try identifiers.make()
        return try await store.change(command: command, capacityProfile: capacityProfile, eventID: eventID, now: now())
    }
}

/// 成员变更存储错误。
public enum V2RoomMembershipStoreError: Error, Equatable, Sendable {
    /// 房间归属已变更。
    case ownerChanged
    /// 房间不存在。
    case roomNotFound
    /// 发起者不是房间归属所有者。
    case actorNotOwner
    /// 目标用户当前不可用。
    case targetUnavailable
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
