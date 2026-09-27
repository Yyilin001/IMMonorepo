import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Account pending group avatar journal pagination")
struct V2PendingGroupAvatarPageTests {
    @Test("equal timestamps and removals between pages neither skip nor repeat remaining operations")
    func keysetPagination() async throws {
        let f = try IntentFixture()
        var ids: [GroupAvatarOperationID] = []
        for _ in 0..<70 {
            let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: .init(uuid: UUID()),
                expectedRevision: 0, mutation: .remove)
            _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil, now: f.now)
            ids.append(command.operationID)
        }
        ids.sort { $0.rawValue < $1.rawValue }
        let first = try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor)
        #expect(first.entries.map(\.id) == Array(ids.prefix(32)))
        for entry in first.entries { try await f.store.cancelGroupAvatarIntent(entry.id) }
        let second = try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor, after: #require(first.next))
        #expect(second.entries.map(\.id) == Array(ids[32..<64]))
        let third = try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor, after: #require(second.next))
        #expect(third.entries.map(\.id) == Array(ids.suffix(6)))
        #expect(third.next == nil)
        #expect(try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor).entries.first?.id == ids[32])
        try await f.store.close(); try f.removeFiles()
    }

    @Test("cursor and empty-list reads enforce account binding and bounded page sizes")
    func accountBinding() async throws {
        let f = try IntentFixture(), foreign = UserID(uuid: UUID())
        await #expect(throws: V2GroupAvatarIntentError.accountMismatch) {
            _ = try await f.store.pendingGroupAvatarOperations(actorUserID: foreign)
        }
        let cursor = V2PendingGroupAvatarPage.Cursor(actorUserID: foreign, createdAt: 1, operationID: .init(uuid: UUID()))
        await #expect(throws: V2GroupAvatarIntentError.accountMismatch) {
            _ = try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor, after: cursor)
        }
        for limit in [0, 65] {
            await #expect(throws: V2GroupAvatarIntentError.invalidRecord) {
                _ = try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor, limit: limit)
            }
        }
        #expect(try await f.store.pendingGroupAvatarOperations(actorUserID: f.actor).entries.isEmpty)
        try await f.store.close(); try f.removeFiles()
    }

    @Test("restart retains the journal and indexes only pending account operations")
    func restartAndQueryPlan() async throws {
        let f = try IntentFixture(), command = try f.command(media: nil)
        _ = try await f.store.freezeGroupAvatarIntent(actorUserID: f.actor, command: command, uploadJobID: nil)
        try await f.store.close()
        let reopened = try f.reopen()
        #expect(try await reopened.pendingGroupAvatarOperations(actorUserID: f.actor).entries.map(\.id) == [command.operationID])
        let plan = try await reopened.databasePool.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT operation_id,created_at FROM v2_group_avatar_intents
                WHERE actor_user_id=? AND (stage NOT IN ('committed','cancelled','closed')
                    OR (stage='closed' AND closed_disposition='awaitingDecision'))
                    AND (created_at,operation_id) > (?,?) ORDER BY created_at,operation_id LIMIT 33
                """, arguments: [f.actor.rawValue, 0, ""]).map { (row: Row) -> String in row["detail"] }
        }
        #expect(plan.contains { $0.contains("v2_group_avatar_pending_account") })
        #expect(!plan.contains { $0.contains("TEMP B-TREE") })
        try await reopened.close(); try f.removeFiles()
    }
}
