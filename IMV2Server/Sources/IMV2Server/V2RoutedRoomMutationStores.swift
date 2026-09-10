import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 仅用于把授权事实桥接进房间归属事务的控制面身份快照。
///
/// 归属存储仍会自行完成全部房间内角色、修订与成员关系校验，
/// 该快照不会替代这些检查。
public struct V2MembershipIdentitySnapshot: Equatable, Sendable {
    /// 发起者用户。
    public let actorUserID: UserID
    /// 目标用户。
    public let targetUserID: UserID
    /// 发起者账号是否有效。
    public let actorIsActive: Bool
    /// 目标账号是否有效。
    public let targetIsActive: Bool

    /// 保存身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    ///   - actorIsActive: 发起者账号是否有效。
    ///   - targetIsActive: 目标账号是否有效。
    public init(
        actorUserID: UserID,
        targetUserID: UserID,
        actorIsActive: Bool,
        targetIsActive: Bool
    ) {
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.actorIsActive = actorIsActive
        self.targetIsActive = targetIsActive
    }
}

/// 成员身份快照读取能力。
public protocol V2MembershipIdentitySnapshotValidating: Sendable {
    /// 读取一次成员身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    /// - Returns: 两个身份事实的快照。
    /// - Throws: 控制面存储不可用时抛出。
    func snapshot(
        actorUserID: UserID,
        targetUserID: UserID
    ) async throws -> V2MembershipIdentitySnapshot
}

/// 支持控制面校验的成员变更存储。
public protocol V2ControlValidatedRoomMembershipStore:
    V2RoomMembershipStore {
    /// 以控制面身份快照与房间归属执行成员变更。
    ///
    /// - Parameters:
    ///   - command: 成员变更命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - identitySnapshot: 控制面提供的身份快照。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 归属不符、身份失效、无权限或持久化失败时抛出。
    func changeControlValidated(
        command: V2ChangeRoomMembershipCommand,
        ownerRoute: V2RoomShardRoute,
        identitySnapshot: V2MembershipIdentitySnapshot,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome
}

/// 在单次控制面快照中读取两个全局身份事实。
///
/// 账号停用仍作为认证与会话栅栏；该检查只是防止新增成员时引用不存在或已停用的身份。
public struct V2PostgresMembershipIdentitySnapshotValidator:
    V2MembershipIdentitySnapshotValidating {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 提供公开资料与账号状态的控制面数据库。
    public init(database: any Database) { self.database = database }

    /// 读取发起者与目标用户的身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    /// - Returns: 两个身份事实的快照。
    /// - Throws: 标识非法或连接不支持 SQL 时抛出
    ///   ``V2RoomMembershipStoreError/corruptPersistenceState``。
    public func snapshot(
        actorUserID: UserID,
        targetUserID: UserID
    ) async throws -> V2MembershipIdentitySnapshot {
        guard let actorUUID = UUID(uuidString: actorUserID.rawValue),
              let targetUUID = UUID(uuidString: targetUserID.rawValue),
              let sql = database as? any SQLDatabase
        else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        let active = try await sql.raw("""
            SELECT profile.user_id
            FROM im_v2.public_user_profiles AS profile
            WHERE profile.user_id = ANY(
                \(bind: [actorUUID, targetUUID])::uuid[]
            )
              AND profile.state = 'active'
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.account_disables AS disabled
                  WHERE disabled.user_id = profile.user_id
              )
            """).all(decoding: ActiveIdentityRow.self)
        let activeIDs = Set(active.map(\.userID))
        return .init(
            actorUserID: actorUserID,
            targetUserID: targetUserID,
            actorIsActive: activeIDs.contains(actorUUID),
            targetIsActive: activeIDs.contains(targetUUID)
        )
    }
}

/// 按房间归属路由成员变更的存储。
///
/// 它先把控制面身份快照与已选定的房间归属一起交给归属存储，
/// 房间内的角色与修订校验仍由归属侧完成。
public struct V2RoutedRoomMembershipStore: V2RoomMembershipStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2ControlValidatedRoomMembershipStore>
    private let identities: any V2MembershipIdentitySnapshotValidating

    /// 组合路由来源、各归属存储与身份校验器。
    ///
    /// - Parameters:
    ///   - router: 房间归属路由来源。
    ///   - stores: 逻辑分片标识到归属存储的映射。
    ///   - identities: 控制面身份快照校验器。
    ///   - physicalStoreKeyByShard: 逻辑分片到物理存储键的映射；为 `nil` 时按标识自身映射。
    /// - Throws: 归属映射为空、含空白标识或物理键不匹配时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(
        router: any V2RoomShardRouting,
        stores: [String: any V2ControlValidatedRoomMembershipStore],
        identities: any V2MembershipIdentitySnapshotValidating,
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        selector = try .init(
            router: router,
            stores: stores,
            physicalStoreKeyByShard: physicalStoreKeyByShard
        )
        self.identities = identities
    }

    /// 执行一次成员变更。
    ///
    /// - Parameters:
    ///   - command: 成员变更命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 归属未配置、身份校验失败或归属存储失败时抛出。
    public func change(
        command: V2ChangeRoomMembershipCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome {
        async let selectedOwner = selector.owner(for: command.roomID)
        async let identitySnapshot = identities.snapshot(
            actorUserID: command.actorUserID,
            targetUserID: command.targetUserID
        )
        let selected = try await selectedOwner
        return try await selected.store.changeControlValidated(
            command: command,
            ownerRoute: selected.route,
            identitySnapshot: identitySnapshot,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }
}

/// 按房间归属路由消息撤回的存储。
public struct V2RoutedMessageWithdrawalStore: V2MessageWithdrawalStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedMessageWithdrawalStore>

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
        stores: [String: any V2OwnerValidatedMessageWithdrawalStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        selector = try .init(
            router: router,
            stores: stores,
            physicalStoreKeyByShard: physicalStoreKeyByShard
        )
    }

    /// 执行一次消息撤回。
    ///
    /// - Parameters:
    ///   - command: 撤回命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func withdraw(
        command: V2WithdrawMessageCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2MessageWithdrawalOutcome {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.withdrawOwnerValidated(
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }
}

/// 按房间归属路由消息表情变更的存储。
public struct V2RoutedMessageReactionStore: V2MessageReactionStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedMessageReactionStore>

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
        stores: [String: any V2OwnerValidatedMessageReactionStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        selector = try .init(
            router: router,
            stores: stores,
            physicalStoreKeyByShard: physicalStoreKeyByShard
        )
    }

    /// 执行一次表情变更。
    ///
    /// - Parameters:
    ///   - command: 表情变更命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 表情变更结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func change(
        command: V2ChangeMessageReactionCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2MessageReactionOutcome {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.changeOwnerValidated(
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }
}

/// 按房间归属路由消息编辑的存储。
public struct V2RoutedMessageEditStore: V2MessageEditStore {
    private let selector: V2RoomOwnerStoreSelector<any V2OwnerValidatedMessageEditStore>

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
        stores: [String: any V2OwnerValidatedMessageEditStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        selector = try .init(
            router: router,
            stores: stores,
            physicalStoreKeyByShard: physicalStoreKeyByShard
        )
    }

    /// 执行一次消息编辑。
    ///
    /// - Parameters:
    ///   - command: 编辑命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 编辑结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func edit(
        command: V2EditMessageCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2MessageEditOutcome {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.editOwnerValidated(
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }
}

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
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 置顶结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func setPinnedMessage(
        actorUserID: UserID,
        command: V2PinnedMessageCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage> {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.setPinnedMessageOwnerValidated(
            actorUserID: actorUserID,
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
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
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 公告结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func setAnnouncement(
        actorUserID: UserID,
        command: V2GroupAnnouncementCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement> {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.setAnnouncementOwnerValidated(
            actorUserID: actorUserID,
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
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
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 权限变更结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func setRolePermissions(
        actorUserID: UserID,
        command: V2GroupRolePermissionsCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
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
            planID: planID,
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
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 角色变更结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func changeMemberRole(
        actorUserID: UserID,
        command: V2GroupMemberRoleCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange> {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.changeMemberRoleOwnerValidated(
            actorUserID: actorUserID,
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }
}

/// 按房间归属路由审核命令的存储。
///
/// 普通审核与可信安全审核都按房间归属选择存储，并在归属事务内复核房间归属。
public struct V2RoutedModerationStore:
    V2ModerationStore,
    V2TrustedSafetyModerationStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedModerationStore>

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
        stores: [String: any V2OwnerValidatedModerationStore],
        physicalStoreKeyByShard: [String: String]? = nil
    ) throws {
        selector = try .init(
            router: router,
            stores: stores,
            physicalStoreKeyByShard: physicalStoreKeyByShard
        )
    }

    /// 以房间归属应用一次普通审核命令。
    ///
    /// - Parameters:
    ///   - command: 审核命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 审核结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func apply(
        command: V2ModerationCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2ModerationOutcome {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.applyOwnerValidated(
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }

    /// 以房间归属应用一次可信安全审核命令。
    ///
    /// - Parameters:
    ///   - command: 审核命令，发起者由服务配置的受信主体提供。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 审核结果。
    /// - Throws: 归属未配置或归属存储失败时抛出。
    public func applyTrustedSafety(
        command: V2ModerationCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2ModerationOutcome {
        let selected = try await selector.owner(for: command.roomID)
        return try await selected.store.applyTrustedSafetyOwnerValidated(
            command: command,
            ownerRoute: selected.route,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }
}

/// 房间归属侧的审核执行能力组合。
public protocol V2RoutedModerationOwnerStore:
    V2ModerationStore,
    V2TrustedSafetyModerationStore {}

extension PostgresV2ModerationStore: V2RoutedModerationOwnerStore {}
extension V2RoutedModerationStore: V2RoutedModerationOwnerStore {}

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

private struct ActiveIdentityRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}
