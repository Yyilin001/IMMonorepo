import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("V2 group-event availability acceleration")
struct V2GroupEventAvailabilityHintTests {
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

    @Test("a pending gap keeps only the durable recovery waterline")
    func coalescingGapDegradesToMetadata() throws {
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
        #expect(merged.liveEvents.isEmpty)
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
