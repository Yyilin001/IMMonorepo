import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing
import Synchronization

@Suite("Room recovery budget driver", .timeLimit(.minutes(1)))
struct V2RoomRecoveryEngineTests {
    @Test(arguments: ["state", "content"], [false, true])
    func rejoinPreservesNewWorkWhenOldRecoveryResponseArrives(stage: String, nonempty: Bool) async throws {
        let (store, wire, engine, user) = try await fixture()
        let room = wire.rooms[0]
        let oldMessage = MessageID(uuid: UUID()), newMessage = MessageID(uuid: UUID())
        func event(message: MessageID, sequence: UInt64, text: String) throws -> V2ClientGroupEvent {
            try .init(sourceEventID: .init(uuid: UUID()), roomSequence: sequence, projectionKind: "message",
                payload: JSONSerialization.data(withJSONObject: ["event_type": "message.accepted", "room_id": room.rawValue,
                    "room_sequence": sequence, "message_id": message.rawValue, "message_revision": 1,
                    "sender_user_id": user.rawValue, "text": text, "server_created_at_ms": 1_750_000_000_000]))
        }
        let oldEvents = nonempty ? [try event(message: oldMessage, sequence: 1, text: "old membership response")] : []
        let newEvents = nonempty ? [try event(message: newMessage, sequence: 5, text: "new membership response")] : []
        await wire.setEvents(oldEvents, room: room)
        let newRequest = Mutex<String?>(nil)
        await wire.interceptResponse(at: stage) {
            let old = try await store.databasePool.read { try String.fetchOne($0, sql: "SELECT request_revision FROM v2_room_recovery_work WHERE room_id = ?", arguments: [room.rawValue]) }
            let records = try [(UInt64(1), 2, "remove"), (UInt64(2), 3, "add")].map { sequence, revision, action in
                try V2ClientSyncRecord(sequence: sequence, sourceEventID: .init(UUID().uuidString), projectionKind: "membership",
                    payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                        "membership_revision": revision, "target_user_id": user.rawValue, "action": action,
                        "title": "Rejoined", "owner_user_id": user.rawValue, "capacity_class": "standard",
                        "created_at_ms": 1000, "server_created_at_ms": 2000]))
            }
            _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("rejoined"),
                receipt: .init("receipt"), hasMore: false, capabilityProfile: "base"))
            let fresh = try #require(try await store.databasePool.read { try String.fetchOne($0, sql: "SELECT request_revision FROM v2_room_recovery_work WHERE room_id = ?", arguments: [room.rawValue]) })
            #expect(fresh != old)
            newRequest.withLock { $0 = fresh }
            await wire.setMembershipRevision(3, room: room)
            await wire.setEvents(newEvents, room: room)
        }
        let personal = RecoveryCompletionDriver { Issue.record("bounded recovery must not claim personal completion") }
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { writer.finish() }
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes), personalSync: personal)
        await #expect(throws: V2RoomRecoveryPersistenceError.staleMembership) {
            _ = try await runner.runBounded(userID: user, maximumPages: 4)
        }
        #expect(await engine.phase == .idle)
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        #expect(try await store.messages(in: room).isEmpty)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_events WHERE room_id = ?", arguments: [room.rawValue]) } == 0)
        let retained = try await store.databasePool.read { try String.fetchOne($0, sql: "SELECT request_revision FROM v2_room_recovery_work WHERE room_id = ?", arguments: [room.rawValue]) }
        #expect(retained == newRequest.withLock { $0 })
        #expect(retained != nil)
        #expect(try await store.databasePool.read { try Int64.fetchOne($0, sql: "SELECT membership_revision FROM v2_room_membership_states WHERE room_id = ? AND is_member = 1", arguments: [room.rawValue]) } == 3)
        let (freshChanges, freshWriter) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { freshWriter.finish() }
        let fresh = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: freshChanges), personalSync: personal)
        let result = try await fresh.runBounded(userID: user, maximumPages: 6)
        #expect(result.processedPageCount > 0 && result.processedPageCount <= 6)
        for room in wire.rooms { #expect(try await store.groupEventCursor(roomID: room) == 5) }
        #expect(try await store.databasePool.read { try Int64.fetchOne($0, sql: "SELECT membership_revision FROM v2_room_sync_states WHERE room_id = ?", arguments: [room.rawValue]) } == 3)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 0)
        #expect(await engine.phase == .idle)
        let messages = try await store.messages(in: room)
        #expect(messages.map(\.messageID) == (nonempty ? [newMessage] : []))
        #expect(!messages.contains(where: { $0.messageID == oldMessage }))
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_events WHERE room_id = ?", arguments: [room.rawValue]) } == (nonempty ? 1 : 0))
        try await store.close()
    }

    @Test(arguments: [false, true], ["state", "content"])
    func membershipRemovalFencesInFlightRecovery(bounded: Bool, stage: String) async throws {
        let (store, wire, engine, user) = try await fixture()
        let room = wire.rooms[0]
        await wire.interceptResponse(at: stage) {
            let removal = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(UUID().uuidString), projectionKind: "membership",
                payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room.rawValue,
                    "membership_revision": 2, "target_user_id": user.rawValue, "action": "remove"]))
            _ = try await store.apply(.init(generation: 1, records: [removal], nextSyncToken: .init("removed"),
                receipt: .init("receipt"), hasMore: false, capabilityProfile: "base"))
        }
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { writer.finish() }
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes),
            personalSync: RecoveryCompletionDriver { Issue.record("revoked recovery must not claim completion") })
        await #expect(throws: V2RoomRecoveryPersistenceError.staleMembership) {
            if bounded { _ = try await runner.runBounded(userID: user, maximumPages: 4) }
            else { try await runner.run(userID: user) }
        }
        #expect(await engine.phase == .idle)
        #expect(await wire.contentPulls == (stage == "content" ? 1 : 0))
        #expect(try await store.groupEventCursor(roomID: room) == 0)
        for table in ["v2_room_sync_states", "v2_room_latest_visible", "v2_room_recovery_work"] {
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table) WHERE room_id = ?", arguments: [room.rawValue]) } == 0)
        }
        let membership = try await store.databasePool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT membership_revision, is_member FROM v2_room_membership_states WHERE room_id = ?", arguments: [room.rawValue])
            return row.map { ($0["membership_revision"] as Int64, $0["is_member"] as Bool) }
        }
        #expect(membership?.0 == 2 && membership?.1 == false)
        try await store.close()
    }

    @Test(arguments: [false, true], ["text", "infinity"])
    func runnerStopsOnInvalidRetryDateAndResumesAfterRepair(bounded: Bool, corruption: String) async throws {
        let (store, wire, engine, user) = try await fixture()
        let scope = try await store.beginRoomRecoveryScan(userID: user)
        let now = Date(timeIntervalSince1970: 10)
        for room in wire.rooms {
            try await store.enqueueRoomRecovery(roomID: room, targetHead: 5, priority: 0, scope: scope, now: now)
        }
        let damagedRoom = wire.rooms[1]
        let original = try await store.databasePool.write { db in
            if corruption == "text" {
                try db.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = 'invalid-date' WHERE room_id = ?", arguments: [damagedRoom.rawValue])
            } else {
                try db.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = ? WHERE room_id = ?", arguments: [Double.infinity, damagedRoom.rawValue])
            }
            return try String.fetchOne(db, sql: "SELECT request_revision FROM v2_room_recovery_work WHERE room_id = ?", arguments: [damagedRoom.rawValue])
        }
        let personal = RecoveryCompletionDriver { Issue.record("invalid or bounded recovery must not claim personal completion") }
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { writer.finish() }
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes), personalSync: personal)
        await #expect(throws: V2RoomRecoveryPersistenceError.invalidWork) {
            if bounded { _ = try await runner.runBounded(userID: user, maximumPages: 4) }
            else { try await runner.run(userID: user) }
        }
        #expect(await engine.phase == .idle)
        #expect(await wire.starts == 1)
        #expect(await wire.directoryCursors.isEmpty)
        #expect(await wire.contentPulls == 0)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 2)
        #expect(try await store.databasePool.read { try String.fetchOne($0, sql: "SELECT request_revision FROM v2_room_recovery_work WHERE room_id = ?", arguments: [damagedRoom.rawValue]) } == original)
        for room in wire.rooms { #expect(try await store.groupEventCursor(roomID: room) == 0) }

        // A runtime reconnect supplies a fresh notification stream. Reuse the
        // stopped engine and durable queue after explicit repair of the bad row.
        try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_room_recovery_work SET next_attempt_at = 10 WHERE room_id = ?", arguments: [damagedRoom.rawValue]) }
        let (freshChanges, freshWriter) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { freshWriter.finish() }
        let fresh = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: freshChanges), personalSync: personal)
        // The later directory page can re-enqueue a room processed from the
        // preexisting queue, so budget for its additional summary verification.
        let result = try await fresh.runBounded(userID: user, maximumPages: 6)
        #expect(result.processedPageCount > 0 && result.processedPageCount <= 6)
        #expect(await wire.starts == 2)
        #expect(await engine.phase == .idle)
        for room in wire.rooms { #expect(try await store.groupEventCursor(roomID: room) == 5) }
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 0)
        try await store.close()
    }

    @Test func overdueIntegrityCheckWaitsForRecoveryCompletion() async throws {
        let (store, wire, engine, user) = try await fixture()
        try await store.databasePool.write { try $0.execute(sql: """
            UPDATE v2_sync_cursor SET applied_sequence = 7, server_acknowledged_sequence = 7
            """) }
        let clock = Mutex(Date(timeIntervalSince1970: 10))
        await wire.setContentFailure(.server(code: "RATE_LIMITED", retryable: true,
            retryAfterSeconds: 2, currentRevision: nil), room: wire.rooms[1])
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { writer.finish() }
        let reachedCompletion = Mutex(false)
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes),
            personalSync: RecoveryCompletionDriver {
                reachedCompletion.withLock { $0 = true }
                // Advancing time during body recovery must not start a second
                // directory before the first round reaches its completion proof.
                #expect(await wire.directoryCursors == [nil, "next"])
                for room in wire.rooms { #expect(try await store.groupEventCursor(roomID: room) == 5) }
                throw RecoveryRunnerFailure.disconnected
            }, now: { clock.withLock { $0 } }, integrityInterval: { 600 }, retrySleep: { _ in
                clock.withLock { $0 = Date(timeIntervalSince1970: 611) }
                await wire.setContentFailure(nil)
            })
        await #expect(throws: RecoveryRunnerFailure.disconnected) { try await runner.run(userID: user) }
        #expect(reachedCompletion.withLock { $0 })
    }

    @Test(arguments: ["RATE_LIMITED", "UNAVAILABLE"], [UInt32(0), UInt32(3)])
    func foregroundRetriesTransientResponseWithoutRestartingCoverage(code: String, seconds: UInt32) async throws {
        let (store, wire, engine, user) = try await fixture()
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT OR REPLACE INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token)
            VALUES (1,'ready',1,7,7,'checkpoint')
            """) }
        await wire.setContentFailure(.server(code: code, retryable: true, retryAfterSeconds: seconds, currentRevision: nil))
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        let delays = Mutex<[TimeInterval]>([])
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes),
            personalSync: RecoveryCompletionDriver { }, retrySleep: { seconds in
                delays.withLock { $0.append(seconds) }
                await wire.setContentFailure(nil)
            })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runner.run(userID: user) }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while await engine.phase != .live {
                    guard ContinuousClock.now < deadline else { throw RecoveryRunnerFailure.disconnected }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        #expect(delays.withLock { $0 } == [TimeInterval(max(1, seconds))])
        #expect(await wire.starts == 1)
        #expect(await wire.directoryCursors == [nil, "next"])
        for room in wire.rooms { #expect(try await store.groupEventCursor(roomID: room) == 5) }
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 0)
        #expect(await engine.phase == .idle)
        writer.finish()
    }

    @Test(arguments: ["listener", "directory", "state", "summary", "personal"])
    func foregroundRetriesEveryRecoveryBoundary(stage: String) async throws {
        let (store, wire, engine, user) = try await fixture()
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT OR REPLACE INTO v2_sync_cursor(singleton,state,generation,applied_sequence,server_acknowledged_sequence,sync_token)
            VALUES (1,'ready',1,7,7,'checkpoint')
            """) }
        await wire.setTransientFailureStage(stage)
        let personalFailed = Mutex(false), delays = Mutex<[TimeInterval]>([])
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes),
            personalSync: RecoveryCompletionDriver {
                if stage == "personal", personalFailed.withLock({ old in
                    if old { return false }; old = true; return true
                }) {
                    throw V2RealtimeTransportError.server(code: "RATE_LIMITED", retryable: true, retryAfterSeconds: 2, currentRevision: nil)
                }
            }, retrySleep: { seconds in delays.withLock { $0.append(seconds) } })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runner.run(userID: user) }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while await engine.phase != .live {
                    guard ContinuousClock.now < deadline else { throw RecoveryRunnerFailure.disconnected }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        #expect(delays.withLock { $0 } == [2])
        #expect(await wire.starts == (stage == "listener" ? 2 : 1))
        #expect(await wire.directoryCursors == (stage == "directory" ? [nil, nil, "next"] : [nil, "next"]))
        for room in wire.rooms { #expect(try await store.groupEventCursor(roomID: room) == 5) }
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") } == 0)
        #expect(await engine.phase == .idle)
        writer.finish()
    }

    @Test func notificationFailureCancelsServerCooldown() async throws {
        let (_, wire, engine, user) = try await fixture()
        await wire.setContentFailure(.server(code: "RATE_LIMITED", retryable: true, retryAfterSeconds: 3600, currentRevision: nil))
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        let (sleeping, entered) = AsyncStream<Void>.makeStream()
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes),
            personalSync: RecoveryCompletionDriver { }, retrySleep: { _ in
                entered.yield(())
                try await Task.sleep(for: .seconds(3600))
            })
        let run = Task { try await runner.run(userID: user) }
        defer { run.cancel(); entered.finish(); writer.finish() }
        var iterator = sleeping.makeAsyncIterator()
        _ = await iterator.next()
        writer.finish(throwing: RecoveryRunnerFailure.disconnected)
        await #expect(throws: RecoveryRunnerFailure.disconnected) { try await run.value }
        #expect(await engine.phase == .idle)
    }

    @Test func continuousHotNotificationsDoNotStarveColdRecovery() async throws {
        let (store, wire, engine, user) = try await fixture()
        let hot = wire.rooms[0], cold = wire.rooms[1]
        await wire.setPageAdvance(1)
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 2, maximumRooms: 0)
        var coldFinishedAt: Int?
        for round in 1...40 {
            let head = UInt64(100 + round)
            await wire.setRoomHead(head, room: hot)
            try await engine.accept(.changed(epoch: wire.epoch, roomID: hot, highWatermark: head))
            let result = try await engine.runBudget(userID: user, maximumDirectoryPages: 0, maximumRooms: 1)
            #expect(result.processedRooms <= 1)
            if try await store.groupEventCursor(roomID: cold) == 5, coldFinishedAt == nil {
                coldFinishedAt = round
            }
        }
        // Five cold pages must receive the reserved every-fourth-round budget.
        #expect(coldFinishedAt != nil && coldFinishedAt! <= 20)
        let hotCursor = try await store.groupEventCursor(roomID: hot)
        // A newer state invalidates its summary and may require another state round.
        // The budget is an upper bound, not a promise of one content page per round.
        #expect(hotCursor > 0)
        let pulls = await wire.contentPulls
        #expect(pulls <= 40)
        #expect(UInt64(pulls) == hotCursor + 5)
        #expect(try await engine.progress().pendingRoomCount == 1)
        await engine.stop()
    }

    @Test func trimmedRecoveryMarksHistoryIncompleteWhileReachingHead() async throws {
        let (store, wire, engine, user) = try await fixture()
        await wire.setTrimmedThrough(3)
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 2)
        for room in wire.rooms {
            #expect(try await store.groupEventCursor(roomID: room) == 5)
            #expect(try await store.roomLogHistoryIsIncomplete(roomID: room))
        }
        #expect(try await engine.progress().pendingRoomCount == 0)
        await engine.stop()
    }

    @Test func contentDenialDoesNotAbortOtherRooms() async throws {
        let (store, wire, engine, user) = try await fixture()
        await wire.setContentFailure(.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil))
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 2)
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_sync_states WHERE room_id = ?", arguments: [wire.rooms[0].rawValue]) } == 0)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 0)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[1]) == 5)
        #expect(try await engine.progress().pendingRoomCount == 0)
        await engine.stop()
    }

    @Test func contentRecoveryRunsIndependentRoomsWithinConfiguredBound() async throws {
        let (store, wire, engine, user) = try await fixture(contentConcurrency: 2)
        await wire.pauseContent()
        let run = Task { try await engine.runBudget(userID: user, maximumDirectoryPages: 2) }
        await wire.waitForConcurrentContentPulls(2)
        #expect(await wire.maximumConcurrentContentPulls == 2)
        await wire.releaseContent()
        let result = try await run.value
        #expect(result.processedRooms == 2)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 5)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[1]) == 5)
        await engine.stop()
    }

    @Test(arguments: ["FORBIDDEN", "UNAVAILABLE"])
    func retryableContentFailureNeverRevokesRoom(code: String) async throws {
        let (store, wire, engine, user) = try await fixture()
        let failure = V2RealtimeTransportError.server(code: code, retryable: true, retryAfterSeconds: 1, currentRevision: nil)
        await wire.setContentFailure(failure)
        await #expect(throws: failure) {
            _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 2)
        }
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_sync_states WHERE room_id = ?", arguments: [wire.rooms[0].rawValue]) } == 1)
        #expect(try await engine.progress().pendingRoomCount > 0)
        await engine.stop()
    }

    @Test func cancelledBoundedRecoveryRetainsCommittedWorkForNextRun() async throws {
        let (store, wire, engine, user) = try await fixture()
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 1, maximumRooms: 0)
        await engine.stop()
        let (events, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { writer.finish() }
        let personal = RecoveryCompletionDriver { Issue.record("Bounded recovery must not perform unlimited personal sync") }
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: events), personalSync: personal)
        await wire.pauseDirectory()
        let running = Task { try await runner.runBounded(userID: user, maximumPages: 4) }
        await wire.waitUntilPaused()
        running.cancel()
        await wire.releaseDirectory()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await engine.phase == .idle)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 0)
        let pending = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(pending == 1)
        let (freshEvents, freshWriter) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        defer { freshWriter.finish() }
        let fresh = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: freshEvents), personalSync: personal)
        let resumed = try await fresh.runBounded(userID: user, maximumPages: 4)
        #expect(resumed.processedPageCount <= 4)
        #expect(await engine.phase == .idle)
        for room in wire.rooms { #expect(try await store.groupEventCursor(roomID: room) == 5) }
        let remaining = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(remaining == 0)
    }

    @Test(arguments: [1, 2, 4])
    func boundedRecoverySpendsOnlyItsPagesAndDrainsConsumer(pages: Int) async throws {
        let (store, wire, engine, user) = try await fixture()
        let (changes, writer) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes),
            personalSync: RecoveryCompletionDriver { Issue.record("bounded recovery must not run unbounded personal catch-up") })
        let result = try await runner.runBounded(userID: user, maximumPages: pages)
        #expect(result.processedPageCount > 0 && result.processedPageCount <= pages)
        #expect(result.stopReason == .pageLimit)
        #expect(await engine.phase == .idle)
        #expect(await wire.starts == 1)
        if pages == 1 {
            #expect(await wire.contentPulls == 0)
            let pending = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
            #expect(pending == 1)
        } else {
            #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 5)
        }
        writer.finish()
    }

    @Test func directoryDiscoversSummariesWithoutVisibleListDemand() async throws {
        let (store, wire, engine, user) = try await fixture()
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 2)
        let count = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_latest_visible") }
        #expect(count == wire.rooms.count)
        let pulls = await wire.summaryPulls
        #expect(pulls > 0)
        try await engine.restartDirectory(userID: user)
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 2)
        #expect(await wire.summaryPulls == pulls)
        #expect(try await engine.progress().pendingRoomCount == 0)
        await engine.stop()
    }

    @Test func requestedSummaryRunsThroughTheOwnedBudget() async throws {
        let (store, wire, engine, user) = try await fixture()
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT OR REPLACE INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        try await engine.prepare(userID: user)
        try await engine.requestLatestVisible(roomIDs: [wire.rooms[0]])
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 0)
        #expect(await wire.summaryPulls == 1)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 5)
        let cached = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_latest_visible") }
        let pending = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(cached == 1 && pending == 0)
        await engine.stop()
    }

    @Test func runnerRechecksDirectoryAndWakesForNotifications() async throws {
        let (store, wire, engine, user) = try await fixture()
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT OR REPLACE INTO v2_sync_cursor (singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 7, 7, 'checkpoint')
            """) }
        let clock = Mutex(Date(timeIntervalSince1970: 10))
        let (changes, changeWriter) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        let (completed, completionWriter) = AsyncStream<Void>.makeStream()
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: changes),
            personalSync: RecoveryCompletionDriver { completionWriter.yield(()) },
            now: { clock.withLock { $0 } }, integrityInterval: { 600 })
        let run = Task { try await runner.run(userID: user) }
        var completions = completed.makeAsyncIterator()
        _ = await completions.next()
        #expect(await wire.directoryCursors == [nil, "next"])
        // Simulate the last source change losing its wake: no notification or
        // disconnect follows, so sequence-gap detection cannot discover it.
        await wire.setRoomHead(7, room: wire.rooms[1])
        #expect(try await store.groupEventCursor(roomID: wire.rooms[1]) == 5)
        clock.withLock { $0 = Date(timeIntervalSince1970: 611) }
        await runner.requestCatchUp()
        _ = await completions.next()
        #expect(await wire.directoryCursors == [nil, "next", nil, "next"])
        #expect(await wire.starts == 1)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[1]) == 7)
        #expect(try await engine.progress().pendingRoomCount == 0)
        await wire.setHead(8)
        changeWriter.yield(.changed(epoch: wire.epoch, roomID: wire.rooms[0], highWatermark: 8))
        _ = await completions.next()
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 8)
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(await engine.phase == .idle)
        changeWriter.finish(); completionWriter.finish()
    }

    @Test(arguments: [false, true])
    func runnerDrainsChildrenOnNotificationFailureOrCancellation(cancel: Bool) async throws {
        let (_, wire, engine, user) = try await fixture()
        let (stream, continuation) = AsyncThrowingStream<V2AccountRoomChange, Error>.makeStream()
        let runner = V2RoomRecoveryRunner(engine: engine, source: RecoveryRunnerSource(stream: stream),
            personalSync: RecoveryCompletionDriver { })
        await wire.pauseDirectory()
        let run = Task { try await runner.run(userID: user) }
        await wire.waitUntilPaused()
        await #expect(throws: V2RoomRecoveryEngineError.concurrentRun) { try await runner.run(userID: user) }
        if cancel { run.cancel() }
        else { continuation.finish(throwing: RecoveryRunnerFailure.disconnected) }
        await wire.releaseDirectory()
        if cancel {
            await #expect(throws: CancellationError.self) { try await run.value }
        } else {
            await #expect(throws: RecoveryRunnerFailure.disconnected) { try await run.value }
        }
        #expect(await engine.phase == .idle)
        continuation.finish()
    }

    @Test func preparingListenerDoesNotDelayConsumptionWithDirectoryOrOldWork() async throws {
        let (store, wire, engine, user) = try await fixture()
        try await engine.prepare(userID: user)
        try await engine.accept(.changed(epoch: wire.epoch, roomID: wire.rooms[0], highWatermark: 5))
        try await engine.prepare(userID: user)
        #expect(await wire.starts == 1)
        #expect(await wire.directoryCursors.isEmpty)
        #expect(await wire.contentPulls == 0)
        let pending = try await store.databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work")
        }
        #expect(pending == 1)
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 0)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 5)
        await engine.stop()
    }

    @Test func preparedListenerKeepsItsAccountAndCoverageBoundary() async throws {
        let (_, wire, engine, user) = try await fixture()
        try await engine.prepare(userID: user)
        await #expect(throws: V2RoomRecoveryPersistenceError.staleScope) {
            try await engine.prepare(userID: UserID(uuid: UUID()))
        }
        await #expect(throws: V2RoomRecoveryEngineError.coverageLost) {
            try await engine.accept(.resyncRequired(epoch: wire.epoch))
        }
        await #expect(throws: V2RoomRecoveryEngineError.coverageLost) {
            try await engine.prepare(userID: user)
        }
        #expect(await wire.starts == 1)
        #expect(await wire.directoryCursors.isEmpty)
        await engine.stop()
    }

    @Test func budgetsResumeAndNotificationsRaiseTargets() async throws {
        let (store, wire, engine, user) = try await fixture()
        let first = try await engine.runBudget(userID: user, maximumDirectoryPages: 1, maximumRooms: 1)
        #expect(first.directoryPages == 1 && first.processedRooms == 1 && !first.directoryComplete)
        let second = try await engine.runBudget(userID: user, maximumDirectoryPages: 1, maximumRooms: 1)
        #expect(second.directoryComplete && second.processedRooms == 1)
        #expect(await wire.starts == 1)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 5)
        await wire.setHead(8)
        try await engine.accept(.changed(epoch: wire.epoch, roomID: wire.rooms[0], highWatermark: 8))
        _ = try await engine.runBudget(userID: user)
        // Invalidation creates a new request; the captured state read cannot finish it.
        _ = try await engine.runBudget(userID: user)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 8)
        #expect(await wire.starts == 1)
        await engine.stop()
    }

    @Test func continuallyNotifiedHotRoomYieldsToColdRoom() async throws {
        let (store, wire, engine, user) = try await fixture()
        await wire.setHead(100)
        await wire.setPageAdvance(1)
        _ = try await engine.runBudget(userID: user, maximumRooms: 1)
        for _ in 0..<3 {
            try await engine.accept(.changed(epoch: wire.epoch, roomID: wire.rooms[0], highWatermark: 100))
            _ = try await engine.runBudget(userID: user, maximumRooms: 1)
        }
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 3)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[1]) == 1)
        await engine.stop()
    }

    @Test func unavailableEndsWorkWithoutPullingContent() async throws {
        let (store, wire, engine, user) = try await fixture()
        await wire.setUnavailable()
        let result = try await engine.runBudget(userID: user)
        #expect(result.processedRooms == 0)
        #expect(await wire.contentPulls == 0)
        let pending = try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_room_recovery_work") }
        #expect(pending == 0)
        await engine.stop()
    }

    @Test func invalidDirectoryCursorRestartsOnTheSameListener() async throws {
        let (store, wire, engine, user) = try await fixture()
        await wire.setHead(100)
        await wire.setPageAdvance(1)
        _ = try await engine.runBudget(userID: user, maximumRooms: 1)
        await wire.resetNextDirectory()
        let reset = try await engine.runBudget(userID: user, maximumRooms: 1)
        #expect(reset.directoryPages == 0 && !reset.directoryComplete)
        _ = try await engine.runBudget(userID: user, maximumRooms: 1)
        #expect(await wire.directoryCursors == [nil, "next", nil])
        #expect(await wire.starts == 1)
        #expect(try await store.groupEventCursor(roomID: wire.rooms[0]) == 3)
        await engine.stop()
    }

    @Test func cancellationCannotCommitALateDirectoryPage() async throws {
        let (_, wire, engine, user) = try await fixture()
        await wire.pauseDirectory()
        let run = Task { try await engine.runBudget(userID: user) }
        await wire.waitUntilPaused()
        await #expect(throws: V2RoomRecoveryEngineError.concurrentRun) { try await engine.runBudget(userID: user) }
        run.cancel()
        await wire.releaseDirectory()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(await wire.contentPulls == 0)
        await engine.stop()
        #expect(await engine.phase == .idle)
    }

    @Test func resyncBoundaryRejectsFurtherBudgetsOnTheOldListener() async throws {
        let (_, wire, engine, user) = try await fixture()
        _ = try await engine.runBudget(userID: user)
        await #expect(throws: V2RoomRecoveryEngineError.coverageLost) { try await engine.accept(.resyncRequired(epoch: wire.epoch)) }
        await #expect(throws: V2RoomRecoveryEngineError.coverageLost) { try await engine.runBudget(userID: user) }
        await engine.stop()
    }

    @Test(arguments: [0, 1, 2])
    func completionRequiresPersonalProofWithoutInterveningChanges(change: Int) async throws {
        let (store, wire, engine, user) = try await fixture()
        _ = try await engine.runBudget(userID: user, maximumDirectoryPages: 2)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT OR REPLACE INTO v2_sync_cursor (singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 7, 7, 'checkpoint')
            """) }
        let driver = RecoveryCompletionDriver {
            if change == 1 {
                try await store.databasePool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET generation = 2") }
            } else if change == 2 {
                try await engine.accept(.changed(epoch: wire.epoch, roomID: wire.rooms[0], highWatermark: 8))
            }
        }
        #expect(try await engine.completeIfCaughtUp(using: driver) == (change == 0))
        if change == 0 {
            #expect(await engine.phase == .live)
            try await engine.accept(.changed(epoch: wire.epoch, roomID: wire.rooms[0], highWatermark: 8))
            #expect(await engine.phase == .catchingUp)
            #expect(try await !engine.completeIfCaughtUp(using: driver))
        } else if change == 1 {
            #expect(await engine.phase == .reconciling)
            _ = try await engine.runBudget(userID: user)
            #expect(await wire.directoryCursors == [nil, "next", nil])
            #expect(await wire.starts == 1)
        } else {
            #expect(await engine.phase == .catchingUp)
        }
        await engine.stop()
    }

    private func fixture(contentConcurrency: Int = 4) async throws -> (GRDBV2LocalSyncStore, RecoveryDriverWire, V2RoomRecoveryEngine, UserID) {
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "recovery-driver-\(UUID()).sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        try await store.databasePool.write { try $0.execute(sql: """
            INSERT INTO v2_sync_cursor(singleton, state, generation, applied_sequence, server_acknowledged_sequence, sync_token)
            VALUES (1, 'ready', 1, 0, 0, 'initial')
            """) }
        let wire = RecoveryDriverWire()
        let group = V2GroupEventSyncEngine(transport: wire, store: store)
        let engine = V2RoomRecoveryEngine(transport: wire, latestVisible: wire, store: store, groupEvents: group,
            contentRecoveryConcurrency: contentConcurrency,
            now: { .init(timeIntervalSince1970: 10) })
        return (store, wire, engine, user)
    }
}

private actor RecoveryDriverWire: V2ClientRoomRecoveryTransport, V2ClientGroupEventTransport, V2ClientRoomLatestVisibleTransport {
    private var eventsByRoom: [RoomID: [V2ClientGroupEvent]] = [:]
    func setEvents(_ events: [V2ClientGroupEvent], room: RoomID) { eventsByRoom[room] = events }
    private var membershipRevisions: [RoomID: UInt64] = [:]
    func setMembershipRevision(_ revision: UInt64, room: RoomID) { membershipRevisions[room] = revision }
    private var responseInterception: (String, @Sendable () async throws -> Void)?
    func interceptResponse(at stage: String, action: @escaping @Sendable () async throws -> Void) {
        responseInterception = (stage, action)
    }
    private func interceptResponseIfNeeded(at stage: String) async throws {
        guard let (expected, action) = responseInterception, expected == stage else { return }
        responseInterception = nil
        try await action()
    }
    private var transientFailureStage: String?
    func setTransientFailureStage(_ stage: String) { transientFailureStage = stage }
    private func failOnce(at stage: String) throws {
        guard transientFailureStage == stage else { return }
        transientFailureStage = nil
        throw V2RealtimeTransportError.server(code: "RATE_LIMITED", retryable: true, retryAfterSeconds: 2, currentRevision: nil)
    }
    private(set) var summaryPulls = 0
    func latestVisible(roomIDs: [RoomID]) throws -> [RoomID: V2ClientRoomLatestVisibleResult] {
        summaryPulls += 1
        try failOnce(at: "summary")
        return try Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, .snapshot(try .init(roomID: $0,
            ownerEpoch: 1, membershipRevision: membershipRevisions[$0] ?? 1, head: roomHeads[$0] ?? head, latest: nil))) })
    }
    nonisolated let epoch = UUID()
    nonisolated let rooms = [RoomID(uuid: UUID()), RoomID(uuid: UUID())]
    private(set) var starts = 0
    private(set) var contentPulls = 0
    private(set) var activeContentPulls = 0
    private(set) var maximumConcurrentContentPulls = 0
    private var contentPaused = false
    private var contentGates: [CheckedContinuation<Void, Never>] = []
    func pauseContent() { contentPaused = true }
    func waitForConcurrentContentPulls(_ count: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while activeContentPulls < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func releaseContent() {
        contentPaused = false
        let gates = contentGates
        contentGates.removeAll()
        gates.forEach { $0.resume() }
    }
    private var contentFailure: V2RealtimeTransportError?
    private var contentFailureRoom: RoomID?
    func setContentFailure(_ error: V2RealtimeTransportError?, room: RoomID? = nil) {
        contentFailure = error
        contentFailureRoom = room
    }
    private var trimmedThrough: UInt64 = 0
    func setTrimmedThrough(_ value: UInt64) { trimmedThrough = value }
    private var head: UInt64 = 5
    private var roomHeads: [RoomID: UInt64] = [:]
    func setRoomHead(_ value: UInt64, room: RoomID) { roomHeads[room] = value }
    private var pageAdvance: UInt64?
    func setPageAdvance(_ value: UInt64) { pageAdvance = value }
    private var unavailable = false
    private var shouldReset = false
    private(set) var directoryCursors: [String?] = []
    func resetNextDirectory() { shouldReset = true }
    private var paused = false
    private var gate: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func setHead(_ value: UInt64) { head = value }
    func setUnavailable() { unavailable = true }
    func pauseDirectory() { paused = true }
    func waitUntilPaused() async {
        if gate != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func releaseDirectory() { gate?.resume(); gate = nil }
    func startAccountRoomChanges() throws -> UUID { starts += 1; try failOnce(at: "listener"); return epoch }
    func userRoomDirectory(cursor: String?, pageSize: Int) async throws -> V2ClientUserRoomPage {
        directoryCursors.append(cursor)
        try failOnce(at: "directory")
        if shouldReset { shouldReset = false; throw V2ClientRoomRecoveryError.directoryResetRequired }
        if paused {
            paused = false
            await withCheckedContinuation { gate = $0; observer?.resume(); observer = nil }
        }
        let index = cursor == nil ? 0 : 1
        return try .init(rooms: [.init(roomID: rooms[index], kind: .group, viewerMembershipRevision: membershipRevisions[rooms[index]] ?? 1, ownerEpoch: 1)],
            nextCursor: index == 0 ? "next" : nil, topologyGeneration: "one")
    }
    func roomSyncStates(roomIDs: [RoomID]) async throws -> [RoomID: V2ClientRoomStateResult] {
        try failOnce(at: "state")
        let response: [RoomID: V2ClientRoomStateResult] = try Dictionary(uniqueKeysWithValues: roomIDs.map { room in
            (room, unavailable ? .unavailable : .state(try .init(roomID: room, ownerEpoch: 1,
                viewerMembershipRevision: membershipRevisions[room] ?? 1, head: roomHeads[room] ?? head, trimmedThrough: trimmedThrough, readThrough: 0, latestOwnMessageSequence: 0)))
        })
        try await interceptResponseIfNeeded(at: "state")
        return response
    }
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage {
        contentPulls += 1
        activeContentPulls += 1
        maximumConcurrentContentPulls = max(maximumConcurrentContentPulls, activeContentPulls)
        if contentPaused { await withCheckedContinuation { contentGates.append($0) } }
        defer { activeContentPulls -= 1 }
        if roomID == (contentFailureRoom ?? rooms[0]), let contentFailure { throw contentFailure }
        let head = roomHeads[roomID] ?? head
        let next = pageAdvance.map { min(head, afterRoomSequence + $0) } ?? head
        let events = (eventsByRoom[roomID] ?? []).filter { $0.roomSequence > afterRoomSequence && $0.roomSequence <= next }
        let response = try V2ClientGroupEventPage(roomID: roomID, events: events, nextRoomSequence: next, hasMore: next < head,
            logTrimmedThroughRoomSequence: trimmedThrough)
        try await interceptResponseIfNeeded(at: "content")
        return response
    }
}

private struct RecoveryCompletionDriver: V2SyncDriving {
    let beforeReturn: @Sendable () async throws -> Void
    func synchronizeUntilCaughtUp() async throws -> V2SyncCycleResult {
        try await beforeReturn()
        return .synchronized(appliedThrough: 7, hasMore: false)
    }
    func completePendingReset() async throws { throw V2RealtimeTransportError.unexpectedResponse }
}

private enum RecoveryRunnerFailure: Error { case disconnected }

private struct RecoveryRunnerSource: V2AccountRoomChangeSource {
    let stream: AsyncThrowingStream<V2AccountRoomChange, Error>
    func nextAccountRoomChange() async throws -> V2AccountRoomChange {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        return value
    }
}
