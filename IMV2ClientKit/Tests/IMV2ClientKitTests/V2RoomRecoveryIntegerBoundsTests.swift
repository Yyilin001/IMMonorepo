import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2RoomRecoveryIntegerBoundsTests {
    @Test(arguments: [false, true], [Double.infinity, -Double.infinity])
    func recoveryProgressRejectsNonFiniteRetryDates(withHealthyRoom: Bool, value: Double) async throws {
        try await withStore { store, scope in
            let now = Date(timeIntervalSince1970: 100), room = RoomID(uuid: UUID())
            #expect(try await store.roomRecoveryProgress(scope: scope).nextAttemptAt == nil)
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: scope, now: now)
            if withHealthyRoom { try await store.enqueueRoomRecovery(roomID: .init(uuid: UUID()), targetHead: 1, priority: 0, scope: scope, now: now) }
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = ? WHERE room_id = ?", arguments: [value, room.rawValue]) }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { _ = try await store.roomRecoveryProgress(scope: scope) }
            #expect(try await store.databasePool.read { try Double.fetchOne($0, sql: "SELECT next_attempt_at FROM v2_room_recovery_work WHERE room_id = ?", arguments: [room.rawValue]) } == value)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = -0.5 WHERE room_id = ?", arguments: [room.rawValue]) }
            let progress = try await store.roomRecoveryProgress(scope: scope)
            #expect(progress.pendingRoomCount == (withHealthyRoom ? 2 : 1))
            #expect(progress.nextAttemptAt == Date(timeIntervalSince1970: -0.5))
        }
    }

    @Test(arguments: [false, true], ["text", "blob"])
    func recoveryProgressRejectsNonNumericRetryDates(withHealthyRoom: Bool, kind: String) async throws {
        try await withStore { store, scope in
            let now = Date(timeIntervalSince1970: 100), room = RoomID(uuid: UUID())
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: scope, now: now)
            if withHealthyRoom { try await store.enqueueRoomRecovery(roomID: .init(uuid: UUID()), targetHead: 1, priority: 0, scope: scope, now: now) }
            try await store.databasePool.write { db in
                if kind == "text" {
                    try db.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = 'invalid-date' WHERE room_id = ?", arguments: [room.rawValue])
                } else {
                    try db.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = X'0102' WHERE room_id = ?", arguments: [room.rawValue])
                }
            }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { _ = try await store.roomRecoveryProgress(scope: scope) }
            #expect(try await store.databasePool.read { try String.fetchOne($0, sql: "SELECT typeof(next_attempt_at) FROM v2_room_recovery_work WHERE room_id = ?", arguments: [room.rawValue]) } == kind)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = 200 WHERE room_id = ?", arguments: [room.rawValue]) }
            let progress = try await store.roomRecoveryProgress(scope: scope)
            #expect(progress.pendingRoomCount == (withHealthyRoom ? 2 : 1))
            #expect(progress.nextAttemptAt == Date(timeIntervalSince1970: withHealthyRoom ? 100 : 200))
        }
    }

    @Test(arguments: ["enqueue", "retry"], ["enqueued_at", "next_attempt_at"])
    func recoveryWorkRejectsInvalidStoredDates(action: String, column: String) async throws {
        for value in [Double.infinity, -Double.infinity] {
            try await withStore { store, scope in
                let room = RoomID(uuid: UUID()), now = Date(timeIntervalSince1970: 100)
                try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: scope, now: now)
                let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
                try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET \(column) = ?", arguments: [value]) }
                await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                    if action == "enqueue" {
                        try await store.enqueueRoomRecovery(roomID: room, targetHead: 2, priority: 1, scope: scope, now: now)
                    } else { try await store.retryRoomRecoveryWork(work, at: now) }
                }
                #expect(try await store.databasePool.read { try Double.fetchOne($0, sql: "SELECT \(column) FROM v2_room_recovery_work") } == value)
                #expect(try await store.databasePool.read { try String.fetchOne($0, sql: "SELECT request_revision FROM v2_room_recovery_work") } == work.requestRevision.uuidString)
                #expect(try await store.databasePool.read { try Int64.fetchOne($0, sql: "SELECT service_sequence FROM v2_room_recovery_scan") } == 0)
                try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET \(column) = 100") }
                try await store.retryRoomRecoveryWork(work, at: now)
                #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).count == 1)
            }
        }
    }

    @Test(arguments: [false, true])
    func recoveryWorkRejectsNonNumericEnqueueDate(oldestFirst: Bool) async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID()), now = Date(timeIntervalSince1970: 100)
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: scope, now: now)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET enqueued_at = 'invalid-date'") }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                _ = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: oldestFirst, now: now)
            }
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET enqueued_at = -0.5") }
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: oldestFirst, now: now).first?.enqueuedAt == Date(timeIntervalSince1970: -0.5))
        }
    }

    @Test(arguments: ["same", "user", "binding"], [Int64(7), Int64.max])
    func scanReplacementPreservesOnlySameAccountFairness(change: String, counter: Int64) async throws {
        try await withStore { store, scope in
            let oldRoom = RoomID(uuid: UUID()), now = Date(timeIntervalSince1970: 100)
            try await store.enqueueRoomRecovery(roomID: oldRoom, targetHead: 1, priority: 0, scope: scope, now: now)
            let user = change == "user" ? UserID(uuid: UUID()) : scope.userID
            try await store.databasePool.write { db in
                try db.execute(sql: "UPDATE v2_room_recovery_scan SET service_sequence = ?", arguments: [counter])
                try db.execute(sql: "UPDATE v2_room_recovery_work SET last_served_order = ?", arguments: [counter])
                if change == "user" { try db.execute(sql: "UPDATE v2_local_installation SET user_id = ?", arguments: [user.rawValue]) }
                if change == "binding" { try db.execute(sql: "UPDATE v2_local_installation SET binding = ?", arguments: [UUID().uuidString]) }
            }
            let renewed = try await store.beginRoomRecoveryScan(userID: user)
            await #expect(throws: V2RoomRecoveryPersistenceError.staleScope) { _ = try await store.roomRecoveryScan(scope: scope) }
            let state = try await store.databasePool.read { db in
                let sequence = try Int64.fetchOne(db, sql: "SELECT service_sequence FROM v2_room_recovery_scan")
                let workCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_recovery_work")
                return (sequence, workCount)
            }
            #expect(state.0 == (change == "same" ? counter : 0))
            #expect(state.1 == (change == "same" ? 1 : 0))
            let room = RoomID(uuid: UUID())
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: renewed, now: now)
            let work = try #require(try await store.roomRecoveryWork(scope: renewed, limit: 10, oldestFirst: true, now: now).first(where: { $0.roomID == room }))
            if change == "same" && counter == Int64.max {
                await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { try await store.retryRoomRecoveryWork(work, at: now) }
            } else {
                try await store.retryRoomRecoveryWork(work, at: now)
                #expect(try await store.databasePool.read { try Int64.fetchOne($0, sql: "SELECT service_sequence FROM v2_room_recovery_scan") } == (change == "same" ? counter + 1 : 1))
            }
        }
    }

    @Test(arguments: ["personal_generation", "owner_epoch", "membership_revision"], [1.5, 9_223_372_036_854_775_808.0])
    func directoryPageRejectsCorruptCachedSummaryBeforeComparing(column: String, value: Double) async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID()), first = RoomID(uuid: UUID()), now = Date(timeIntervalSince1970: 100)
            try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token) VALUES (1, 'ready', 1, 0, 0, 'initial')") }
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            let cached = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 30, latest: nil)
            #expect(try await store.commitRoomLatestVisible(cached, request: request))
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_latest_visible SET \(column) = ?", arguments: [value]) }
            let page = try V2ClientUserRoomPage(rooms: [first, room].map { try .init(roomID: $0, kind: .group, viewerMembershipRevision: 1, ownerEpoch: 1) }, nextCursor: "next", topologyGeneration: "topology")
            let before = try await store.roomRecoveryScan(scope: scope)
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: now) }
            let after = try await store.roomRecoveryScan(scope: scope)
            #expect(after.cursor == before.cursor && after.topologyGeneration == before.topologyGeneration && after.directoryComplete == before.directoryComplete)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 0)
            #expect(try await store.databasePool.read { try Double.fetchOne($0, sql: "SELECT \(column) FROM v2_room_latest_visible") } == value)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_latest_visible SET \(column) = 1") }
            try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: nil, request: try await store.roomRecoveryScan(scope: scope), now: now)
            #expect(try await store.roomRecoveryScan(scope: scope).cursor == "next")
            let work = try await store.roomRecoveryWork(scope: scope, limit: 10, oldestFirst: true, now: now)
            #expect(work.count == 2)
            #expect(work.first(where: { $0.roomID == room })?.requiresSummary == false)
            #expect(work.first(where: { $0.roomID == first })?.requiresSummary == true)
        }
    }

    @Test(arguments: ["target_head", "applied_room_sequence"], [1.5, 9_223_372_036_854_775_808.0])
    func recoveryCompletionValidatesComparisonInputs(column: String, value: Double) async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID()), now = Date(timeIntervalSince1970: 100)
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 30, priority: 0, scope: scope, now: now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
            let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1, viewerMembershipRevision: 1, head: 30, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
            _ = try await store.commitRoomRecoveryState(state, work: work, now: now)
            try await store.applyGroupEventPage(.init(roomID: room, events: [], nextRoomSequence: 30, hasMore: false))
            let table = column == "target_head" ? "v2_room_recovery_work" : "v2_group_event_cursors"
            try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value]) }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { _ = try await store.finishRoomRecoveryWork(work) }
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 1)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = 30") }
            #expect(try await store.finishRoomRecoveryWork(work))
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 0)
        }
    }

    @Test(arguments: ["read", "enqueue", "ensure", "state", "summary", "retry"],
          [("target_head", 1.5), ("target_head", 9_223_372_036_854_775_808.0),
           ("priority", 1.5), ("last_served_order", 1.5), ("last_served_order", 9_223_372_036_854_775_808.0),
           ("directory_membership_revision", 1.5), ("directory_membership_revision", 9_223_372_036_854_775_808.0),
           ("directory_owner_epoch", 1.5), ("directory_owner_epoch", 9_223_372_036_854_775_808.0)])
    func recoveryWorkIntegersCannotBeHiddenByMerge(action: String, field: (String, Double)) async throws {
        let (column, value) = field
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID()), now = Date(timeIntervalSince1970: 100)
            try await store.databasePool.write { try $0.execute(sql: "INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token) VALUES (1, 'ready', 1, 0, 0, 'initial')") }
            try await store.enqueueRoomLatestVisible(roomID: room, scope: scope, now: now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 2, viewerMembershipRevision: 2, head: 30, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
            let summary = try V2RoomLatestVisible(roomID: room, ownerEpoch: 2, membershipRevision: 2, head: 30, latest: nil)
            let original = try await store.databasePool.write { db in
                let original = try Int64.fetchOne(db, sql: "SELECT \(column) FROM v2_room_recovery_work")
                try db.execute(sql: "UPDATE v2_room_recovery_work SET \(column) = ?", arguments: [value])
                return original
            }
            func apply() async throws {
                switch action {
                case "read": _ = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now)
                case "enqueue": try await store.enqueueRoomRecovery(roomID: room, targetHead: 30, priority: 2, scope: scope, now: now)
                case "ensure": try await store.ensureRoomLatestVisible(roomID: room, scope: scope, now: now)
                case "retry": try await store.retryRoomRecoveryWork(work, at: now)
                case "state": _ = try await store.commitRoomRecoveryState(state, work: work, now: now)
                default: _ = try await store.commitRoomLatestVisible(summary, request: request, work: work)
                }
            }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { try await apply() }
            let persisted = try await store.databasePool.read { db in
                let raw = try Double.fetchOne(db, sql: "SELECT \(column) FROM v2_room_recovery_work")
                let revision = try String.fetchOne(db, sql: "SELECT request_revision FROM v2_room_recovery_work")
                let needsState = try Bool.fetchOne(db, sql: "SELECT requires_state FROM v2_room_recovery_work")
                let needsSummary = try Bool.fetchOne(db, sql: "SELECT requires_summary FROM v2_room_recovery_work")
                let states = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_sync_states")
                let summaries = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_latest_visible")
                return (raw, revision, needsState, needsSummary, states, summaries)
            }
            #expect(persisted.0 == value)
            #expect(persisted.1 == work.requestRevision.uuidString)
            #expect(persisted.2 == true && persisted.3 == true)
            #expect(persisted.4 == 0 && persisted.5 == 0)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET \(column) = ?", arguments: [original]) }
            try await apply()
        }
    }

    @Test(arguments: [1.5, 9_223_372_036_854_775_808.0], [false, true])
    func latestVisibleRejectsInvalidSequenceHiddenBelowMaximum(value: Double, unrelated: Bool) async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID()), other = RoomID(uuid: UUID())
            let corruptMessage = MessageID(uuid: UUID())
            try await store.databasePool.write { db in
                try db.execute(sql: "INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token) VALUES (1, 'ready', 1, 0, 0, 'initial')")
                for (id, sequence, destination) in [(corruptMessage.rawValue, 10, unrelated ? other.rawValue : room.rawValue), (MessageID(uuid: UUID()).rawValue, 20, room.rawValue)] {
                    try db.execute(sql: "INSERT INTO v2_message_projections(message_id, source_event_id, room_id, room_sequence, message_revision, sender_user_id, text_body, server_created_at, timeline_sequence) VALUES (?, ?, ?, ?, 1, ?, 'local', 100, ?)", arguments: [id, UUID().uuidString, destination, sequence, UserID(uuid: UUID()).rawValue, sequence])
                }
            }
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            let initial = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 30, latest: nil)
            #expect(try await store.commitRoomLatestVisible(initial, request: request))
            try await store.enqueueRoomLatestVisible(roomID: room, scope: scope, now: .now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_message_projections SET room_sequence = ? WHERE message_id = ?", arguments: [value, corruptMessage.rawValue]) }
            let next = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 31, latest: nil)
            if unrelated {
                #expect(try await store.roomLatestVisible(roomID: room, scope: scope) == initial)
                #expect(try await store.commitRoomLatestVisible(next, request: request, work: work))
            } else {
                if value == 1.5 {
                    await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { _ = try await store.roomLatestVisible(roomID: room, scope: scope) }
                }
                await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) { _ = try await store.commitRoomLatestVisible(next, request: request, work: work) }
                let pending = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: .now).first)
                #expect(pending.requiresSummary && pending.requestRevision == work.requestRevision)
            }
            let raw = try await store.databasePool.read { try Double.fetchOne($0, sql: "SELECT room_sequence FROM v2_message_projections WHERE message_id = ?", arguments: [corruptMessage.rawValue]) }
            #expect(raw == value)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_message_projections SET room_sequence = 10 WHERE message_id = ?", arguments: [corruptMessage.rawValue]) }
            #expect(try await store.commitRoomLatestVisible(next, request: request, work: work))
            #expect(try await store.roomLatestVisible(roomID: room, scope: scope) == next)
        }
    }

    @Test(arguments: ["applied_room_sequence", "log_trimmed_through_room_sequence"],
          [(1.5, false), (9_223_372_036_854_775_808.0, false), (1.5, true), (9_223_372_036_854_775_808.0, true)])
    func roomPageRejectsCorruptCursorBeforeApplyingEvents(column: String, scenario: (Double, Bool)) async throws {
        let (value, hasEvent) = scenario
        try await withStore { store, _ in
            let room = RoomID(uuid: UUID())
            try await store.applyGroupEventPage(.init(roomID: room, events: [], nextRoomSequence: 20, hasMore: false, logTrimmedThroughRoomSequence: 5))
            let payload = try JSONSerialization.data(withJSONObject: ["event_type": "room.frozen", "room_id": room.rawValue,
                "room_sequence": 30, "actor_user_id": UserID(uuid: UUID()).rawValue, "server_created_at_ms": 1000])
            let event = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 30, projectionKind: "moderation", payload: payload)
            let page = try V2ClientGroupEventPage(roomID: room, events: hasEvent ? [event] : [], nextRoomSequence: 30, hasMore: false, logTrimmedThroughRoomSequence: 25)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_group_event_cursors SET \(column) = ?, history_incomplete = 0", arguments: [value]) }
            await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.applyGroupEventPage(page) }
            let state = try await store.databasePool.read { db in
                let raw = try Double.fetchOne(db, sql: "SELECT \(column) FROM v2_group_event_cursors")
                let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM v2_group_event_cursors")
                let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_group_events")
                let controls = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_room_control_projections")
                let gap = try Bool.fetchOne(db, sql: "SELECT history_incomplete FROM v2_group_event_cursors")
                return (raw, type, events, controls, gap)
            }
            #expect(state.0 == value)
            #expect(state.1 == "real")
            #expect(state.2 == 0 && state.3 == 0)
            #expect(state.4 == false)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_group_event_cursors SET \(column) = ?", arguments: [column == "applied_room_sequence" ? 20 : 5]) }
            try await store.applyGroupEventPage(page)
            #expect(try await store.groupEventCursor(roomID: room) == 30)
            #expect(try await store.roomLogTrimmedThroughSequence(roomID: room) == 25)
            #expect(try await store.databasePool.read { try Bool.fetchOne($0, sql: "SELECT history_incomplete FROM v2_group_event_cursors") } == true)
            try await store.applyGroupEventPage(page)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_events") } == (hasEvent ? 1 : 0))
        }
    }

    @Test func finalServiceSequenceAndExhaustedRetryAreAtomic() async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID())
            let now = Date(timeIntervalSince1970: 100)
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: scope, now: now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
            try await store.databasePool.write {
                try $0.execute(sql: "UPDATE v2_room_recovery_scan SET service_sequence = ?", arguments: [Int64.max - 1])
            }
            let retry = now.addingTimeInterval(10)
            try await store.retryRoomRecoveryWork(work, at: retry)
            let sequence = try await store.databasePool.read {
                try Int64.fetchOne($0, sql: "SELECT last_served_order FROM v2_room_recovery_work")
            }
            #expect(sequence == Int64.max)
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                try await store.retryRoomRecoveryWork(work, at: retry.addingTimeInterval(10))
            }
            let persisted = try await store.databasePool.read { db in
                (try Int64.fetchOne(db, sql: "SELECT service_sequence FROM v2_room_recovery_scan"),
                 try Double.fetchOne(db, sql: "SELECT next_attempt_at FROM v2_room_recovery_work"))
            }
            #expect(persisted.0 == Int64.max)
            #expect(persisted.1 == retry.timeIntervalSince1970)
            let pending = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: retry)
            #expect(pending.first?.requestRevision == work.requestRevision)
        }
    }

    @Test func maximumStateRoundTripsAndInvalidTargetsPreserveWork() async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID())
            let now = Date(timeIntervalSince1970: 100)
            let maximum = UInt64(Int64.max)
            try await store.enqueueRoomRecovery(roomID: room, targetHead: maximum, priority: 0, scope: scope, now: now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
            let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: maximum,
                viewerMembershipRevision: maximum, head: maximum, trimmedThrough: maximum,
                readThrough: maximum, latestOwnMessageSequence: maximum)
            #expect(try await store.commitRoomRecoveryState(state, work: work, now: now) == .advance)
            #expect(try await store.roomSynchronizationState(roomID: room, scope: scope) == state)
            let before = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now)
            for value in [maximum + 1, UInt64.max] {
                await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                    try await store.enqueueRoomRecovery(roomID: room, targetHead: value, priority: 0, scope: scope, now: now)
                }
            }
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now) == before)
            // Test actual schema constraints rather than disabling them to create corrupt rows.
            for column in ["owner_epoch", "membership_revision", "head", "trimmed_through", "read_through", "latest_own_sequence"] {
                await #expect(throws: DatabaseError.self) {
                    try await store.databasePool.write { db in
                        try db.execute(sql: "UPDATE v2_room_sync_states SET \(column) = -1")
                    }
                }
            }
            #expect(try await store.roomSynchronizationState(roomID: room, scope: scope) == state)
        }
    }

    @Test(arguments: ["owner_epoch", "membership_revision", "head", "target_head", "service_sequence"],
          [1.5, Double(Int64.max)])
    func nonintegerStorageFailsWithoutMutation(column: String, value: Double) async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID())
            let now = Date(timeIntervalSince1970: 100)
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: scope, now: now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
            let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
            _ = try await store.commitRoomRecoveryState(state, work: work, now: now)
            let table = column == "target_head" ? "v2_room_recovery_work"
                : column == "service_sequence" ? "v2_room_recovery_scan" : "v2_room_sync_states"
            // These writes pass the real schema; no constraints are disabled.
            try await store.databasePool.write {
                try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value])
            }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                if column == "service_sequence" {
                    try await store.retryRoomRecoveryWork(work, at: now.addingTimeInterval(10))
                } else if column == "target_head" {
                    _ = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now)
                } else {
                    _ = try await store.roomSynchronizationState(roomID: room, scope: scope)
                }
            }
            let persisted = try await store.databasePool.read {
                (try Double.fetchOne($0, sql: "SELECT \(column) FROM \(table)"),
                 try String.fetchOne($0, sql: "SELECT typeof(\(column)) FROM \(table)"),
                 try Double.fetchOne($0, sql: "SELECT next_attempt_at FROM v2_room_recovery_work"))
            }
            #expect(persisted.0 == value && persisted.1 == "real")
            #expect(persisted.2 == now.timeIntervalSince1970)
            try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = 1") }
            #expect(try await store.roomSynchronizationState(roomID: room, scope: scope) == state)
            #expect(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).count == 1)
        }
    }

    @Test(arguments: [1.5, Double(Int64.max)])
    func malformedMembershipCannotAuthorizeOrDeleteWork(value: Double) async throws {
        try await withStore { store, scope in
            let room = RoomID(uuid: UUID())
            let now = Date(timeIntervalSince1970: 100)
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 1, priority: 0, scope: scope, now: now)
            let work = try #require(try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now).first)
            let state = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 1,
                viewerMembershipRevision: 1, head: 1, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
            _ = try await store.commitRoomRecoveryState(state, work: work, now: now)
            try await store.databasePool.write {
                try $0.execute(sql: "INSERT INTO v2_room_membership_states VALUES (?, ?, 'source', 1)", arguments: [room.rawValue, value])
            }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                _ = try await store.roomSynchronizationState(roomID: room, scope: scope)
            }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                _ = try await store.roomRecoveryWork(scope: scope, limit: 1, oldestFirst: true, now: now)
            }
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                _ = try await store.commitRoomRecoveryUnavailable(work)
            }
            let summary = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 1, head: 1, latest: nil)
            await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
                _ = try await store.databasePool.read { try GRDBV2LocalSyncStore.latestVisibleIsCurrent(summary, db: $0) }
            }
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 1)
        }
    }

    @Test(arguments: ["owner_epoch", "membership_revision", "head", "message_sequence", "message_revision", "media_count"],
          [1.5, Double(Int64.max)])
    func summaryDecoderRejectsRealIntegers(column: String, value: Double) throws {
        var fields: [String: (any DatabaseValueConvertible)?] = [
            "room_id": UUID().uuidString, "owner_epoch": 1, "membership_revision": 1, "head": Int64.max,
            "message_id": UUID().uuidString, "sender_id": UUID().uuidString,
            "message_sequence": 1, "message_revision": 1, "preview": "test", "media_count": 0,
            "created_at_reference": 100.0
        ]
        fields[column] = value
        #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
            _ = try GRDBV2LocalSyncStore.decodeLatestVisible(Row(fields))
        }
    }

    private func withStore(_ body: (GRDBV2LocalSyncStore, V2RoomRecoveryScope) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "recovery-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        do {
            let scope = try await store.beginRoomRecoveryScan(userID: user)
            try await body(store, scope)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}
