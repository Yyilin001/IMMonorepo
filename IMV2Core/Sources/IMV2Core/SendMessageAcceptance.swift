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
        limits: V2MessageCommandLimits
    ) throws {
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount <= limits.maxUTF8Bytes,
              (byteCount > 0 || !media.isEmpty),
              media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count,
              mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else {
            throw V2SendMessageValidationError.invalidTextLength
        }
        try V2RichMessageContent.validate(text: text, entities: entities)
        self.roomID = roomID
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
        self.targetRule = targetRule
    }
}

public enum V2SendMessageValidationError: Error, Equatable, Sendable {
    case invalidTextLength
}

public struct V2CommandDeduplicationKey: Hashable, Sendable {
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID

    public init(senderUserID: UserID, clientMessageID: ClientMessageID) {
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
    }
}

public struct V2AcceptedMessage: Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
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
    public let createdAt: Date

    public init(
        messageID: MessageID,
        roomID: RoomID,
        roomSequence: UInt64,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference] = [],
        mediaPresentations: [V2MediaPresentation] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil,
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.text = text
        self.media = media
        let presentations = mediaPresentations.isEmpty && !media.isEmpty
            ? media.map(V2MediaPresentation.legacy)
            : mediaPresentations
        precondition(presentations.map(\.mediaID) == media.map(\.mediaID))
        self.mediaPresentations = presentations
        self.mentions = mentions
        precondition((try? V2RichMessageContent.validate(text: text, entities: entities)) != nil)
        self.entities = entities
        self.replyTo = replyTo
        self.groupDeliveryMode = groupDeliveryMode
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
    public let acceptedMessage: V2AcceptedMessage
    public let eventID: EventID
    public let fanoutPlan: V2FanoutPlanDraft
    public let nextRoomState: V2RoomCommandState
    public let nextShardState: ShardAdmissionState

    public init(
        acceptedMessage: V2AcceptedMessage,
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
    public let acceptedCommands: [V2CommandDeduplicationKey: V2AcceptedMessage]

    public init(
        roomID: RoomID,
        nextRoomSequence: UInt64,
        admission: RoomAdmissionState,
        acceptedCommands: [V2CommandDeduplicationKey: V2AcceptedMessage] = [:]
    ) {
        self.roomID = roomID
        self.nextRoomSequence = nextRoomSequence
        self.admission = admission
        self.acceptedCommands = acceptedCommands
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
    case idempotent(V2AcceptedMessage)
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
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID
        )
        if let prior = roomState.acceptedCommands[deduplicationKey] {
            return prior.text == command.text && prior.media == command.media && prior.mentions == command.mentions && prior.entities == command.entities && prior.replyTo == command.replyTo ? .idempotent(prior) : .idempotencyConflict
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
            let accepted = V2AcceptedMessage(
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
            acceptedCommands[deduplicationKey] = accepted
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
