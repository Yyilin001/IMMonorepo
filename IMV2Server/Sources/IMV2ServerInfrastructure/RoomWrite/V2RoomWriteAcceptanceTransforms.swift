import IMV2Core

func roomWriteWithTimelineSequence(_ writeSet: V2MessageAcceptanceTransaction, timelineSequence: UInt64) throws -> V2MessageAcceptanceTransaction {
    let revisedMessage = try roomWriteWithTimelineSequence(writeSet.acceptedMessage, timelineSequence: timelineSequence)
    return .init(acceptedMessage: revisedMessage, eventID: writeSet.eventID, nextRoomState: writeSet.nextRoomState, nextShardState: writeSet.nextShardState)
}

func roomWriteWithTimelineSequence(
    _ message: V2AcceptedMessageDraft,
    timelineSequence: UInt64
) throws -> V2AcceptedMessageDraft {
    .init(
        messageID: message.messageID,
        roomID: message.roomID,
        roomSequence: message.roomSequence,
        timelineSequence: timelineSequence,
        senderUserID: message.senderUserID,
        clientMessageID: message.clientMessageID,
        text: message.text,
        media: message.media,
        mentions: message.mentions,
        entities: message.entities,
        replyTo: message.replyTo,
        groupCapacityClass: message.groupCapacityClass,
        createdAt: message.createdAt
    )
}
