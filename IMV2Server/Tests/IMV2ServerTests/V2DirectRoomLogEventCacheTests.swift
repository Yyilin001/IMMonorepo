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

    @Test("returns a safe short page when the durable watermark advances after capture")
    func returnsShortPageAcrossWatermarkRace() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8
        ))
        await cache.recordCommittedPlainDirectMessage(
            try message(roomID: roomID, sequence: 1, membershipRevision: 4)
        )

        let page = try #require(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 2,
            afterRoomSequence: 0,
            pageSize: 100
        ))
        #expect(page.events.map(\.roomSequence) == [1])
        #expect(page.nextRoomSequence == 1)
        #expect(page.hasMore)
        #expect((await cache.snapshot()).hits == 1)
    }

    @Test("hybrid-group messages share one cached payload behind the membership fence")
    func cachesHybridGroupMessage() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8
        ))
        let accepted = try message(
            roomID: roomID,
            sequence: 1,
            membershipRevision: 7,
            groupDeliveryMode: .largeGroupHybrid
        )
        await cache.recordCommittedPlainDirectMessage(accepted)

        #expect(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 8,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1
        ) == nil)
        let page = try #require(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 7,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1
        ))
        #expect(page.events.map(\.roomSequence) == [1])
        #expect(page.events.first?.sourceEventID == accepted.sourceEventID)
    }

    @Test("authorized prepared pages reuse encoded bytes before event-array materialization")
    func reusesPreparedPageBehindFreshMembershipFence() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1
        ))
        for sequence in 1 ... 2 {
            await cache.recordCommittedPlainDirectMessage(try message(
                roomID: roomID,
                sequence: UInt64(sequence),
                membershipRevision: 7,
                groupDeliveryMode: .largeGroupHybrid
            ))
        }
        let preparedCache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 1
        ))

        func pull(requestID: UInt64) async throws -> V2Frame {
            let result = try await cache.preparedPage(
                roomID: roomID,
                actorJoinedRevision: 7,
                actorLeftRevision: nil,
                currentHighWatermark: 2,
                afterRoomSequence: 0,
                pageSize: 100,
                context: preparedContext(requestID: requestID, cache: preparedCache)
            )
            guard case .prepared(let response) = result else {
                Issue.record("expected a prepared page")
                throw V2GroupEventLogError.corruptPersistenceState
            }
            return response.frame
        }

        let first = try await pull(requestID: 101)
        let second = try await pull(requestID: 202)
        let decoded = try V2ServerProtobufFrameCodec.decode(second)

        #expect(first.payload == second.payload)
        #expect(decoded.requestID == 202)
        #expect(decoded.groupEventPage.events.map(\.roomSequence) == [1, 2])
        #expect(preparedCache.snapshot().misses == 1)
        #expect(preparedCache.snapshot().hits == 1)
        #expect((await cache.snapshot()).hits == 2)
    }

    @Test("prepared pages never cross join or leave membership revisions")
    func preparedPagePreservesMembershipEpoch() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1
        ))
        await cache.recordCommittedPlainDirectMessage(try message(
            roomID: roomID,
            sequence: 1,
            membershipRevision: 7,
            groupDeliveryMode: .largeGroupHybrid
        ))
        let preparedCache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 1
        ))

        let joinedAfterEvent = try await cache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: 8,
            actorLeftRevision: nil,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1,
            context: preparedContext(requestID: 1, cache: preparedCache)
        )
        let leftAtEvent = try await cache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: 1,
            actorLeftRevision: 7,
            currentHighWatermark: 1,
            afterRoomSequence: 0,
            pageSize: 1,
            context: preparedContext(requestID: 2, cache: preparedCache)
        )

        guard case .miss = joinedAfterEvent else {
            Issue.record("a post-event join must miss")
            return
        }
        guard case .miss = leftAtEvent else {
            Issue.record("an event at or after leave revision must miss")
            return
        }
        #expect(preparedCache.snapshot().entries == 0)
    }

    @Test("prepared page budgeting keeps cursors resumable and reports oversized first events")
    func preparedPagePreservesPayloadBudget() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1
        ))
        for sequence in 1 ... 2 {
            await cache.recordCommittedPlainDirectMessage(try message(
                roomID: roomID,
                sequence: UInt64(sequence),
                membershipRevision: 1,
                groupDeliveryMode: .largeGroupHybrid
            ))
        }
        let preparedCache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 1
        ))

        let tooSmall = try await cache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 2,
            afterRoomSequence: 0,
            pageSize: 2,
            context: preparedContext(
                requestID: 1,
                cache: preparedCache,
                maximumGroupEventPagePayloadBytes: 64
            )
        )
        guard case .eventTooLarge = tooSmall else {
            Issue.record("the first event must not be silently skipped")
            return
        }

        let oneEventBudget = try await cache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 2,
            afterRoomSequence: 0,
            pageSize: 1,
            context: preparedContext(requestID: 2, cache: preparedCache)
        )
        guard case .prepared(let response) = oneEventBudget else {
            Issue.record("expected a bounded prepared page")
            return
        }
        let decoded = try V2ServerProtobufFrameCodec.decode(response.frame)
        #expect(decoded.groupEventPage.events.map(\.roomSequence) == [1])
        #expect(decoded.groupEventPage.nextRoomSequence == 1)
        #expect(decoded.groupEventPage.hasMore_p)
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

    @Test("a saturated hot room advances its retained window without losing continuity")
    func advancesSaturatedRoomWindow() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 1_024,
            maximumBytes: 16 * 1_024 * 1_024,
            maximumEventsPerRoom: 1_024,
            shardCount: 1
        ))
        for sequence in 1...4_096 {
            await cache.recordCommittedPlainDirectMessage(try message(
                roomID: roomID,
                sequence: UInt64(sequence),
                membershipRevision: 1,
                groupDeliveryMode: .largeGroupHybrid
            ))
        }

        let snapshot = await cache.snapshot()
        #expect(snapshot.cachedEvents == 1_024)
        #expect(snapshot.cachedRooms == 1)
        let page = try #require(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 1,
            actorLeftRevision: nil,
            currentHighWatermark: 4_096,
            afterRoomSequence: 3_072,
            pageSize: 500
        ))
        #expect(page.events.first?.roomSequence == 3_073)
        #expect(page.events.last?.roomSequence == 3_572)
        #expect(page.events.count == 500)
        #expect(page.hasMore)

        // A delayed duplicate outside the retained window is irrelevant to
        // future cursors and must not disturb the contiguous hot tail.
        await cache.recordCommittedPlainDirectMessage(try message(
            roomID: roomID,
            sequence: 1,
            membershipRevision: 1,
            groupDeliveryMode: .largeGroupHybrid
        ))
        #expect((await cache.snapshot()).cachedEvents == 1_024)
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

    @Test("a foreground candidate materializes committed mailbox writes before missing")
    func candidateMaterializesCommittedMailboxWrites() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1,
            maximumPendingWrites: 8
        ))
        cache.enqueueCommittedPlainDirectMessage(try message(
            roomID: roomID,
            sequence: 1,
            membershipRevision: 1,
            groupDeliveryMode: .largeGroupHybrid
        ))
        #expect((await cache.snapshot()).pendingWrites == 1)

        let candidate = try #require(await cache.candidate(
            roomID: roomID,
            afterRoomSequence: 0,
            pageSize: 1
        ))
        #expect(candidate.events.map(\.entry.roomSequence) == [1])
        let snapshot = await cache.snapshot()
        #expect(snapshot.pendingWrites == 0)
        #expect(snapshot.cachedEvents == 1)
        #expect(snapshot.misses == 0)
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

    @Test("a relayed group batch seeds recovery without becoming an authorization source")
    func relayedGroupBatchSeedsAuthorizedRecovery() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1,
            maximumPendingWrites: 8
        ))
        let service = V2GroupEventLogService(
            store: RejectingGroupEventLogStore(),
            directRoomLogEventCache: cache
        )
        let events = try (1 ... 2).map { sequence in
            try #require(V2GroupRoomLiveEventDraft(message(
                roomID: roomID,
                sequence: UInt64(sequence),
                membershipRevision: 7,
                groupDeliveryMode: .largeGroupHybrid
            ))?.materialized())
        }

        service.recordRelayedForegroundEvents(events)
        // The publishing Gateway receives its own Core NATS message too.
        // Replaying the exact batch must remain an idempotent cache operation.
        service.recordRelayedForegroundEvents(events)

        #expect(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 8,
            actorLeftRevision: nil,
            currentHighWatermark: 2,
            afterRoomSequence: 0,
            pageSize: 2
        ) == nil)
        let authorized = try #require(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 7,
            actorLeftRevision: nil,
            currentHighWatermark: 2,
            afterRoomSequence: 0,
            pageSize: 2
        ))
        #expect(authorized.events.map(\.roomSequence) == [1, 2])
        #expect(authorized.events.map(\.sourceEventID) == events.map(\.sourceEventID))
        let snapshot = await cache.snapshot()
        #expect(snapshot.cachedEvents == 2)
        #expect(snapshot.cachedRooms == 1)
    }

    @Test("a relayed group batch preserves bounded mailbox accounting")
    func relayedGroupBatchPreservesMailboxBounds() async throws {
        let roomID = try RoomID(UUID().uuidString)
        let cache = V2DirectRoomLogEventCache(configuration: .init(
            maximumEvents: 8,
            maximumBytes: 1_048_576,
            maximumEventsPerRoom: 8,
            shardCount: 1,
            maximumPendingWrites: 2
        ))
        let service = V2GroupEventLogService(
            store: RejectingGroupEventLogStore(),
            directRoomLogEventCache: cache
        )
        let events = try (1 ... 3).map { sequence in
            try #require(V2GroupRoomLiveEventDraft(message(
                roomID: roomID,
                sequence: UInt64(sequence),
                membershipRevision: 7,
                groupDeliveryMode: .largeGroupHybrid
            ))?.materialized())
        }

        service.recordRelayedForegroundEvents(events)
        var snapshot = await cache.snapshot()
        #expect(snapshot.pendingWrites == 2)
        #expect(snapshot.droppedWrites == 1)

        let page = try #require(await cache.page(
            roomID: roomID,
            actorJoinedRevision: 7,
            actorLeftRevision: nil,
            currentHighWatermark: 2,
            afterRoomSequence: 0,
            pageSize: 2
        ))
        #expect(page.events.map(\.roomSequence) == [1, 2])
        snapshot = await cache.snapshot()
        #expect(snapshot.pendingWrites == 0)
        #expect(snapshot.cachedEvents == 2)
        #expect(snapshot.droppedWrites == 1)
    }

    private func message(
        roomID: RoomID,
        sequence: UInt64,
        membershipRevision: UInt64,
        sourceEventID: EventID? = try? EventID(UUID().uuidString),
        groupDeliveryMode: V2GroupDeliveryMode? = nil
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
            groupDeliveryMode: groupDeliveryMode,
            usesRoomEventLog: true,
            sourceEventID: sourceEventID,
            acceptedMembershipRevision: membershipRevision,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func preparedContext(
        requestID: UInt64,
        cache: V2PreparedGroupEventPageCache,
        maximumGroupEventPagePayloadBytes: Int = 48 * 1_024
    ) -> V2PreparedGroupEventPageEncodingContext {
        .init(
            requestID: requestID,
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024,
            maximumExpansionRatio: 64,
            maximumGroupEventPagePayloadBytes: maximumGroupEventPagePayloadBytes,
            cache: cache
        )
    }
}

private struct RejectingGroupEventLogStore: V2GroupEventLogStore {
    func pull(
        roomID _: RoomID,
        actorUserID _: UserID,
        afterRoomSequence _: UInt64,
        pageSize _: Int
    ) async throws -> V2GroupEventLogPage {
        throw V2GroupEventLogError.corruptPersistenceState
    }

    func subscribe(
        roomID _: RoomID,
        actorUserID _: UserID
    ) async throws -> V2GroupEventSubscription {
        throw V2GroupEventLogError.corruptPersistenceState
    }
}
