import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Direct room-log event cache")
struct V2DirectRoomLogEventCacheTests {
    @Test("plain payload fast encoder preserves the canonical JSON contract")
    func plainPayloadFastEncoderPreservesJSONContract() throws {
        let message = V2AcceptedMessage(
            messageID: try .init("00000000-0000-0000-0000-000000000101"),
            roomID: try .init("00000000-0000-0000-0000-000000000102"),
            roomSequence: 17,
            timelineSequence: 23,
            senderUserID: try .init("00000000-0000-0000-0000-000000000103"),
            clientMessageID: try .init("00000000-0000-0000-0000-000000000104"),
            text: "quote \" slash \\ controls \u{8}\u{c}\n\r\t\u{1f} 中文🙂",
            mediaPresentations: [],
            usesRoomEventLog: true,
            sourceEventID: try .init("00000000-0000-0000-0000-000000000105"),
            acceptedMembershipRevision: 9,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )

        let encoded = try #require(V2DirectRoomLogPayloadCodec.encode(message))
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(object["event_type"] as? String == "message.accepted")
        #expect(object["message_id"] as? String == message.messageID.rawValue)
        #expect(object["room_id"] as? String == message.roomID.rawValue)
        #expect((object["room_sequence"] as? NSNumber)?.uint64Value == 17)
        #expect((object["timeline_sequence"] as? NSNumber)?.uint64Value == 23)
        #expect(object["sender_user_id"] as? String == message.senderUserID.rawValue)
        #expect(object["text"] as? String == message.text)
        #expect((object["server_created_at_ms"] as? NSNumber)?.int64Value == 1_700_000_000_125)
        #expect((object["entities"] as? [Any])?.isEmpty == true)
        #expect((object["media_ids"] as? [Any])?.isEmpty == true)
        #expect((object["media_presentations"] as? [Any])?.isEmpty == true)
        #expect((object["mention_user_ids"] as? [Any])?.isEmpty == true)
        #expect(object["mentions_everyone"] as? Bool == false)
        #expect(object["message_revision"] as? Int == 1)
        #expect(object["reply_to_message_id"] is NSNull)
        #expect(object["forwarded_from_message_id"] is NSNull)
        #expect(object["forwarded_from_user_id"] is NSNull)
    }

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

    @Test("room LRU refresh is O(1)-compatible and evicts the cold room")
    func evictsLeastRecentlyUsedRoom() async throws {
        let firstRoomID = try RoomID(UUID().uuidString)
        let secondRoomID = try RoomID(UUID().uuidString)
        let thirdRoomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 2,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 1,
            shardCount: 1
        ))
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: firstRoomID, sequence: 1, membershipRevision: 1)
        )
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: secondRoomID, sequence: 1, membershipRevision: 1)
        )
        #expect(await cache.page(
            roomID: firstRoomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1
        ) != nil)

        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: thirdRoomID, sequence: 1, membershipRevision: 1)
        )

        #expect(await cache.page(
            roomID: firstRoomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1
        ) != nil)
        #expect(await cache.page(
            roomID: secondRoomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1
        ) == nil)
        let snapshot = await cache.snapshot()
        #expect(snapshot.cachedEvents == 2)
        #expect(snapshot.cachedRooms == 2)
    }

    @Test("aggregate shard budgets remain exact under room churn")
    func preservesAggregateShardBudgets() async throws {
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 8_192,
            maximumEventsPerRoom: 2,
            shardCount: 4
        ))
        for _ in 0..<64 {
            let roomID = try RoomID(UUID().uuidString)
            await cache.recordCommittedPlainDirectMessage(
                try message(roomID: roomID, sequence: 1, membershipRevision: 1)
            )
        }
        let snapshot = await cache.snapshot()
        #expect(snapshot.cachedEvents <= 8)
        #expect(snapshot.cachedBytes <= 8_192)
        #expect(snapshot.cachedRooms <= snapshot.cachedEvents)
    }

    @Test("a definite coverage miss is observable before durable authorization")
    func identifiesDefiniteCoverageMiss() async throws {
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8
        ))
        let missingRoom = try RoomID(UUID().uuidString)

        #expect(await cache.candidate(
            roomID: missingRoom,
            afterRoomSequence: 0,
            pageSize: 100
        ) == nil)
        #expect((await cache.snapshot()).misses == 1)
    }

    @Test("post-commit writes are bounded and materialized by the owned runner")
    func drainsBoundedPostCommitMailbox() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1,
            maximumPendingWrites: 1
        ))
        cache.enqueueCommittedPlainDirectMessage(
            try message(roomID: roomID, sequence: 1, membershipRevision: 1)
        )
        cache.enqueueCommittedPlainDirectMessage(
            try message(roomID: roomID, sequence: 2, membershipRevision: 1)
        )
        var snapshot = await cache.snapshot()
        #expect(snapshot.cachedEvents == 0)
        #expect(snapshot.pendingWrites == 1)
        #expect(snapshot.droppedWrites == 1)

        let runner = Task { await cache.run() }
        for _ in 0..<20 {
            snapshot = await cache.snapshot()
            if snapshot.pendingWrites == 0 && snapshot.cachedEvents == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        snapshot = await cache.snapshot()
        #expect(snapshot.pendingWrites == 0)
        #expect(snapshot.cachedEvents == 1)
        #expect(snapshot.droppedWrites == 1)
        await cache.finish()
        await runner.value
    }

    @Test("one prepared direct payload retains its durable membership fence")
    func recordsPreparedDirectPayloadWithoutReencoding() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let payload = Data("already-encoded-payload".utf8)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1,
            maximumPendingWrites: 1
        ))
        let event = V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 1,
            sourceEventID: try .init(UUID().uuidString),
            roomSequence: 1,
            projectionKind: "message",
            payload: payload,
            recipientUserIDs: [try .init(UUID().uuidString)],
            acceptedMembershipRevision: 7
        )
        cache.enqueueCommittedPlainDirectEvent(event)
        let runner = Task { await cache.run() }
        for _ in 0..<20 where (await cache.snapshot()).cachedEvents == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 8,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1
        ) == nil)
        let authorized = try #require(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 7,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1
        ))
        #expect(authorized.events.first?.payload == payload)
        await cache.finish()
        await runner.value
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
