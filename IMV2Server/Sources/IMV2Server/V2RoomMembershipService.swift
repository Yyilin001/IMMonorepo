import Foundation
import IMV2Core

public struct V2AuthenticatedMembershipChange: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MembershipOperationID
    public let targetUserID: UserID
    public let action: V2RoomMembershipAction
    public let expectedMembershipRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: MembershipOperationID, targetUserID: UserID, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.targetUserID = targetUserID
        self.action = action
        self.expectedMembershipRevision = expectedMembershipRevision
    }
}

public enum V2RoomMembershipChangeOutcome: Equatable, Sendable {
    case changed(V2RoomMembershipChange)
    case idempotent(V2RoomMembershipChange)
    case idempotencyConflict
    case revisionConflict(current: UInt64)
    case targetAlreadyMember
    case targetNotMember
    case memberLimitReached
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

public protocol V2RoomMembershipStore: Sendable {
    func change(
        command: V2ChangeRoomMembershipCommand,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome
}

public struct V2RoomMembershipIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    public func make() throws -> (eventID: EventID, planID: FanoutPlanID) {
        try (EventID(makeUUID().uuidString), FanoutPlanID(makeUUID().uuidString))
    }
}

/// Domain entry point for owner-authorized add/remove operations. Database
/// locking, historical target freezing, and the source transaction stay behind
/// `V2RoomMembershipStore` so the gateway never decides membership policy.
public struct V2RoomMembershipService: Sendable {
    private let store: any V2RoomMembershipStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2RoomMembershipIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2RoomMembershipStore, capacityProfile: V2CapacityProfile, identifiers: V2RoomMembershipIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    public func change(_ request: V2AuthenticatedMembershipChange) async throws -> V2RoomMembershipChangeOutcome {
        let command = try V2ChangeRoomMembershipCommand(
            roomID: request.roomID,
            actorUserID: request.actorUserID,
            operationID: request.operationID,
            targetUserID: request.targetUserID,
            action: request.action,
            expectedMembershipRevision: request.expectedMembershipRevision
        )
        let ids = try identifiers.make()
        return try await store.change(command: command, capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now())
    }
}

public enum V2RoomMembershipStoreError: Error, Equatable, Sendable {
    case ownerChanged
    case roomNotFound
    case actorNotOwner
    case targetUnavailable
    case corruptPersistenceState
}
