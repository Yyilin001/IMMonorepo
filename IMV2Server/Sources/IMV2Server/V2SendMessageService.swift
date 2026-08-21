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

/// An immutable acceptance request prepared by the domain layer.  Keeping the
/// generated identifiers with the request is essential: an ordered batch may
/// retry its PostgreSQL transaction, but it must never mint a second message
/// or event identity for the same client operation.
public struct V2RoomWriteRequest: Sendable {
    public let command: V2SendMessageCommand
    public let capacityProfile: V2CapacityProfile
    public let identifiers: V2AcceptanceIdentifiers
    public let now: Date

    public init(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) {
        self.command = command
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }
}

/// A store that can make a compatible ordered input subset durable atomically.
///
/// This is deliberately a separate protocol rather than a convenience method
/// on `V2RoomWriteStore`. The batcher keeps the result for every independent
/// command, so an implementation can atomically commit the subset it has
/// classified as compatible while the remaining distinct rooms use their
/// ordinary durable path. A false classification is never an authorization
/// outcome and cannot be returned to a client.
public protocol V2AtomicRoomWriteBatchStore: V2RoomWriteStore {
    /// A process-local, advisory classification for one pending batch.
    ///
    /// `true` means the implementation expects the request to be eligible for
    /// its shared transaction fast path.  It is never an authorization
    /// decision: a later atomic attempt must still take every authoritative
    /// lock and may decline the request when a durable revision changed.  A
    /// `false` result merely lets the batcher send that independent request
    /// through the established one-command path without making unrelated,
    /// eligible requests give up their set-based transaction.
    func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool]

    func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome]
}

public extension V2AtomicRoomWriteBatchStore {
    /// Stores that do not expose a cheap advisory classifier retain the
    /// original all-or-nothing attempt behaviour.  This keeps the classifier
    /// an optimisation rather than a new requirement for correctness.
    func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        Array(repeating: true, count: requests.count)
    }
}

/// A batch implementation may decline a shape that cannot preserve the
/// ordinary command semantics in a shared transaction (for example a command
/// with attachments or a room that requires a policy side effect).  The
/// batcher then retries the original immutable requests through the ordinary
/// per-command path.  This is distinct from a storage error: it is never
/// exposed to a client and never acknowledges a partial batch.
public enum V2AtomicRoomWriteBatchError: Error, Equatable, Sendable {
    case unsupportedRequestShape
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
    private let batcher: V2SendMessageAdmissionBatcher?
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let idFactory: V2AcceptanceIDFactory
    private let now: @Sendable () -> Date

    /// When enabled, the batcher takes foreground-write admission immediately
    /// around its actual database work. The gateway command boundary must not
    /// also reserve one permit per waiting message, otherwise a batching wait
    /// consumes the whole foreground lane before a transaction starts.
    var managesForegroundWriteAdmission: Bool {
        batcher?.managesForegroundWriteAdmission ?? false
    }

    public init(
        store: any V2RoomWriteStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        idFactory: V2AcceptanceIDFactory = .init(),
        batcher: V2SendMessageAdmissionBatcher? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.batcher = batcher
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
        let prepared = V2RoomWriteRequest(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: try idFactory.make(),
            now: now()
        )
        if let batcher {
            return try await batcher.accept(prepared)
        }
        return try await store.accept(
            command: prepared.command,
            capacityProfile: prepared.capacityProfile,
            identifiers: prepared.identifiers,
            now: prepared.now
        )
    }
}
