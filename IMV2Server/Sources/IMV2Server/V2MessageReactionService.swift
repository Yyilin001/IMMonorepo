import Foundation
import IMV2Core

public struct V2AuthenticatedMessageReaction: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageReactionOperationID
    public let messageID: MessageID
    public let reaction: String
    public let action: V2MessageReactionAction

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.messageID = messageID; self.reaction = reaction; self.action = action
    }
}

public enum V2MessageReactionOutcome: Equatable, Sendable {
    case changed(V2MessageReactionChange)
    case idempotent(V2MessageReactionChange)
    case idempotencyConflict
    case alreadyInDesiredState
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

public protocol V2MessageReactionStore: Sendable {
    func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageReactionOutcome
}

public struct V2MessageReactionIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    public func make() throws -> (eventID: EventID, planID: FanoutPlanID) {
        try (.init(makeUUID().uuidString), .init(makeUUID().uuidString))
    }
}

public struct V2MessageReactionService: Sendable {
    private let store: any V2MessageReactionStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageReactionIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2MessageReactionStore, capacityProfile: V2CapacityProfile, identifiers: V2MessageReactionIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.capacityProfile = capacityProfile; self.identifiers = identifiers; self.now = now
    }

    public func change(_ request: V2AuthenticatedMessageReaction) async throws -> V2MessageReactionOutcome {
        let ids = try identifiers.make()
        return try await store.change(command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, reaction: request.reaction, action: request.action), capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now())
    }
}

public enum V2MessageReactionStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotMember
    case messageWithdrawn
    case reactionLimitReached
    case corruptPersistenceState
}
