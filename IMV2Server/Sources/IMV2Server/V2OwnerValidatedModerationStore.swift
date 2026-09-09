import Foundation
import IMV2Core

/// Runtime ownership capability, separate from ordinary versus trusted safety
/// authorization. Both entry points require the selected room owner route.
public protocol V2OwnerValidatedModerationStore: Sendable {
    func applyOwnerValidated(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2ModerationOutcome
    func applyTrustedSafetyOwnerValidated(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2ModerationOutcome
}
