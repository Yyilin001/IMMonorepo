import Foundation

public struct V2MessageCommandLimits: Equatable, Sendable {
    public let maxUTF8Bytes: Int
    public static let maxMediaAttachments = 10
    public static let maxMentions = 20

    public init(maxUTF8Bytes: Int) throws {
        guard maxUTF8Bytes > 0 else {
            throw V2CoreError.invalidPositiveValue
        }
        self.maxUTF8Bytes = maxUTF8Bytes
    }
}

public struct V2SendMessageCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    public let targetRule: FanoutTargetRule
    /// Server-created attribution for a copied message. It is never decoded
    /// from the ordinary send-message protocol surface.
    public let forwardedFrom: V2ForwardMessageSource?
    public let fingerprint: V2SendMessageFingerprint

    public init(
        roomID: RoomID,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        targetRule: FanoutTargetRule = .eligibleMemberCount,
        forwardedFrom: V2ForwardMessageSource? = nil,
        limits: V2MessageCommandLimits
    ) throws {
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount <= limits.maxUTF8Bytes,
              (byteCount > 0 || !media.isEmpty),
              media.count <= V2MessageCommandLimits.maxMediaAttachments,
              (media.count < 2 || Set(media).count == media.count),
              mentions.count <= V2MessageCommandLimits.maxMentions,
              (mentions.count < 2 || Set(mentions).count == mentions.count)
        else {
            throw V2SendMessageValidationError.invalidTextLength
        }
        try V2RichMessageContent.validate(text: text, entities: entities)
        if case .exactTargetCount(let count) = targetRule, count < 0 {
            throw V2CoreError.invalidNonNegativeValue
        }
        self.roomID = roomID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.targetRule = targetRule
        self.forwardedFrom = forwardedFrom
        self.fingerprint = V2SendMessageFingerprint(
            roomID: roomID, senderUserID: senderUserID,
            clientMessageID: clientMessageID, text: text, media: media,
            mentions: mentions, entities: entities, replyTo: replyTo,
            targetRule: targetRule, forwardedFrom: forwardedFrom
        )
    }
}

/// Presentation metadata carried by historical accepted messages. This is not
/// sufficient to authorize a new forward and intentionally needs no revision.
public struct V2ForwardedMessageAttribution: Equatable, Sendable {
    public let messageID: MessageID
    public let senderUserID: UserID

    public init(messageID: MessageID, senderUserID: UserID) {
        self.messageID = messageID
        self.senderUserID = senderUserID
    }
}

/// Server-created source snapshot for a new forward. Unlike presentation
/// attribution, this always carries the exact version used for acceptance.
public struct V2ForwardMessageSource: Equatable, Sendable {
    public let messageID: MessageID
    public let senderUserID: UserID
    public let sourceRevision: V2MessageRevision

    public init(messageID: MessageID, senderUserID: UserID, sourceRevision: V2MessageRevision) {
        self.messageID = messageID
        self.senderUserID = senderUserID
        self.sourceRevision = sourceRevision
    }
}

public enum V2SendMessageValidationError: Error, Equatable, Sendable {
    case invalidTextLength
}

public struct V2CommandDeduplicationKey: Hashable, Sendable {
    public let roomID: RoomID
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID

    public init(roomID: RoomID, senderUserID: UserID, clientMessageID: ClientMessageID) {
        self.roomID = roomID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
    }
}

/// A message accepted by the pure admission reducer but not yet materialized
/// against a media store.  It is deliberately separate from
/// ``V2AcceptedMessage``: attachment presentation data is authoritative
/// storage metadata, not something the reducer can invent safely.
public struct V2AcceptedMessageDraft: Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    /// A room-local presentation sequence shared by ordinary messages and
    /// private activity entries. It is deliberately independent from
    /// `roomSequence`: read receipts and message mutations continue to use
    /// the message-only sequence without gaps introduced by system activity.
    public let timelineSequence: UInt64
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    /// Present only for a group room. It is acceptance metadata used for
    /// non-authoritative foreground availability hints; it does not change
    /// the durable fan-out or acknowledgement contract.
    public let groupDeliveryMode: V2GroupDeliveryMode?
    /// True when this accepted message is durably recovered from the room
    /// event log rather than the per-user fan-out stream. The hint itself is
    /// best effort; the room cursor remains authoritative.
    public let usesRoomEventLog: Bool
    public let createdAt: Date

    public init(
        messageID: MessageID,
        roomID: RoomID,
        roomSequence: UInt64,
        timelineSequence: UInt64? = nil,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence ?? roomSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        precondition((try? V2RichMessageContent.validate(text: text, entities: entities)) != nil)
        self.entities = entities
        self.replyTo = replyTo
        self.groupDeliveryMode = groupDeliveryMode
        self.usesRoomEventLog = usesRoomEventLog
        self.createdAt = createdAt
    }

    /// Produces the only message type that may leave the acceptance/storage
    /// boundary.  The exact ordered media identity check makes a missing or
    /// substituted presentation unrepresentable in the response model.
    public func materialized(
        mediaPresentations: [V2MediaPresentation],
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false,
        sourceEventID: EventID? = nil,
        acceptedMembershipRevision: UInt64? = nil,
        directRecipientUserID: UserID? = nil,
        projectionCreatedAtUnixMilliseconds: Int64? = nil
    ) -> V2AcceptedMessage {
        V2AcceptedMessage(
            messageID: messageID,
            roomID: roomID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            senderUserID: senderUserID,
            clientMessageID: clientMessageID,
            text: text,
            media: media,
            mediaPresentations: mediaPresentations,
            mentions: mentions,
            entities: entities,
            replyTo: replyTo,
            groupDeliveryMode: groupDeliveryMode,
            usesRoomEventLog: usesRoomEventLog,
            sourceEventID: sourceEventID,
            acceptedMembershipRevision: acceptedMembershipRevision,
            directRecipientUserID: directRecipientUserID,
            projectionCreatedAtUnixMilliseconds: projectionCreatedAtUnixMilliseconds,
            createdAt: createdAt
        )
    }
}

/// The complete, storage-materialized result of a successful send command.
/// A value of this type is safe to serialize, project, or render.
public struct V2AcceptedMessage: Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    /// See ``V2AcceptedMessageDraft/timelineSequence``.
    public let timelineSequence: UInt64
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let text: String
    public let media: [V2MediaReference]
    public let mediaPresentations: [V2MediaPresentation]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    /// Present only for a group room. It is acceptance metadata used for
    /// non-authoritative foreground availability hints; it does not change
    /// the durable fan-out or acknowledgement contract.
    public let groupDeliveryMode: V2GroupDeliveryMode?
    /// See ``V2AcceptedMessageDraft/usesRoomEventLog``.
    public let usesRoomEventLog: Bool
    /// Internal durable source identifier for a canonical room-log event.
    /// It is intentionally not part of the transport acknowledgement, but
    /// allows a server-local read-through cache to preserve the same replay
    /// identity as the database event stream.
    public let sourceEventID: EventID?
    /// Membership revision captured by the committed canonical event. A
    /// cache must check this fence against a freshly authorized reader before
    /// returning the event.
    public let acceptedMembershipRevision: UInt64?
    /// For a plain direct room-log event, the other participant captured by
    /// the same locked acceptance transaction.  This is deliberately server
    /// internal: it lets a live delivery accelerator target only identities
    /// that were visible at commit time instead of inferring recipients from
    /// a later subscription or membership lookup.
    public let directRecipientUserID: UserID?
    /// Exact persisted message-projection time. Date can lose submillisecond
    /// precision at distant epochs; caches and live hints must retain the
    /// database's integer value. This metadata is not part of the send receipt.
    public let projectionCreatedAtUnixMilliseconds: Int64?
    public let createdAt: Date

    public init(
        messageID: MessageID,
        roomID: RoomID,
        roomSequence: UInt64,
        timelineSequence: UInt64? = nil,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference] = [],
        mediaPresentations: [V2MediaPresentation],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false,
        sourceEventID: EventID? = nil,
        acceptedMembershipRevision: UInt64? = nil,
        directRecipientUserID: UserID? = nil,
        projectionCreatedAtUnixMilliseconds: Int64? = nil,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence ?? roomSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        precondition(mediaPresentations.map(\.mediaID) == media.map(\.mediaID))
        self.mediaPresentations = mediaPresentations
        self.mentions = mentions
        precondition((try? V2RichMessageContent.validate(text: text, entities: entities)) != nil)
        self.entities = entities
        self.replyTo = replyTo
        self.groupDeliveryMode = groupDeliveryMode
        self.usesRoomEventLog = usesRoomEventLog
        self.sourceEventID = sourceEventID
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.directRecipientUserID = directRecipientUserID
        self.projectionCreatedAtUnixMilliseconds = projectionCreatedAtUnixMilliseconds
        self.createdAt = createdAt
    }
}

public struct V2FanoutPlanDraft: Equatable, Sendable {
    public let id: FanoutPlanID
    public let sourceEventID: EventID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let reservation: FanoutAdmissionReservation

    public init(
        id: FanoutPlanID,
        sourceEventID: EventID,
        roomID: RoomID,
        roomSequence: UInt64,
        reservation: FanoutAdmissionReservation
    ) {
        self.id = id
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.reservation = reservation
    }
}

/// The entire value returned by a successful reduction is written in one
/// room-shard transaction: canonical message, dedupe record, event, outbox,
/// plan, room admission and shard admission. Storage adapters must not split it.
public struct V2MessageAcceptanceTransaction: Equatable, Sendable {
    public let acceptedMessage: V2AcceptedMessageDraft
    public let eventID: EventID
    public let fanoutPlan: V2FanoutPlanDraft
    public let nextRoomState: V2RoomCommandState
    public let nextShardState: ShardAdmissionState

    public init(
        acceptedMessage: V2AcceptedMessageDraft,
        eventID: EventID,
        fanoutPlan: V2FanoutPlanDraft,
        nextRoomState: V2RoomCommandState,
        nextShardState: ShardAdmissionState
    ) {
        self.acceptedMessage = acceptedMessage
        self.eventID = eventID
        self.fanoutPlan = fanoutPlan
        self.nextRoomState = nextRoomState
        self.nextShardState = nextShardState
    }
}

public struct V2RoomCommandState: Equatable, Sendable {
    public let roomID: RoomID
    public let nextRoomSequence: UInt64
    public let admission: RoomAdmissionState
    public let acceptedCommands: [V2CommandDeduplicationKey: V2AcceptedSendCommand]

    public init(
        roomID: RoomID,
        nextRoomSequence: UInt64,
        admission: RoomAdmissionState,
        acceptedCommands: [V2CommandDeduplicationKey: V2AcceptedSendCommand] = [:]
    ) {
        self.roomID = roomID
        self.nextRoomSequence = nextRoomSequence
        self.admission = admission
        self.acceptedCommands = acceptedCommands
    }
}

/// The reducer retains the original input identity with its acceptance. A
/// storage implementation must not reconstruct this fingerprint from an
/// editable message row or replace it after a content mutation.
public struct V2AcceptedSendCommand: Equatable, Sendable {
    public let fingerprint: V2SendMessageFingerprint
    public let acceptedMessage: V2AcceptedMessageDraft

    public init(fingerprint: V2SendMessageFingerprint, acceptedMessage: V2AcceptedMessageDraft) {
        self.fingerprint = fingerprint
        self.acceptedMessage = acceptedMessage
    }
}

public struct V2AcceptanceIdentifiers: Equatable, Sendable {
    public let messageID: MessageID
    public let eventID: EventID
    public let planID: FanoutPlanID

    public init(messageID: MessageID, eventID: EventID, planID: FanoutPlanID) {
        self.messageID = messageID
        self.eventID = eventID
        self.planID = planID
    }
}

public enum V2SendMessageAcceptanceResult: Equatable, Sendable {
    case accepted(V2MessageAcceptanceTransaction)
    case idempotent(V2AcceptedMessageDraft)
    case idempotencyConflict
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

public enum V2SendMessageReducer {
    public static func reduce(
        command: V2SendMessageCommand,
        roomState: V2RoomCommandState,
        shardState: ShardAdmissionState,
        profile: RoomCapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) throws -> V2SendMessageAcceptanceResult {
        guard roomState.roomID == command.roomID else {
            throw V2SendMessageReducerError.roomMismatch
        }

        let deduplicationKey = V2CommandDeduplicationKey(
            roomID: command.roomID,
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID
        )
        if let prior = roomState.acceptedCommands[deduplicationKey] {
            return prior.fingerprint == command.fingerprint
                ? .idempotent(prior.acceptedMessage) : .idempotencyConflict
        }

        let admission = try FanoutAdmissionEvaluator.reserve(
            request: FanoutAdmissionRequest(targetRule: command.targetRule),
            profile: profile,
            roomState: roomState.admission,
            shardState: shardState,
            now: now
        )
        switch admission {
        case .rateLimited(let retryAfterSeconds):
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .accepted(let reservation, let reservedRoomAdmission, let reservedShardState):
            let accepted = V2AcceptedMessageDraft(
                messageID: identifiers.messageID,
                roomID: command.roomID,
                roomSequence: roomState.nextRoomSequence,
                senderUserID: command.senderUserID,
                clientMessageID: command.clientMessageID,
                text: command.text,
                media: command.media,
                mentions: command.mentions,
                entities: command.entities,
                replyTo: command.replyTo,
                createdAt: now
            )
            var acceptedCommands = roomState.acceptedCommands
            acceptedCommands[deduplicationKey] = .init(
                fingerprint: command.fingerprint, acceptedMessage: accepted
            )
            let nextRoomState = V2RoomCommandState(
                roomID: roomState.roomID,
                nextRoomSequence: roomState.nextRoomSequence + 1,
                admission: reservedRoomAdmission,
                acceptedCommands: acceptedCommands
            )
            let plan = V2FanoutPlanDraft(
                id: identifiers.planID,
                sourceEventID: identifiers.eventID,
                roomID: command.roomID,
                roomSequence: accepted.roomSequence,
                reservation: reservation
            )
            return .accepted(
                V2MessageAcceptanceTransaction(
                    acceptedMessage: accepted,
                    eventID: identifiers.eventID,
                    fanoutPlan: plan,
                    nextRoomState: nextRoomState,
                    nextShardState: reservedShardState
                )
            )
        }
    }
}

public enum V2SendMessageReducerError: Error, Equatable, Sendable {
    case roomMismatch
}
