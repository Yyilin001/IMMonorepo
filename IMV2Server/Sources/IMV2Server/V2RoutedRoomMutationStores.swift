import Fluent
import Foundation
import IMV2Core
import SQLKit

/// A control-plane identity snapshot used only to bridge an authorization
/// fact into a room-owner transaction. The owner store still performs every
/// room-local role, revision and membership check itself.
public struct V2MembershipIdentitySnapshot: Equatable, Sendable {
    public let actorUserID: UserID
    public let targetUserID: UserID
    public let actorIsActive: Bool
    public let targetIsActive: Bool

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

public protocol V2MembershipIdentitySnapshotValidating: Sendable {
    func snapshot(
        actorUserID: UserID,
        targetUserID: UserID
    ) async throws -> V2MembershipIdentitySnapshot
}

public protocol V2ControlValidatedRoomMembershipStore:
    V2RoomMembershipStore {
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

/// Reads the two global identity facts in one control-store snapshot. Account
/// disable remains an authentication/session fence; this check prevents a new
/// membership from naming a missing or already-disabled identity.
public struct V2PostgresMembershipIdentitySnapshotValidator:
    V2MembershipIdentitySnapshotValidating {
    private let database: any Database

    public init(database: any Database) { self.database = database }

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

public struct V2RoutedRoomMembershipStore: V2RoomMembershipStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2ControlValidatedRoomMembershipStore>
    private let identities: any V2MembershipIdentitySnapshotValidating

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

public struct V2RoutedMessageWithdrawalStore: V2MessageWithdrawalStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedMessageWithdrawalStore>

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

public struct V2RoutedMessageReactionStore: V2MessageReactionStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedMessageReactionStore>

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

public struct V2RoutedMessageEditStore: V2MessageEditStore {
    private let selector: V2RoomOwnerStoreSelector<any V2OwnerValidatedMessageEditStore>

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

public struct V2RoutedGroupCapabilitiesStore: V2GroupCapabilitiesStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedGroupCapabilitiesStore>

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

public struct V2RoutedModerationStore:
    V2ModerationStore,
    V2TrustedSafetyModerationStore {
    private let selector:
        V2RoomOwnerStoreSelector<any V2OwnerValidatedModerationStore>

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
