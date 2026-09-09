import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Bounded anchored projection windows", .timeLimit(.minutes(1)))
struct V2ListWindowTests {
    @Test("thousands of newer conversations do not displace the anchor or expand the window")
    func conversationWindowSurvivesHeadInsertion() async throws {
        let store = try makeStore()
        try await seedConversations(store, range: 1...2_000)
        let anchor = conversationCursor(1_000)
        let first = try await store.conversationListWindow(isArchived: false, around: anchor)
        #expect(first.page.entries.count == 200 && first.hasEarlier && first.page.nextCursor != nil)
        #expect(first.page.entries[50].roomID == anchor.roomID)
        try await seedConversations(store, range: 2_001...4_000)
        let refreshed = try await store.conversationListWindow(isArchived: false, around: anchor)
        #expect(refreshed.page.entries.map(\.roomID) == first.page.entries.map(\.roomID))
        #expect(refreshed.anchor == anchor)
        // Resolve the anchor's new sort position inside the read snapshot.
        try await store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_conversation_list_entries SET is_pinned = 1, last_activity = 5000 WHERE room_id = ?", arguments: [anchor.roomID.rawValue])
        }
        let moved = try await store.conversationListWindow(isArchived: false, around: anchor)
        #expect(moved.anchor?.roomID == anchor.roomID && moved.anchor?.isPinned == true)
        #expect(moved.page.entries.first?.roomID == anchor.roomID)
        #expect(moved.page.entries.count == 200 && !moved.hasEarlier)
        try await store.close()
    }

    @Test("deleted anchors choose the nearest successor, or predecessor at the end", arguments: [1, 500, 1_000])
    func deletedConversationAnchor(index: Int) async throws {
        let store = try makeStore()
        try await seedConversations(store, range: 1...1_000)
        let anchor = conversationCursor(index)
        try await store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM v2_conversation_list_entries WHERE room_id = ?", arguments: [anchor.roomID.rawValue])
        }
        let result = try await store.conversationListWindow(isArchived: false, around: anchor)
        #expect(result.anchor?.roomID == RoomID(uuid: identifier(index == 1 ? 2 : index - 1)))
        #expect(result.page.entries.count == 200)
        #expect(!result.page.entries.contains { $0.roomID == anchor.roomID })
        try await store.close()
    }

    @Test("equal timestamps preserve ID order and archive scope")
    func tiedConversationKeys() async throws {
        let store = try makeStore()
        try await seedConversations(store, range: 1...1_000)
        try await store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_conversation_list_entries SET last_activity = 7, is_archived = 1")
        }
        let anchor = V2ClientConversationListCursor(isPinned: false, lastActivity: Date(timeIntervalSince1970: 7), roomID: .init(uuid: identifier(500)))
        let result = try await store.conversationListWindow(isArchived: true, around: anchor, limit: 100, precedingCount: 25)
        #expect(result.page.entries.map(\.roomID) == (475...574).map { .init(uuid: identifier($0)) })
        #expect(result.anchor == anchor && result.hasEarlier)
        let wrongScope = try await store.conversationListWindow(isArchived: false, around: anchor)
        #expect(wrongScope.page.entries.isEmpty && wrongScope.anchor == nil && !wrongScope.hasEarlier)
        try await store.close()
    }

    @Test("each relationship scope keeps a bounded anchor window and excludes revoked rows", arguments: [0, 1, 2])
    func relationshipScopes(kind: Int) async throws {
        let store = try makeStore()
        let current = UserID(uuid: identifier(99_999))
        let scope: V2ClientRelationshipPageScope = switch kind {
        case 0: .accepted
        case 1: .incomingRequests(currentUserID: current)
        default: .outgoingRequests(currentUserID: current)
        }
        try await store.databasePool.write { db in
            for group in 0..<3 {
                for index in 1...1_000 {
                    let id = identifier(group * 10_000 + index).uuidString
                    let requester: String? = group == 0 ? nil : (group == 1 ? id : current.rawValue)
                    try db.execute(sql: "INSERT INTO v2_relationship_projections (target_user_id, state, requested_by_user_id, updated_at) VALUES (?, ?, ?, ?)", arguments: [id, group == 0 ? "accepted" : "pending", requester, Double(index)])
                }
            }
        }
        let anchor = V2ClientRelationshipCursor(updatedAt: Date(timeIntervalSince1970: 500), targetUserID: .init(uuid: identifier(kind * 10_000 + 500)))
        let result = try await store.relationshipWindow(scope: scope, around: anchor)
        #expect(result.page.relationships.count == 200 && result.hasEarlier && result.page.nextCursor != nil)
        #expect(result.page.relationships[50].targetUserID == anchor.targetUserID)
        #expect(result.page.totalCount == nil)
        #expect(result.page.relationships.allSatisfy { row in
            switch kind {
            case 0: row.state == .accepted
            case 1: row.state == .pending && row.requestedByUserID != current
            default: row.state == .pending && row.requestedByUserID == current
            }
        })
        try await store.databasePool.write { db in
            try db.execute(sql: "UPDATE v2_relationship_projections SET state = 'none', requested_by_user_id = NULL WHERE target_user_id = ?", arguments: [anchor.targetUserID.rawValue])
        }
        let changed = try await store.relationshipWindow(scope: scope, around: anchor)
        #expect(changed.anchor?.targetUserID == .init(uuid: identifier(kind * 10_000 + 499)))
        #expect(!changed.page.relationships.contains { $0.targetUserID == anchor.targetUserID })
        try await store.close()
    }

    @Test("range branches use ordered index seeks instead of scanning from the head")
    func windowRangeQueryPlans() async throws {
        let store = try makeStore()
        try await store.databasePool.read { db in
            let statements = [
                "SELECT room_id, last_activity, is_pinned, is_archived, mute_until FROM v2_conversation_list_entries WHERE is_archived = 0 AND is_pinned = 0 AND last_activity < 500 ORDER BY is_pinned DESC, last_activity DESC, room_id ASC LIMIT 201",
                "SELECT room_id, last_activity, is_pinned, is_archived, mute_until FROM v2_conversation_list_entries WHERE is_archived = 0 AND is_pinned = 0 AND last_activity = 500 AND room_id >= 'id' ORDER BY is_pinned DESC, last_activity DESC, room_id ASC LIMIT 201",
                "SELECT target_user_id, state, requested_by_user_id, updated_at FROM v2_relationship_projections WHERE state = 'accepted' AND updated_at > 500 ORDER BY updated_at ASC, target_user_id DESC LIMIT 201"
            ]
            for sql in statements {
                let details = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
                #expect(details.contains { $0.contains("SEARCH") && ($0.contains("last_activity<?") || $0.contains("room_id>?") || $0.contains("updated_at>?")) })
                #expect(!details.contains { $0.contains("TEMP B-TREE") || $0.contains("SCAN ") })
            }
        }
        try await store.close()
    }

    private func seedConversations(_ store: GRDBV2LocalSyncStore, range: ClosedRange<Int>) async throws {
        try await store.databasePool.write { db in
            for index in range {
                try db.execute(sql: "INSERT INTO v2_conversation_list_entries (room_id, last_activity) VALUES (?, ?)", arguments: [identifier(index).uuidString, Double(index)])
            }
        }
    }

    private func conversationCursor(_ index: Int) -> V2ClientConversationListCursor {
        .init(isPinned: false, lastActivity: Date(timeIntervalSince1970: Double(index)), roomID: .init(uuid: identifier(index)))
    }

    private func identifier(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-list-window-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
    }
}
