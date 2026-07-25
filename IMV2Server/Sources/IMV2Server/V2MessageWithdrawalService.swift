import Foundation
import IMV2Core

public struct V2AuthenticatedMessageWithdrawal: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageWithdrawalOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
    }
}

public enum V2MessageWithdrawalOutcome: Equatable, Sendable {
    case withdrawn(V2MessageWithdrawal)
    case idempotent(V2MessageWithdrawal)
    case idempotencyConflict
    case revisionConflict(current: UInt64)
    case alreadyWithdrawn
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

/// The store owns row locking, authorization, admission reservation, message
/// tombstoning, event/outbox creation, and durable operation replay in one
/// room-shard transaction.
public protocol V2MessageWithdrawalStore: Sendable {
    func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageWithdrawalOutcome
}

public struct V2MessageWithdrawalIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    public func make() throws -> (eventID: EventID, planID: FanoutPlanID) {
        try (.init(makeUUID().uuidString), .init(makeUUID().uuidString))
    }
}

public struct V2MessageWithdrawalService: Sendable {
    private let store: any V2MessageWithdrawalStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageWithdrawalIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2MessageWithdrawalStore, capacityProfile: V2CapacityProfile, identifiers: V2MessageWithdrawalIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    public func withdraw(_ request: V2AuthenticatedMessageWithdrawal) async throws -> V2MessageWithdrawalOutcome {
        let ids = try identifiers.make()
        return try await store.withdraw(
            command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, expectedMessageRevision: request.expectedMessageRevision),
            capacityProfile: capacityProfile,
            eventID: ids.eventID,
            planID: ids.planID,
            now: now()
        )
    }
}

public enum V2MessageWithdrawalStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotAuthor
    case corruptPersistenceState
}
