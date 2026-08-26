import Foundation
import IMV2Core

/// A post-commit acceleration payload for an active plain direct conversation.
///
/// It is intentionally not a durable delivery record: loss, duplication and
/// reordering are repaired by the existing room-log cursor.  The recipient
/// set is captured from the same locked transaction that committed the event,
/// so a gateway never derives authorization from a later, potentially stale
/// foreground subscription.
public struct V2DirectRoomLiveEvent: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64
    public let sourceEventID: EventID
    public let roomSequence: UInt64
    public let projectionKind: String
    public let payload: Data
    public let recipientUserIDs: Set<UserID>

    init(
        roomID: RoomID,
        highWatermark: UInt64,
        sourceEventID: EventID,
        roomSequence: UInt64,
        projectionKind: String,
        payload: Data,
        recipientUserIDs: Set<UserID>
    ) {
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.sourceEventID = sourceEventID
        self.roomSequence = roomSequence
        self.projectionKind = projectionKind
        self.payload = payload
        self.recipientUserIDs = recipientUserIDs
    }

    public init?(_ message: V2AcceptedMessage) {
        guard let draft = V2DirectRoomLiveEventDraft(message),
              let materialized = draft.materialized()
        else { return nil }
        self = materialized
    }

    static func payload(for message: V2AcceptedMessage) -> Data? {
        V2DirectRoomLogPayloadCodec.encode(message)
    }
}

/// Keeps only already-committed, immutable acceptance data on the foreground
/// hint queue. JSON creation is deliberately deferred until the queue's
/// background relay runs: a sender's accepted response must not pay for two
/// JSON transformations merely because the peer currently has the room open.
struct V2DirectRoomLiveEventDraft: Equatable, Sendable {
    let message: V2AcceptedMessage
    let sourceEventID: EventID
    let recipientUserIDs: Set<UserID>

    init?(_ message: V2AcceptedMessage) {
        guard message.usesRoomEventLog,
              message.groupDeliveryMode == nil,
              message.media.isEmpty,
              message.mentions.isEmpty,
              message.replyTo == nil,
              let sourceEventID = message.sourceEventID,
              message.acceptedMembershipRevision != nil,
              let directRecipientUserID = message.directRecipientUserID,
              directRecipientUserID != message.senderUserID
        else { return nil }
        self.message = message
        self.sourceEventID = sourceEventID
        recipientUserIDs = [message.senderUserID, directRecipientUserID]
    }

    func materialized() -> V2DirectRoomLiveEvent? {
        guard let payload = V2DirectRoomLiveEvent.payload(for: message) else { return nil }
        return .init(
            roomID: message.roomID,
            highWatermark: message.roomSequence,
            sourceEventID: sourceEventID,
            roomSequence: message.roomSequence,
            projectionKind: "message",
            payload: payload,
            recipientUserIDs: recipientUserIDs
        )
    }
}
