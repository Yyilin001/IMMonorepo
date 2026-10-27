import Foundation
import GRDB
import Testing
@testable import IMV2ClientKit

@Suite("Committed projection invalidations", .timeLimit(.minutes(1)))
struct V2ProjectionChangeTests {
    @Test("commit metrics originate from successful transactions, never rollback or cold subscription")
    func realCommitVisibilityMeasurement() async throws {
        let store = try makeStore(), diagnostics = V2NetworkDiagnostics()
        store.installNetworkDiagnostics(diagnostics)
        var updates = await store.projectionChanges().makeAsyncIterator()
        #expect(await updates.next()?.conversationCommit == nil)
        enum Rollback: Error { case requested }
        await #expect(throws: Rollback.self) {
            try await store.databasePool.write { db in try insertMessage(1, db: db); throw Rollback.requested }
        }
        #expect(diagnostics.snapshot().projections.isEmpty)
        try await store.databasePool.write { db in try insertMessage(2, db: db) }
        let change = try #require(await updates.next())
        let stamp = try #require(change.conversationCommit)
        #expect(diagnostics.snapshot().projections.count == 1)
        #expect(diagnostics.snapshot().projections.first?.phase == .willCommitToDidCommit)
        stamp.didPublishSnapshot(); stamp.didPublishSnapshot()
        #expect(diagnostics.snapshot().projections.count == 2)
        #expect(diagnostics.snapshot().projections.last?.phase == .didCommitToConversationSnapshot)
        #expect(diagnostics.snapshot().projections.allSatisfy { $0.elapsed.isFinite && $0.elapsed >= 0 })
        try await store.close()
    }

    @Test("ordinary writes publish once after commit and close finishes subscriptions")
    func ordinaryCommitAndClose() async throws {
        let store = try makeStore()
        let subscription = await store.projectionChanges()
        var updates = subscription.makeAsyncIterator()
        #expect(await updates.next() == .all)
        try await store.databasePool.write { db in
            try insertMessage(1, db: db)
            try insertMessage(2, db: db)
        }
        #expect(await updates.next() == .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: false, roomIDs: ["room"]))
        #expect(subscription.hub.take(subscription.identifier) == nil)
        try await store.close()
        #expect(await updates.next() == nil)
        var closed = await store.projectionChanges().makeAsyncIterator()
        #expect(await closed.next() == nil)
    }

    @Test("message effect receipts do not escalate ordinary changes or wake unrelated scopes")
    func effectReceiptsAreInternalMetadata() async throws {
        let store = try makeStore()
        let subscription = await store.projectionChanges()
        var updates = subscription.makeAsyncIterator()
        _ = await updates.next()
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_message_effects VALUES ('event-1', 'message', 'message-1', 'room-1', 1, ?)", arguments: [Data(repeating: 1, count: 32)])
            try insertMessage(1, db: db)
        }
        #expect(await updates.next() == .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: false, roomIDs: ["room"]))
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_message_effects VALUES ('event-2', 'message', 'message-1', 'room-1', 1, ?)", arguments: [Data(repeating: 2, count: 32)])
        }
        #expect(subscription.hub.take(subscription.identifier) == nil)
        try await store.close()
    }

    @Test("a busy subscriber unions scopes and preserves earlier urgency")
    func pendingChangesAreNotDropped() async throws {
        let store = try makeStore()
        var slow = await store.projectionChanges().makeAsyncIterator()
        var fast = await store.projectionChanges().makeAsyncIterator()
        #expect(await slow.next() == .all)
        #expect(await fast.next() == .all)
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_user_add_preference(singleton, allows_being_added, revision, updated_at) VALUES(1, 0, 1, 1)")
        }
        #expect(await fast.next() == .init(scopes: [.privacy, .conversationDetails], requiresImmediateRefresh: true))
        for value in 1...40 {
            try await store.databasePool.write { db in try insertMessage(value, db: db) }
        }
        #expect(await fast.next() == .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: false, roomIDs: ["room"]))
        #expect(await slow.next() == .init(scopes: [.privacy, .conversations, .conversationDetails, .conversationTimeline], requiresImmediateRefresh: true))
        try await store.close()
    }

    @Test("rolled back transactions and savepoints cannot invalidate the UI")
    func rollbackAndSavepoint() async throws {
        let store = try makeStore()
        let subscription = await store.projectionChanges()
        var updates = subscription.makeAsyncIterator()
        _ = await updates.next()
        enum Rollback: Error { case requested }
        await #expect(throws: Rollback.self) {
            try await store.databasePool.write { db in
                try insertMessage(1, db: db)
                throw Rollback.requested
            }
        }
        #expect(subscription.hub.take(subscription.identifier) == nil)
        try await store.databasePool.write { db in
            try db.inSavepoint {
                try db.execute(sql: "INSERT INTO v2_user_add_preference(singleton, allows_being_added, revision, updated_at) VALUES(1, 0, 1, 1)")
                return .rollback
            }
            try insertMessage(2, db: db)
        }
        #expect(await updates.next() == .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: false, roomIDs: ["room"]))
        try await store.close()
    }

    @Test("updates, deletes, snapshots and unknown projections remain immediate")
    func protectiveChanges() async throws {
        let store = try makeStore()
        try await store.databasePool.write { db in try insertMessage(1, db: db) }
        var updates = await store.projectionChanges().makeAsyncIterator()
        _ = await updates.next()
        try await store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_message_projections SET is_withdrawn = 1, text_body = '' WHERE message_id = 'message-1'")
        }
        #expect(await updates.next() == .init(scopes: [.conversations, .conversationTimeline, .resources], requiresImmediateRefresh: true, roomIDs: ["room"]))
        try await store.databasePool.write { db in try db.execute(sql: "DELETE FROM v2_message_projections") }
        #expect(await updates.next() == .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: true))
        try await store.databasePool.write { db in
            try db.execute(sql: "CREATE TABLE v2_future_projection(value INTEGER)")
            try db.execute(sql: "INSERT INTO v2_future_projection VALUES(1)")
        }
        #expect(await updates.next() == .all)
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_snapshots(singleton, snapshot_id, generation, base_sequence, root_digest, next_sync_token, acknowledgement_receipt) VALUES(1, 'snapshot', 1, 0, 'digest', 'token', 'receipt')")
        }
        #expect(await updates.next() == .all)
        try await store.close()
    }

    @Test("room scoped message commits stay local and deleted or unknown rows fall back globally")
    func roomScopeAndGlobalFallback() async throws {
        let store = try makeStore()
        var updates = await store.projectionChanges().makeAsyncIterator()
        _ = await updates.next()
        try await store.databasePool.write { db in
            try insertMessage(1, roomID: "room-a", db: db)
            try insertMessage(2, roomID: "room-b", db: db)
        }
        let mixed = try #require(await updates.next())
        #expect(mixed.scopes == [.conversations, .conversationTimeline])
        #expect(mixed.roomIDs == ["room-a", "room-b"])
        try await store.databasePool.write { db in try db.execute(sql: "DELETE FROM v2_message_projections WHERE message_id = 'message-1'") }
        #expect(try #require(await updates.next()).roomIDs == nil)
        try await store.close()
    }

    @Test("timeline and detail metadata tables retain their refresh categories")
    func timelineAndMetadataTableScopes() {
        let message = V2ProjectionTransactionObserver.change(table: "v2_message_projections", kind: .insert).scopes
        #expect(message.contains(.conversationTimeline))
        #expect(!message.contains(.conversationMetadata))
        let favorite = V2ProjectionTransactionObserver.change(table: "v2_message_favorites", kind: .update).scopes
        #expect(favorite.contains(.conversationTimeline))
        #expect(!favorite.contains(.conversationMetadata))
        let announcement = V2ProjectionTransactionObserver.change(table: "v2_group_announcements", kind: .update).scopes
        #expect(announcement.contains(.conversationMetadata))
        #expect(!announcement.contains(.conversationTimeline))
        let tombstone = V2ProjectionTransactionObserver.change(table: "v2_message_tombstones", kind: .update).scopes
        #expect(tombstone.contains(.conversationDetails))
        let roomProfile = V2ProjectionTransactionObserver.change(table: "v2_room_profile_projections", kind: .update).scopes
        #expect(roomProfile.contains(.conversationDetails))
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-projection-changes-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
    }
    private func insertMessage(_ value: Int, roomID: String = "room", db: Database) throws {
        try db.execute(sql: """
            INSERT INTO v2_message_projections(message_id, source_event_id, room_id, room_sequence, message_revision,
                sender_user_id, text_body, server_created_at, timeline_sequence) VALUES(?, ?, ?, ?, 1, 'sender', 'hello', ?, ?)
            """, arguments: ["message-\(value)", "event-\(value)", roomID, value, value, value])
    }
}
