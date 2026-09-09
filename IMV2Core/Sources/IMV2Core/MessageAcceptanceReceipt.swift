import Foundation

/// Immutable proof that a send committed. It deliberately cannot carry text,
/// entities/URLs or attachment contents and is safe to replay after erasure.
/// Content is obtained only through the normal authorized projection/read path.
public struct V2MessageAcceptanceReceipt: Equatable, Sendable {
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let timelineSequence: UInt64
    public let senderUserID: UserID
    public let clientMessageID: ClientMessageID
    public let groupDeliveryMode: V2GroupDeliveryMode?
    public let usesRoomEventLog: Bool
    public let sourceEventID: EventID?
    public let acceptedMembershipRevision: UInt64?
    public let directRecipientUserID: UserID?
    public let createdAt: Date

    public init(
        messageID: MessageID, roomID: RoomID, roomSequence: UInt64,
        timelineSequence: UInt64, senderUserID: UserID, clientMessageID: ClientMessageID,
        groupDeliveryMode: V2GroupDeliveryMode?, usesRoomEventLog: Bool,
        sourceEventID: EventID?, acceptedMembershipRevision: UInt64?,
        directRecipientUserID: UserID?, createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.groupDeliveryMode = groupDeliveryMode
        self.usesRoomEventLog = usesRoomEventLog
        self.sourceEventID = sourceEventID
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.directRecipientUserID = directRecipientUserID
        self.createdAt = createdAt
    }
}

public extension V2AcceptedMessage {
    var receipt: V2MessageAcceptanceReceipt {
        .init(
            messageID: messageID, roomID: roomID, roomSequence: roomSequence,
            timelineSequence: timelineSequence, senderUserID: senderUserID,
            clientMessageID: clientMessageID, groupDeliveryMode: groupDeliveryMode,
            usesRoomEventLog: usesRoomEventLog, sourceEventID: sourceEventID,
            acceptedMembershipRevision: acceptedMembershipRevision,
            directRecipientUserID: directRecipientUserID, createdAt: createdAt
        )
    }
}
