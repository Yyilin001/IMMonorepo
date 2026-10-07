import IMV2ServerContracts
import Foundation
import IMV2Core

/// 有序群能力变更的领域边界。
///
/// PostgreSQL 实现必须让状态变更与房间事件投递在同一事务内原子提交；
/// 显式声明该协议可避免网关处理层自行持有 SQL 或授权逻辑。
public protocol V2GroupCapabilitiesStore: Sendable {
    /// 设置群置顶消息。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 置顶消息命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 置顶变更结果。
    /// - Throws: 房间或消息不存在、权限不足或持久化失败时抛出。
    func setPinnedMessage(actorUserID: UserID, command: V2PinnedMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage>

    /// 设置群公告。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 群公告命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 公告变更结果。
    /// - Throws: 房间不存在、权限不足或持久化失败时抛出。
    func setAnnouncement(actorUserID: UserID, command: V2GroupAnnouncementCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement>

    /// 设置角色权限。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 角色权限命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 权限变更结果。
    /// - Throws: 房间不存在、权限不足、修订冲突或持久化失败时抛出。
    func setRolePermissions(actorUserID: UserID, command: V2GroupRolePermissionsCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>

    /// 调整成员角色。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 成员角色命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 成员角色变更结果。
    /// - Throws: 目标用户不是成员、权限不足或持久化失败时抛出。
    func changeMemberRole(actorUserID: UserID, command: V2GroupMemberRoleCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>
}

/// 群能力命令的执行结果。
public enum V2GroupCapabilitiesOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    /// 本次调用实际提交了变更。
    case applied(Value)
    /// 同一幂等标识已提交过等价命令，返回其原有结果而未产生第二次效果。
    case idempotent(Value)
    /// 同一幂等标识已被不同载荷的命令占用。
    case idempotencyConflict
    /// 房间已处于命令要求的状态，未产生新事件。
    case alreadyInDesiredState
    /// 命令携带的目标修订与当前状态不一致。
    case revisionConflict
    /// 被限流，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
    /// 准入当前不可用，附带不可用原因。
    case unavailable(V2CommandAdmissionUnavailableReason)
}

/// 群能力存储错误。
public enum V2GroupCapabilitiesStoreError: Error, Equatable, Sendable {
    case operationClosed
    /// The selected resource is not a ready group avatar in this room home.
    case resourceUnavailable
    /// 房间不存在。
    case roomNotFound
    /// 命令引用的消息不存在。
    case messageNotFound
    /// 发起者不是房间当前成员。
    case actorNotMember
    /// 发起者角色不允许执行该命令。
    case actorNotAuthorized
    /// 命令目标用户不是房间成员。
    case targetNotMember
    /// 目标房间不是群聊，不适用群能力命令。
    case notGroupRoom
    /// 目标消息已被撤回。
    case messageWithdrawn
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 群能力命令的事件标识生成器。
public struct V2GroupCapabilitiesIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    /// 注入 UUID 来源，默认使用系统实现。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包，测试可注入确定性实现。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成本次命令的事件标识。
    ///
    /// - Returns: 本次命令使用的事件标识。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> EventID { try .init(makeUUID().uuidString) }
}

/// 群能力命令的对外服务，负责补齐标识与授时后转交存储。
