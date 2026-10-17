import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("V2 group-event availability acceleration")
struct V2GroupEventAvailabilityHintTests {
    @Test("different rooms retain independent pending notifications")
    func independentRoomInbox() throws {
        var inbox = V2RoomEventInbox(maximumRooms: 2)
        let a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID())
        try inbox.offer(.init(roomID: a, highWatermark: 1))
        try inbox.offer(.init(roomID: b, highWatermark: 3))
        try inbox.offer(.init(roomID: a, highWatermark: 2))
        #expect(inbox.next() == .init(roomID: a, highWatermark: 2))
        #expect(inbox.next() == .init(roomID: b, highWatermark: 3))
        #expect(inbox.next() == nil)
    }

    @Test("inbox overflow reports failure instead of silently losing another room")
    func inboxOverflow() throws {
        var inbox = V2RoomEventInbox(maximumRooms: 1)
        let a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID())
        try inbox.offer(.init(roomID: a, highWatermark: 1))
        #expect(throws: V2TLSFrameConnectionError.unexpectedResponse) {
            try inbox.offer(.init(roomID: b, highWatermark: 2))
        }
        #expect(inbox.next()?.roomID == a)
    }

    @Test("unpersistable optional event sequences degrade to a metadata wake", arguments: [false, true], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func liveSequenceBounds(direct: Bool, sequence: UInt64) {
        var hint = IMV2GroupEventAvailable()
        hint.highWatermark = sequence
        let value = event(sequence: sequence, idSuffix: 601)
        if direct {
            hint.sourceEventID = value.sourceEventID
            hint.roomSequence = sequence
            hint.projectionKind = value.projectionKind
            hint.eventPayload = value.payload
        } else { hint.liveEvents = [value] }
        let decoded = V2TLSFrameConnection.liveGroupEvents(from: hint)
        #expect(decoded.map(\.roomSequence) == (sequence > 0 && sequence <= UInt64(Int64.max) ? [sequence] : []))
    }

    @Test("an ordered protobuf live batch maps to domain events")
    func decodesOrderedLiveBatch() throws {
        var hint = IMV2GroupEventAvailable()
        hint.roomID = "00000000-0000-0000-0000-000000000601"
        hint.highWatermark = 12
        hint.liveEvents = [
            event(sequence: 10, idSuffix: 610),
            event(sequence: 11, idSuffix: 611),
            event(sequence: 12, idSuffix: 612),
        ]

        let decoded = V2TLSFrameConnection.liveGroupEvents(from: hint)

        #expect(decoded.map(\.roomSequence) == [10, 11, 12])
        #expect(decoded.map(\.projectionKind) == ["message", "message", "message"])
    }

    @Test("a malformed optional batch degrades to a metadata-only wake")
    func rejectsNoncontiguousLiveBatch() {
        var hint = IMV2GroupEventAvailable()
        hint.roomID = "00000000-0000-0000-0000-000000000602"
        hint.highWatermark = 13
        hint.liveEvents = [
            event(sequence: 10, idSuffix: 620),
            event(sequence: 13, idSuffix: 621),
        ]

        #expect(V2TLSFrameConnection.liveGroupEvents(from: hint).isEmpty)
    }

    @Test("pending frames retain one bounded contiguous live batch")
    func coalescesOverlappingContiguousFrames() throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000603")
        let older = V2GroupEventAvailabilityHint(
            roomID: roomID,
            highWatermark: 12,
            liveEvents: [
                try clientEvent(sequence: 10, idSuffix: 630),
                try clientEvent(sequence: 11, idSuffix: 631),
                try clientEvent(sequence: 12, idSuffix: 632),
            ]
        )
        let newer = V2GroupEventAvailabilityHint(
            roomID: roomID,
            highWatermark: 14,
            liveEvents: [
                try clientEvent(sequence: 12, idSuffix: 632),
                try clientEvent(sequence: 13, idSuffix: 633),
                try clientEvent(sequence: 14, idSuffix: 634),
            ]
        )

        let merged = older.coalescing(with: newer)

        #expect(merged.highWatermark == 14)
        #expect(merged.liveEvents.map(\.roomSequence) == [10, 11, 12, 13, 14])
    }

    @Test("a pending gap retains bounded bodies until its predecessor arrives")
    func coalescingGapRetainsBodies() throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000604")
        let older = V2GroupEventAvailabilityHint(
            roomID: roomID,
            highWatermark: 10,
            liveEvents: [try clientEvent(sequence: 10, idSuffix: 640)]
        )
        let newer = V2GroupEventAvailabilityHint(
            roomID: roomID,
            highWatermark: 12,
            liveEvents: [try clientEvent(sequence: 12, idSuffix: 642)]
        )

        let merged = older.coalescing(with: newer)

        #expect(merged.highWatermark == 12)
        #expect(merged.liveEvents.map(\.roomSequence) == [10, 12])
    }

    @Test("single and batch bodies may end before the committed head", arguments: [false, true])
    func prefixBelowHead(direct: Bool) {
        var hint = IMV2GroupEventAvailable()
        hint.highWatermark = 10
        let value = event(sequence: 8, idSuffix: 8)
        if direct {
            hint.roomSequence = value.roomSequence; hint.sourceEventID = value.sourceEventID
            hint.projectionKind = value.projectionKind; hint.eventPayload = value.payload
        } else { hint.liveEvents = [value] }
        #expect(V2TLSFrameConnection.liveGroupEvents(from: hint).map(\.roomSequence) == [8])
        hint.highWatermark = 7
        #expect(V2TLSFrameConnection.liveGroupEvents(from: hint).isEmpty)
    }

    @Test("same-H and lower-H bodies fill sparse prefixes without losing metadata")
    func sameHeadAndLatePredecessor() throws {
        let room = RoomID(uuid: UUID())
        let a = try clientEvent(sequence: 8, idSuffix: 8)
        let b = try clientEvent(sequence: 9, idSuffix: 9)
        let c = try clientEvent(sequence: 10, idSuffix: 10)
        let gap = V2GroupEventAvailabilityHint(roomID: room, highWatermark: 10, liveEvents: [a])
            .coalescing(with: .init(roomID: room, highWatermark: 10, liveEvents: [c]))
        let filled = gap.coalescing(with: .init(roomID: room, highWatermark: 9, liveEvents: [b]))
            .coalescing(with: .init(roomID: room, highWatermark: 12))
        #expect(filled.highWatermark == 12)
        #expect(filled.liveEvents == [a, b, c])
        #expect(filled.coalescing(with: filled) == filled)
        let conflict = try clientEvent(sequence: 9, idSuffix: 99)
        #expect(filled.coalescing(with: .init(roomID: room, highWatermark: 12, liveEvents: [conflict])).liveEvents.isEmpty)
    }

    @Test("coalescing remains bounded and retains H on overflow")
    func boundedBodies() throws {
        let room = RoomID(uuid: UUID())
        let limit = V2GroupEventLogLimits.maximumPageSize
        let events = try (1...limit).map { try clientEvent(sequence: UInt64($0), idSuffix: $0) }
        let merged = V2GroupEventAvailabilityHint(roomID: room, highWatermark: UInt64(limit), liveEvents: events)
            .coalescing(with: .init(roomID: room, highWatermark: UInt64(limit + 1),
                liveEvents: [try clientEvent(sequence: UInt64(limit + 1), idSuffix: limit + 1)]))
        #expect(merged.liveEvents.count == limit)
        #expect(merged.liveEvents.first?.roomSequence == 2)
        #expect(merged.highWatermark == UInt64(limit + 1))
    }

    @Test("byte overflow retains recovery H without unbounded payload retention")
    func byteBudget() throws {
        let room = RoomID(uuid: UUID())
        let body = Data(repeating: 1, count: 600_000)
        let events = try (1...2).map { try V2ClientGroupEvent(sourceEventID: .init(UUID().uuidString),
            roomSequence: UInt64($0), projectionKind: "message", payload: body) }
        let merged = V2GroupEventAvailabilityHint(roomID: room, highWatermark: 2, liveEvents: [events[0]])
            .coalescing(with: .init(roomID: room, highWatermark: 2, liveEvents: [events[1]]))
        #expect(merged.highWatermark == 2)
        #expect(merged.liveEvents == [events[1]])
    }

    private func event(sequence: UInt64, idSuffix: Int) -> IMV2GroupEvent {
        var value = IMV2GroupEvent()
        value.sourceEventID = String(format: "00000000-0000-0000-0000-%012d", idSuffix)
        value.roomSequence = sequence
        value.projectionKind = "message"
        value.payload = Data("payload-\(sequence)".utf8)
        return value
    }

    private func clientEvent(sequence: UInt64, idSuffix: Int) throws -> V2ClientGroupEvent {
        try .init(
            sourceEventID: try! EventID(
                String(format: "00000000-0000-0000-0000-%012d", idSuffix)
            ),
            roomSequence: sequence,
            projectionKind: "message",
            payload: Data("payload-\(sequence)".utf8)
        )
    }
}
