import Foundation
import IMV2Core

public struct V2AuthenticatedMessageEdit: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageEditOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64
    public let text: String

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String) {
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.messageID = messageID; self.expectedMessageRevision = expectedMessageRevision; self.text = text
    }
}

public enum V2MessageEditOutcome: Equatable, Sendable {
    case edited(V2MessageEdit)
    case idempotent(V2MessageEdit)
    case idempotencyConflict
    case revisionConflict(current: UInt64)
    case alreadyWithdrawn
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

public protocol V2MessageEditStore: Sendable {
    func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2MessageEditOutcome
}

public struct V2MessageEditIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    public func make() throws -> (eventID: EventID, planID: FanoutPlanID) { try (.init(makeUUID().uuidString), .init(makeUUID().uuidString)) }
}

public struct V2MessageEditService: Sendable {
    private let store: any V2MessageEditStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2MessageEditIDFactory
    private let now: @Sendable () -> Date
    private let maximumTextUTF8Bytes: Int

    public init(store: any V2MessageEditStore, capacityProfile: V2CapacityProfile, maximumTextUTF8Bytes: Int, identifiers: V2MessageEditIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.capacityProfile = capacityProfile; self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.identifiers = identifiers; self.now = now
    }

    public func edit(_ request: V2AuthenticatedMessageEdit) async throws -> V2MessageEditOutcome {
        let ids = try identifiers.make()
        return try await store.edit(
            command: .init(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, messageID: request.messageID, expectedMessageRevision: request.expectedMessageRevision, text: request.text, maximumUTF8Bytes: maximumTextUTF8Bytes),
            capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now()
        )
    }
}

public enum V2MessageEditStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotAuthor
    case corruptPersistenceState
}
