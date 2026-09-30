import IMV2ServerContracts
import Foundation
import IMV2Core

func roomWriteShardAdmissionReservation(
    from initial: ShardAdmissionState,
    to next: ShardAdmissionState,
    roomShardID: String? = nil,
    capacityProfileID: String? = nil
) throws -> ShardAdmissionReservation {
    guard let initialLease = initial.lease, let nextLease = next.lease,
          initialLease.id == nextLease.id,
          initialLease.generation == nextLease.generation
    else { throw V2RoomWriteStoreError.corruptPersistenceState }

    let commandDelta = nextLease.commandWindow.used - initialLease.commandWindow.used
    guard commandDelta >= 0
    else { throw V2RoomWriteStoreError.corruptPersistenceState }

    return try .init(
        leaseID: uuid(nextLease.id),
        generation: signed(nextLease.generation),
        commandDelta: commandDelta,
        roomShardID: roomShardID,
        capacityProfileID: capacityProfileID
    )
}

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



private func uuid<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}
