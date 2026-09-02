import Foundation
import IMV2Core

/// A post-commit acceleration payload for an active plain room conversation.
///
/// It is intentionally not a durable delivery record: loss, duplication and
/// reordering are repaired by the existing room-log cursor.  The recipient
/// set is captured from the same locked transaction that committed the event,
/// so a gateway never derives authorization from a later, potentially stale
/// foreground subscription. Direct rooms carry their exact two-user audience;
/// group rooms carry the durable membership epoch of both the append and the
/// subscription, avoiding per-message member enumeration while failing closed
/// after every membership mutation.
public struct V2DirectRoomLiveEvent: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64
    public let sourceEventID: EventID
    public let roomSequence: UInt64
    public let projectionKind: String
    public let payload: Data
    public let recipientUserIDs: Set<UserID>
    /// Non-nil for a group-room broadcast. The routing registry emits the
    /// payload only to subscriptions authorized at this exact revision.
    public let groupMembershipRevision: UInt64?
    /// Durable membership fence captured by the accepting transaction. It is
    /// not needed for socket routing, but lets the room-log acceleration cache
    /// reuse this already-encoded payload without copying and encoding the
    /// complete accepted message a second time.
    let acceptedMembershipRevision: UInt64?
    /// Process-local transport identity of the request origin. It removes only
    /// the redundant echo to that one socket; it is never an audience grant
    /// and is harmless on another Gateway where no connection can match it.
    let excludedConnectionID: UUID?

    init(
        roomID: RoomID,
        highWatermark: UInt64,
        sourceEventID: EventID,
        roomSequence: UInt64,
        projectionKind: String,
        payload: Data,
        recipientUserIDs: Set<UserID>,
        groupMembershipRevision: UInt64? = nil,
        acceptedMembershipRevision: UInt64? = nil,
        excludedConnectionID: UUID? = nil
    ) {
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.sourceEventID = sourceEventID
        self.roomSequence = roomSequence
        self.projectionKind = projectionKind
        self.payload = payload
        self.recipientUserIDs = recipientUserIDs
        self.groupMembershipRevision = groupMembershipRevision
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.excludedConnectionID = excludedConnectionID
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

/// Keeps the already-ordered production microbatch on its shared COW storage.
/// Compatibility callers may still supply reordered events, in which case the
/// existing deterministic sort is retained. This is intentionally internal:
/// durable room sequence, not arrival order, remains the public contract.
@inline(__always)
func v2GroupEventsOrderedByRoomSequence(
    _ events: [V2DirectRoomLiveEvent]
) -> [V2DirectRoomLiveEvent] {
    guard events.count > 1 else { return events }
    for index in 1..<events.count
    where events[index - 1].roomSequence > events[index].roomSequence {
        return events.sorted { $0.roomSequence < $1.roomSequence }
    }
    return events
}

/// Group equivalent of ``V2DirectRoomLiveEventDraft``. It deliberately
/// supports only the already-canonical plain Hybrid message shape. Richer
/// events keep the durable cursor path until their payload contracts can be
/// shared without changing semantics.
struct V2GroupRoomLiveEventDraft: Equatable, Sendable {
    let message: V2AcceptedMessage
    let sourceEventID: EventID
    let membershipRevision: UInt64
    let excludedConnectionID: UUID?

    init?(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID? = nil
    ) {
        guard message.usesRoomEventLog,
              message.groupDeliveryMode == .largeGroupHybrid,
              message.media.isEmpty,
              message.mentions.isEmpty,
              message.replyTo == nil,
              let sourceEventID = message.sourceEventID,
              let membershipRevision = message.acceptedMembershipRevision
        else { return nil }
        self.message = message
        self.sourceEventID = sourceEventID
        self.membershipRevision = membershipRevision
        // A group batch must have one byte-identical representation and one
        // audience for every socket. The sender may already have advanced its
        // local cursor from the acceptance ACK and will simply skip the
        // duplicate entry; per-event connection exclusion would destroy the
        // encode-once property.
        self.excludedConnectionID = nil
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
            recipientUserIDs: [],
            groupMembershipRevision: membershipRevision,
            acceptedMembershipRevision: membershipRevision,
            excludedConnectionID: excludedConnectionID
        )
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
    let excludedConnectionID: UUID?

    init?(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID? = nil
    ) {
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
        self.excludedConnectionID = excludingConnectionID
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
            recipientUserIDs: recipientUserIDs,
            acceptedMembershipRevision: message.acceptedMembershipRevision,
            excludedConnectionID: excludedConnectionID
        )
    }
}
