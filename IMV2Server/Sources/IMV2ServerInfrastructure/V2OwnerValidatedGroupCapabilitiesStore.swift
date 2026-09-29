import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 具备房间归属意识的群能力执行接口。
///
/// 走路由的群命令必须把已选定的归属原样带入事务，操作重放路径同样如此；
/// 事务内以该归属校验房间记录，代次不一致即拒绝提交。
public protocol V2OwnerValidatedGroupCapabilitiesStore: Sendable {
    /// 按房间归属设置置顶消息。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 置顶消息命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 置顶结果。
    /// - Throws: 归属不一致、权限不足或持久化失败时抛出。
    func setPinnedMessageOwnerValidated(actorUserID: UserID, command: V2PinnedMessageCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage>

    /// 按房间归属设置群公告。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 群公告命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 公告结果。
    /// - Throws: 归属不一致、权限不足或持久化失败时抛出。
    func setAnnouncementOwnerValidated(actorUserID: UserID, command: V2GroupAnnouncementCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement>

    /// 按房间归属修改角色权限。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 角色权限命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 权限变更结果。
    /// - Throws: 归属不一致、权限不足或持久化失败时抛出。
    func setRolePermissionsOwnerValidated(actorUserID: UserID, command: V2GroupRolePermissionsCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>

    /// 按房间归属调整成员角色。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 成员角色命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 成员角色变更结果。
    /// - Throws: 归属不一致、权限不足或持久化失败时抛出。
    func changeMemberRoleOwnerValidated(actorUserID: UserID, command: V2GroupMemberRoleCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>
}
