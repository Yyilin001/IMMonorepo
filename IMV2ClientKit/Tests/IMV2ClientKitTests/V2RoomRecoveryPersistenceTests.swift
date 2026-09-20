import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Durable room recovery scan")
struct V2RoomRecoveryPersistenceTests {
    @Test(arguments: ["round", "generation"])
    func directoryResponseCannotAdvanceReplacedScan(change: String) async throws {
        let (store, _, _, user) = try fixture()
        try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token) VALUES (1,'ready',1,0,0,'initial')") }
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let request = try await store.roomRecoveryScan(scope: scope)
        let room = RoomID(uuid: UUID())
        let page = try V2ClientUserRoomPage(rooms: [.init(roomID: room, kind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)], nextCursor: nil, topologyGeneration: "one")
        if change == "round" { try await store.restartRoomRecoveryDirectory(scope: scope) }
        else { try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET generation = 2") } }
        await #expect(throws: V2RoomRecoveryPersistenceError.stalePage) {
            try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: request.cursor, request: request, now: .now)
        }
        #expect(try await !store.roomRecoveryScan(scope: scope).directoryComplete)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 0)
        try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        #expect(try await store.roomRecoveryScan(scope: scope).directoryComplete)
        #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first?.roomID == room)
    }

    @Test(arguments: ["uncaptured", "owner", "membership", "head"])
    func bodyAuthorizationTracksIdentityButAllowsProgress(change: String) async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user), room = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 5, priority: 0, scope: scope, now: .now)
        let initial = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1, head: 5, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0), work: initial, now: .now)
        let captured = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        if change != "uncaptured" {
            _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: change == "owner" ? 2 : 1,
                viewerMembershipRevision: change == "membership" ? 2 : 1, head: 6, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0), work: captured, now: .now)
        }
        let page = try V2ClientGroupEventPage(roomID: room, events: [], nextRoomSequence: 5, hasMore: false)
        if change == "head" {
            _ = try await store.applyRoomRecoveryPage(page, work: captured)
            #expect(try await store.groupEventCursor(roomID: room) == 5)
        } else {
            await #expect(throws: V2RoomRecoveryPersistenceError.staleMembership) {
                _ = try await store.applyRoomRecoveryPage(page, work: change == "uncaptured" ? initial : captured)
            }
            #expect(try await store.groupEventCursor(roomID: room) == 0)
        }
        #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).count == 1)
    }

    @Test(arguments: [false, true])
    func oldBodyCannotBorrowRejoinedStateAuthorization(summaryHasWork: Bool) async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID()), oldMessage = MessageID(uuid: UUID())
        try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token) VALUES (1,'ready',1,0,0,'initial')") }
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 5, priority: 0, scope: scope, now: .now)
        let initial = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1, head: 5, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0), work: initial, now: .now)
        let old = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        let oldSummaryRequest = try await store.beginRoomLatestVisibleRequest(scope: scope)
        let oldSummary = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 5,
            latest: .init(id: oldMessage, senderID: user, sequence: 1, revision: 1,
                preview: "old membership summary", mediaCount: 0, createdAt: .now))
        let records = try [(UInt64(1), 2, "remove"), (UInt64(2), 3, "add")].map { sequence, revision, action in
            try V2ClientSyncRecord(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: "membership",
                payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                    "membership_revision": revision, "target_user_id": user.rawValue, "action": action,
                    "title": "Rejoined", "owner_user_id": user.rawValue, "capacity_class": "standard", "created_at_ms": 1000, "server_created_at_ms": 2000]))
        }
        _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("rejoined"), receipt: .init("receipt"), hasMore: false, capabilityProfile: "base"))
        let pending = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 3, head: 5, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0), work: pending, now: .now)
        let current = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        #expect(try await !store.commitRoomLatestVisible(oldSummary, request: oldSummaryRequest, work: summaryHasWork ? old : nil))
        #expect(try await store.roomLatestVisible(roomID: room, scope: scope) == nil)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT requires_summary FROM v2_room_recovery_work WHERE room_id = ?", arguments: [room.rawValue]) } == 1)
        let currentSummaryRequest = try await store.beginRoomLatestVisibleRequest(scope: scope)
        let currentSummary = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 3, head: 5, latest: nil)
        #expect(try await store.commitRoomLatestVisible(currentSummary, request: currentSummaryRequest, work: current))
        #expect(try await !store.commitRoomLatestVisible(oldSummary, request: oldSummaryRequest, work: summaryHasWork ? old : nil))
        #expect(try await store.roomLatestVisible(roomID: room, scope: scope) == currentSummary)
        let payload = try JSONSerialization.data(withJSONObject: ["event_type": "message.accepted", "room_id": room.rawValue, "room_sequence": 1,
            "message_id": oldMessage.rawValue, "message_revision": 1, "sender_user_id": user.rawValue, "text": "stale body", "server_created_at_ms": 1_750_000_000_000])
        let page = try V2ClientGroupEventPage(roomID: room, events: [.init(sourceEventID: .init(uuid: UUID()), roomSequence: 1, projectionKind: "message", payload: payload)], nextRoomSequence: 5, hasMore: false)
        await #expect(throws: V2RoomRecoveryPersistenceError.staleMembership) { _ = try await store.applyRoomRecoveryPage(page, work: old) }
        #expect(try await store.messages(in: room).isEmpty)
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first?.requestRevision == current.requestRevision)
        _ = try await store.applyRoomRecoveryPage(.init(roomID: room, events: [], nextRoomSequence: 5, hasMore: false), work: current)
        #expect(try await store.groupEventCursor(roomID: room) == 5)
        #expect(try await store.messages(in: room).isEmpty)
    }

    @Test func personalGrantAfterDirectoryCreatesDurableRecovery() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        try await store.commitRoomRecoveryDirectoryPage(.init(rooms: [], nextCursor: nil, topologyGeneration: "grant"),
            expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        let room = RoomID(uuid: UUID())
        let grant = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(UUID().uuidString), projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                "membership_revision": 2, "target_user_id": user.rawValue, "action": "add", "title": "New membership",
                "owner_user_id": UserID(uuid: UUID()).rawValue, "capacity_class": "standard",
                "created_at_ms": 1000, "server_created_at_ms": 2000]))
        let batch = try V2ClientSyncBatch(generation: 1, records: [grant], nextSyncToken: .init("grant"),
            receipt: .init("receipt"), hasMore: false, capabilityProfile: "base")
        _ = try await store.apply(batch)
        let work = try await store.roomRecoveryWork(scope: scope, limit: 10, oldestFirst: true, now: .now)
        #expect(work.count == 1)
        #expect(work.first?.roomID == room)
        #expect(work.first?.requiresState == true)
        #expect(work.first?.requiresSummary == true)
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        #expect(try await store.roomRecoveryCompletionCandidate(scope: scope) == nil)
        _ = try await store.apply(batch)
        let replayed = try await store.roomRecoveryWork(scope: scope, limit: 10, oldestFirst: true, now: .now)
        #expect(replayed.count == 1)
        #expect(replayed.first?.requestRevision == work.first?.requestRevision)
    }

    @Test(arguments: ["no-scan", "stale-binding", "other-member"])
    func personalGrantDoesNotCreateUnownedWork(scenario: String) async throws {
        let (store, _, _, user) = try fixture()
        if scenario != "no-scan" {
            _ = try await store.beginRoomRecoveryScan(userID: user)
        }
        if scenario == "stale-binding" {
            try await store.databasePool.write {
                try $0.execute(sql: "UPDATE v2_room_recovery_scan SET installation_binding = 'retired-installation'")
            }
        }
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        let room = RoomID(uuid: UUID())
        let target = scenario == "other-member" ? UserID(uuid: UUID()) : user
        let grant = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(UUID().uuidString), projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                "membership_revision": 2, "target_user_id": target.rawValue, "action": "add", "title": "Membership boundary",
                "owner_user_id": user.rawValue, "capacity_class": "standard", "created_at_ms": 1000,
                "server_created_at_ms": 2000]))
        _ = try await store.apply(.init(generation: 1, records: [grant], nextSyncToken: .init("boundary"),
            receipt: .init("boundary-receipt"), hasMore: false, capabilityProfile: "base"))
        let count = try await store.databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work")
        }
        #expect(count == 0)
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        #expect(try await store.cursor()?.appliedSequence == 1)
    }

    @Test func cachedActivityOrdersPagesBeforeContentArrives() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
        let older = RoomID(uuid: UUID()), newer = RoomID(uuid: UUID())
        for (room, time) in [(older, 10.0), (newer, 20.0)] {
            let snapshot = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 5,
                latest: .init(id: .init(uuid: UUID()), senderID: user, sequence: 4, revision: 1,
                    preview: "cached", mediaCount: 0, createdAt: .init(timeIntervalSince1970: time)))
            #expect(try await store.commitRoomLatestVisible(snapshot, request: request))
        }
        let first = try await store.conversationListPage(isArchived: false, before: nil, limit: 1)
        #expect(first.entries.first?.roomID == newer)
        #expect(first.entries.first?.lastMessage == nil)
        #expect(first.entries.first?.latestVisible?.latest?.preview == "cached")
        let second = try await store.conversationListPage(isArchived: false, before: first.nextCursor, limit: 1)
        #expect(second.entries.first?.roomID == older)
        // Older local projection writes cannot clobber an authoritative cached position.
        try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_conversation_list_entries SET last_activity = 1 WHERE room_id = ?", arguments: [newer.rawValue]) }
        let retained = try await store.conversationListPage(isArchived: false, before: nil, limit: 1)
        #expect(retained.entries.first?.roomID == newer && retained.entries.first?.lastActivity == Date(timeIntervalSince1970: 20))
        try await store.databasePool.write { try $0.execute(sql: "DELETE FROM v2_room_latest_visible WHERE room_id = ?", arguments: [newer.rawValue]) }
        let remaining = try await store.conversationListPage(isArchived: false, before: nil, limit: 1)
        #expect(remaining.entries.first?.roomID == older)
        #expect(try await store.groupEventCursor(roomID: newer) == 0)
    }

    @Test(arguments: ["head", "revoked", "reset", "unavailable"])
    func invalidatedSummaryQueuesOnlyAuthorizedCurrentGeneration(change: String) async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        let room = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 8, priority: 0, scope: scope, now: .now)
        let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 8, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0), work: work, now: .now)
        let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
        #expect(try await store.commitRoomLatestVisible(.init(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 8, latest: nil), request: request))
        try await store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM v2_room_recovery_work")
            switch change {
            case "head": try db.execute(sql: "UPDATE v2_room_sync_states SET head = 9 WHERE room_id = ?", arguments: [room.rawValue])
            case "revoked": try db.execute(sql: "INSERT INTO v2_room_membership_states VALUES (?, 2, 'removed', 0)", arguments: [room.rawValue])
            case "unavailable": try db.execute(sql: "DELETE FROM v2_room_sync_states WHERE room_id = ?", arguments: [room.rawValue])
            default: try db.execute(sql: "UPDATE v2_sync_cursor SET generation = 2")
            }
        }
        let cached = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_latest_visible") }
        #expect(cached == 0)
        let queued = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
        if change == "head" { #expect(queued.count == 1 && queued[0].requiresSummary && queued[0].requiresState) }
        else { #expect(queued.isEmpty) }
    }

    @Test func personalRemovalPurgesRecoveryAndRejectsLateSummary() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        let room = RoomID(uuid: UUID())
        try await store.enqueueRoomLatestVisible(roomID: room, scope: scope, now: .now)
        let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 8, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0), work: work, now: .now)
        let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
        let snapshot = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 8, latest: nil)
        #expect(try await store.commitRoomLatestVisible(snapshot, request: request))
        let removal = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(UUID().uuidString), projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                "membership_revision": 2, "target_user_id": user.rawValue, "action": "remove"]))
        _ = try await store.apply(.init(generation: 1, records: [removal], nextSyncToken: .init("removed"),
            receipt: .init("receipt"), hasMore: false, capabilityProfile: "base"))
        for table in ["v2_room_sync_states", "v2_room_latest_visible", "v2_room_recovery_work"] {
            let count = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }
            #expect(count == 0)
        }
        #expect(try await !store.commitRoomLatestVisible(snapshot, request: request))
    }

    @Test func repeatedSummaryDemandPreservesFlightAndBackoff() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID())
        let now = Date(timeIntervalSince1970: 100)
        try await store.ensureRoomLatestVisible(roomID: room, scope: scope, now: now)
        let first = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
        try await store.retryRoomRecoveryWork(first, at: now.addingTimeInterval(60))
        for _ in 0..<10 {
            try await store.ensureRoomLatestVisible(roomID: room, scope: scope, now: now.addingTimeInterval(1))
        }
        let early = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now.addingTimeInterval(59))
        #expect(early.isEmpty)
        let ready = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now.addingTimeInterval(60)).first)
        #expect(ready.requestRevision == first.requestRevision)
        #expect(ready.enqueuedAt == first.enqueuedAt && ready.requiresSummary)
        // A real new fact must still supersede the captured response.
        try await store.enqueueRoomLatestVisible(roomID: room, scope: scope, now: now.addingTimeInterval(61))
        let renewed = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now.addingTimeInterval(61)).first)
        #expect(renewed.requestRevision != first.requestRevision)
    }

    @Test func summaryCompletionPreservesNewRequestsAndRaisesContentTarget() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        let room = RoomID(uuid: UUID())
        try await store.enqueueRoomLatestVisible(roomID: room, scope: scope, now: .now)
        let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
        let snapshot = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 9, latest: nil)
        #expect(try await store.commitRoomLatestVisible(snapshot, request: request, work: work))
        let updated = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        #expect(!updated.requiresSummary && updated.requiresState && updated.targetHead == 9)
        #expect(try await !store.finishRoomRecoveryWork(updated))
        try await store.enqueueRoomLatestVisible(roomID: room, scope: scope, now: .now)
        #expect(try await store.commitRoomLatestVisible(snapshot, request: request, work: work))
        let newer = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        #expect(newer.requiresSummary && newer.requestRevision != work.requestRevision)
        #expect(try await store.groupEventCursor(roomID: room) == 0)
    }

    @Test(arguments: ["unchanged", "reset", "revoked", "newHead"])
    func latestVisibleCacheIsDisplayOnlyAndFenced(change: String) async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        let room = RoomID(uuid: UUID())
        let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
        let snapshot = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 8,
            latest: .init(id: .init(uuid: UUID()), senderID: user, sequence: 7, revision: 1,
                preview: "latest", mediaCount: 0, createdAt: .now))
        #expect(try await store.commitRoomLatestVisible(snapshot, request: request))
        #expect(try await store.roomLatestVisible(roomID: room, scope: scope) == snapshot)
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        if change == "reset" {
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET generation = 2") }
        } else if change == "revoked" {
            try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_room_membership_states VALUES (?, 2, 'removed', 0)", arguments: [room.rawValue]) }
        } else if change == "newHead" {
            let newer = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 9, latest: nil)
            #expect(try await store.commitRoomLatestVisible(newer, request: request))
        }
        #expect(try await store.commitRoomLatestVisible(snapshot, request: request) == (change == "unchanged"))
        if change == "reset" || change == "revoked" {
            #expect(try await store.roomLatestVisible(roomID: room, scope: scope) == nil)
        }
        #expect(try await store.groupEventCursor(roomID: room) == 0)
    }

    @Test(arguments: ["owner_epoch", "membership_revision", "head", "trimmed_through", "read_through", "latest_own_sequence", "member", "watermark", "pending", "acknowledged"], [1.5, Double(Int64.max)])
    func unreadSnapshotStorageTypes(field: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unread-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), unknown = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 12, priority: 1, scope: scope, now: .now)
        let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 12, trimmedThrough: 0, readThrough: 3, latestOwnMessageSequence: 7), work: work, now: .now)
        let initial = try await store.roomUnreadSnapshot(roomIDs: [room])
        #expect(initial[room]?.localReadWatermark == nil)
        #expect(initial[room]?.displayedUnread == 5)
        func command(_ sequence: UInt64) -> V2PendingReadReceipt {
            .init(roomID: room, operationID: .init(uuid: UUID()), readThroughRoomSequence: sequence, state: .pending,
                attemptCount: 0, nextAttemptAt: .init(timeIntervalSince1970: 10), resultingRoomSequence: nil, terminalCode: nil)
        }
        let small = command(1)
        try await store.enqueue(small)
        try await store.enqueue(command(10))
        if field == "acknowledged" { try await store.markReadReceiptAcknowledged(operationID: small.operationID, roomSequence: 1) }
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_read_watermarks VALUES (?, 1, 0)", arguments: [room.rawValue])
            try db.execute(sql: "INSERT INTO v2_room_membership_states VALUES (?, 1, 'member', 1)", arguments: [room.rawValue])
        }
        let table: String, column: String, key: String, identifier: String
        switch field {
        case "member": table = "v2_room_membership_states"; column = "membership_revision"; key = "room_id"; identifier = room.rawValue
        case "watermark": table = "v2_room_read_watermarks"; column = "read_through_room_sequence"; key = "room_id"; identifier = room.rawValue
        case "pending", "acknowledged": table = "v2_pending_read_receipts"; column = field == "pending" ? "read_through_room_sequence" : "resulting_room_sequence"; key = "operation_id"; identifier = small.operationID.rawValue
        default: table = "v2_room_sync_states"; column = field; key = "room_id"; identifier = room.rawValue
        }
        // Bypass only the head/child relationship CHECK for otherwise unreachable fixtures.
        let bypass = (field == "head" && value < 7) || (["trimmed_through", "read_through", "latest_own_sequence"].contains(field) && value > 12)
        let original = try await store.databasePool.write { db in
            let original = try #require(try Int64.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE \(key) = ?", arguments: [identifier]))
            if bypass { try db.execute(sql: "PRAGMA ignore_check_constraints = ON") }
            defer { if bypass { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") } }
            try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(key) = ?", arguments: [value, identifier])
            return original
        }
        await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.roomUnreadSnapshot(roomIDs: [room, room, unknown]) }
        #expect(try await store.roomUnreadSnapshot(roomIDs: [unknown]).isEmpty)
        #expect(try await store.roomUnreadSnapshot(roomIDs: []).isEmpty)
        let raw = try await store.databasePool.read { db in
            let value = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE \(key) = ?", arguments: [identifier])
            let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table) WHERE \(key) = ?", arguments: [identifier])
            return (value, type)
        }
        #expect(raw.0 == value)
        #expect(raw.1 == "real")
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(key) = ?", arguments: [original, identifier]) }
        let repaired = try await store.roomUnreadSnapshot(roomIDs: [room, room, unknown])
        #expect(repaired.count == 1)
        #expect(repaired[room]?.serverUnreadCount == 5)
        #expect(repaired[room]?.localReadWatermark == 10)
        #expect(repaired[room]?.displayedUnread == 2)
        try await store.close()
    }

    @Test func unreadSnapshotUsesStateAndRejectsRevokedOrForeignAccountRows() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID())
        let unknown = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 12, priority: 1, scope: scope, now: .now)
        let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 12, trimmedThrough: 0, readThrough: 3, latestOwnMessageSequence: 7), work: work, now: .now)
        let first = try await store.roomUnreadSnapshot(roomIDs: [room, room, unknown])
        #expect(first.count == 1)
        #expect(first[room]?.serverUnreadCount == 5)
        #expect(first[room]?.displayedUnread == 5)
        try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_room_read_watermarks VALUES (?, 10, 0)", arguments: [room.rawValue]) }
        let optimistic = try await store.roomUnreadSnapshot(roomIDs: [room])
        #expect(optimistic[room]?.serverUnreadCount == 5)
        #expect(optimistic[room]?.displayedUnread == 2)
        try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_room_membership_states VALUES (?, 2, 'removed', 0)", arguments: [room.rawValue]) }
        #expect(try await store.roomUnreadSnapshot(roomIDs: [room]).isEmpty)
        try await store.databasePool.write {
            try $0.execute(sql: "DELETE FROM v2_room_membership_states")
            try $0.execute(sql: "UPDATE v2_room_recovery_scan SET installation_binding = 'foreign'")
        }
        #expect(try await store.roomUnreadSnapshot(roomIDs: [room]).isEmpty)
    }

    @Test func pageAndWorkSurviveReopen() async throws {
        let (store, url, binding, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID())
        let page = try V2ClientUserRoomPage(rooms: [.init(roomID: room, kind: .group,
            viewerMembershipRevision: 1, ownerEpoch: 1)], nextCursor: "next", topologyGeneration: "one")
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 12, priority: 1, scope: scope, now: .init(timeIntervalSince1970: 1))
        try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .init(timeIntervalSince1970: 2))
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await reopened.roomRecoveryScan(scope: scope).cursor == "next")
        let head = try await reopened.databasePool.read { try Int64.fetchOne($0, sql: "SELECT target_head FROM v2_room_recovery_work") }
        #expect(head == 12)
        let fresh = try await reopened.beginRoomRecoveryScan(userID: user)
        #expect(try await reopened.roomRecoveryScan(scope: fresh).cursor == nil)
        await #expect(throws: V2RoomRecoveryPersistenceError.staleScope) {
            try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        }
        let count = try await reopened.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(count == 1)
    }

    @Test func rejectedPageCannotPartiallyEnqueue() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let empty = try V2ClientUserRoomPage(rooms: [], nextCursor: "next", topologyGeneration: "one")
        try await store.commitRoomRecoveryDirectoryPage(empty, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        let changed = try V2ClientUserRoomPage(rooms: [.init(roomID: .init(uuid: UUID()), kind: .group,
            viewerMembershipRevision: 1, ownerEpoch: 1)], nextCursor: nil, topologyGeneration: "two")
        await #expect(throws: V2RoomRecoveryPersistenceError.topologyChanged) {
            try await store.commitRoomRecoveryDirectoryPage(changed, expectedCursor: "next", request: try await store.roomRecoveryScan(scope: scope), now: .now)
        }
        #expect(try await store.roomRecoveryScan(scope: scope).cursor == "next")
        let count = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(count == 0)
        let last = try V2ClientUserRoomPage(rooms: [], nextCursor: nil, topologyGeneration: "one")
        try await store.commitRoomRecoveryDirectoryPage(last, expectedCursor: "next", request: try await store.roomRecoveryScan(scope: scope), now: .now)
        #expect(try await store.roomRecoveryScan(scope: scope).directoryComplete)
    }

    @Test func midPageWriteFailureRollsBackEarlierWorkAndCursor() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let first = RoomID(uuid: UUID()), failing = RoomID(uuid: UUID())
        try await store.databasePool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_second_recovery_insert BEFORE INSERT ON v2_room_recovery_work
                WHEN NEW.room_id = '\(failing.rawValue)' BEGIN SELECT RAISE(ABORT, 'injected write failure'); END
                """)
        }
        let page = try V2ClientUserRoomPage(rooms: [first, failing].map {
            try .init(roomID: $0, kind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)
        }, nextCursor: "next", topologyGeneration: "one")
        await #expect(throws: DatabaseError.self) {
            try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        }
        let count = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(count == 0)
        let scan = try await store.roomRecoveryScan(scope: scope)
        #expect(scan.cursor == nil && scan.topologyGeneration == nil && !scan.directoryComplete)
    }

    @Test func accountBindingFencesOldWork() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.enqueueRoomRecovery(roomID: .init(uuid: UUID()), targetHead: 4, priority: 1, scope: scope, now: .now)
        let replacement = UserID(uuid: UUID())
        try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_local_installation SET user_id = ?", arguments: [replacement.rawValue]) }
        await #expect(throws: V2RoomRecoveryPersistenceError.staleScope) { try await store.roomRecoveryScan(scope: scope) }
        _ = try await store.beginRoomRecoveryScan(userID: replacement)
        let count = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(count == 0)
    }

    @Test(arguments: [0, 1, 2])
    func realtimeAndRecoveryShareOneMessageWithoutDroppingNewWork(order: Int) async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 1, scope: scope, now: .now)
        let initialWork = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        _ = try await store.commitRoomRecoveryState(.init(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0), work: initialWork, now: .now)
        let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 100, oldestFirst: false, now: .now).first(where: { $0.roomID == room }))
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "message.accepted", "room_id": room.rawValue, "room_sequence": 1,
            "message_id": message.rawValue, "message_revision": 1, "sender_user_id": user.rawValue,
            "text": "concurrent-recovery", "server_created_at_ms": 1_750_000_000_000
        ], options: [.sortedKeys])
        let page = try V2ClientGroupEventPage(roomID: room, events: [.init(sourceEventID: .init(uuid: UUID()),
            roomSequence: 1, projectionKind: "message", payload: payload)], nextRoomSequence: 1, hasMore: false)
        // This notification arrives after the older body request captured work.
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 2, priority: 1, scope: scope, now: .now)
        if order == 0 {
            _ = try await store.applyGroupEventPageReportingChanges(page)
            _ = try await store.applyRoomRecoveryPage(page, work: work)
        } else if order == 1 {
            _ = try await store.applyRoomRecoveryPage(page, work: work)
            _ = try await store.applyGroupEventPageReportingChanges(page)
        } else {
            async let realtime = store.applyGroupEventPageReportingChanges(page)
            async let recovery = store.applyRoomRecoveryPage(page, work: work)
            _ = try await (realtime, recovery)
        }
        let messages = try await store.messages(in: room)
        #expect(messages.count == 1 && messages.first?.messageID == message)
        #expect(try await store.groupEventCursor(roomID: room) == 1)
        let pending = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
        #expect(pending.targetHead == 2 && pending.requestRevision != work.requestRevision)
    }

    @Test func stateCannotCompleteContentAndLateWorkCannotDeleteNewTarget() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 10, priority: 1, scope: scope, now: .now)
        let initial = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: false, now: .now)
        var work = try #require(initial.first)
        let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 10, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        #expect(try await store.commitRoomRecoveryState(state, work: work, now: .now) == .advance)
        work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 100, oldestFirst: false, now: .now).first(where: { $0.roomID == room }))
        #expect(try await !store.finishRoomRecoveryWork(work))
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 12, priority: 1, scope: scope, now: .now)
        _ = try await store.applyRoomRecoveryPage(.init(roomID: room, events: [], nextRoomSequence: 10, hasMore: false), work: work)
        let pending = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: false, now: .now)
        var newer = try #require(pending.first)
        #expect(newer.targetHead == 12 && newer.requestRevision != work.requestRevision && newer.requiresState)
        let current = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 12, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        _ = try await store.commitRoomRecoveryState(current, work: newer, now: .now)
        newer = try #require(try await store.roomRecoveryWork(scope: scope, limit: 100, oldestFirst: false, now: .now).first(where: { $0.roomID == room }))
        _ = try await store.applyRoomRecoveryPage(.init(roomID: room, events: [], nextRoomSequence: 12, hasMore: false), work: newer)
        #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: false, now: .now).isEmpty)
    }

    @Test func mixedStateRequiresReconciliationAndRevocationFencesReads() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 10, priority: 0, scope: scope, now: .now)
        let pending = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
        let work = try #require(pending.first)
        let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 10, trimmedThrough: 0, readThrough: 8, latestOwnMessageSequence: 0)
        _ = try await store.commitRoomRecoveryState(state, work: work, now: .now)
        let mixed = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 12, trimmedThrough: 0, readThrough: 7, latestOwnMessageSequence: 0)
        #expect(try await store.commitRoomRecoveryState(mixed, work: work, now: .now) == .reconcile)
        #expect(try await store.roomSynchronizationState(roomID: room, scope: scope) == state)
        try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_room_membership_states VALUES (?, 2, 'removed', 0)", arguments: [room.rawValue]) }
        #expect(try await store.roomSynchronizationState(roomID: room, scope: scope) == nil)
        await #expect(throws: V2RoomRecoveryPersistenceError.staleMembership) {
            try await store.commitRoomRecoveryState(state, work: work, now: .now)
        }
        await #expect(throws: V2RoomRecoveryPersistenceError.staleMembership) {
            try await store.applyRoomRecoveryPage(.init(roomID: room, events: [], nextRoomSequence: 10, hasMore: false), work: work)
        }
        let cursorCount = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_event_cursors") }
        #expect(cursorCount == 0)
    }

    @Test func fairnessAndRetryUsePersistentAgeAndCapturedRevision() async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let cold = RoomID(uuid: UUID()), hot = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: cold, targetHead: 1, priority: 0, scope: scope, now: .init(timeIntervalSince1970: 1))
        try await store.enqueueRoomRecovery(roomID: hot, targetHead: 1, priority: 2, scope: scope, now: .init(timeIntervalSince1970: 2))
        let urgent = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: false, now: .now)
        #expect(urgent.first?.roomID == hot)
        let fair = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
        let old = try #require(fair.first)
        #expect(old.roomID == cold)
        try await store.enqueueRoomRecovery(roomID: cold, targetHead: 2, priority: 0, scope: scope, now: .now)
        try await store.retryRoomRecoveryWork(old, at: .distantFuture)
        let current = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
        #expect(current.first?.roomID == cold)
        #expect(current.first?.enqueuedAt == .init(timeIntervalSince1970: 1))
    }

    @Test func serviceOrderSurvivesNewNotificationsAndReopen() async throws {
        let (store, url, binding, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let hot = RoomID(uuid: UUID()), cold = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: hot, targetHead: 100, priority: 2, scope: scope, now: .init(timeIntervalSince1970: 1))
        try await store.enqueueRoomRecovery(roomID: cold, targetHead: 100, priority: 0, scope: scope, now: .init(timeIntervalSince1970: 2))
        let selected = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
        var work = try #require(selected.first)
        #expect(work.roomID == hot)
        let state = try V2RoomSynchronizationState(roomID: hot, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 100, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        _ = try await store.commitRoomRecoveryState(state, work: work, now: .now)
        work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 100, oldestFirst: false, now: .now).first(where: { $0.roomID == hot }))
        try await store.enqueueRoomRecovery(roomID: hot, targetHead: 101, priority: 2, scope: scope, now: .now)
        _ = try await store.applyRoomRecoveryPage(.init(roomID: hot, events: [], nextRoomSequence: 1, hasMore: true), work: work)
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let fresh = try await reopened.beginRoomRecoveryScan(userID: user)
        let fair = try await reopened.roomRecoveryWork(scope: fresh, limit: 1, oldestFirst: true, now: .now)
        #expect(fair.first?.roomID == cold)
        let priority = try await reopened.roomRecoveryWork(scope: fresh, limit: 1, oldestFirst: false, now: .now)
        #expect(priority.first?.roomID == hot)
    }

    @Test(arguments: [0, 1, 2, 3])
    func unavailableIsConditionalAndPreservesContentCursor(intervening: Int) async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let room = RoomID(uuid: UUID())
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 8, priority: 1, scope: scope, now: .now)
        let initial = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: false, now: .now)
        var first = try #require(initial.first)
        let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
            head: 8, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
        _ = try await store.commitRoomRecoveryState(state, work: first, now: .now)
        first = try #require(try await store.roomRecoveryWork(scope: scope, limit: 100, oldestFirst: false, now: .now).first(where: { $0.roomID == room }))
        try await store.enqueueRoomRecovery(roomID: room, targetHead: 9, priority: 1, scope: scope, now: .now)
        _ = try await store.applyRoomRecoveryPage(.init(roomID: room, events: [], nextRoomSequence: 8, hasMore: false), work: first)
        let selected = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: false, now: .now)
        let work = try #require(selected.first)
        switch intervening {
        case 1:
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 10, priority: 1, scope: scope, now: .now)
        case 2:
            try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_room_membership_states VALUES (?, 3, 'rejoined', 1)", arguments: [room.rawValue]) }
        case 3:
            let newer = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1,
                head: 10, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
            _ = try await store.commitRoomRecoveryState(newer, work: work, now: .now)
        default: break
        }
        #expect(try await store.commitRoomRecoveryUnavailable(work) == (intervening == 0))
        #expect(try await store.groupEventCursor(roomID: room) == 8)
        let remaining = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: false, now: .now)
        #expect(remaining.isEmpty == (intervening == 0))
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func completionRequiresTheSameRoundAndAcknowledgedPersonalCheckpoint(change: Int) async throws {
        let (store, _, _, user) = try fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        try await store.databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO v2_sync_cursor (singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
                VALUES (1, 'ready', 1, 7, 7, 'checkpoint')
                """)
        }
        let page = try V2ClientUserRoomPage(rooms: [], nextCursor: nil, topologyGeneration: "one")
        try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        let captured = try await store.roomRecoveryCompletionCandidate(scope: scope)
        let candidate = try #require(captured)
        switch change {
        case 1:
            try await store.enqueueRoomRecovery(roomID: .init(uuid: UUID()), targetHead: 1, priority: 0, scope: scope, now: .now)
            let pending = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now)
            let work = try #require(pending.first)
            try await store.retryRoomRecoveryWork(work, at: .distantFuture)
            let progress = try await store.roomRecoveryProgress(scope: scope)
            #expect(progress.pendingRoomCount == 1 && progress.nextAttemptAt == .distantFuture)
            #expect(try await store.roomRecoveryCompletionCandidate(scope: scope) == nil)
        case 2:
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET generation = 2") }
        case 3:
            try await store.restartRoomRecoveryDirectory(scope: scope)
            try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: .now)
        case 4:
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET applied_sequence = 8, pending_ack_receipt = 'receipt', pending_ack_sequence = 8") }
        case 5:
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET applied_sequence = 8, server_acknowledged_sequence = 8") }
        default: break
        }
        #expect(try await store.verifyRoomRecoveryCompletion(candidate, personalAppliedThrough: change == 4 ? 8 : 7) == (change == 0))
    }

    private func fixture() throws -> (GRDBV2LocalSyncStore, URL, V2LocalInstallationBinding, UserID) {
        let url = FileManager.default.temporaryDirectory.appending(path: "room-recovery-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        return (store, url, binding, user)
    }
}
