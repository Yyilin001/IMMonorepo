import FluentKit
import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit

/// 按房间归属路由群能力变更的存储。
public struct V2RoutedGroupCapabilitiesStore: V2GroupCapabilitiesStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedGroupCapabilitiesStore>

    /// 组合路由来源与各归属存储。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - stores: 逻辑分片标识到归属存储的映射。
    ///   - physicalStoreKeyByShard: 逻辑分片到物理存储键的映射；为 `nil` 时按标识自身映射。
    /// - Throws: 归属映射为空、含空白标识或物理键不匹配时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2OwnerValidatedGroupCapabilitiesStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        selector = try .init(
            router: router,
            stores: stores,
            physicalStoreKeyByShard: physicalStoreKeyByShard
        )
    }

    /// 设置群置顶消息。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 置顶消息命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 置顶结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func setPinnedMessage(
        actorUserID: UserID,
        command: V2PinnedMessageCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        now: Date
    ) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.setPinnedMessageOwnerValidated(
            actorUserID: actorUserID,
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            now: now
        )
    }

    /// 设置群公告。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 群公告命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 公告结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func setAnnouncement(
        actorUserID: UserID,
        command: V2GroupAnnouncementCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        now: Date
    ) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.setAnnouncementOwnerValidated(
            actorUserID: actorUserID,
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            now: now
        )
    }

    /// 设置角色权限。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 角色权限命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 权限变更结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func setRolePermissions(
        actorUserID: UserID,
        command: V2GroupRolePermissionsCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        now: Date
    ) async throws -> V2GroupCapabilitiesOutcome<
        V2GroupRolePermissionsChange
    > {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.setRolePermissionsOwnerValidated(
            actorUserID: actorUserID,
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            now: now
        )
    }

    /// 调整成员角色。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起操作的用户。
    ///   - command: 成员角色命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 角色变更结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func changeMemberRole(
        actorUserID: UserID,
        command: V2GroupMemberRoleCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        now: Date
    ) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.changeMemberRoleOwnerValidated(
            actorUserID: actorUserID,
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            now: now
        )
    }
}

private struct V2RoomOwnerStoreSelector<Store: Sendable>: Sendable {
    private let router: any V2RoomShardRouting
    private let stores: [String: Store]

    init(
        router: any V2RoomShardRouting,
        stores: [String: Store],
        physicalStoreKeyByShard: [String: String]?
    ) throws {
        guard !stores.isEmpty,
              stores.keys.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        let keys = physicalStoreKeyByShard ?? Dictionary(
            uniqueKeysWithValues: stores.keys.map { ($0, $0) }
        )
        guard Set(keys.keys) == Set(stores.keys),
              keys.values.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.router = router
        self.stores = stores
    }

    // Callers enforcing ownership must retain the epoch even if every logical
    // shard currently shares a database. Topology alone is not an owner fence.
    func owner(for roomID: RoomID) async throws -> (route: V2RoomShardRoute, store: Store) {
        let route = try await router.route(for: roomID)
        guard let store = stores[route.shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return (route, store)
    }
}
