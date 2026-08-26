import Foundation
import Testing
@testable import IMV2Server

@Suite("Direct send policy cache")
struct V2DirectSendPolicyCacheTests {
    @Test("entries are keyed by room and sender and invalidate at room scope")
    func invalidatesAllSendersForRoom() async throws {
        let cache = V2DirectSendPolicyCache(capacity: 2)
        let roomID = UUID()
        let first = V2DirectSendPolicyCache.Key(roomID: roomID, senderID: UUID())
        let second = V2DirectSendPolicyCache.Key(roomID: roomID, senderID: UUID())
        let entry = makeEntry()

        await cache.insert(entry, for: first)
        await cache.insert(entry, for: second)
        #expect(await cache.value(for: first) == entry)
        #expect(await cache.value(for: second) == entry)

        await cache.invalidate(roomID: roomID)
        #expect(await cache.value(for: first) == nil)
        #expect(await cache.value(for: second) == nil)
    }

    @Test("capacity evicts the least recently used entry")
    func boundsMemory() async throws {
        let cache = V2DirectSendPolicyCache(capacity: 2)
        let first = V2DirectSendPolicyCache.Key(roomID: UUID(), senderID: UUID())
        let second = V2DirectSendPolicyCache.Key(roomID: UUID(), senderID: UUID())
        let third = V2DirectSendPolicyCache.Key(roomID: UUID(), senderID: UUID())

        await cache.insert(makeEntry(), for: first)
        await cache.insert(makeEntry(), for: second)
        // Refresh the first key. The second key must now be the O(1) tail.
        #expect(await cache.value(for: first) != nil)
        await cache.insert(makeEntry(), for: third)

        #expect(await cache.value(for: first) != nil)
        #expect(await cache.value(for: second) == nil)
        #expect(await cache.value(for: third) != nil)
        let snapshot = await cache.snapshot()
        #expect(snapshot.entries == 2)
        #expect(snapshot.evictions == 1)
        #expect(snapshot.insertions == 3)
        #expect(snapshot.hits == 3)
        #expect(snapshot.misses == 1)
    }

    @Test("reply-marker refinement preserves the durable revision fence")
    func replyMarkerRefinementAdvancesPairRevision() throws {
        let entry = makeEntry(
            directPairRevision: 41,
            senderHasReplied: false
        )
        let refined = entry.markingSenderHasReplied()

        #expect(refined.senderHasReplied)
        #expect(refined.directPairRevision == 42)
        #expect(refined.recipientID == entry.recipientID)
        #expect(refined.recipientPolicyRevision == entry.recipientPolicyRevision)
    }

    private func makeEntry(
        directPairRevision: Int64 = 1,
        senderHasReplied: Bool = true
    ) -> V2DirectSendPolicyCache.Entry {
        .init(
            recipientID: UUID(), directPairRevision: directPairRevision,
            senderPolicyRevision: 1, recipientPolicyRevision: 1,
            senderProfileVisibleToRecipient: true, senderCanSend: true,
            senderIsActive: true,
            recipientIsActive: true, blocked: false, isFriend: true,
            senderHasReplied: senderHasReplied, recipientHasReplied: true, allowsStrangers: true,
            senderAccountKind: nil, senderAccountStatus: nil,
            senderAllowsServiceMessages: nil, recipientAccountKind: nil,
            recipientAccountStatus: nil, recipientAllowsCustomerMessages: nil
        )
    }
}
