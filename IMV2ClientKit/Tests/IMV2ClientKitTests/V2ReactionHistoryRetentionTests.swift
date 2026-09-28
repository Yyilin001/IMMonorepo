import Foundation
import GRDB
import Testing
@testable import IMV2ClientKit

@Suite("Reaction history ownership", .serialized)
struct V2ReactionHistoryRetentionTests {
    @Test("only proven completed history is removed; a queued successor survives")
    func completedHistoryAndSuccessor() async throws {
        let f = try ReactionWorkFixture()
        defer { f.remove() }
        let first = try await f.service.enqueue(roomID: f.room, messageID: f.message,
            reaction: "👍", targetState: .present)
        #expect(try await f.service.prepareNextIntent())
        try await f.service.execute(f.claim(first))
        // Submit committed remotely but lost its response. Age alone is not proof.
        let future = Date().addingTimeInterval(8 * 24 * 60 * 60)
        #expect(try await f.store.pruneCompletedOperationHistory(now: future) == 0)
        #expect(try await f.store.operationWork(id: first)?.execution.isTerminal == false)
        let next = try await f.service.enqueue(roomID: f.room, messageID: f.message,
            reaction: "👍", targetState: .absent)
        let work = try #require(try await f.store.operationWork(id: first))
        guard case .claimed(let recovery) = try await f.store.claimOperationWork(
            id: first, ownerID: UUID(), action: .reconcile, now: work.nextActionAt) else {
            Issue.record("missing original-operation recovery claim")
            return
        }
        try await f.service.execute(recovery)
        #expect(try await f.store.operationWork(id: first)?.execution == .committed)
        #expect(try await f.store.pruneCompletedOperationHistory(now: future) == 1)
        #expect(try await f.store.operationWork(id: first) == nil)
        let draft = try #require(try await f.store.nextReactionDraft(now: Date()))
        #expect(draft.id == next && draft.targetState == .absent)
        // The successor obtains a fresh authoritative own-key baseline, independent
        // of the pruned local receipt and the aggregate timeline projection.
        #expect(try await f.service.prepareNextIntent())
        #expect(try await f.store.reactionCommand(workID: next).expectedReactionRevision == 8)
        #expect(await f.remote.submissions == 1)
        try await f.store.close()
    }
}
