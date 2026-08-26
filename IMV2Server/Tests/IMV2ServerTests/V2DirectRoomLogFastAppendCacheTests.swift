import Foundation
import IMV2Core
import Testing
@testable import IMV2Server

@Suite("Direct room-log fast append cache")
struct V2DirectRoomLogFastAppendCacheTests {
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

    private func makeEntry(sequence: Int64) throws -> V2DirectRoomLogFastAppendCache.Entry {
        let recipientID = UUID()
        return try .init(
            policy: .init(
                recipientID: recipientID,
                directPairRevision: 1,
                senderPolicyRevision: 1,
                recipientPolicyRevision: 1,
                senderProfileVisibleToRecipient: true,
                senderCanSend: true,
                senderIsActive: true,
                recipientIsActive: true,
                blocked: false,
                isFriend: true,
                senderHasReplied: true,
                recipientHasReplied: true,
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
            expectedRoomSequence: sequence,
            expectedTimelineSequence: sequence,
            membershipRevision: 1,
            shardState: ShardAdmissionState(
                lease: ShardAdmissionLease(
                    id: try .init(UUID().uuidString),
                    generation: 1,
                    validUntil: Date().addingTimeInterval(60),
                    commandWindow: try .init(limit: 500_000),
                    fanoutWindow: try .init(limit: 100_000),
                    maxOutstandingFanoutUnits: 100_000,
                    maxOutstandingPlans: 100_000
                ),
                outstandingFanoutUnits: 0,
                outstandingPlans: 0
            )
        )
    }
}
