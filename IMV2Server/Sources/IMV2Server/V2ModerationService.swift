import Foundation
import IMV2Core

/// The gateway has already authenticated the actor. This boundary deliberately
/// accepts no caller-supplied role or safety-service identity; those are
/// derived by the authoritative store or a separate privileged API.
public struct V2AuthenticatedModeration: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let targetUserID: UserID?
    public let messageID: MessageID?
    public let muteUntil: Date?
    public let reasonCode: V2ModerationReasonCode

    public init(roomID: RoomID, actorUserID: UserID, operationID: ModerationOperationID, action: V2ModerationAction, targetUserID: UserID? = nil, messageID: MessageID? = nil, muteUntil: Date? = nil, reasonCode: V2ModerationReasonCode) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.action = action
        self.targetUserID = targetUserID
        self.messageID = messageID
        self.muteUntil = muteUntil
        self.reasonCode = reasonCode
    }
}

/// A result carries no report text or message body. Those remain protected in
/// the authoritative audit store and never become generic room-sync payload.
public struct V2ModerationResult: Equatable, Sendable {
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let targetUserID: UserID?
    public let messageID: MessageID?
    public let messageRevision: UInt64?
    /// Present only for an audit-level member removal.  It is persisted with
    /// the moderation operation so a retry returns the original membership
    /// fence rather than reading mutable room state.
    public let membershipRevision: UInt64?
    public let muteUntil: Date?
    public let roomSequence: UInt64
    public let eventID: EventID
    public let fanoutPlanID: FanoutPlanID
    public let createdAt: Date

    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction, targetUserID: UserID?, messageID: MessageID?, messageRevision: UInt64? = nil, membershipRevision: UInt64? = nil, muteUntil: Date?, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) {
        self.roomID = roomID
        self.operationID = operationID
        self.action = action
        self.targetUserID = targetUserID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.membershipRevision = membershipRevision
        self.muteUntil = muteUntil
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}

public enum V2ModerationOutcome: Equatable, Sendable {
    case applied(V2ModerationResult)
    case idempotent(V2ModerationResult)
    case idempotencyConflict
    case targetNotMember
    case messageAlreadyRedacted
    case actionAlreadyInDesiredState
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

/// One PostgreSQL transaction must derive the actor role, enforce the action,
/// write authoritative state, append the room event and audit row, reserve the
/// fan-out plan, enqueue outbox work, and persist the idempotency result.
public protocol V2ModerationStore: Sendable {
    func apply(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2ModerationOutcome
}

/// A separately authenticated safety-service call. It intentionally has no
/// caller-supplied actor identity: the service instance is configured with a
/// trusted audit principal and is never reachable through the TCP gateway.
public struct V2TrustedSafetyRoomControl: Sendable {
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let reasonCode: V2ModerationReasonCode

    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction, reasonCode: V2ModerationReasonCode) throws {
        guard action == .freezeRoom || action == .unfreezeRoom else {
            throw V2ModerationValidationError.invalidActionShape
        }
        self.roomID = roomID
        self.operationID = operationID
        self.action = action
        self.reasonCode = reasonCode
    }
}

/// Privileged safety commands are constructed inside the service process, not
/// decoded from a gateway frame.  Redaction is included here so a delayed
/// content-review verdict follows the same audited tombstone path as a human
/// moderator, without requiring the service account to be a room member.
public struct V2TrustedSafetyModeration: Sendable {
    public let roomID: RoomID
    public let operationID: ModerationOperationID
    public let action: V2ModerationAction
    public let messageID: MessageID?
    public let expectedMessageRevision: UInt64?
    public let reasonCode: V2ModerationReasonCode

    public init(roomID: RoomID, operationID: ModerationOperationID, action: V2ModerationAction, messageID: MessageID? = nil, expectedMessageRevision: UInt64? = nil, reasonCode: V2ModerationReasonCode) throws {
        guard action == .freezeRoom || action == .unfreezeRoom || action == .redactMessage else {
            throw V2ModerationValidationError.invalidActionShape
        }
        guard (action == .redactMessage) == (messageID != nil) else {
            throw V2ModerationValidationError.invalidActionShape
        }
        guard action == .redactMessage || expectedMessageRevision == nil else {
            throw V2ModerationValidationError.invalidActionShape
        }
        self.roomID = roomID
        self.operationID = operationID
        self.action = action
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
        self.reasonCode = reasonCode
    }
}

public protocol V2TrustedSafetyModerationStore: Sendable {
    func applyTrustedSafety(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2ModerationOutcome
}

public struct V2ModerationIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }
    public func make() throws -> (eventID: EventID, planID: FanoutPlanID) {
        try (.init(makeUUID().uuidString), .init(makeUUID().uuidString))
    }
}

public struct V2ModerationService: Sendable {
    private let store: any V2ModerationStore
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2ModerationIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2ModerationStore, capacityProfile: V2CapacityProfile, identifiers: V2ModerationIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    public func apply(_ request: V2AuthenticatedModeration) async throws -> V2ModerationOutcome {
        let ids = try identifiers.make()
        let command = try V2ModerationCommand(
            roomID: request.roomID,
            actorUserID: request.actorUserID,
            operationID: request.operationID,
            action: request.action,
            targetUserID: request.targetUserID,
            messageID: request.messageID,
            muteUntil: request.muteUntil,
            reasonCode: request.reasonCode
        )
        return try await store.apply(command: command, capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now())
    }
}

/// The privileged counterpart to `V2ModerationService`. Construction is a
/// deployment-time trust decision: only an authenticated safety-service/admin
/// integration receives this object and its configured audit principal.
public struct V2TrustedSafetyModerationService: Sendable {
    private let store: any V2TrustedSafetyModerationStore
    private let safetyActorUserID: UserID
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2ModerationIDFactory
    private let now: @Sendable () -> Date

    public init(store: any V2TrustedSafetyModerationStore, safetyActorUserID: UserID, capacityProfile: V2CapacityProfile, identifiers: V2ModerationIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.safetyActorUserID = safetyActorUserID
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    public func apply(_ request: V2TrustedSafetyRoomControl) async throws -> V2ModerationOutcome {
        try await apply(V2TrustedSafetyModeration(
            roomID: request.roomID,
            operationID: request.operationID,
            action: request.action,
            reasonCode: request.reasonCode
        ))
    }

    public func apply(_ request: V2TrustedSafetyModeration) async throws -> V2ModerationOutcome {
        let ids = try identifiers.make()
        let command = try V2ModerationCommand(
            roomID: request.roomID,
            actorUserID: safetyActorUserID,
            operationID: request.operationID,
            action: request.action,
            messageID: request.messageID,
            expectedMessageRevision: request.expectedMessageRevision,
            reasonCode: request.reasonCode
        )
        return try await store.applyTrustedSafety(command: command, capacityProfile: capacityProfile, eventID: ids.eventID, planID: ids.planID, now: now())
    }
}

public enum V2ModerationStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case messageNotFound
    case actorNotAuthorized
    case unsupportedAction
    case corruptPersistenceState
}
