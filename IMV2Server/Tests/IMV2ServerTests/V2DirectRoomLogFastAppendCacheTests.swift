@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite("Direct room-log fast append cache")
struct V2DirectRoomLogFastAppendCacheTests {
    @Test("Append counters preserve ordinary totals and saturate without disturbing cached policies", arguments: ["attempt", "committed", "fallback"])
    func counterIntegerBoundaries(kind: String) async throws {
        let cache = V2DirectRoomLogFastAppendCache(capacity: 1)
        let key = V2DirectRoomLogFastAppendCache.Key(roomID: UUID(), senderID: UUID())
        let entry = try makeEntry(sequence: 1)
        await cache.insert(entry, for: key)
        @Sendable func record(_ count: Int) async {
            switch kind {
            case "attempt": await cache.recordAttempt(count: count)
            case "committed": await cache.recordCommitted(count: count)
            default: await cache.recordFallback(count: count)
            }
        }
        func verify(_ expected: Int64) async {
            let snapshot = await cache.snapshot()
            #expect(snapshot.attemptedAppends == (kind == "attempt" ? expected : 0))
            #expect(snapshot.committedAppends == (kind == "committed" ? expected : 0))
            #expect(snapshot.fallbackAppends == (kind == "fallback" ? expected : 0))
            #expect(snapshot.entries == 1)
        }
        for count in [Int.min, -1, 0] { await record(count) }
        await verify(0)
        await record(1)
        await record(2)
        await verify(3)
        await record(Int.max - 3)
        await verify(.max)
        await record(1)
        await verify(.max)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await record(Int.max) } }
        }
        await verify(.max)
        #expect(await cache.value(for: key) == entry)
        let replacement = try makeEntry(sequence: 2, directPairRevision: 2)
        await cache.insert(replacement, for: key)
        #expect(await cache.value(for: key) == replacement)
        await cache.invalidate(key)
        #expect(await cache.value(for: key) == nil)
        let final = await cache.snapshot()
        #expect(final.entries == 0)
        #expect(final.lookupHits == 2)
        #expect(final.lookupMisses == 1)
    }

    @Test("capacity evicts the least recently used entry in constant time")
    func evictsLeastRecentlyUsedEntry() async throws {
        let cache = V2DirectRoomLogFastAppendCache(capacity: 2)
        let first = V2DirectRoomLogFastAppendCache.Key(roomID: UUID(), senderID: UUID())
        let second = V2DirectRoomLogFastAppendCache.Key(roomID: UUID(), senderID: UUID())
        let third = V2DirectRoomLogFastAppendCache.Key(roomID: UUID(), senderID: UUID())
        let firstEntry = try makeEntry(sequence: 1)
        let secondEntry = try makeEntry(sequence: 2)
        let thirdEntry = try makeEntry(sequence: 3)

        await cache.insert(firstEntry, for: first)
        await cache.insert(secondEntry, for: second)
        #expect(await cache.value(for: first) == firstEntry)
        await cache.insert(thirdEntry, for: third)

        #expect(await cache.value(for: first) == firstEntry)
        #expect(await cache.value(for: second) == nil)
        #expect(await cache.value(for: third) == thirdEntry)
        let snapshot = await cache.snapshot()
        #expect(snapshot.entries == 2)
        #expect(snapshot.insertions == 3)
        #expect(snapshot.evictions == 1)
        #expect(snapshot.lookupHits == 3)
        #expect(snapshot.lookupMisses == 1)
    }

    @Test("batch lookup preserves input order and room invalidation uses the room index")
    func batchLookupAndRoomInvalidation() async throws {
        let cache = V2DirectRoomLogFastAppendCache(capacity: 4)
        let roomID = UUID()
        let first = V2DirectRoomLogFastAppendCache.Key(roomID: roomID, senderID: UUID())
        let second = V2DirectRoomLogFastAppendCache.Key(roomID: roomID, senderID: UUID())
        let missing = V2DirectRoomLogFastAppendCache.Key(roomID: UUID(), senderID: UUID())
        let firstEntry = try makeEntry(sequence: 11)
        let secondEntry = try makeEntry(sequence: 12)

        await cache.insert(firstEntry, for: first)
        await cache.insert(secondEntry, for: second)
        let values = await cache.valuesIfAllPresent(for: [second, first])
        #expect(values == [secondEntry, firstEntry])
        #expect(await cache.valuesIfAllPresent(for: [second, missing, first]) == nil)
        // The lookup stops at the first miss; it must not churn recency or
        // metrics for the unused suffix of a batch that will fall back.
        let lookupSnapshot = await cache.snapshot()
        #expect(lookupSnapshot.lookupHits == 3)
        #expect(lookupSnapshot.lookupMisses == 1)

        await cache.invalidate(roomID: roomID)
        #expect(await cache.value(for: first) == nil)
        #expect(await cache.value(for: second) == nil)
        #expect(await cache.snapshot().entries == 0)
    }

    @Test("reciprocal reply promotion preserves the cached room and shard snapshot", arguments: [Int64(7), Int64.max - 1])
    func reciprocalReplyPromotionIsRevisionFenced(revision: Int64) async throws {
        let cache = V2DirectRoomLogFastAppendCache(capacity: 2)
        let key = V2DirectRoomLogFastAppendCache.Key(roomID: UUID(), senderID: UUID())
        let entry = try makeEntry(
            sequence: 21,
            directPairRevision: revision,
            recipientHasReplied: false
        )
        await cache.insert(entry, for: key)

        await cache.markRecipientsHaveReplied([.init(
            key: key,
            expectedDirectPairRevision: revision
        )])
        let promoted = try #require(await cache.value(for: key))
        #expect(promoted.policy.recipientHasReplied)
        #expect(promoted.policy.directPairRevision == revision + 1)
        #expect(promoted.roomShardID == entry.roomShardID)
        #expect(promoted.membershipRevision == entry.membershipRevision)

        await cache.markRecipientsHaveReplied([.init(
            key: key,
            expectedDirectPairRevision: revision
        )])
        #expect(await cache.value(for: key)?.policy.directPairRevision == revision + 1)
        await cache.markRecipientsHaveReplied([.init(key: key, expectedDirectPairRevision: revision + 1)])
        #expect(await cache.value(for: key) == promoted)
    }

    private func makeEntry(
        sequence: Int64,
        directPairRevision: Int64 = 1,
        recipientHasReplied: Bool = true
    ) throws -> V2DirectRoomLogFastAppendCache.Entry {
        let recipientID = UUID()
        return try .init(
            policy: .init(
                recipientID: recipientID,
                directPairRevision: directPairRevision,
                senderPolicyRevision: 1,
                recipientPolicyRevision: 1,
                senderProfileVisibleToRecipient: true,
                senderCanSend: true,
                senderIsActive: true,
                recipientIsActive: true,
                blocked: false,
                isFriend: true,
                senderHasReplied: true,
                recipientHasReplied: recipientHasReplied,
                allowsStrangers: true,
                senderAccountKind: nil,
                senderAccountStatus: nil,
                senderAllowsServiceMessages: nil,
                recipientAccountKind: nil,
                recipientAccountStatus: nil,
                recipientAllowsCustomerMessages: nil
            ),
            roomShardID: "rooms-load-00",
            capacityProfileID: "loadtest-v17",
            membershipRevision: 1,
            shardState: ShardAdmissionState(
                lease: ShardAdmissionLease(
                    id: try .init(UUID().uuidString),
                    generation: 1,
                    validUntil: Date().addingTimeInterval(60),
                    commandWindow: try .init(limit: 500_000)))
        )
    }
}
