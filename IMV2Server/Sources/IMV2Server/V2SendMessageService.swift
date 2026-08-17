import Foundation
import IMV2Core

/// Values that are available only after a transport has authenticated the
/// caller.  The public protocol decoder must never be allowed to supply the
/// sender id directly.
public struct V2AuthenticatedSendMessage: Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?

    public init(roomID: RoomID, actorUserID: UserID, clientMessageID: ClientMessageID, text: String, media: [V2MediaReference] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}

public enum V2SendMessageOutcome: Equatable, Sendable {
    case accepted(V2AcceptedMessage)
    case idempotent(V2AcceptedMessage)
    case idempotencyConflict
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
    /// The server persisted a private activity and composer capability for
    /// this exact operation. No message, room event or fan-out plan exists.
    case denied(V2DirectMessageDenied)
}

public struct V2DirectMessageDenied: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case generic
        case systemAccountReadOnly = "system_account_read_only"
    }

    public let roomID: RoomID
    public let sourceEventID: EventID
    public let timelineSequence: UInt64
    public let createdAt: Date
    public let reason: Reason

    public init(roomID: RoomID, sourceEventID: EventID, timelineSequence: UInt64, createdAt: Date, reason: Reason = .generic) {
        precondition(timelineSequence > 0)
        self.roomID = roomID
        self.sourceEventID = sourceEventID
        self.timelineSequence = timelineSequence
        self.createdAt = createdAt
        self.reason = reason
    }
}

/// Binds a runtime capacity policy to the persisted room profile identifier.
/// A policy may never be selected only by process-wide default configuration.
public struct V2CapacityProfile: Equatable, Sendable {
    public let id: String
    public let limits: RoomCapacityProfile

    public init(id: String, limits: RoomCapacityProfile) throws {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw V2CapacityProfileError.invalidIdentifier }
        self.id = normalized
        self.limits = limits
    }
}

public enum V2CapacityProfileError: Error, Equatable, Sendable { case invalidIdentifier }

/// The persistence boundary owns row locking and the database transaction.
/// Its successful implementation must persist the entire Core transaction
/// value, never just the message row.
public protocol V2RoomWriteStore: Sendable {
    func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome
}

public enum V2RoomWriteStoreError: Error, Equatable, Sendable {
    case roomNotFound
    case actorNotEligible
    case actorMuted
    case roomFrozen
    case capacityProfileMismatch
    case corruptPersistenceState
    case directMessageBlocked
    case strangerMessagePermissionDenied
    case strangerMessageLimitReached
    case replyTargetNotFound
}

public struct V2AcceptanceIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID

    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.makeUUID = makeUUID
    }

    public func make() throws -> V2AcceptanceIdentifiers {
        try V2AcceptanceIdentifiers(
            messageID: MessageID(makeUUID().uuidString),
            eventID: EventID(makeUUID().uuidString),
            planID: FanoutPlanID(makeUUID().uuidString)
        )
    }
}

public struct V2SendMessageService: Sendable {
    private let store: any V2RoomWriteStore
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let idFactory: V2AcceptanceIDFactory
    private let now: @Sendable () -> Date

    public init(
        store: any V2RoomWriteStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        idFactory: V2AcceptanceIDFactory = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.idFactory = idFactory
        self.now = now
    }

    public func send(_ request: V2AuthenticatedSendMessage) async throws -> V2SendMessageOutcome {
        let command = try V2SendMessageCommand(
            roomID: request.roomID,
            senderUserID: request.actorUserID,
            clientMessageID: request.clientMessageID,
            text: request.text,
            media: request.media,
            mentions: request.mentions,
            entities: request.entities,
            replyTo: request.replyTo,
            limits: limits
        )
        return try await store.accept(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: try idFactory.make(),
            now: now()
        )
    }
}
