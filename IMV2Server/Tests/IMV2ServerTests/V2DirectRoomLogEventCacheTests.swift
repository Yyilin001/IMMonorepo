import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Direct room-log event cache")
struct V2DirectRoomLogEventCacheTests {
    @Test("returns only a fresh-fence contiguous direct-event page")
    func returnsContiguousAuthorizedPage() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8
        ))
        let first = try message(roomID: roomID, sequence: 1, membershipRevision: 4)
        let second = try message(roomID: roomID, sequence: 2, membershipRevision: 4)
        await cache.recordCommittedPlainDirectMessage(first)
        await cache.recordCommittedPlainDirectMessage(second)

        let page = try #require(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 2,
            afterRoomSequence: 0,
            pageSize: 100
        ))
        #expect(page.events.map(\.roomSequence) == [1, 2])
        #expect(page.events.map(\.sourceEventID) == [first.sourceEventID, second.sourceEventID])
        #expect(!page.hasMore)
        #expect((await cache.snapshot()).hits == 1)
    }

    @Test("never serves a stale membership epoch or an unknown sequence gap")
    func rejectsStaleMembershipAndGaps() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8
        ))
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: roomID, sequence: 1, membershipRevision: 4)
        )
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: roomID, sequence: 3, membershipRevision: 4)
        )

        let staleEpoch = await cache.page(
            roomID: roomID,
            actorJoinedRevision: 5,
            actorLeftRevision: nil,
            currentHighWatermark: 3,
            afterRoomSequence: 0,
            pageSize: 100
        )
        #expect(staleEpoch == nil)

        let unknownGap = await cache.page(
            roomID: roomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 3,
            afterRoomSequence: 0,
            pageSize: 100
        )
        #expect(unknownGap == nil)
        #expect((await cache.snapshot()).misses == 2)
    }

    @Test("bounds retained rooms and ignores rich or incomplete direct events")
    func boundsMemoryAndRejectsIneligibleEvents() async throws {
        let firstRoomID = try RoomID(UUID().uuidString)
        let secondRoomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 1,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 4
        ))
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: firstRoomID, sequence: 1, membershipRevision: 1)
        )
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: secondRoomID, sequence: 1, membershipRevision: 1)
        )
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: secondRoomID, sequence: 2, membershipRevision: 1, sourceEventID: nil)
        )

        let snapshot = await cache.snapshot()
        #expect(snapshot.cachedEvents == 1)
        #expect(snapshot.cachedRooms == 1)
        #expect(snapshot.bypassedIneligibleEvents == 1)
    }

    private func message(
        roomID: RoomID,
        sequence: UInt64,
        membershipRevision: UInt64,
        sourceEventID: EventID? = try? EventID(UUID().uuidString)
    ) throws -> V2AcceptedMessage {
        try .init(
            messageID: .init(UUID().uuidString),
            roomID: roomID,
            roomSequence: sequence,
            timelineSequence: sequence,
            senderUserID: .init(UUID().uuidString),
            clientMessageID: .init(UUID().uuidString),
            text: "cache-message-\(sequence)",
            mediaPresentations: [],
            usesRoomEventLog: true,
            sourceEventID: sourceEventID,
            acceptedMembershipRevision: membershipRevision,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
