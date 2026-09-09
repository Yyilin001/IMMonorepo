import Foundation
import IMV2Core

/// Runtime-only owner validation capabilities. Public command services remain
/// unaware of routes; routed stores must pass the exact selected shard/epoch.
public protocol V2OwnerValidatedMessageEditStore: Sendable {
    func editOwnerValidated(command: V2EditMessageCommand, ownerRoute: V2RoomShardRoute,
        capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageEditOutcome
}

public protocol V2OwnerValidatedMessageWithdrawalStore: Sendable {
    func withdrawOwnerValidated(command: V2WithdrawMessageCommand, ownerRoute: V2RoomShardRoute,
        capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageWithdrawalOutcome
}

public protocol V2OwnerValidatedMessageReactionStore: Sendable {
    func changeOwnerValidated(command: V2ChangeMessageReactionCommand, ownerRoute: V2RoomShardRoute,
        capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageReactionOutcome
}

