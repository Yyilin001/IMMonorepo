import Foundation
import IMV2Core

/// Owner-aware runtime capability. Routed group commands must carry the exact
/// selected route into the transaction, including operation replay.
public protocol V2OwnerValidatedGroupCapabilitiesStore: Sendable {
    func setPinnedMessageOwnerValidated(actorUserID: UserID, command: V2PinnedMessageCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2PinnedMessage>
    func setAnnouncementOwnerValidated(actorUserID: UserID, command: V2GroupAnnouncementCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupAnnouncement>
    func setRolePermissionsOwnerValidated(actorUserID: UserID, command: V2GroupRolePermissionsCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupRolePermissionsChange>
    func changeMemberRoleOwnerValidated(actorUserID: UserID, command: V2GroupMemberRoleCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2GroupCapabilitiesOutcome<V2GroupMemberRoleChange>
}
