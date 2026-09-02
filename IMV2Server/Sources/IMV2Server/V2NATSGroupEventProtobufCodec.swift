import Foundation
import IMV2Core
import SwiftProtobuf

/// Versioned process-to-process encoding for Core NATS group notifications.
/// The five-byte prefix prevents malformed JSON or a future wire version from
/// being interpreted as the current protobuf schema. PostgreSQL remains the
/// authority, so an invalid acceleration body degrades to its validated room
/// waterline while an invalid envelope is discarded.
enum V2NATSGroupEventProtobufCodec {
    private static let magic: [UInt8] = [0x49, 0x4D, 0x4E, 0x47] // "IMNG"
    private static let version: UInt8 = 1
    private static let header = Data(magic + [version])
    private static let maximumGroupEvents = 64

    static func recognizes(_ payload: Data) -> Bool {
        payload.count >= header.count
            && payload.prefix(header.count).elementsEqual(header)
    }

    static func encode(
        _ notification: V2ForegroundGroupEventNotification
    ) throws -> Data {
        var wire = IMV2InternalGroupEventNotification()
        switch notification {
        case .wake(let wake):
            wire.roomID = try identifierBytes(wake.roomID)
            wire.highWatermark = wake.highWatermark
            wire.wake = .init()
        case .directEvent(let event):
            wire.roomID = try identifierBytes(event.roomID)
            wire.highWatermark = event.highWatermark
            wire.directEvent = try directEvent(event)
        case .groupEvents(let events):
            guard let first = events.first,
                  let last = events.last,
                  events.count <= maximumGroupEvents,
                  let membershipRevision = first.groupMembershipRevision,
                  membershipRevision > 0,
                  first.recipientUserIDs.isEmpty,
                  first.excludedConnectionID == nil,
                  events.allSatisfy({ event in
                      event.roomID == first.roomID
                          && event.groupMembershipRevision == membershipRevision
                          && event.recipientUserIDs.isEmpty
                          && event.excludedConnectionID == nil
                  })
            else { throw V2NATSGroupEventWakeBrokerError.invalidPayload }
            var batch = IMV2InternalGroupEventBatch()
            batch.membershipRevision = membershipRevision
            batch.events = try events.map { event in
                var value = IMV2InternalGroupEvent()
                value.sourceEventID = try identifierBytes(event.sourceEventID)
                value.roomSequence = event.roomSequence
                value.projectionKind = event.projectionKind
                value.payload = event.payload
                return value
            }
            wire.roomID = try identifierBytes(first.roomID)
            wire.highWatermark = last.highWatermark
            wire.groupEvents = batch
        }
        var result = header
        result.append(try wire.serializedData())
        return result
    }

    static func decode(
        _ payload: Data
    ) -> V2ForegroundGroupEventNotification? {
        guard recognizes(payload), payload.count > header.count,
              let wire = try? IMV2InternalGroupEventNotification(
                  serializedBytes: payload.dropFirst(header.count)
              ),
              let roomUUID = uuid(wire.roomID),
              wire.highWatermark > 0
        else { return nil }
        let roomID = RoomID(uuid: roomUUID)
        let wake = V2ForegroundGroupEventNotification.wake(.init(
            roomID: roomID,
            highWatermark: wire.highWatermark
        ))
        switch wire.body {
        case .wake, nil:
            return wake
        case .directEvent(let direct):
            guard direct.roomSequence == wire.highWatermark,
                  direct.roomSequence > 0,
                  !direct.projectionKind.isEmpty,
                  !direct.payload.isEmpty,
                  let sourceEventUUID = uuid(direct.sourceEventID)
            else { return wake }
            let recipientValues = direct.recipientUserIds.compactMap(uuid)
            let recipients = Set(recipientValues.map(UserID.init(uuid:)))
            let isExactAudience = !recipients.isEmpty
                && recipientValues.count == direct.recipientUserIds.count
                && recipients.count == direct.recipientUserIds.count
                && !direct.hasGroupMembershipRevision
            let isGroupAudience = direct.recipientUserIds.isEmpty
                && direct.hasGroupMembershipRevision
                && direct.groupMembershipRevision > 0
                && !direct.hasExcludedConnectionID
            guard isExactAudience || isGroupAudience else { return wake }
            let excludedConnectionID: UUID?
            if direct.hasExcludedConnectionID {
                guard let excluded = uuid(direct.excludedConnectionID) else {
                    return wake
                }
                excludedConnectionID = excluded
            } else {
                excludedConnectionID = nil
            }
            let revision = direct.hasGroupMembershipRevision
                ? direct.groupMembershipRevision
                : nil
            return .directEvent(.init(
                roomID: roomID,
                highWatermark: wire.highWatermark,
                sourceEventID: EventID(uuid: sourceEventUUID),
                roomSequence: direct.roomSequence,
                projectionKind: direct.projectionKind,
                payload: direct.payload,
                recipientUserIDs: recipients,
                groupMembershipRevision: revision,
                acceptedMembershipRevision: revision,
                excludedConnectionID: excludedConnectionID
            ))
        case .groupEvents(let batch):
            guard !batch.events.isEmpty,
                  batch.events.count <= maximumGroupEvents,
                  batch.membershipRevision > 0
            else { return wake }
            var previousSequence: UInt64 = 0
            var events: [V2DirectRoomLiveEvent] = []
            events.reserveCapacity(batch.events.count)
            for event in batch.events {
                guard event.roomSequence > previousSequence,
                      !event.projectionKind.isEmpty,
                      !event.payload.isEmpty,
                      let sourceEventUUID = uuid(event.sourceEventID)
                else { return wake }
                previousSequence = event.roomSequence
                events.append(.init(
                    roomID: roomID,
                    highWatermark: event.roomSequence,
                    sourceEventID: EventID(uuid: sourceEventUUID),
                    roomSequence: event.roomSequence,
                    projectionKind: event.projectionKind,
                    payload: event.payload,
                    recipientUserIDs: [],
                    groupMembershipRevision: batch.membershipRevision,
                    acceptedMembershipRevision: batch.membershipRevision,
                    excludedConnectionID: nil
                ))
            }
            guard previousSequence == wire.highWatermark else { return wake }
            return .groupEvents(events)
        }
    }

    private static func directEvent(
        _ event: V2DirectRoomLiveEvent
    ) throws -> IMV2InternalDirectEvent {
        var wire = IMV2InternalDirectEvent()
        wire.sourceEventID = try identifierBytes(event.sourceEventID)
        wire.roomSequence = event.roomSequence
        wire.projectionKind = event.projectionKind
        wire.payload = event.payload
        wire.recipientUserIds = try event.recipientUserIDs
            .sorted()
            .map(identifierBytes)
        if let revision = event.groupMembershipRevision {
            wire.groupMembershipRevision = revision
        }
        if let excludedConnectionID = event.excludedConnectionID {
            wire.excludedConnectionID = uuidBytes(excludedConnectionID)
        }
        return wire
    }

    private static func identifierBytes<Tag>(
        _ identifier: V2Identifier<Tag>
    ) throws -> Data {
        guard let value = identifier.uuidValue else {
            throw V2NATSGroupEventWakeBrokerError.invalidPayload
        }
        return uuidBytes(value)
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        var bytes = value.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    private static func uuid(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        return data.withUnsafeBytes { bytes in
            let value = bytes.bindMemory(to: UInt8.self)
            return UUID(uuid: (
                value[0], value[1], value[2], value[3],
                value[4], value[5], value[6], value[7],
                value[8], value[9], value[10], value[11],
                value[12], value[13], value[14], value[15]
            ))
        }
    }
}
