import Foundation
import Synchronization
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 client sync")
struct V2SyncEngineTests {
    @Test("policy recovery does not truncate fractional persisted counters or fences", arguments: ["attempt_count", "membership_revision", "generation"])
    func fractionalPolicyRecoveryBounds(column: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-policy-fraction-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        do {
            _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
            _ = try await store.enqueueMissingRolePolicyBaselines(limit: 1)
            let request = try #require(try await store.pendingRolePolicyBaselineRequests().first)
            let pool = await store.databasePool
            let original = try await pool.read { try #require(try Int64.fetchOne($0, sql: "SELECT \(column) FROM v2_role_policy_recovery_requests")) }
            let fraction = Double(original) + 0.5
            try await pool.write { try $0.execute(sql: "UPDATE v2_role_policy_recovery_requests SET \(column) = ?", arguments: [fraction]) }
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.pendingRolePolicyBaselineRequests() }
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.dueRolePolicyBaselineRequests(at: Date(timeIntervalSince1970: 1_000)) }
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.recordRolePolicyRecoveryFailure(.pause, for: request) }
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT \(column) FROM v2_role_policy_recovery_requests") } == fraction)
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT state FROM v2_role_policy_recovery_requests") } == "pending")
            try await pool.write { try $0.execute(sql: "UPDATE v2_role_policy_recovery_requests SET \(column) = ?", arguments: [original]) }
            #expect(try await store.pendingRolePolicyBaselineRequests() == [request])
            #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request))
            #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("restored cursor positions reject fractional storage values before conversion", arguments: ["generation", "applied_sequence", "server_acknowledged_sequence", "pending_ack_sequence", "pending_base_sequence"])
    func fractionalCursorBounds(column: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-cursor-fraction-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        do {
            _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
            if column == "pending_base_sequence" {
                try await store.beginReset(.init(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture))
            }
            let before = try await store.cursor()
            let pool = await store.databasePool
            let original = try await pool.read { try #require(try Int64.fetchOne($0, sql: "SELECT \(column) FROM v2_sync_cursor")) }
            let fraction = Double(original) + (column == "pending_ack_sequence" ? -0.5 : 0.5)
            try await pool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET \(column) = ?", arguments: [fraction]) }
            await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.cursor() }
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT \(column) FROM v2_sync_cursor") } == fraction)
            try await pool.write { try $0.execute(sql: "UPDATE v2_sync_cursor SET \(column) = ?", arguments: [original]) }
            #expect(try await store.cursor() == before)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("restored snapshot page index rejects corruption and preserves resumable progress")
    func restoredSnapshotPageIndexBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-snapshot-index-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
            let message = MessageID(uuid: UUID()), room = RoomID(uuid: UUID())
            let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "message", entityKey: message.rawValue), sourceEventID: .init(uuid: UUID()), sequence: 10,
                payload: snapshotMessagePayload(messageID: message.rawValue, roomID: room.rawValue, text: "snapshot", revision: 1, isWithdrawn: false))
            let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
            try await store.beginReset(reset)
            try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
            let pool = await store.databasePool
            let cursor = try await store.cursor()
            for value in [Int64.min, -1, 2, Int64.max] {
                try await pool.write { db in
                    try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                    defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                    try db.execute(sql: "UPDATE v2_snapshot_import SET next_page_index = ?", arguments: [value])
                }
                await #expect(throws: V2ClientSyncError.snapshotMismatch) {
                    _ = try await store.nextSnapshotPageIndex(for: fixture.manifest)
                }
                #expect(try await store.cursor() == cursor)
                #expect(try await pool.read { db in try Int64.fetchOne(db, sql: "SELECT next_page_index FROM v2_snapshot_import") } == value)
            }
            try await pool.write { db in try db.execute(sql: "UPDATE v2_snapshot_import SET next_page_index = 0") }
            #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == 0)
            try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
            #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == fixture.manifest.pageCount)
            try await store.prepareSnapshotActivation(fixture.manifest)
            try await store.activateAcknowledgedSnapshot(fixture.manifest)
            #expect(try await store.cursor()?.appliedSequence == 10)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("snapshot search generation validates before activation and preserves imported progress", arguments: [Int64.min, -1, 0, 1, Int64.max - 1, Int64.max])
    func snapshotSearchGenerationBounds(generation: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-snapshot-search-generation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
            let message = MessageID(uuid: UUID()), room = RoomID(uuid: UUID())
            let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "message", entityKey: message.rawValue), sourceEventID: .init(uuid: UUID()), sequence: 10,
                payload: snapshotMessagePayload(messageID: message.rawValue, roomID: room.rawValue, text: "snapshot", revision: 1, isWithdrawn: false))
            let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
            try await store.beginReset(reset)
            try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
            try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
            let pool = await store.databasePool
            let cursor = try await store.cursor()
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_message_search_state SET generation = ?", arguments: [generation])
            }
            let invalid = generation <= 0 || generation == Int64.max
            if invalid {
                if generation <= 0 {
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.prepareSnapshotActivation(fixture.manifest) }
                } else {
                    await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.prepareSnapshotActivation(fixture.manifest) }
                }
                #expect(try await store.cursor() == cursor)
                #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == 1)
                #expect(try await pool.read { try Int64.fetchOne($0, sql: "SELECT generation FROM v2_message_search_state") } == generation)
                try await pool.write { try $0.execute(sql: "UPDATE v2_message_search_state SET generation = 1") }
            }
            try await store.prepareSnapshotActivation(fixture.manifest)
            try await store.activateAcknowledgedSnapshot(fixture.manifest)
            #expect(try await store.cursor()?.appliedSequence == 10)
            #expect(try await pool.read { try GRDBV2LocalSyncStore.messageSearchIndexGeneration(db: $0) } == (invalid ? 2 : generation + 1))
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("corrupt snapshot counters fail before progress and can resume after repair", arguments: ["apply", "prepare", "activate"], ["applied_items", "applied_bytes"])
    func corruptSnapshotCounters(stage: String, column: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-snapshot-count-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "message", entityKey: message.rawValue), sourceEventID: .init(uuid: UUID()), sequence: 10,
            payload: snapshotMessagePayload(messageID: message.rawValue, roomID: room.rawValue, text: "snapshot", revision: 1, isWithdrawn: false))
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        do {
            try await store.beginReset(reset)
            try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
            if stage != "apply" { try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest) }
            if stage == "activate" { try await store.prepareSnapshotActivation(fixture.manifest) }
            let pool = await store.databasePool
            let before = try await pool.read { db in try #require(try Int64.fetchOne(db, sql: "SELECT \(column) FROM v2_snapshot_import")) }
            let cursor = try await store.cursor()
            for value in [Int64.min, -1] {
                try await pool.write { db in
                    try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                    defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                    try db.execute(sql: "UPDATE v2_snapshot_import SET \(column) = ?", arguments: [value])
                }
                await #expect(throws: V2ClientSyncError.snapshotMismatch) {
                    switch stage {
                    case "apply": try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
                    case "prepare": try await store.prepareSnapshotActivation(fixture.manifest)
                    default: try await store.activateAcknowledgedSnapshot(fixture.manifest)
                    }
                }
                #expect(try await store.cursor() == cursor)
                #expect(try await pool.read { db in try Int64.fetchOne(db, sql: "SELECT \(column) FROM v2_snapshot_import") } == value)
            }
            try await pool.write { db in try db.execute(sql: "UPDATE v2_snapshot_import SET \(column) = ?", arguments: [before]) }
            if stage == "apply" { try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest) }
            try await store.prepareSnapshotActivation(fixture.manifest)
            try await store.activateAcknowledgedSnapshot(fixture.manifest)
            #expect(try await store.cursor()?.generation == 2)
            #expect(try await store.cursor()?.appliedSequence == 10)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("restore time is deducted from the sync deadline and the owned connection drains")
    func backgroundUsesRemainingDeadline() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let batch = try boundedSyncBatch(1, hasMore: false)
        let transport = BoundedSyncProbe(results: [.ready(batch), .ready(batch)], blocksFirstPull: true)
        let connection = BoundedSyncConnection(onDisconnect: { await transport.releasePull() })
        let runner = V2BackgroundSyncRunner(connection: connection, syncEngine: .init(transport: transport, store: store, capabilityProfile: "base"), budget: .init(workDuration: .seconds(30)))
        let started = ContinuousClock.now
        await #expect(throws: V2BackgroundSyncError.deadlineReached) {
            try await runner.run(until: .now.advanced(by: .milliseconds(50)))
        }
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(await connection.disconnects == 1)
        #expect(try await store.cursor() == nil)
        #expect(try await runner.run().didCommitNewRecords)
        #expect(await connection.connects == 2)
        try await store.close()
    }

    @Test("a shorter Push waiter leaves an existing sync owner and the next Push can restart")
    func backgroundJoinedDeadlineDoesNotCancelOwner() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let batch = try boundedSyncBatch(1, hasMore: false)
        let transport = BoundedSyncProbe(results: [.ready(batch), .ready(batch)], blocksFirstPull: true)
        let connection = BoundedSyncConnection()
        let runner = V2BackgroundSyncRunner(connection: connection, syncEngine: .init(transport: transport, store: store, capabilityProfile: "base"))
        let owner = Task { try await runner.run() }
        await transport.waitForBlockedPull()
        await #expect(throws: V2BackgroundSyncError.deadlineReached) {
            try await runner.run(until: .now.advanced(by: .milliseconds(50)))
        }
        #expect(await connection.disconnects == 0)
        #expect(await connection.connects == 1)
        await transport.releasePull()
        #expect(try await owner.value.didCommitNewRecords)
        #expect(try await !runner.run().didCommitNewRecords)
        #expect(await connection.connects == 2)
        try await store.close()
    }

    @Test("personal and room-log background work share a four-page budget")
    func backgroundFeedsSharePageBudget() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let transport = BoundedSyncProbe(results: try [1, 2, 3].map { .ready(try boundedSyncBatch($0, hasMore: true)) })
        let rooms = BackgroundGroupEventStoreFake(roomIDs: try ["room-a", "room-b", "room-c"].map(RoomID.init))
        let roomTransport = BackgroundGroupEventTransportFake()
        let runner = V2BackgroundSyncRunner(connection: BoundedSyncConnection(), syncEngine: .init(transport: transport, store: store, capabilityProfile: "base"), roomSync: .init(transport: roomTransport, store: rooms), budget: .init(maximumPages: 4))
        let result = try await runner.run()
        #expect(result.processedPageCount == 4 && result.didCommitNewRecords && result.stopReason == .pageLimit)
        #expect(await transport.tokens.count == 2)
        #expect(await roomTransport.requestedRoomIDs().count == 2)
        try await store.close()
    }

    @Test("concurrent replay counts only room events inserted by its own SQLite transaction")
    func groupCommitCountExcludesReplay() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let room = try RoomID("00000000-0000-0000-0000-000000000220")
        let page = try V2ClientGroupEventPage(roomID: room, events: [try .init(sourceEventID: .init(uuid: UUID()), roomSequence: 1, projectionKind: "message", payload: messagePayload(text: "one commit"))], nextRoomSequence: 1, hasMore: false)
        async let first = store.applyGroupEventPageReportingChanges(page)
        async let second = store.applyGroupEventPageReportingChanges(page)
        let results = try await [first, second]
        #expect(results.map(\.insertedEventCount).sorted() == [0, 1])
        #expect(results.allSatisfy { $0.appliedThrough == 1 })
        try await store.close()
    }

    @Test("background deadline closes its blocked transport and drains before returning")
    func backgroundDeadlineDrainsOwnedPull() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let transport = BoundedSyncProbe(results: [.ready(try boundedSyncBatch(1, hasMore: false))], blocksFirstPull: true)
        let connection = BoundedSyncConnection(onDisconnect: { await transport.releasePull() })
        let runner = V2BackgroundSyncRunner(connection: connection, syncEngine: .init(transport: transport, store: store, capabilityProfile: "base"), budget: .init(workDuration: .milliseconds(100)))
        let started = ContinuousClock.now
        await #expect(throws: V2BackgroundSyncError.deadlineReached) { try await runner.run() }
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(await connection.disconnects == 1)
        #expect(try await store.cursor() == nil)
        #expect(await transport.acknowledged.isEmpty)
        try await store.close()
    }

    @Test("a background deadline while queued cannot close or cancel the foreground sync")
    func backgroundDeadlinePreservesForegroundOwner() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let gate = V2SyncOperationGate()
        let foregroundWire = BoundedSyncProbe(results: [.ready(try boundedSyncBatch(1, hasMore: false))], blocksFirstPull: true)
        let foreground = V2SyncEngine(transport: foregroundWire, store: store, capabilityProfile: "base", operationGate: gate)
        let owner = Task { try await foreground.synchronizeOnce() }
        await foregroundWire.waitForBlockedPull()
        let backgroundWire = BoundedSyncProbe(results: [])
        let connection = BoundedSyncConnection()
        let runner = V2BackgroundSyncRunner(connection: connection, syncEngine: .init(transport: backgroundWire, store: store, capabilityProfile: "base", operationGate: gate), budget: .init(workDuration: .milliseconds(100)))
        await #expect(throws: V2BackgroundSyncError.deadlineReached) { try await runner.run() }
        #expect(await backgroundWire.tokens.isEmpty)
        #expect(await connection.disconnects == 1)
        #expect(await foregroundWire.acknowledged.isEmpty)
        await foregroundWire.releasePull()
        #expect(try await owner.value == .synchronized(appliedThrough: 1, hasMore: false))
        try await store.close()
    }

    @Test("background stop drains work and permits a fresh bounded operation")
    func backgroundStopThenRestart() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let batch = try boundedSyncBatch(1, hasMore: false)
        let transport = BoundedSyncProbe(results: [.ready(batch), .ready(batch)], blocksFirstPull: true)
        let connection = BoundedSyncConnection(onDisconnect: { await transport.releasePull() })
        let runner = V2BackgroundSyncRunner(connection: connection, syncEngine: .init(transport: transport, store: store, capabilityProfile: "base"))
        let first = Task { try await runner.run() }
        await transport.waitForBlockedPull()
        await runner.stop()
        await #expect(throws: CancellationError.self) { try await first.value }
        let result = try await runner.run()
        #expect(result.didCommitNewRecords && result.stopReason == .caughtUp)
        #expect(await connection.connects == 2)
        try await store.close()
    }

    @Test("incremental work stops at its page budget and resumes from the committed cursor")
    func incrementalPageBudget() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let transport = BoundedSyncProbe(results: try (1...6).map { .ready(try boundedSyncBatch($0, hasMore: $0 < 6)) })
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        let first = try await engine.synchronizeIncrementally(maximumPages: 4)
        #expect(first.processedPageCount == 4 && first.didCommitNewRecords && first.stopReason == .pageLimit)
        #expect(try await store.cursor()?.appliedSequence == 4)
        #expect(await transport.acknowledged == [1, 2, 3, 4])
        let second = try await engine.synchronizeIncrementally(maximumPages: 4)
        #expect(second.processedPageCount == 2 && second.didCommitNewRecords && second.stopReason == .caughtUp)
        #expect(try await store.cursor()?.appliedSequence == 6)
        #expect(await transport.tokens.dropFirst().allSatisfy { $0 != nil })
        try await store.close()
    }

    @Test("bounded incremental work defers reset without fetching snapshot data")
    func incrementalResetIsDeferred() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 0, expiresAt: .distantFuture)
        let transport = BoundedSyncProbe(results: [.resetRequired(reset)])
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        for _ in 0..<2 {
            let result = try await engine.synchronizeIncrementally(maximumPages: 4)
            #expect(result.stopReason == .resetPending && !result.didCommitNewRecords)
        }
        #expect(await transport.tokens.count == 1)
        #expect(await transport.snapshotRequests == 0)
        #expect(try await store.cursor()?.pendingReset == reset)
        try await store.close()
    }

    @Test("an empty successful incremental page does not report new committed records")
    func emptyIncrementalPageHasNoNewData() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let batch = try V2ClientSyncBatch(generation: 1, records: [], nextSyncToken: try .init("empty"), receipt: try .init("empty-receipt"), hasMore: false, capabilityProfile: "base")
        let transport = BoundedSyncProbe(results: [.ready(batch)])
        let result = try await V2SyncEngine(transport: transport, store: store, capabilityProfile: "base").synchronizeIncrementally(maximumPages: 4)
        #expect(!result.didCommitNewRecords && result.stopReason == .caughtUp)
        try await store.close()
    }

    @Test("a cancelled pull returning late cannot commit or ACK its page")
    func cancelledLatePullDoesNotCommit() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let transport = BoundedSyncProbe(results: [.ready(try boundedSyncBatch(1, hasMore: false))], blocksFirstPull: true)
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        let pending = Task { try await engine.synchronizeOnce() }
        await transport.waitForBlockedPull()
        pending.cancel()
        await transport.releasePull()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await store.cursor() == nil)
        #expect(await transport.acknowledged.isEmpty)
        try await store.close()
    }

    @Test("two engines sharing a store serialize cycles and a queued cancellation leaves the owner running")
    func sharedSyncOwnershipAndQueuedCancellation() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let gate = V2SyncOperationGate()
        let transport = BoundedSyncProbe(results: try [1, 2].map { .ready(try boundedSyncBatch($0, hasMore: false)) }, blocksFirstPull: true)
        let foreground = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base", operationGate: gate)
        let background = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base", operationGate: gate)
        let owner = Task { try await foreground.synchronizeOnce() }
        await transport.waitForBlockedPull()
        let queued = Task { try await background.synchronizeIncrementally(maximumPages: 4) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.waitingOperationCount != 1 {
            guard ContinuousClock.now < deadline else {
                queued.cancel(); await transport.releasePull(); _ = await owner.result
                throw BoundedSyncProbe.Failure.waitTimedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await transport.tokens.count == 1)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await gate.waitingOperationCount == 0)
        await transport.releasePull()
        _ = try await owner.value
        _ = try await background.synchronizeOnce()
        #expect(await transport.tokens == [nil, try .init("bounded-token-1")])
        #expect(await transport.acknowledged == [1, 2])
        #expect(try await store.cursor()?.appliedSequence == 2)
        try await store.close()
    }

    @Test("snapshot terminal state accepts its later source event without new search work", arguments: ["personal", "preview", "room"], ["valid", "bad-text", "legacy-reply"])
    func terminalSnapshotReplay(_ feed: String, state: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-terminal-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), origin = EventID(uuid: UUID())
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "message", entityKey: message.rawValue), sourceEventID: origin, sequence: 10, payload: snapshotMessagePayload(messageID: message.rawValue, roomID: room.rawValue, text: "[removed]", revision: 3, isWithdrawn: true))
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        try await store.prepareSnapshotActivation(fixture.manifest)
        try await store.activateAcknowledgedSnapshot(fixture.manifest)
        try await store.close()
        let pool = try DatabasePool(path: url.path)
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM v2_message_search_jobs")
            if state == "bad-text" { try db.execute(sql: "UPDATE v2_message_projections SET text_body='corrupt terminal body'") }
            if state == "legacy-reply" { try db.execute(sql: "UPDATE v2_message_projections SET reply_to_message_id=?", arguments: [UUID().uuidString.lowercased()]) }
        }
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let event = EventID(uuid: UUID())
        let payload = try JSONSerialization.data(withJSONObject: ["event_type":"message.withdrawn", "room_id":room.rawValue, "message_id":message.rawValue, "room_sequence":8, "message_revision":3])
        let page = try V2ClientGroupEventPage(roomID: room, events: [try .init(sourceEventID: event, roomSequence: 8, projectionKind: "message", payload: payload)], nextRoomSequence: 8, hasMore: false)
        let batch = try V2ClientSyncBatch(generation: 2, records: [.init(sequence: 11, sourceEventID: event, projectionKind: "message", payload: payload)], nextSyncToken: .init("terminal"), receipt: .init("terminal-receipt"), hasMore: false, capabilityProfile: "base")
        func apply() async throws {
            switch feed {
            case "personal": _ = try await reopened.apply(batch)
            case "preview": _ = try await reopened.applyForegroundGroupEventPreviewPage(page)
            default: _ = try await reopened.applyGroupEventPage(page)
            }
        }
        if state == "bad-text" {
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await apply() }
            #expect(try await reopened.cursor()?.appliedSequence == 10)
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_effects") } == 0)
        } else {
            try await apply()
            _ = try await reopened.applyForegroundGroupEventPreviewPage(page)
            let value = try #require(await reopened.messages(in: room).first)
            #expect(value.isWithdrawn && value.messageRevision == 3 && value.text == "[removed]" && value.replyTo == nil)
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_effects") } == 1)
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_search_jobs") } == 0)
        }
        try await pool.close(); try await reopened.close()
    }

    @Test("ordinary withdrawal removes reply references together with content")
    func terminalContentReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-terminal-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        var original = try #require(JSONSerialization.jsonObject(with: messagePayload(text: "quoted text")) as? [String: Any])
        original["reply_to_message_id"] = UUID().uuidString
        let room = try RoomID(#require(original["room_id"] as? String))
        let removal = try JSONSerialization.data(withJSONObject: ["event_type":"message.withdrawn", "room_id":room.rawValue, "message_id":original["message_id"]!, "message_revision":3])
        _ = try await store.applyGroupEventPage(.init(roomID: room, events: [
            .init(sourceEventID: .init(uuid: UUID()), roomSequence: 1, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: original)),
            .init(sourceEventID: .init(uuid: UUID()), roomSequence: 3, projectionKind: "message", payload: removal)], nextRoomSequence: 3, hasMore: false))
        #expect(try await store.messages(in: room).first?.replyTo == nil)
        try await store.close()
    }


    @Test("complete replacement retains attachments, mentions and references without duplicate search work")
    func completeEditReplacementRichContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-replacement-rich-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let origin = EventID(uuid: UUID()), eventID = EventID(uuid: UUID())
        let media = UUID().uuidString, mentioned = UUID().uuidString, reply = UUID().uuidString
        let forwardedMessage = UUID().uuidString, forwardedUser = UUID().uuidString
        var body = try #require(JSONSerialization.jsonObject(with: completeEditPayload(origin: origin.rawValue)) as? [String: Any])
        var replacement = try #require(body["replacement"] as? [String: Any])
        var state = try #require(replacement["state"] as? [String: Any])
        state["media_ids"] = [media]
        state["media_presentations"] = [["media_id":media, "kind":"image", "content_type":"image/jpeg", "byte_count":256]]
        state["mention_user_ids"] = [mentioned]
        state["reply_to_message_id"] = reply
        state["forwarded_from_message_id"] = forwardedMessage
        state["forwarded_from_user_id"] = forwardedUser
        replacement["state"] = state; body["replacement"] = replacement
        let room = try RoomID(#require(state["room_id"] as? String))
        var original = state; original["message_revision"] = 1; original["text"] = "original attachment text"
        _ = try await store.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: origin, roomSequence: 1, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: original))], nextRoomSequence: 1, hasMore: false))
        let page = try V2ClientGroupEventPage(roomID: room, events: [try .init(sourceEventID: eventID, roomSequence: 3, projectionKind: "message", payload: try JSONSerialization.data(withJSONObject: body))], nextRoomSequence: 3, hasMore: false)
        _ = try await store.applyForegroundGroupEventPreviewPage(page)
        let value = try #require(await store.messages(in: room).first)
        #expect(value.messageRevision == 3 && value.text == "authorized current")
        #expect(value.media.map(\.mediaID) == [try .init(media)])
        #expect(value.mediaPresentations.first?.contentType == "image/jpeg" && value.mediaPresentations.first?.byteCount == 256)
        #expect(value.mentions == [try .user(.init(mentioned))])
        #expect(value.replyTo?.messageID == (try .init(reply)))
        let expectedForwardedMessage = try MessageID(forwardedMessage)
        let expectedForwardedUser = try UserID(forwardedUser)
        #expect(value.forwardedFrom?.messageID == expectedForwardedMessage && value.forwardedFrom?.senderUserID == expectedForwardedUser)
        let pool = try DatabasePool(path: url.path)
        try await pool.write { try $0.execute(sql: "DELETE FROM v2_message_search_jobs") }
        _ = try await store.applyForegroundGroupEventPreviewPage(page)
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_search_jobs") } == 0)
        state["mention_user_ids"] = [UUID().uuidString]; replacement["state"] = state; body["replacement"] = replacement
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: eventID, roomSequence: 3, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: body))], nextRoomSequence: 3, hasMore: false))
        }
        #expect(try await store.messages(in: room).first == value)
        try await pool.close(); try await store.close()
    }


    @Test("replacement failures roll back cursor, projection and effect claim", arguments: ["room", "sequence", "origin", "same-revision", "terminal"])
    func completeEditReplacementRollback(_ defect: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-replacement-rollback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let room = try RoomID("00000000-0000-0000-0000-000000000220")
        let origin = EventID(uuid: UUID())
        let payload = try completeEditPayload(origin: origin.rawValue)
        _ = try await store.applyGroupEventPage(.init(roomID: room, events: [.init(sourceEventID: .init(uuid: UUID()), roomSequence: 3, projectionKind: "message", payload: payload)], nextRoomSequence: 3, hasMore: false))
        if defect == "terminal" {
            let stone = try JSONSerialization.data(withJSONObject: ["event_type":"message.withdrawn", "room_id":room.rawValue, "message_id":"00000000-0000-0000-0000-000000000001", "message_revision":4])
            _ = try await store.applyGroupEventPage(.init(roomID: room, events: [.init(sourceEventID: .init(uuid: UUID()), roomSequence: 4, projectionKind: "message", payload: stone)], nextRoomSequence: 4, hasMore: false))
        }
        let before = try await store.messages(in: room)
        var body = try #require(JSONSerialization.jsonObject(with: completeEditPayload(origin: origin.rawValue, revision: defect == "same-revision" ? 3 : 5)) as? [String: Any])
        var replacement = try #require(body["replacement"] as? [String: Any])
        var state = try #require(replacement["state"] as? [String: Any])
        body["room_sequence"] = 5
        if defect == "origin" { replacement["accepted_event_id"] = UUID().uuidString }
        if defect == "same-revision" { state["text"] = "conflicting complete body"; body["text"] = state["text"] }
        replacement["state"] = state; body["replacement"] = replacement
        let pool = try DatabasePool(path: url.path)
        let countBefore = try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_effects") }
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.applyGroupEventPage(.init(roomID: defect == "room" ? .init(uuid: UUID()) : room, events: [.init(sourceEventID: .init(uuid: UUID()), roomSequence: defect == "sequence" ? 6 : 5, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: body))], nextRoomSequence: 6, hasMore: false))
        }
        #expect(try await store.messages(in: room) == before)
        #expect(try await store.groupEventCursor(roomID: room) == (defect == "terminal" ? 4 : 3))
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_message_effects") } == countBefore)
        try await pool.close(); try await store.close()
    }

    @Test("real owner-produced complete edits materialize in ClientKit", arguments: ["shared", "inline"])
    func realOwnerReplacementFixture(_ variant: String) async throws {
        guard let root = ProcessInfo.processInfo.environment["IMV2_REPLACEMENT_TEST_FIXTURE_DIRECTORY"] else { return }
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root).appending(path: variant + ".json"))) as? [String: Any])
        let accepted = try #require(fixture["accepted"] as? [String: Any])
        let edit = try #require(fixture["edit"] as? [String: Any])
        let room = try RoomID(#require(edit["room_id"] as? String))
        let origin = try EventID(#require(fixture["origin_event_id"] as? String))
        let eventID = try EventID(#require(fixture["event_id"] as? String))
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-replacement-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        _ = try await store.applyGroupEventPage(.init(roomID: room, events: [
            .init(sourceEventID: origin, roomSequence: 1, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: accepted)),
            .init(sourceEventID: eventID, roomSequence: 3, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: edit))], nextRoomSequence: 3, hasMore: false))
        let value = try #require(await store.messages(in: room).first)
        #expect(value.sourceEventID == origin && value.roomSequence == 1 && value.messageRevision == 3)
        #expect(value.text == "visible after rejoin")
        try await store.close()
    }


    @Test("complete edit replacements bridge authorized gaps and late baselines across all feeds", arguments: ["personal", "preview", "room"], [false, true])
    func completeEditReplacementGap(_ feed: String, baselineFirst: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let room = try RoomID("00000000-0000-0000-0000-000000000220")
        let origin = EventID(uuid: UUID())
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: origin, projectionKind: "message", payload: messagePayload(text: "original"))
        let edit = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init(uuid: UUID()), projectionKind: "message", payload: try completeEditPayload(origin: origin.rawValue))
        if baselineFirst {
            _ = try await store.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: origin, roomSequence: 1, projectionKind: "message", payload: accepted.payload)], nextRoomSequence: 1, hasMore: false))
        }
        let page = try V2ClientGroupEventPage(roomID: room, events: [try .init(sourceEventID: edit.sourceEventID, roomSequence: 3, projectionKind: "message", payload: edit.payload)], nextRoomSequence: 3, hasMore: false)
        switch feed {
        case "personal": _ = try await store.apply(.init(generation: 1, records: [.init(sequence: 1, sourceEventID: edit.sourceEventID, projectionKind: "message", payload: edit.payload)], nextSyncToken: .init("replace"), receipt: .init("replace-receipt"), hasMore: false, capabilityProfile: "base"))
        case "preview": _ = try await store.applyForegroundGroupEventPreviewPage(page)
        default: _ = try await store.applyGroupEventPage(page)
        }
        let value = try #require(await store.messages(in: room).first)
        #expect(value.sourceEventID == origin && value.messageRevision == 3 && value.text == "authorized current")
        #expect(value.roomSequence == 1 && value.timelineSequence == 1)
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        _ = try await reopened.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: origin, roomSequence: 1, projectionKind: "message", payload: accepted.payload)], nextRoomSequence: 1, hasMore: false))
        _ = try await reopened.applyForegroundGroupEventPreviewPage(page)
        #expect(try await reopened.messages(in: room).first == value)
        let conflict = try completeEditPayload(origin: UUID().uuidString)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await reopened.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: edit.sourceEventID, roomSequence: 3, projectionKind: "message", payload: conflict)], nextRoomSequence: 3, hasMore: false))
        }
        let stone = try JSONSerialization.data(withJSONObject: ["event_type":"message.withdrawn", "room_id":room.rawValue, "message_id":value.messageID.rawValue, "message_revision":4])
        _ = try await reopened.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: .init(uuid: UUID()), roomSequence: 4, projectionKind: "message", payload: stone)], nextRoomSequence: 4, hasMore: false))
        let late = try completeEditPayload(origin: origin.rawValue, revision: 2)
        _ = try await reopened.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: .init(uuid: UUID()), roomSequence: 2, projectionKind: "message", payload: late)], nextRoomSequence: 2, hasMore: false))
        #expect(try await reopened.messages(in: room).first?.isWithdrawn == true)
        try await reopened.close()
    }

    @Test("complete edit envelopes reject incomplete or mismatched authority", arguments: ["schema", "null", "origin", "member", "sequence", "room", "revision", "text", "media", "timeline", "nullable", "withdrawn"])
    func completeEditReplacementValidation(_ defect: String) throws {
        var body = try #require(JSONSerialization.jsonObject(with: completeEditPayload(origin: UUID().uuidString)) as? [String: Any])
        var replacement = try #require(body["replacement"] as? [String: Any])
        var state = try #require(replacement["state"] as? [String: Any])
        switch defect {
        case "schema": replacement["schema_version"] = 2
        case "null": body["replacement"] = NSNull()
        case "origin": replacement["accepted_event_id"] = ""
        case "member": replacement["accepted_membership_revision"] = -1
        case "sequence": body["room_sequence"] = 1
        case "room": state["room_id"] = UUID().uuidString
        case "revision": state["message_revision"] = 2
        case "text": state["text"] = "different"
        case "media": state.removeValue(forKey: "media_ids")
        case "timeline": state.removeValue(forKey: "timeline_sequence")
        case "nullable": state.removeValue(forKey: "reply_to_message_id")
        default: state["is_withdrawn"] = true
        }
        replacement["state"] = state
        if defect != "null" { body["replacement"] = replacement }
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init(uuid: UUID()), projectionKind: "message", payload: try JSONSerialization.data(withJSONObject: body))
        #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try V2LocalMessageEffect(record: record) }
    }


    @Test("scanned-through room cursors persist hidden ranges without manufacturing events", arguments: [false, true], [false, true])
    func scannedRoomCursorPersistence(preview: Bool, empty: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let roomID = RoomID(uuid: UUID())
        let event = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 3, projectionKind: "message",
            payload: try messagePayload(roomID: roomID.rawValue, roomSequence: 3, messageID: UUID().uuidString, text: "visible"))
        let page = try V2ClientGroupEventPage(roomID: roomID, events: empty ? [] : [event], nextRoomSequence: 5, hasMore: false)
        if preview {
            let engine = V2ForegroundGroupEventPreviewEngine(transport: GroupEventTransportFake(page: page), store: store)
            #expect(try await engine.synchronizeOnePage(roomID: roomID).appliedEventCount == (empty ? 0 : 1))
            #expect(try await engine.cursor(roomID: roomID) == 5)
            #expect(try await store.groupEventCursor(roomID: roomID) == 0)
            #expect(try await store.cursor() == nil)
        } else {
            let engine = V2GroupEventSyncEngine(transport: GroupEventTransportFake(page: page), store: store)
            #expect(try await engine.synchronizeOnePage(roomID: roomID).appliedEventCount == (empty ? 0 : 1))
            #expect(try await store.groupEventCursor(roomID: roomID) == 5)
            let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
            #expect(try await reopened.groupEventCursor(roomID: roomID) == 5)
            #expect(try await reopened.applyGroupEventPage(page) == 5)
        }
        #expect(try await store.messages(in: roomID).count == (empty ? 0 : 1))
        let invalid = try V2ClientGroupEvent(sourceEventID: .init(uuid: UUID()), roomSequence: 6, projectionKind: "message", payload: Data([1]))
        let broken = try V2ClientGroupEventPage(roomID: roomID, events: [invalid], nextRoomSequence: 9, hasMore: false)
        await #expect(throws: (any Error).self) {
            if preview { _ = try await store.applyForegroundGroupEventPreviewPage(broken) }
            else { _ = try await store.applyGroupEventPage(broken) }
        }
        #expect(try await store.groupEventCursor(roomID: roomID) == (preview ? 0 : 5))
        #expect(try await store.messages(in: roomID).count == (empty ? 0 : 1))
    }


    @Test("favorite collection uses a stable bounded keyset cursor")
    func favoriteCollectionPagination() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000180"
        let messageIDs = [
            "00000000-0000-0000-0000-000000000181",
            "00000000-0000-0000-0000-000000000182",
            "00000000-0000-0000-0000-000000000183",
        ]
        var records: [V2ClientSyncRecord] = []
        for (index, messageID) in messageIDs.enumerated() {
            records.append(try .init(
                sequence: UInt64(index + 1),
                sourceEventID: .init("00000000-0000-0000-0000-00000000018\(index + 4)"),
                projectionKind: "message",
                payload: messagePayload(
                    roomID: roomID,
                    roomSequence: UInt64(index + 1),
                    messageID: messageID,
                    text: "favorite-\(index + 1)",
                    createdAtMilliseconds: 1_750_000_000_000 + Int64(index)
                )
            ))
        }
        for (index, messageID) in messageIDs.enumerated() {
            records.append(try .init(
                sequence: UInt64(index + 4),
                sourceEventID: .init("00000000-0000-0000-0000-00000000019\(index + 1)"),
                projectionKind: "message_favorite",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": roomID,
                    "message_id": messageID,
                    "is_favorited": true,
                    "updated_at_ms": 1_750_000_100_000 + index,
                ])
            ))
        }
        _ = try await store.apply(.init(
            generation: 1,
            records: records,
            nextSyncToken: .init("favorite-page-token"),
            receipt: .init("favorite-page-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let first = try await store.favoritedMessages(limit: 2)
        #expect(first.messages.map(\.messageID.rawValue) == [messageIDs[2], messageIDs[1]])
        let cursor = try #require(first.nextCursor)
        let second = try await store.favoritedMessages(before: cursor, limit: 2)
        #expect(second.messages.map(\.messageID.rawValue) == [messageIDs[0]])
        #expect(second.nextCursor == nil)
    }

    @Test("conversation preferences and favorites support room-scoped batch reads")
    func conversationPreferenceBatchReads() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let firstRoomID = try RoomID("00000000-0000-0000-0000-000000000201")
        let secondRoomID = try RoomID("00000000-0000-0000-0000-000000000202")
        let firstMessageID = try MessageID("00000000-0000-0000-0000-000000000203")
        let secondMessageID = try MessageID("00000000-0000-0000-0000-000000000204")
        let records = try [
            V2ClientSyncRecord(
                sequence: 1,
                sourceEventID: .init("00000000-0000-0000-0000-000000000205"),
                projectionKind: "conversation_state",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": firstRoomID.rawValue,
                    "is_pinned": true,
                    "is_archived": false,
                    "mute_until_ms": 1_750_000_100_000,
                    "updated_at_ms": 1_750_000_000_000,
                ])
            ),
            V2ClientSyncRecord(
                sequence: 2,
                sourceEventID: .init("00000000-0000-0000-0000-000000000206"),
                projectionKind: "conversation_state",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": secondRoomID.rawValue,
                    "is_pinned": false,
                    "is_archived": true,
                    "mute_until_ms": 0,
                    "updated_at_ms": 1_750_000_000_001,
                ])
            ),
            V2ClientSyncRecord(
                sequence: 3,
                sourceEventID: .init("00000000-0000-0000-0000-000000000207"),
                projectionKind: "message_favorite",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": firstRoomID.rawValue,
                    "message_id": firstMessageID.rawValue,
                    "is_favorited": true,
                    "updated_at_ms": 1_750_000_000_002,
                ])
            ),
            V2ClientSyncRecord(
                sequence: 4,
                sourceEventID: .init("00000000-0000-0000-0000-000000000208"),
                projectionKind: "message_favorite",
                payload: JSONSerialization.data(withJSONObject: [
                    "room_id": secondRoomID.rawValue,
                    "message_id": secondMessageID.rawValue,
                    "is_favorited": true,
                    "updated_at_ms": 1_750_000_000_003,
                ])
            ),
        ]

        _ = try await store.apply(.init(
            generation: 1,
            records: records,
            nextSyncToken: .init("batch-read-token"),
            receipt: .init("batch-read-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let states = try await store.conversationStates()
        #expect(states.count == 2)
        #expect(states[firstRoomID]?.isPinned == true)
        #expect(states[firstRoomID]?.muteUntil == Date(timeIntervalSince1970: 1_750_000_100))
        #expect(states[secondRoomID]?.isArchived == true)
        #expect(states[secondRoomID]?.muteUntil == nil)
        #expect(try await store.favoritedMessageIDs(in: firstRoomID) == Set([firstMessageID]))
        #expect(try await store.favoritedMessageIDs(in: secondRoomID) == Set([secondMessageID]))
    }

    @Test("private activity is projected separately from messages and disables only the direct composer")
    func privateTimelineActivityAndCapabilityAreApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000210"
        let activity = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000211"),
            projectionKind: "timeline_activity",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "direct_message_restricted",
                "room_id": roomID,
                "timeline_sequence": 2,
                "server_created_at_ms": 1_750_000_000_000,
            ])
        )
        let capability = try V2ClientSyncRecord(
            sequence: 2,
            sourceEventID: .init("00000000-0000-0000-0000-000000000211"),
            projectionKind: "direct_sending_capability",
            payload: try JSONSerialization.data(withJSONObject: [
                "room_id": roomID,
                "can_send": false,
                "updated_at_ms": 1_750_000_000_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [activity, capability], nextSyncToken: .init("activity-token"), receipt: .init("activity-receipt"), hasMore: false, capabilityProfile: "base"))

        #expect(try await store.messages(in: .init(roomID)).isEmpty)
        let projected = try #require(await store.timelineActivities(in: .init(roomID)).first)
        #expect(projected.kind == .directMessageRestricted)
        #expect(projected.timelineSequence == 2)
        #expect(try await store.directSendingCapability(roomID: .init(roomID))?.canSend == false)
    }

    @Test("conversation timeline uses stable keyset pages across messages and activities")
    func conversationTimelineUsesUnifiedKeysetPages() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000212"
        let records: [V2ClientSyncRecord] = try (1...5).map { sequence in
            if sequence.isMultiple(of: 2) {
                return try .init(
                    sequence: UInt64(sequence),
                    sourceEventID: .init(String(format: "00000000-0000-0000-0000-%012d", 220 + sequence)),
                    projectionKind: "timeline_activity",
                    payload: JSONSerialization.data(withJSONObject: [
                        "event_type": "direct_message_restricted",
                        "room_id": roomID,
                        "timeline_sequence": sequence,
                        "server_created_at_ms": 1_750_000_000_000 + sequence,
                    ])
                )
            }
            return try .init(
                sequence: UInt64(sequence),
                sourceEventID: .init(String(format: "00000000-0000-0000-0000-%012d", 220 + sequence)),
                projectionKind: "message",
                payload: messagePayload(
                    roomID: roomID,
                    roomSequence: UInt64(sequence),
                    messageID: String(format: "00000000-0000-0000-0000-%012d", 230 + sequence),
                    text: "message-\(sequence)"
                )
            )
        }
        _ = try await store.apply(.init(
            generation: 1,
            records: records,
            nextSyncToken: .init("timeline-page-token"),
            receipt: .init("timeline-page-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let newest = try await store.conversationTimelinePage(in: .init(roomID), limit: 3)
        #expect((newest.messages.map(\.timelineSequence) + newest.activities.map(\.timelineSequence)).sorted() == [3, 4, 5])
        let cursor = try #require(newest.olderCursor)
        #expect(cursor.timelineSequence == 3)

        let older = try await store.conversationTimelinePage(in: .init(roomID), before: cursor, limit: 3)
        #expect((older.messages.map(\.timelineSequence) + older.activities.map(\.timelineSequence)).sorted() == [1, 2])
        #expect(older.olderCursor == nil)
    }

    @Test("media presentation metadata survives durable message projection")
    func mediaPresentationProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000218"
        let mediaID = "00000000-0000-0000-0000-000000000219"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-00000000021a"),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.accepted",
                "message_id": "00000000-0000-0000-0000-00000000021b",
                "room_id": roomID,
                "room_sequence": 1,
                "message_revision": 1,
                "sender_user_id": "00000000-0000-0000-0000-00000000021c",
                "text": "图片",
                "media_ids": [mediaID],
                "media_presentations": [[
                    "media_id": mediaID,
                    "kind": "image",
                    "content_type": "image/jpeg",
                    "byte_count": 2_048,
                ]],
                "mention_user_ids": [],
                "mentions_everyone": false,
                "server_created_at_ms": 1_750_000_000_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("media-token"), receipt: .init("media-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init(roomID)).first)
        #expect(message.mediaPresentations == [try .init(mediaID: .init(mediaID), kind: .image, contentType: "image/jpeg", byteCount: 2_048)])
    }

    @Test("forward attribution survives live sync and local projection")
    func forwardAttributionProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000250"
        let sourceMessageID = "00000000-0000-0000-0000-000000000251"
        let sourceSenderID = "00000000-0000-0000-0000-000000000252"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000253"),
            projectionKind: "message",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "message.accepted",
                "message_id": "00000000-0000-0000-0000-000000000254",
                "room_id": roomID,
                "room_sequence": 1,
                "message_revision": 1,
                "sender_user_id": "00000000-0000-0000-0000-000000000255",
                "text": "转发内容",
                "forwarded_from_message_id": sourceMessageID,
                "forwarded_from_user_id": sourceSenderID,
                "server_created_at_ms": 1_750_000_000_000,
            ])
        )

        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("forward-token"), receipt: .init("forward-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init(roomID)).first)
        let expectedAttribution = try V2ForwardedMessageAttribution(messageID: .init(sourceMessageID), senderUserID: .init(sourceSenderID))
        #expect(message.forwardedFrom == expectedAttribution)
    }

    @Test("moderation sync facts are durably projected before acknowledgement")
    func moderationProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "member.muted",
            "room_id": "00000000-0000-0000-0000-000000000220",
            "room_sequence": 4,
            "actor_user_id": "00000000-0000-0000-0000-000000000221",
            "target_user_id": "00000000-0000-0000-0000-000000000222",
            "mute_until_ms": 1_750_000_300_000,
            "server_created_at_ms": 1_750_000_000_000,
        ])
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000223"), projectionKind: "moderation", payload: payload)
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("moderation-token"), receipt: .init("moderation-receipt"), hasMore: false, capabilityProfile: "base"))

        let action = try #require(await store.moderationActions().first)
        #expect(action.roomSequence == 4)
        #expect(action.targetUserID.rawValue == "00000000-0000-0000-0000-000000000222")
        #expect(action.muteUntil == Date(timeIntervalSince1970: 1_750_000_300))
    }

    @Test("trusted room control facts become a durable current-state projection")
    func roomControlProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000260"
        let actorID = "00000000-0000-0000-0000-000000000261"
        let frozen = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000262"), projectionKind: "moderation", payload: try JSONSerialization.data(withJSONObject: ["event_type": "room.frozen", "room_id": roomID, "room_sequence": 5, "actor_user_id": actorID, "server_created_at_ms": 1_750_000_000_000]))
        let unfrozen = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000263"), projectionKind: "moderation", payload: try JSONSerialization.data(withJSONObject: ["event_type": "room.unfrozen", "room_id": roomID, "room_sequence": 6, "actor_user_id": actorID, "server_created_at_ms": 1_750_000_001_000]))
        _ = try await store.apply(.init(generation: 1, records: [frozen, unfrozen], nextSyncToken: .init("room-control-token"), receipt: .init("room-control-receipt"), hasMore: false, capabilityProfile: "base"))

        let control = try #require(await store.roomControl(roomID: .init(roomID)))
        #expect(control.isFrozen == false)
        #expect(control.roomSequence == 6)
        #expect(control.actorUserID.rawValue == actorID)
    }

    @Test("group room identity arrives before its first message")
    func roomProfileProjectionIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000267"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000268"),
            projectionKind: "room",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "room.created", "room_id": roomID, "title": "项目群",
                "owner_user_id": "00000000-0000-0000-0000-000000000269",
                "membership_revision": 1,
                "delivery_mode": "standard_fanout",
                "created_at_ms": 1_750_000_000_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("room-token"), receipt: .init("room-receipt"), hasMore: false, capabilityProfile: "base"))
        let profile = try #require(await store.roomProfile(roomID: .init(roomID)))
        #expect(profile.title == "项目群")
        let page = try await store.conversationListPage(isArchived: false, limit: 10)
        #expect(page.entries.map(\.roomID.rawValue) == [roomID])
        #expect(page.entries.first?.lastMessage == nil)
    }

    @Test("a member added after group creation receives a compact room profile")
    func membershipProjectionBootstrapsAddedMemberRoomIdentity() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000270"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000271"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID, "title": "后加入的群",
                "owner_user_id": "00000000-0000-0000-0000-000000000272",
                "target_user_id": "00000000-0000-0000-0000-000000000273",
                "action": "add", "membership_revision": 2,
                "delivery_mode": "standard_fanout",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("member-token"), receipt: .init("member-receipt"), hasMore: false, capabilityProfile: "base"))

        let profile = try #require(await store.roomProfile(roomID: .init(roomID)))
        #expect(profile.title == "后加入的群")
        #expect(profile.membershipRevision == 2)
        #expect(profile.deliveryMode == .standardFanout)
    }

    @Test("a room profile without its required delivery mode is rejected")
    func roomProfileRejectsMissingDeliveryMode() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-00000000026f"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed",
                "room_id": "00000000-0000-0000-0000-00000000026e",
                "title": "缺少投递模式",
                "owner_user_id": "00000000-0000-0000-0000-00000000026d",
                "target_user_id": "00000000-0000-0000-0000-00000000026c",
                "action": "add",
                "membership_revision": 1,
                "created_at_ms": 1_750_000_000_000,
                "server_created_at_ms": 1_750_000_001_000,
            ])
        )

        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            _ = try await store.apply(.init(
                generation: 1,
                records: [record],
                nextSyncToken: .init("missing-mode-token"),
                receipt: .init("missing-mode-receipt"),
                hasMore: false,
                capabilityProfile: "base"
            ))
        }
    }

    @Test("a hybrid membership projection enrolls the room in cursor synchronization")
    func hybridMembershipProjectionRegistersRoomLog() async throws {
        let databaseURL = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: databaseURL, installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-000000000274"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000275"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID, "title": "大群",
                "owner_user_id": "00000000-0000-0000-0000-000000000276",
                "target_user_id": "00000000-0000-0000-0000-000000000277",
                "action": "add", "membership_revision": 2,
                "delivery_mode": "large_group_hybrid",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("hybrid-member-token"), receipt: .init("hybrid-member-receipt"), hasMore: false, capabilityProfile: "base"))

        #expect(try await store.knownRoomLogRoomIDs(after: nil, limit: 10) == [try .init(roomID)])
        try await store.markRoomEventUnauthorized(roomID: .init(roomID))
        #expect(try await store.knownRoomLogRoomIDs(after: nil, limit: 10).isEmpty)
        #expect(try await store.roomProfile(roomID: .init(roomID))?.deliveryMode == .largeGroupHybrid)
        #expect(try await store.groupEventAccess(roomID: .init(roomID)) == .init(
            delivery: .durableRoomLog,
            isAuthorized: false
        ))

        let reopenedStore = try GRDBV2LocalSyncStore(databaseURL: databaseURL, installationBinding: testInstallationBinding)
        #expect(try await reopenedStore.groupEventAccess(roomID: .init(roomID)) == .init(
            delivery: .durableRoomLog,
            isAuthorized: false
        ))
        #expect(try await reopenedStore.knownRoomLogRoomIDs(after: nil, limit: 10).isEmpty)

        let reauthorizedRecord = try V2ClientSyncRecord(
            sequence: 2,
            sourceEventID: .init("00000000-0000-0000-0000-000000000273"),
            projectionKind: "membership",
            payload: JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID, "title": "大群",
                "owner_user_id": "00000000-0000-0000-0000-000000000276",
                "target_user_id": "00000000-0000-0000-0000-000000000277",
                "action": "add", "membership_revision": 3,
                "delivery_mode": "large_group_hybrid",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_002_000,
            ])
        )
        _ = try await reopenedStore.apply(.init(
            generation: 1,
            records: [reauthorizedRecord],
            nextSyncToken: .init("hybrid-reauthorized-token"),
            receipt: .init("hybrid-reauthorized-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))
        #expect(try await reopenedStore.groupEventAccess(roomID: .init(roomID)) == .init(
            delivery: .durableRoomLog,
            isAuthorized: true
        ))
        #expect(try await reopenedStore.knownRoomLogRoomIDs(after: nil, limit: 10) == [try .init(roomID)])
    }

    @Test("a room-log page and its cursor commit atomically and accept an exact retry")
    func hybridGroupEventPageIsDurableAndIdempotent() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000278")
        let event = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-000000000279"),
            roomSequence: 3,
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 3, messageID: "00000000-0000-0000-0000-00000000027a", text: "从群日志拉取")
        )
        let page = try V2ClientGroupEventPage(roomID: roomID, events: [event], nextRoomSequence: 3, hasMore: false)

        #expect(try await store.applyGroupEventPage(page) == 3)
        #expect(try await store.applyGroupEventPage(page) == 3)
        #expect(try await store.groupEventCursor(roomID: roomID) == 3)
        #expect(try await store.messages(in: roomID).map(\.text) == ["从群日志拉取"])
    }

    @Test("snapshot reset preserves the authorized hybrid room-log projection and cursor")
    func snapshotPreservesHybridRoomLogOwnership() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let roomID = try RoomID("00000000-0000-0000-0000-0000000002b0")
        let membershipEventID = try EventID("00000000-0000-0000-0000-0000000002b1")
        let membershipPayload = try JSONSerialization.data(withJSONObject: [
            "event_type": "membership_changed",
            "room_id": roomID.rawValue,
            "title": "重置后仍保留的大群",
            "owner_user_id": "00000000-0000-0000-0000-0000000002b2",
            "target_user_id": "00000000-0000-0000-0000-0000000002b3",
            "action": "add",
            "membership_revision": 2,
            "delivery_mode": "large_group_hybrid",
            "created_at_ms": 1_750_000_000_000,
            "server_created_at_ms": 1_750_000_001_000,
        ])
        _ = try await store.apply(.init(
            generation: 1,
            records: [.init(
                sequence: 1,
                sourceEventID: membershipEventID,
                projectionKind: "membership",
                payload: membershipPayload
            )],
            nextSyncToken: .init("hybrid-before-reset"),
            receipt: .init("hybrid-before-reset-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let roomEvent = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-0000000002b4"),
            roomSequence: 7,
            projectionKind: "message",
            payload: messagePayload(
                roomID: roomID.rawValue,
                roomSequence: 7,
                messageID: "00000000-0000-0000-0000-0000000002b5",
                text: "room-log-owned"
            )
        )
        let announcement = try V2ClientGroupEvent(sourceEventID: .init("hybrid-announcement"), roomSequence: 9, projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: ["event_type": "group.announcement_changed", "room_id": roomID.rawValue, "revision": 2, "body": "hybrid announcement", "server_created_at_ms": 2_000, "room_sequence": 9]))
        let livePolicy = try rolePolicyFact(sequence: 1, revision: 5, permissions: [], roomSequence: 10, room: roomID)
        let policyEvent = try V2ClientGroupEvent(sourceEventID: livePolicy.sourceEventID, roomSequence: 10, projectionKind: livePolicy.projectionKind, payload: livePolicy.payload)
        let roomPage = try V2ClientGroupEventPage(
            roomID: roomID,
            events: [roomEvent, try .init(sourceEventID: .init("snapshot-room-edit"), roomSequence: 8, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: ["event_type": "message.edited", "room_id": roomID.rawValue, "message_id": "00000000-0000-0000-0000-0000000002b5", "message_revision": 2, "text": "room-log-edited"])), announcement, policyEvent],
            nextRoomSequence: 10,
            hasMore: false
        )
        _ = try await store.applyGroupEventPage(roomPage)

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-0000000002b6"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantFuture
        )
        let snapshotItem = try V2SnapshotProjectionItem(
            key: .init(projectionKind: "room", entityKey: roomID.rawValue),
            sourceEventID: membershipEventID,
            sequence: 1,
            payload: membershipPayload
        )
        let oldPolicy = try rolePolicyFact(sequence: 1, revision: 2, permissions: ["send_messages"], roomSequence: 5, room: roomID)
        let policyItem = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "permissions:\(roomID.rawValue):member"), sourceEventID: oldPolicy.sourceEventID, sequence: 1, payload: oldPolicy.payload)
        let transport = try ProjectionSnapshotTransport(
            reset: reset,
            pages: [.init(items: [policyItem, snapshotItem])]
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()

        #expect(try await store.groupEventCursor(roomID: roomID) == 10)
        #expect(try await store.messages(in: roomID).map(\.text) == ["room-log-edited"])
        #expect(try await store.applyGroupEventPage(roomPage) == 10)
        // The snapshot preserved revision 2 and its receipts. A delayed
        // accepted preview must not compare its old body with edited content.
        _ = try await store.applyForegroundGroupEventPreviewPage(.init(roomID: roomID, events: [roomEvent], nextRoomSequence: 7, hasMore: false))
        #expect(try await store.messages(in: roomID).first?.text == "room-log-edited")
        #expect(try await store.groupAnnouncement(roomID: roomID)?.body == "hybrid announcement")
        #expect(try await store.groupRolePolicies(roomID: roomID).first?.permissions == [])
        #expect(try await store.groupRolePolicies(roomID: roomID).first?.revision == 5)
        let changedPolicy = try rolePolicyFact(sequence: 1, revision: 5, permissions: ["send_messages"], roomSequence: 10, room: roomID)
        let changedPolicyEvent = try V2ClientGroupEvent(sourceEventID: changedPolicy.sourceEventID, roomSequence: 10, projectionKind: changedPolicy.projectionKind, payload: changedPolicy.payload)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.applyForegroundGroupEventPreviewPage(.init(roomID: roomID, events: [changedPolicyEvent], nextRoomSequence: 10, hasMore: false))
        }
        var altered = try #require(JSONSerialization.jsonObject(with: announcement.payload) as? [String: Any])
        altered["body"] = "altered receipt"
        let conflict = try V2ClientGroupEvent(sourceEventID: announcement.sourceEventID, roomSequence: 9, projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: altered))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.applyForegroundGroupEventPreviewPage(.init(roomID: roomID, events: [conflict], nextRoomSequence: 9, hasMore: false))
        }
    }

    @Test("one group-log pull reports durable progress for a foreground caller")
    func hybridGroupEventPullReportsProgress() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-00000000027b")
        let event = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-00000000027c"),
            roomSequence: 1,
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 1, messageID: "00000000-0000-0000-0000-00000000027d", text: "前台轮询")
        )
        let transport = GroupEventTransportFake(page: try .init(roomID: roomID, events: [event], nextRoomSequence: 1, hasMore: true))
        let engine = V2GroupEventSyncEngine(transport: transport, store: store)

        #expect(try await engine.synchronizeOnePage(roomID: roomID) == .init(appliedEventCount: 1, hasMore: true))
        #expect(try await store.groupEventCursor(roomID: roomID) == 1)
        #expect(try await store.messages(in: roomID).map(\.text) == ["前台轮询"])
    }

    @Test("a standard-group foreground preview stays outside durable group cursors and personal ACKs")
    func standardGroupForegroundPreviewIsTransientAndIdempotent() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-00000000028a")
        let profile = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-00000000028b"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID.rawValue, "title": "普通群",
                "owner_user_id": "00000000-0000-0000-0000-00000000028c",
                "target_user_id": "00000000-0000-0000-0000-00000000028d",
                "action": "add", "membership_revision": 2,
                "delivery_mode": "standard_fanout",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        let delivered = try V2ClientSyncRecord(
            sequence: 2,
            sourceEventID: .init("00000000-0000-0000-0000-00000000028e"),
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 2, messageID: "00000000-0000-0000-0000-00000000028f", text: "可靠投递")
        )
        _ = try await store.apply(.init(generation: 1, records: [profile, delivered], nextSyncToken: .init("standard-preview-token"), receipt: .init("standard-preview-receipt"), hasMore: false, capabilityProfile: "base"))

        let preview = try V2ClientGroupEvent(
            sourceEventID: .init("00000000-0000-0000-0000-000000000290"),
            roomSequence: 3,
            projectionKind: "message",
            payload: messagePayload(roomID: roomID.rawValue, roomSequence: 3, messageID: "00000000-0000-0000-0000-000000000291", text: "前台预览")
        )
        let transport = GroupEventTransportFake(page: try .init(roomID: roomID, events: [preview], nextRoomSequence: 3, hasMore: false))
        let engine = V2ForegroundGroupEventPreviewEngine(transport: transport, store: store)

        #expect(try await store.groupEventAccess(roomID: roomID) == .init(
            delivery: .foregroundPreview,
            isAuthorized: true
        ))
        #expect(try await engine.synchronizeOnePage(roomID: roomID) == .init(appliedEventCount: 1, hasMore: false))
        #expect(await transport.requestedCursors() == [2])
        #expect(try await store.messages(in: roomID).map(\.text) == ["可靠投递", "前台预览"])
        #expect(try await store.groupEventCursor(roomID: roomID) == 0)
        #expect(try await store.cursor()?.appliedSequence == 2)

        // A retry is safe and still does not create a durable room-log ACK.
        #expect(try await engine.synchronizeOnePage(roomID: roomID).appliedEventCount == 1)
        #expect(try await store.groupEventCursor(roomID: roomID) == 0)
    }

    @Test("a forbidden hybrid room revokes event access without blocking normal synchronization")
    func forbiddenHybridRoomStopsFutureCursorPulls() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomID = "00000000-0000-0000-0000-00000000027e"
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-00000000027f"),
            projectionKind: "membership",
            payload: try JSONSerialization.data(withJSONObject: [
                "event_type": "membership_changed", "room_id": roomID, "title": "已移出的大群",
                "owner_user_id": "00000000-0000-0000-0000-000000000280",
                "target_user_id": "00000000-0000-0000-0000-000000000281",
                "action": "remove", "membership_revision": 3,
                "delivery_mode": "large_group_hybrid",
                "created_at_ms": 1_750_000_000_000, "server_created_at_ms": 1_750_000_001_000,
            ])
        )
        _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("removed-hybrid-token"), receipt: .init("removed-hybrid-receipt"), hasMore: false, capabilityProfile: "base"))
        let engine = V2GroupEventSyncEngine(transport: ForbiddenGroupEventTransport(), store: store)

        _ = try await engine.synchronizeBackgroundKnownRooms(maximumPages: 1)

        #expect(try await store.knownRoomLogRoomIDs(after: nil, limit: 10).isEmpty)
        #expect(try await store.groupEventAccess(roomID: .init(roomID)) == .init(
            delivery: .durableRoomLog,
            isAuthorized: false
        ))
    }

    @Test("background hybrid maintenance is page-bounded and round-robin fair")
    func backgroundHybridMaintenanceIsBoundedAndFair() async throws {
        let first = try RoomID("00000000-0000-0000-0000-0000000002a0")
        let second = try RoomID("00000000-0000-0000-0000-0000000002a1")
        let store = BackgroundGroupEventStoreFake(roomIDs: [first, second])
        let transport = BackgroundGroupEventTransportFake()
        let engine = V2GroupEventSyncEngine(transport: transport, store: store)

        let firstPass = try await engine.synchronizeBackgroundKnownRooms(maximumPages: 3)
        #expect(firstPass == .init(processedPageCount: 2, appliedEventCount: 0, mayHaveRemainingWork: true))
        #expect(await transport.requestedRoomIDs() == [first, second])

        let secondPass = try await engine.synchronizeBackgroundKnownRooms(maximumPages: 1)
        #expect(secondPass == .init(processedPageCount: 1, appliedEventCount: 0, mayHaveRemainingWork: true))
        #expect(await transport.requestedRoomIDs() == [first, second, first])

        // Scheduling position is owned by the store, so a replacement engine
        // continues from the next room instead of resetting to the first.
        let replacementEngine = V2GroupEventSyncEngine(transport: transport, store: store)
        _ = try await replacementEngine.synchronizeBackgroundKnownRooms(maximumPages: 1)
        #expect(await transport.requestedRoomIDs() == [first, second, first, second])
    }

    @Test("local store applies an incremental batch once and accepts an exact retry")
    func incrementalApplyIsIdempotent() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let mentionUserID = "00000000-0000-0000-0000-000000000280"
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000201"), projectionKind: "message", payload: messagePayload(text: "payload", mentionedUserIDs: [mentionUserID], mentionsEveryone: true))
        let batch = try V2ClientSyncBatch(
            generation: 1,
            records: [record],
            nextSyncToken: try .init("token-1"),
            receipt: try .init("receipt-1"),
            hasMore: false,
            capabilityProfile: "base"
        )

        #expect(try await store.apply(batch).appliedSequence == 1)
        #expect(try await store.apply(batch).appliedSequence == 1)
        #expect(try await store.events() == [record])
        let projection = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(projection.text == "payload")
        #expect(projection.roomSequence == 1)
        #expect(projection.mentions == [.user(try .init(mentionUserID)), .everyone])
    }

    @Test("conversation summaries use the latest durable message per room")
    func conversationSummariesAreDerivedFromProjections() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let roomA = "00000000-0000-0000-0000-000000000220"
        let roomB = "00000000-0000-0000-0000-000000000230"
        let records = [
            try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-0000000002c1"), projectionKind: "message", payload: messagePayload(roomID: roomA, roomSequence: 1, messageID: "00000000-0000-0000-0000-0000000002d1", text: "older", createdAtMilliseconds: 1_750_000_000_000)),
            try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-0000000002c2"), projectionKind: "message", payload: messagePayload(roomID: roomB, roomSequence: 1, messageID: "00000000-0000-0000-0000-0000000002d2", text: "other room", createdAtMilliseconds: 1_750_000_001_000)),
            try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-0000000002c3"), projectionKind: "message", payload: messagePayload(roomID: roomA, roomSequence: 2, messageID: "00000000-0000-0000-0000-0000000002d3", text: "latest", createdAtMilliseconds: 1_750_000_002_000)),
        ]
        _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("summary-token"), receipt: .init("summary-receipt"), hasMore: false, capabilityProfile: "base"))

        let page = try await store.conversationListPage(isArchived: false, limit: 10)
        #expect(page.entries.map(\.roomID.rawValue) == [roomA, roomB])
        #expect(page.entries.compactMap(\.lastMessage?.text) == ["latest", "other room"])
        #expect(try await store.messages(in: try .init(roomA)).map(\.text) == ["older", "latest"])
    }

    @Test("conversation list uses an indexed stable keyset across pinned, empty, and archived rooms")
    func conversationListPagination() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let pinned = "00000000-0000-0000-0000-000000000401"
        let tiedFirst = "00000000-0000-0000-0000-000000000402"
        let tiedSecond = "00000000-0000-0000-0000-000000000403"
        let emptyGroup = "00000000-0000-0000-0000-000000000404"
        let archived = "00000000-0000-0000-0000-000000000405"
        let records = try [
            V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000411"), projectionKind: "message", payload: messagePayload(roomID: pinned, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000421", text: "pinned", createdAtMilliseconds: 1_750_000_001_000)),
            V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000412"), projectionKind: "message", payload: messagePayload(roomID: tiedFirst, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000422", text: "tie-a", createdAtMilliseconds: 1_750_000_002_000)),
            V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000413"), projectionKind: "message", payload: messagePayload(roomID: tiedSecond, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000423", text: "tie-b", createdAtMilliseconds: 1_750_000_002_000)),
            V2ClientSyncRecord(sequence: 4, sourceEventID: .init("00000000-0000-0000-0000-000000000414"), projectionKind: "message", payload: messagePayload(roomID: archived, roomSequence: 1, messageID: "00000000-0000-0000-0000-000000000424", text: "archived", createdAtMilliseconds: 1_750_000_003_000)),
            V2ClientSyncRecord(
                sequence: 5,
                sourceEventID: .init("00000000-0000-0000-0000-000000000415"),
                projectionKind: "room",
                payload: JSONSerialization.data(withJSONObject: [
                    "event_type": "room.created",
                    "room_id": emptyGroup,
                    "title": "Empty Group",
                    "owner_user_id": "00000000-0000-0000-0000-000000000406",
                    "membership_revision": 1,
                    "delivery_mode": "standard_fanout",
                    "created_at_ms": 1_750_000_001_500,
                ])
            ),
            V2ClientSyncRecord(sequence: 6, sourceEventID: .init("00000000-0000-0000-0000-000000000416"), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
                "room_id": pinned, "is_pinned": true, "is_archived": false,
                "mute_until_ms": 0, "updated_at_ms": 1_750_000_004_000,
            ])),
            V2ClientSyncRecord(sequence: 7, sourceEventID: .init("00000000-0000-0000-0000-000000000417"), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
                "room_id": archived, "is_pinned": false, "is_archived": true,
                "mute_until_ms": 0, "updated_at_ms": 1_750_000_004_001,
            ])),
        ]
        _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("conversation-list-1"), receipt: .init("conversation-list-receipt-1"), hasMore: false, capabilityProfile: "base"))

        let first = try await store.conversationListPage(isArchived: false, limit: 2)
        #expect(first.entries.map(\.roomID.rawValue) == [pinned, tiedFirst])
        let cursor = try #require(first.nextCursor)
        let second = try await store.conversationListPage(isArchived: false, before: cursor, limit: 2)
        #expect(second.entries.map(\.roomID.rawValue) == [tiedSecond, emptyGroup])
        #expect(second.entries.last?.lastMessage == nil)
        #expect(second.entries.last?.roomProfile?.title == "Empty Group")
        #expect(second.nextCursor == nil)

        let archivedPage = try await store.conversationListPage(isArchived: true, limit: 2)
        #expect(archivedPage.entries.map(\.roomID.rawValue) == [archived])

        let archiveTie = try V2ClientSyncRecord(sequence: 8, sourceEventID: .init("00000000-0000-0000-0000-000000000418"), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
            "room_id": tiedFirst, "is_pinned": false, "is_archived": true,
            "mute_until_ms": 0, "updated_at_ms": 1_750_000_004_002,
        ]))
        _ = try await store.apply(.init(generation: 1, records: [archiveTie], nextSyncToken: .init("conversation-list-2"), receipt: .init("conversation-list-receipt-2"), hasMore: false, capabilityProfile: "base"))
        #expect(try await store.conversationListPage(isArchived: true, limit: 2).entries.map(\.roomID.rawValue) == [archived, tiedFirst])
    }

    @Test("social sync records become durable local privacy and relationship projections")
    func socialProjectionsConverge() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let target = "00000000-0000-0000-0000-000000000290"
        let relationship = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000291"), projectionKind: "relationship", payload: socialPayload(["target_user_id": target, "state": "pending", "requested_by_user_id": target, "updated_at_ms": 1_750_000_000_000]))
        let block = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000292"), projectionKind: "user_block", payload: socialPayload(["target_user_id": target, "is_blocked": true, "updated_at_ms": 1_750_000_001_000]))
        let preference = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000293"), projectionKind: "stranger_message_permission", payload: socialPayload(["allows_stranger_messages": false, "updated_at_ms": 1_750_000_002_000]))
        _ = try await store.apply(.init(generation: 1, records: [relationship, block, preference], nextSyncToken: .init("social-token"), receipt: .init("social-receipt"), hasMore: false, capabilityProfile: "base"))

        let storedRelationship = try #require(await store.relationships().first)
        #expect(storedRelationship.targetUserID.rawValue == target)
        #expect(storedRelationship.state == .pending)
        #expect(try await store.blocks().map(\.targetUserID.rawValue) == [target])
        #expect(try await store.strangerMessagePreference()?.allowsStrangerMessages == false)
    }

    @Test("relationship list uses stable bounded pages for each request scope")
    func relationshipListPagination() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let currentUserID = try UserID("00000000-0000-0000-0000-000000000450")
        let acceptedFirst = "00000000-0000-0000-0000-000000000451"
        let acceptedSecond = "00000000-0000-0000-0000-000000000452"
        let incoming = "00000000-0000-0000-0000-000000000453"
        let outgoing = "00000000-0000-0000-0000-000000000454"
        let records = try [
            V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000461"), projectionKind: "relationship", payload: socialPayload(["target_user_id": acceptedFirst, "state": "accepted", "updated_at_ms": 1_750_000_003_000])),
            V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000462"), projectionKind: "relationship", payload: socialPayload(["target_user_id": acceptedSecond, "state": "accepted", "updated_at_ms": 1_750_000_003_000])),
            V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000463"), projectionKind: "relationship", payload: socialPayload(["target_user_id": incoming, "state": "pending", "requested_by_user_id": incoming, "updated_at_ms": 1_750_000_002_000])),
            V2ClientSyncRecord(sequence: 4, sourceEventID: .init("00000000-0000-0000-0000-000000000464"), projectionKind: "relationship", payload: socialPayload(["target_user_id": outgoing, "state": "pending", "requested_by_user_id": currentUserID.rawValue, "updated_at_ms": 1_750_000_001_000])),
        ]
        _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("relationship-page"), receipt: .init("relationship-page-receipt"), hasMore: false, capabilityProfile: "base"))
        let firstIdentity = try V2PublicIdentity(
            userID: .init(acceptedFirst),
            handle: .init("alice_one"),
            displayName: "Alice 张三",
            accountKind: .regular
        )
        let secondIdentity = try V2PublicIdentity(
            userID: .init(acceptedSecond),
            handle: .init("malice_two"),
            displayName: "Malice",
            accountKind: .regular
        )
        let revisionOne = try #require(V2ProfileRevision(rawValue: 1))
        try await store.saveProfileView(.init(
            userID: firstIdentity.userID,
            publicIdentity: firstIdentity,
            avatar: nil,
            state: .active,
            revision: revisionOne,
            visibilityRevision: revisionOne
        ))
        try await store.saveProfileView(.init(
            userID: secondIdentity.userID,
            publicIdentity: secondIdentity,
            avatar: nil,
            state: .active,
            revision: revisionOne,
            visibilityRevision: revisionOne
        ))

        let first = try await store.relationshipPage(scope: .accepted, limit: 1, includeTotalCount: true)
        #expect(first.relationships.map(\.targetUserID.rawValue) == [acceptedFirst])
        #expect(first.totalCount == 2)
        let cursor = try #require(first.nextCursor)
        let second = try await store.relationshipPage(scope: .accepted, before: cursor, limit: 1)
        #expect(second.relationships.map(\.targetUserID.rawValue) == [acceptedSecond])
        #expect(second.nextCursor == nil)
        #expect(second.totalCount == nil)

        let incomingPage = try await store.relationshipPage(scope: .incomingRequests(currentUserID: currentUserID), limit: 10, includeTotalCount: true)
        #expect(incomingPage.relationships.map(\.targetUserID.rawValue) == [incoming])
        #expect(incomingPage.totalCount == 1)

        let outgoingPage = try await store.relationshipPage(scope: .outgoingRequests(currentUserID: currentUserID), limit: 10, includeTotalCount: true)
        #expect(outgoingPage.relationships.map(\.targetUserID.rawValue) == [outgoing])
        #expect(outgoingPage.totalCount == 1)

        let firstSearchPage = try await store.relationshipPage(scope: .accepted, matching: "LIC", limit: 1)
        #expect(firstSearchPage.relationships.map(\.targetUserID.rawValue) == [acceptedFirst])
        let searchCursor = try #require(firstSearchPage.nextCursor)
        let secondSearchPage = try await store.relationshipPage(scope: .accepted, matching: "lic", before: searchCursor, limit: 1)
        #expect(secondSearchPage.relationships.map(\.targetUserID.rawValue) == [acceptedSecond])
        #expect(secondSearchPage.nextCursor == nil)
        let searchWindow = try await store.relationshipWindow(scope: .accepted, matching: "lic", around: searchCursor, limit: 2, precedingCount: 1)
        #expect(searchWindow.page.relationships.map(\.targetUserID.rawValue) == [acceptedFirst, acceptedSecond])
        #expect(searchWindow.anchor == searchCursor)
        let otherSearch = try await store.relationshipWindow(scope: .accepted, matching: "张三", around: searchCursor, limit: 2, precedingCount: 1)
        #expect(otherSearch.page.relationships.map(\.targetUserID.rawValue) == [acceptedFirst])
        #expect(try await store.relationshipPage(scope: .accepted, matching: "张三", limit: 10).relationships.map(\.targetUserID.rawValue) == [acceptedFirst])

        let revisionTwo = try #require(V2ProfileRevision(rawValue: 2))
        let renamedIdentity = try V2PublicIdentity(
            userID: firstIdentity.userID,
            handle: .init("carol_one"),
            displayName: "Carol",
            accountKind: firstIdentity.accountKind
        )
        try await store.saveProfileView(.init(
            userID: renamedIdentity.userID,
            publicIdentity: renamedIdentity,
            avatar: nil,
            state: .active,
            revision: revisionTwo,
            visibilityRevision: revisionTwo
        ))
        #expect(try await store.relationshipPage(scope: .accepted, matching: "lic", limit: 10).relationships.map(\.targetUserID.rawValue) == [acceptedSecond])
        try await store.markProfileUnavailable(userID: secondIdentity.userID)
        #expect(try await store.relationshipPage(scope: .accepted, matching: "lic", limit: 10).relationships.isEmpty)
    }

    @Test("malformed message projections roll back the entire sync batch")
    func invalidMessagePayloadIsNotAcknowledgedOrPersisted() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000221"), projectionKind: "message", payload: Data("not-json".utf8))
        let batch = try V2ClientSyncBatch(generation: 1, records: [record], nextSyncToken: .init("invalid-token"), receipt: .init("invalid-receipt"), hasMore: false, capabilityProfile: "base")

        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.apply(batch)
        }
        #expect(try await store.cursor() == nil)
        #expect(try await store.events().isEmpty)
    }

    @Test("message effects converge across preview, personal and durable room feeds after reopen", arguments: ["preview-first", "personal-first", "room-first", "legacy-upgrade"])
    func messageEffectsAreSharedAcrossFeeds(order: String) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let records = try [
            V2ClientSyncRecord(sequence: 1, sourceEventID: .init("effect-accepted"), projectionKind: "message", payload: messagePayload(text: "before")),
            V2ClientSyncRecord(sequence: 2, sourceEventID: .init("effect-edited"), projectionKind: "message", payload: editPayload(text: "after", revision: 2)),
            V2ClientSyncRecord(sequence: 3, sourceEventID: .init("effect-withdrawn"), projectionKind: "message", payload: JSONSerialization.data(withJSONObject: ["event_type": "message.withdrawn", "message_id": "00000000-0000-0000-0000-000000000001", "room_id": "00000000-0000-0000-0000-000000000220", "message_revision": 3]))
        ]
        let page = try V2ClientGroupEventPage(roomID: .init("00000000-0000-0000-0000-000000000220"), events: records.map { try .init(sourceEventID: $0.sourceEventID, roomSequence: $0.sequence, projectionKind: $0.projectionKind, payload: $0.payload) }, nextRoomSequence: 3, hasMore: false)
        let batch = try V2ClientSyncBatch(generation: 1, records: records, nextSyncToken: .init("effects-token"), receipt: .init("effects-receipt"), hasMore: false, capabilityProfile: "base")
        switch order {
        case "preview-first": _ = try await store.applyForegroundGroupEventPreviewPage(page)
        case "room-first": _ = try await store.applyGroupEventPage(page)
        default: _ = try await store.apply(batch)
        }
        let pool = try DatabasePool(path: url.path)
        try await pool.write { db in try db.execute(sql: "DELETE FROM v2_message_search_jobs") }
        try await store.close()
        if order == "legacy-upgrade" {
            try await pool.write { db in
                try db.execute(sql: "DROP TABLE v2_message_effects")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'recordSharedMessageEffects'")
            }
        }
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        _ = try await reopened.apply(batch)
        _ = try await reopened.applyForegroundGroupEventPreviewPage(page)
        _ = try await reopened.applyGroupEventPage(page)
        let message = try #require(await reopened.messages(in: page.roomID).first)
        #expect(message.isWithdrawn && message.messageRevision == 3 && message.text == "[removed]")
        #expect(try await reopened.groupEventCursor(roomID: page.roomID) == 3)
        #expect(try await pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM v2_message_search_jobs") } == 0)
        #expect(try await pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM v2_message_effects") } == 3)

        // JSON whitespace/order is transport spelling, while changed semantic
        // text under the same event identity must roll back the new cursor.
        let spelling = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: records[1].payload), options: [.prettyPrinted, .sortedKeys])
        _ = try await reopened.applyForegroundGroupEventPreviewPage(.init(roomID: page.roomID, events: [.init(sourceEventID: records[1].sourceEventID, roomSequence: 2, projectionKind: "message", payload: spelling)], nextRoomSequence: 2, hasMore: false))
        let conflict = try V2ClientSyncRecord(sequence: 4, sourceEventID: records[1].sourceEventID, projectionKind: "message", payload: editPayload(text: "conflict", revision: 2))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await reopened.apply(.init(generation: 1, records: [conflict], nextSyncToken: .init("conflict"), receipt: .init("conflict-receipt"), hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM v2_sync_events") } == 3)
    }

    @Test("a delayed edit cannot resurrect a message when its tombstone arrived first", arguments: [false, true])
    func historicalEditAfterTombstone(hasBaseline: Bool) async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let room = try RoomID("00000000-0000-0000-0000-000000000220")
        if hasBaseline {
            _ = try await store.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [try .init(sourceEventID: .init("late-edit-base"), roomSequence: 1, projectionKind: "message", payload: messagePayload(text: "before"))], nextRoomSequence: 1, hasMore: false))
        }
        let stone = try JSONSerialization.data(withJSONObject: ["event_type": "message.withdrawn", "message_id": "00000000-0000-0000-0000-000000000001", "room_id": room.rawValue, "message_revision": 3])
        let records = try [V2ClientSyncRecord(sequence: 1, sourceEventID: .init("late-edit-stone"), projectionKind: "message", payload: stone),
            V2ClientSyncRecord(sequence: 2, sourceEventID: .init("late-edit"), projectionKind: "message", payload: editPayload(text: "must never reappear", revision: 2))]
        let cursor = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("late-edit-token"), receipt: .init("late-edit-receipt"), hasMore: false, capabilityProfile: "base"))
        #expect(cursor.appliedSequence == 2)
        let messages = try await store.messages(in: room)
        #expect(messages.allSatisfy { $0.isWithdrawn && $0.text == "[removed]" })
        #expect(messages.count == (hasBaseline ? 1 : 0))
    }

    @Test("an effect claim rolls back with a missing baseline and can retry after recovery")
    func messageEffectClaimIsAtomicWithProjection() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let edit = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("failed-edit"), projectionKind: "message", payload: editPayload(text: "after", revision: 2))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.apply(.init(generation: 1, records: [edit], nextSyncToken: .init("missing"), receipt: .init("missing-receipt"), hasMore: false, capabilityProfile: "base"))
        }
        let pool = try DatabasePool(path: url.path)
        #expect(try await pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM v2_message_effects") } == 0)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("recovered-base"), projectionKind: "message", payload: messagePayload(text: "before"))
        let recoveredEdit = try V2ClientSyncRecord(sequence: 2, sourceEventID: edit.sourceEventID, projectionKind: "message", payload: edit.payload)
        _ = try await store.apply(.init(generation: 1, records: [accepted, recoveredEdit], nextSyncToken: .init("recovered"), receipt: .init("recovered-receipt"), hasMore: false, capabilityProfile: "base"))
        #expect(try await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first?.text == "after")
    }

    @Test("withdrawal becomes a durable tombstone without losing canonical message order")
    func withdrawalTombstoneIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000223"), projectionKind: "message", payload: messagePayload(text: "remove me"))
        let withdrawn = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000224"), projectionKind: "message", payload: withdrawalPayload())
        _ = try await store.apply(.init(generation: 1, records: [accepted, withdrawn], nextSyncToken: .init("withdraw-token"), receipt: .init("withdraw-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.isWithdrawn)
        #expect(message.messageRevision == 2)
        #expect(message.roomSequence == 1)
    }

    @Test("withdrawal clears independently projected reactions")
    func withdrawalClearsIndependentReactions() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-0000000002c1"), projectionKind: "message", payload: messagePayload(text: "react then withdraw"))
        let added = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-0000000002c2"), projectionKind: "message_reaction", payload: reactionPayload(action: "add"))
        let withdrawn = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-0000000002c3"), projectionKind: "message", payload: withdrawalPayload())

        _ = try await store.apply(.init(
            generation: 1,
            records: [accepted, added, withdrawn],
            nextSyncToken: .init("withdraw-reaction-token"),
            receipt: .init("withdraw-reaction-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        var late = try #require(JSONSerialization.jsonObject(with: reactionPayload(action: "add")) as? [String: Any])
        late["actor_user_id"] = "00000000-0000-0000-0000-000000000223"
        late["room_sequence"] = 3
        let lateRecord = try V2ClientSyncRecord(sequence: 4, sourceEventID: .init("late-unseen-reaction"), projectionKind: "message_reaction", payload: JSONSerialization.data(withJSONObject: late))
        let cursor = try await store.apply(.init(generation: 1, records: [lateRecord], nextSyncToken: .init("late-reaction"), receipt: .init("late-reaction-receipt"), hasMore: false, capabilityProfile: "base"))
        #expect(cursor.appliedSequence == 4)
        #expect(try await store.reactions(for: .init("00000000-0000-0000-0000-000000000001")).isEmpty)
    }

    @Test("moderator redaction becomes the same durable tombstone projection")
    func redactionTombstoneIsApplied() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-0000000002a1"), projectionKind: "message", payload: messagePayload(text: "moderate me"))
        let redacted = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-0000000002a2"), projectionKind: "message", payload: redactionPayload())
        _ = try await store.apply(.init(generation: 1, records: [accepted, redacted], nextSyncToken: .init("redaction-token"), receipt: .init("redaction-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.isWithdrawn)
        #expect(message.messageRevision == 2)
        #expect(try await store.events().map(\.sourceEventID) == [accepted.sourceEventID, redacted.sourceEventID])
    }

    @Test("reaction removals fence older additions across feeds and restart", arguments: ["remove-first", "add-first"])
    func orderedReactionEffects(order: String) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let room = try RoomID("00000000-0000-0000-0000-000000000220"), message = try MessageID("00000000-0000-0000-0000-000000000001")
        func record(_ sequence: UInt64, _ roomSequence: UInt64, _ action: String, event: String) throws -> V2ClientSyncRecord {
            var payload = try #require(JSONSerialization.jsonObject(with: reactionPayload(action: action)) as? [String: Any])
            payload["room_sequence"] = roomSequence
            return try .init(sequence: sequence, sourceEventID: .init(event), projectionKind: "message_reaction", payload: JSONSerialization.data(withJSONObject: payload))
        }
        let add = try record(2, 20, "add", event: "reaction-add"), remove = try record(3, 30, "remove", event: "reaction-remove")
        let early = order == "remove-first" ? remove : add
        _ = try await store.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: early.sourceEventID, roomSequence: order == "remove-first" ? 30 : 20, projectionKind: early.projectionKind, payload: early.payload)], nextRoomSequence: order == "remove-first" ? 30 : 20, hasMore: false))
        let base = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("reaction-base"), projectionKind: "message", payload: messagePayload(text: "reaction base"))
        let cursor = try await store.apply(.init(generation: 1, records: [base, add, remove], nextSyncToken: .init("reaction-order"), receipt: .init("reaction-order-receipt"), hasMore: false, capabilityProfile: "base"))
        #expect(cursor.appliedSequence == 3)
        #expect(try await store.reactions(for: message).isEmpty)
        try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let readd = try record(4, 40, "add", event: "reaction-readd")
        _ = try await reopened.apply(.init(generation: 1, records: [readd], nextSyncToken: .init("reaction-readd"), receipt: .init("reaction-readd-receipt"), hasMore: false, capabilityProfile: "base"))
        _ = try await reopened.applyForegroundGroupEventPreviewPage(.init(roomID: room, events: [.init(sourceEventID: remove.sourceEventID, roomSequence: 30, projectionKind: remove.projectionKind, payload: remove.payload)], nextRoomSequence: 30, hasMore: false))
        #expect(try await reopened.reactions(for: message).count == 1)
        let conflict = try record(5, 30, "add", event: "reaction-remove")
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await reopened.apply(.init(generation: 1, records: [conflict], nextSyncToken: .init("reaction-conflict"), receipt: .init("reaction-conflict-receipt"), hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await reopened.cursor()?.appliedSequence == 4)
    }

    @Test("reaction migration backfills ordered facts and restarts old unversioned snapshot staging", arguments: [false, true])
    func reactionMigrationRestartsSnapshot(prepared: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let add = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("migration-reaction-add"), projectionKind: "message_reaction", payload: reactionPayload(action: "add"))
        let remove = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("migration-reaction-remove"), projectionKind: "message_reaction", payload: reactionPayload(action: "remove"))
        _ = try await store.apply(.init(generation: 1, records: [add, remove], nextSyncToken: .init("migration-reactions"), receipt: .init("migration-reactions-receipt"), hasMore: false, capabilityProfile: "base"))
        let reset = try V2ClientResetRequired(snapshotID: .init("reaction-upgrade-snapshot"), generation: 2, baseSequence: 0, expiresAt: .distantFuture)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 0, capabilityProfile: "base"))
        if prepared { try await store.prepareSnapshotActivation(fixture.manifest) }
        try await store.close()
        let old = try DatabasePool(path: url.path)
        try await old.write { db in
            for table in ["v2_reaction_versions", "v2_reaction_effects", "v2_snapshot_shadow_reaction_versions", "v2_snapshot_shadow_reaction_effects"] { try db.execute(sql: "DROP TABLE \(table)") }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'orderReactionEffects'")
        }
        try old.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        #expect(try await reopened.cursor()?.pendingReset == reset)
        #expect(try await reopened.importedSnapshotManifest(for: reset) == nil)
        #expect(try await reopened.reactions(for: .init("00000000-0000-0000-0000-000000000001")).isEmpty)
        try await reopened.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 0, capabilityProfile: "base"))
        try await reopened.prepareSnapshotActivation(fixture.manifest)
        try await reopened.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await reopened.cursor()?.generation == 2)
    }

    @Test("reaction version must come from the payload and match a room envelope")
    func reactionVersionBoundary() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        var payload = try #require(JSONSerialization.jsonObject(with: reactionPayload(action: "add")) as? [String: Any])
        payload.removeValue(forKey: "room_sequence")
        let missing = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("missing-reaction-version"), projectionKind: "message_reaction", payload: JSONSerialization.data(withJSONObject: payload))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.apply(.init(generation: 1, records: [missing], nextSyncToken: .init("missing-reaction"), receipt: .init("missing-reaction-receipt"), hasMore: false, capabilityProfile: "base"))
        }
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.applyForegroundGroupEventPreviewPage(.init(roomID: .init("00000000-0000-0000-0000-000000000220"), events: [.init(sourceEventID: missing.sourceEventID, roomSequence: 99, projectionKind: "message_reaction", payload: reactionPayload(action: "add"))], nextRoomSequence: 99, hasMore: false))
        }
    }

    @Test("reaction add and remove converge as a set without changing message content")
    func reactionSetProjectionConverges() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000227"), projectionKind: "message", payload: messagePayload(text: "react to me"))
        let added = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000228"), projectionKind: "message_reaction", payload: reactionPayload(action: "add"))
        let removed = try V2ClientSyncRecord(sequence: 3, sourceEventID: .init("00000000-0000-0000-0000-000000000229"), projectionKind: "message_reaction", payload: reactionPayload(action: "remove"))
        _ = try await store.apply(.init(generation: 1, records: [accepted, added, removed], nextSyncToken: .init("reaction-token"), receipt: .init("reaction-receipt"), hasMore: false, capabilityProfile: "base"))

        #expect(try await store.reactions(for: .init("00000000-0000-0000-0000-000000000001")).isEmpty)
        #expect(try await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first?.text == "react to me")
    }

    @Test("revision-fenced edit replaces text but cannot overwrite a tombstone")
    func editProjectionReplacesOnlyTheCurrentRevision() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let accepted = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000230"), projectionKind: "message", payload: messagePayload(text: "before"))
        let edited = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000231"), projectionKind: "message", payload: editPayload(text: "after", revision: 2))
        _ = try await store.apply(.init(generation: 1, records: [accepted, edited], nextSyncToken: .init("edit-token"), receipt: .init("edit-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.text == "after")
        #expect(message.messageRevision == 2)
        #expect(!message.isWithdrawn)
    }

    @Test("a tombstone received before its projection is retained and applied when the projection arrives")
    func withdrawalTombstoneSurvivesProjectionReordering() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let withdrawn = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000225"), projectionKind: "message", payload: withdrawalPayload())
        let accepted = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000226"), projectionKind: "message", payload: messagePayload(roomSequence: 2, messageID: "00000000-0000-0000-0000-000000000001", text: "already removed"))

        _ = try await store.apply(.init(generation: 1, records: [withdrawn, accepted], nextSyncToken: .init("withdraw-reordered-token"), receipt: .init("withdraw-reordered-receipt"), hasMore: false, capabilityProfile: "base"))

        let message = try #require(await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).first)
        #expect(message.isWithdrawn)
        #expect(message.messageRevision == 2)
        #expect(message.roomSequence == 2)
    }

    @Test("V2 local database and SQLite sidecars are excluded from backup")
    func localStoreExcludesManagedArtifactsFromBackup() async throws {
        #if canImport(Darwin)
        let directory = try backupEligibleTestDirectory()
        let testRoot = directory.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: testRoot)
        }
        let url = directory.appendingPathComponent("v2.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)

        try await store.refreshBackupExclusion()
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                #expect(try sidecar.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            }
        }
        #else
        // The Darwin backup exclusion resource value does not exist on Linux.
        // SQLite behavior remains covered by the other local-store tests.
        #endif
    }

    @Test("explicit personal rebuild survives restart and response loss without deleting the outbox")
    func durablePersonalSnapshotRebuild() async throws {
        let url = temporaryDatabaseURL()
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000009001"), projectionKind: "message", payload: messagePayload(text: "old local baseline"))
        let batch = try V2ClientSyncBatch(generation: 1, records: [record], nextSyncToken: .init("old-token"), receipt: .init("old-receipt"), hasMore: false, capabilityProfile: "base")
        _ = try await store.apply(batch)
        let pending = V2PendingMessageCommand(roomID: try .init("00000000-0000-0000-0000-000000009002"), clientMessageID: try .init("00000000-0000-0000-0000-000000009003"), text: "keep this outbox", state: .pending, attemptCount: 0, nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(pending)
        try await store.close()
        let legacy = try DatabasePool(path: url.path)
        try await legacy.write { db in
            try db.execute(sql: "DROP TABLE v2_sync_rebuild_requests")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'recordSnapshotRebuildIntent'")
        }
        try legacy.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        #expect(try await !store.requiresSnapshotRebuild())
        #expect(try await store.cursor()?.appliedSequence == 1)
        #expect(try await store.pendingMessageCommands() == [pending])
        try await store.requestSnapshotRebuild()
        try await store.requestSnapshotRebuild()
        #expect(try await store.requiresSnapshotRebuild())
        await #expect(throws: V2ClientSyncError.snapshotRebuildRequired) { try await store.apply(batch) }
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000009004"), generation: 4, baseSequence: 10, expiresAt: .distantFuture)
        let transport = try RebuildSnapshotTransport(reset: reset)
        var engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        await #expect(throws: RebuildSnapshotTransport.ResponseLost.self) { try await engine.synchronizeOnce() }
        #expect(try await store.requiresSnapshotRebuild())
        #expect(try await store.cursor()?.appliedSequence == 1)
        #expect(try await store.pendingMessageCommands() == [pending])
        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        #expect(try await store.requiresSnapshotRebuild())
        // A pending reset resumes its saved generation without issuing another
        // forced request, including after the process restarts.
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()
        #expect(try await !store.requiresSnapshotRebuild())
        #expect(try await store.cursor()?.generation == 4)
        #expect(try await store.cursor()?.appliedSequence == 10)
        #expect(try await store.pendingMessageCommands() == [pending])
        #expect(await transport.rebuildFlags() == [true, true])
        #expect(await transport.tokensWereAbsent())
    }

    @Test("normal generation fences stay strict and cancelled rebuilds keep their durable intent")
    func rebuildGenerationFenceAndCancellation() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        _ = try await store.apply(.init(generation: 1, records: [], nextSyncToken: .init("old"), receipt: .init("receipt"), hasMore: false, capabilityProfile: "base"))
        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000009005"), generation: 4, baseSequence: 0, expiresAt: .distantFuture)
        await #expect(throws: V2ClientSyncError.generationMismatch) { try await store.beginReset(reset) }
        try await store.requestSnapshotRebuild()
        try await store.beginReset(reset)
        try await store.cancelReset(reset)
        #expect(try await store.requiresSnapshotRebuild())
        #expect(try await store.cursor()?.generation == 1)
    }

    @Test("engine persists before acknowledgement and records the acknowledged watermark")
    func engineAcknowledgesOnlyAfterApply() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000202"), projectionKind: "message", payload: messagePayload(text: "ack"))
        let transport = FakeTransport(pullResult: .ready(try .init(
            generation: 1,
            records: [record],
            nextSyncToken: try .init("token-2"),
            receipt: try .init("receipt-2"),
            hasMore: false,
            capabilityProfile: "base"
        )))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .synchronized(appliedThrough: 1, hasMore: false))
        #expect(await transport.acknowledgements() == [.init(generation: 1, sequence: 1, receipt: try .init("receipt-2"))])
        #expect(try await store.cursor()?.serverAcknowledgedSequence == 1)
        #expect(try await store.cursor()?.syncToken == .init("token-2"))
    }

    @Test("an ACK response loss retries by pulling the persisted token before applying again")
    func lostIncrementalAcknowledgementResponseRecovers() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000263"),
            projectionKind: "message",
            payload: messagePayload(text: "ack-retry")
        )
        let firstBatch = try V2ClientSyncBatch(
            generation: 1,
            records: [record],
            nextSyncToken: .init("ack-retry-token"),
            receipt: .init("ack-retry-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        )
        let retryBatch = try V2ClientSyncBatch(
            generation: 1,
            records: [],
            nextSyncToken: .init("ack-retry-token-2"),
            receipt: .init("ack-retry-receipt-2"),
            hasMore: false,
            capabilityProfile: "base"
        )
        let transport = LostIncrementalACKTransport(
            first: firstBatch,
            retry: retryBatch
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        await #expect(throws: LostIncrementalACKTransport.Failure.responseLost) {
            _ = try await engine.synchronizeOnce()
        }
        #expect(try await store.cursor()?.pendingAcknowledgementReceipt == firstBatch.receipt)

        #expect(try await engine.synchronizeOnce() == .synchronized(
            appliedThrough: 1,
            hasMore: false
        ))
        #expect(await transport.requestedTokens() == [nil, firstBatch.nextSyncToken])
        #expect(await transport.acknowledgementReceipts() == [
            firstBatch.receipt,
            retryBatch.receipt,
        ])
        #expect(try await store.cursor()?.pendingAcknowledgementReceipt == nil)
        #expect(try await store.events() == [record])
    }

    @Test("an expired sync token retries once from the server cursor without duplicating local state")
    func expiredSyncTokenRecoversFromServerCursor() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let record = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000264"),
            projectionKind: "message",
            payload: messagePayload(text: "expired-token")
        )
        let oldReceipt = try V2SyncReceipt("expired-token-old-receipt")
        _ = try await store.apply(.init(
            generation: 1,
            records: [record],
            nextSyncToken: .init("expired-token-old"),
            receipt: oldReceipt,
            hasMore: false,
            capabilityProfile: "base"
        ))
        try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: oldReceipt)

        let transport = ExpiredSyncTokenTransport(
            batch: try .init(
                generation: 1,
                records: [],
                nextSyncToken: .init("expired-token-recovered"),
                receipt: .init("expired-token-recovered-receipt"),
                hasMore: false,
                capabilityProfile: "base"
            )
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        #expect(try await engine.synchronizeOnce() == .synchronized(
            appliedThrough: 1,
            hasMore: false
        ))
        #expect(await transport.requestedTokens() == [
            try V2SyncToken("expired-token-old"),
            nil,
        ])
        #expect(try await store.cursor()?.syncToken == .init("expired-token-recovered"))
        #expect(try await store.events() == [record])
    }

    @Test("a mismatched persisted receipt cannot advance the acknowledged watermark")
    func receiptFencesAcknowledgement() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000205"), projectionKind: "message", payload: messagePayload(text: "receipt"))
        _ = try await store.apply(.init(
            generation: 1,
            records: [record],
            nextSyncToken: try .init("token-3"),
            receipt: try .init("receipt-3"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        await #expect(throws: V2ClientSyncError.acknowledgementReceiptMismatch) {
            try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: .init("wrong-receipt"))
        }
        #expect(try await store.cursor()?.serverAcknowledgedSequence == 0)
    }

    @Test("a batch for an unnegotiated capability profile is never persisted or acknowledged")
    func rejectsUnsupportedCapabilityProfile() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let transport = FakeTransport(pullResult: .ready(try .init(
            generation: 1,
            records: [],
            nextSyncToken: try .init("token-unsupported"),
            receipt: try .init("receipt-unsupported"),
            hasMore: false,
            capabilityProfile: "future-profile"
        )))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        await #expect(throws: V2ClientSyncError.unsupportedCapabilityProfile) {
            _ = try await engine.synchronizeOnce()
        }
        #expect(try await store.cursor() == nil)
        #expect(await transport.acknowledgements().isEmpty)
    }

    @Test("sync values outside SQLite's signed integer domain are rejected atomically")
    func rejectsUnpersistableUnsignedSequences() async throws {
        let limitExceeded = UInt64(Int64.max) + 1

        let oversizedRecordStore = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        await #expect(throws: V2ClientSyncError.storageRangeExceeded) {
        let oversizedRecord = try V2ClientSyncRecord(
            sequence: limitExceeded,
            sourceEventID: try .init("00000000-0000-0000-0000-0000000002b1"),
            projectionKind: "message",
            payload: messagePayload(text: "must not persist")
        )
            try await oversizedRecordStore.apply(.init(generation: 1, records: [oversizedRecord], nextSyncToken: try .init("range-token-1"), receipt: try .init("range-receipt-1"), hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await oversizedRecordStore.cursor() == nil)
        #expect(try await oversizedRecordStore.events().isEmpty)

        let oversizedProjectionStore = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let oversizedProjection = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: try .init("00000000-0000-0000-0000-0000000002b2"),
            projectionKind: "message",
            payload: messagePayload(roomSequence: limitExceeded, text: "must not persist")
        )
        await #expect(throws: V2ClientSyncError.storageRangeExceeded) {
            try await oversizedProjectionStore.apply(.init(generation: 1, records: [oversizedProjection], nextSyncToken: try .init("range-token-2"), receipt: try .init("range-receipt-2"), hasMore: false, capabilityProfile: "base"))
        }
        #expect(try await oversizedProjectionStore.cursor() == nil)
        #expect(try await oversizedProjectionStore.events().isEmpty)
    }

    @Test("invalid snapshot page integers preserve staging and allow the exact page to resume", arguments: ["index", "itemCount"], [Int.min, -1, 0, 1, Int.max])
    func snapshotPageIntegerBounds(field: String, value: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-snapshot-page-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 7, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "message", entityKey: message.rawValue), sourceEventID: .init(uuid: UUID()), sequence: 7,
            payload: snapshotMessagePayload(messageID: message.rawValue, roomID: room.rawValue, text: "resumed page", revision: 1, isWithdrawn: false))
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        let page = try #require(fixture.pages.first)
        func candidate() throws -> V2ClientSnapshotPage {
            try V2ClientSnapshotPage(index: field == "index" ? value : page.index, digest: page.digest,
            firstKey: page.firstKey, lastKey: page.lastKey, itemCount: field == "itemCount" ? value : page.itemCount, payload: page.payload)
        }
        do {
            try await store.beginReset(reset)
            try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 7, capabilityProfile: "base"))
            let before = try await store.cursor()
            if (field == "index" && value != 0) || (field == "itemCount" && value != 1) {
                let expected: V2ClientSyncError = field == "index" ? .snapshotMismatch : .snapshotProjectionConflict
                await #expect(throws: expected) { try await store.applySnapshotPage(try candidate(), for: fixture.manifest) }
                #expect(try await store.cursor() == before)
                #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == 0)
                try await store.applySnapshotPage(page, for: fixture.manifest)
            } else {
                try await store.applySnapshotPage(try candidate(), for: fixture.manifest)
            }
            #expect(try await store.nextSnapshotPageIndex(for: fixture.manifest) == 1)
            try await store.prepareSnapshotActivation(fixture.manifest)
            try await store.activateAcknowledgedSnapshot(fixture.manifest)
            #expect(try await store.cursor()?.appliedSequence == 7)
            #expect(try await store.cursor()?.pendingReset == nil)
            let restored = try await store.messages(in: room)
            #expect(restored.map(\.messageID) == [message])
            #expect(restored.map(\.text) == ["resumed page"])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("snapshot reset stays fenced until durable snapshot acknowledgement")
    func resetSnapshotFence() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let snapshotID = try SnapshotID("00000000-0000-0000-0000-000000000203")
        let reset = try V2ClientResetRequired(
            snapshotID: snapshotID,
            generation: 2,
            baseSequence: 7,
            expiresAt: .distantFuture
        )
        let transport = FakeTransport(pullResult: .resetRequired(reset))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        #expect(try await store.cursor()?.state == .resetPending)
        try await engine.completePendingReset()
        let cursor = try #require(await store.cursor())
        #expect(cursor.state == .ready)
        #expect(cursor.generation == 2)
        #expect(cursor.appliedSequence == 7)
        #expect(cursor.serverAcknowledgedSequence == 7)
        #expect(await transport.snapshotAcknowledgementCount() == 1)
    }

    @Test("V3 snapshot atomically replaces typed projections and preserves withdrawn-message privacy")
    func snapshotV3AtomicallyReplacesProjection() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let old = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000229"),
            projectionKind: "message",
            payload: messagePayload(text: "old")
        )
        _ = try await store.apply(.init(
            generation: 1,
            records: [old],
            nextSyncToken: .init("before-v3-reset"),
            receipt: .init("before-v3-reset-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        ))

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000230"),
            generation: 2,
            baseSequence: 6,
            expiresAt: .distantFuture
        )
        let messageID = try MessageID("00000000-0000-0000-0000-000000000232")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000233")
        let relationshipTarget = try UserID("00000000-0000-0000-0000-000000000247")
        let items = [
            try V2SnapshotProjectionItem(
                key: .init(projectionKind: "message", entityKey: messageID.rawValue),
                sourceEventID: .init("00000000-0000-0000-0000-000000000231"),
                sequence: 2,
                payload: snapshotMessagePayload(
                    messageID: messageID.rawValue,
                    roomID: roomID.rawValue,
                    text: "[removed]",
                    revision: 2,
                    isWithdrawn: true
                )
            ),
            try V2SnapshotProjectionItem(
                key: .init(projectionKind: "relationship", entityKey: relationshipTarget.rawValue),
                sourceEventID: .init("00000000-0000-0000-0000-000000000248"),
                sequence: 3,
                payload: socialPayload([
                    "target_user_id": relationshipTarget.rawValue,
                    "state": "accepted",
                    "updated_at_ms": 1_750_000_010_000,
                ])
            ),
        ]
        let transport = try ProjectionSnapshotTransport(
            reset: reset,
            pages: [.init(items: items)]
        )
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()

        #expect(try await store.messages(in: .init("00000000-0000-0000-0000-000000000220")).isEmpty)
        let restored = try #require(await store.messages(in: roomID).first)
        #expect(restored.messageID == messageID)
        #expect(restored.text == "[removed]")
        #expect(restored.messageRevision == 2)
        #expect(restored.isWithdrawn)
        #expect(try await store.reactions(for: messageID).isEmpty)
        #expect(try await store.relationships() == [
            .init(
                targetUserID: relationshipTarget,
                state: .accepted,
                requestedByUserID: nil,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_010)
            )
        ])
        #expect(try await store.events().isEmpty)
        #expect(try await store.cursor()?.appliedSequence == 6)
    }

    @Test("V3 snapshot restores ordered reaction presence and removal", arguments: [false, true])
    func snapshotV3RestoresIndependentReaction(removed: Bool) async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let messageID = try MessageID("00000000-0000-0000-0000-000000000001")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000220")
        let actorID = try UserID("00000000-0000-0000-0000-000000000222")
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-0000000002d0"),
            generation: 2,
            baseSequence: 2,
            expiresAt: .distantFuture
        )
        let reaction = "👍"
        let items = [
            try V2SnapshotProjectionItem(
                key: .init(projectionKind: "message", entityKey: messageID.rawValue),
                sourceEventID: .init("00000000-0000-0000-0000-0000000002d1"),
                sequence: 1,
                payload: snapshotMessagePayload(
                    messageID: messageID.rawValue,
                    roomID: roomID.rawValue,
                    text: "snapshot reaction",
                    revision: 1,
                    isWithdrawn: false
                )
            ),
            try V2SnapshotProjectionItem(
                key: .init(
                    projectionKind: "message_reaction",
                    entityKey: "\(messageID.rawValue):\(actorID.rawValue):\(reaction)"
                ),
                sourceEventID: .init("00000000-0000-0000-0000-0000000002d2"),
                sequence: 2,
                payload: reactionPayload(action: removed ? "remove" : "add")
            ),
        ]
        let transport = try ProjectionSnapshotTransport(reset: reset, pages: [.init(items: items)])
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        try await engine.completePendingReset()

        #expect(try await store.reactions(for: messageID) == (removed ? [] : [
            .init(roomID: roomID, messageID: messageID, actorUserID: actorID, reaction: reaction)
        ]))
        if removed {
            _ = try await store.applyForegroundGroupEventPreviewPage(.init(roomID: roomID, events: [try .init(sourceEventID: .init("old-reaction-add"), roomSequence: 2, projectionKind: "message_reaction", payload: reactionPayload(action: "add"))], nextRoomSequence: 2, hasMore: false))
            #expect(try await store.reactions(for: messageID).isEmpty)
        }
    }

    @Test("an interrupted snapshot keeps the ready projection and resumes only missing pages")
    func snapshotStagingResumesAfterInterruption() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let existing = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000209"), projectionKind: "message", payload: messagePayload(text: "ready"))
        _ = try await store.apply(.init(generation: 1, records: [existing], nextSyncToken: .init("before-reset"), receipt: .init("before-receipt"), hasMore: false, capabilityProfile: "base"))
        let reset = try V2ClientResetRequired(snapshotID: .init("00000000-0000-0000-0000-000000000210"), generation: 2, baseSequence: 4, expiresAt: .distantFuture)
        let transport = try ResumableSnapshotTransport(reset: reset)
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        let changes = await store.projectionChanges()
        var notifications = changes.makeAsyncIterator()
        #expect(await notifications.next() == .all)
        #expect(try await engine.synchronizeOnce() == .resetPending(reset))
        await #expect(throws: SnapshotInterruption.once) {
            try await engine.completePendingReset()
        }
        #expect(try await store.events() == [existing])
        #expect(try await store.cursor()?.state == .resetPending)

        #expect(changes.hub.take(changes.identifier) == nil)
        try await engine.completePendingReset()
        #expect(await notifications.next() == .all)
        #expect(try await store.events().isEmpty)
        #expect(try await store.cursor()?.state == .ready)
        #expect(await transport.pageRequests() == [0, 1, 1])
        #expect(await transport.snapshotAcknowledgements() == 1)
        try await store.close()
    }

    @Test("a crash after server snapshot ACK resumes from the durable shadow before pulling")
    func snapshotAckCrashWindowResumesSafely() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let existing = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000259"),
            projectionKind: "message",
            payload: messagePayload(text: "live-until-activation")
        )
        let oldReceipt = try V2SyncReceipt("before-ack-crash-receipt")
        _ = try await store.apply(.init(
            generation: 1,
            records: [existing],
            nextSyncToken: .init("before-ack-crash-token"),
            receipt: oldReceipt,
            hasMore: false,
            capabilityProfile: "base"
        ))
        try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: oldReceipt)

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000260"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantFuture
        )
        let transport = try SnapshotCrashWindowTransport(reset: reset)
        try await store.beginReset(reset)
        let manifest = await transport.fetchSnapshotManifest(for: reset)
        try await store.beginSnapshotImport(
            manifest,
            initialDigest: V2SnapshotV3Digest.initial(
                baseSequence: reset.baseSequence,
                capabilityProfile: manifest.capabilityProfile
            )
        )
        // This represents the durable server commit followed by process death
        // before the client can activate its local shadow projection.
        try await transport.acknowledgeSnapshot(manifest)
        #expect(try await store.events() == [existing])

        let restarted = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )
        #expect(try await restarted.synchronizeOnce() == .resetPending(reset))
        #expect(await transport.pullCount() == 0)
        try await restarted.completePendingReset()

        let cursor = try #require(await store.cursor())
        #expect(cursor.state == .ready)
        #expect(cursor.generation == 2)
        #expect(try await store.events().isEmpty)
        #expect(await transport.manifestRequestCount() == 1)
        #expect(await transport.snapshotAcknowledgementCount() == 2)
    }

    @Test("a server-rejected expired snapshot restores the exact pre-reset cursor")
    func rejectedSnapshotRestoresPreviousCursor() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let existing = try V2ClientSyncRecord(
            sequence: 1,
            sourceEventID: .init("00000000-0000-0000-0000-000000000261"),
            projectionKind: "message",
            payload: messagePayload(text: "preserved-after-expiry")
        )
        let oldToken = try V2SyncToken("before-expired-reset-token")
        let oldReceipt = try V2SyncReceipt("before-expired-reset-receipt")
        _ = try await store.apply(.init(
            generation: 1,
            records: [existing],
            nextSyncToken: oldToken,
            receipt: oldReceipt,
            hasMore: false,
            capabilityProfile: "base"
        ))
        try await store.markServerAcknowledged(generation: 1, sequence: 1, receipt: oldReceipt)

        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000262"),
            generation: 2,
            baseSequence: 1,
            expiresAt: .distantPast
        )
        let transport = try SnapshotCrashWindowTransport(
            reset: reset,
            acknowledgementError: .server(
                code: "RESET_REQUIRED",
                retryable: false,
                retryAfterSeconds: 0,
                currentRevision: nil
            )
        )
        try await store.beginReset(reset)
        let engine = V2SyncEngine(
            transport: transport,
            store: store,
            capabilityProfile: "base"
        )

        await #expect(throws: V2RealtimeTransportError.server(
            code: "RESET_REQUIRED",
            retryable: false,
            retryAfterSeconds: 0,
            currentRevision: nil
        )) {
            try await engine.completePendingReset()
        }

        let cursor = try #require(await store.cursor())
        #expect(cursor.state == .ready)
        #expect(cursor.generation == 1)
        #expect(cursor.appliedSequence == 1)
        #expect(cursor.serverAcknowledgedSequence == 1)
        #expect(cursor.syncToken == nil)
        #expect(cursor.pendingReset == nil)
        #expect(try await store.events() == [existing])

        let replayTransport = FakeTransport(pullResult: .ready(try .init(
            generation: 1,
            records: [],
            nextSyncToken: try .init("after-expired-reset-token"),
            receipt: try .init("after-expired-reset-receipt"),
            hasMore: false,
            capabilityProfile: "base"
        )))
        let recoveryEngine = V2SyncEngine(
            transport: replayTransport,
            store: store,
            capabilityProfile: "base"
        )
        #expect(try await recoveryEngine.synchronizeOnce() == .synchronized(
            appliedThrough: 1,
            hasMore: false
        ))
        #expect(await replayTransport.acknowledgements().isEmpty)
        #expect(try await store.cursor()?.serverAcknowledgedSequence == 1)
        #expect(try await store.cursor()?.syncToken == .init("after-expired-reset-token"))
        #expect(try await store.events() == [existing])
    }

    @Test("availability-driven sync drains all contiguous batches")
    func drainsUntilCaughtUp() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let first = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000206"), projectionKind: "message", payload: messagePayload(text: "first"))
        let second = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("00000000-0000-0000-0000-000000000207"), projectionKind: "message", payload: messagePayload(roomSequence: 2, text: "second"))
        let transport = SequencedTransport(results: [
            .ready(try .init(generation: 1, records: [first], nextSyncToken: try .init("token-4"), receipt: try .init("receipt-4"), hasMore: true, capabilityProfile: "base")),
            .ready(try .init(generation: 1, records: [second], nextSyncToken: try .init("token-5"), receipt: try .init("receipt-5"), hasMore: false, capabilityProfile: "base")),
        ])
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")

        #expect(try await engine.synchronizeUntilCaughtUp() == .synchronized(appliedThrough: 2, hasMore: false))
        #expect(await transport.pullCount() == 2)
        #expect(try await store.events() == [first, second])
    }

    @Test("availability runner turns a hint into durable sync work")
    func availabilityRunnerTriggersSync() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000208"), projectionKind: "message", payload: messagePayload(text: "hint"))
        let engine = V2SyncEngine(
            transport: FakeTransport(pullResult: .ready(try .init(generation: 1, records: [record], nextSyncToken: try .init("token-6"), receipt: try .init("receipt-6"), hasMore: false, capabilityProfile: "base"))),
            store: store,
            capabilityProfile: "base"
        )
        let runner = V2AvailabilityDrivenSyncRunner(source: OneHintThenStopSource(), syncEngine: engine)

        await #expect(throws: AvailabilityStop.finished) {
            try await runner.run()
        }
        #expect(try await store.events() == [record])
    }

    @Test("availability runner flushes durable commands after the projection is synchronized")
    func availabilityRunnerFlushesAfterSync() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: .init("00000000-0000-0000-0000-000000000209"), projectionKind: "message", payload: messagePayload(text: "flush"))
        let engine = V2SyncEngine(
            transport: FakeTransport(pullResult: .ready(try .init(generation: 1, records: [record], nextSyncToken: try .init("token-7"), receipt: try .init("receipt-7"), hasMore: false, capabilityProfile: "base"))),
            store: store,
            capabilityProfile: "base"
        )
        let flushRecorder = AvailabilityFlushRecorder()
        let runner = V2AvailabilityDrivenSyncRunner(
            source: OneHintThenStopSource(),
            syncEngine: engine,
            afterSynchronization: { await flushRecorder.record() }
        )

        await #expect(throws: AvailabilityStop.finished) {
            try await runner.run()
        }

        #expect(try await store.events() == [record])
        #expect(await flushRecorder.count() == 1)
    }

    @Test("availability runner completes a reset before post-sync effects")
    func availabilityRunnerCompletesReset() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000210"),
            generation: 2,
            baseSequence: 7,
            expiresAt: .distantFuture
        )
        let transport = FakeTransport(pullResult: .resetRequired(reset))
        let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        let recorder = AvailabilityFlushRecorder()
        let runner = V2AvailabilityDrivenSyncRunner(
            source: OneHintThenStopSource(),
            syncEngine: engine,
            afterSynchronization: { await recorder.record() }
        )

        await #expect(throws: AvailabilityStop.finished) {
            try await runner.run()
        }

        #expect(try await store.cursor()?.state == .ready)
        #expect(await transport.snapshotAcknowledgementCount() == 1)
        #expect(await recorder.count() == 1)
    }

    @Test("a second snapshot swaps the already-renamed projection bank")
    func repeatedSnapshotActivation() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        for generation in UInt64(2) ... 3 {
            let reset = try V2ClientResetRequired(
                snapshotID: .init("00000000-0000-0000-0000-0000000002e\(generation)"),
                generation: generation,
                baseSequence: generation,
                expiresAt: .distantFuture
            )
            let transport = try ProjectionSnapshotTransport(reset: reset, pages: [])
            let engine = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
            #expect(try await engine.synchronizeOnce() == .resetPending(reset))
            try await engine.completePendingReset()
            #expect(try await store.cursor()?.generation == generation)
        }
    }

    @Test("message effect migration resumes a snapshot staged by the previous schema", arguments: [false, true])
    func messageEffectMigrationPreservesSnapshot(prepared: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let reset = try V2ClientResetRequired(snapshotID: .init("effect-upgrade-snapshot"), generation: 2, baseSequence: 0, expiresAt: .distantFuture)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 0, capabilityProfile: "base"))
        if prepared { try await store.prepareSnapshotActivation(fixture.manifest) }
        try await store.close()
        let old = try DatabasePool(path: url.path)
        try await old.write { db in
            try db.execute(sql: "DROP TABLE v2_message_effects")
            try db.execute(sql: "DROP TABLE v2_snapshot_shadow_message_effects")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'recordSharedMessageEffects'")
        }
        try old.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        try await reopened.prepareSnapshotActivation(fixture.manifest)
        try await reopened.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await reopened.cursor()?.generation == 2)
        try await reopened.cleanupRetiredSnapshotTables()
    }

    @Test("prepared snapshot fences local projection writers until cancellation")
    func preparedSnapshotFencesProjectionWrites() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-0000000002e4"),
            generation: 2,
            baseSequence: 0,
            expiresAt: .distantFuture
        )
        let fixture = try makeSnapshotFixture(reset: reset, pages: [])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(
            fixture.manifest,
            initialDigest: V2SnapshotV3Digest.initial(baseSequence: 0, capabilityProfile: "base")
        )
        try await store.prepareSnapshotActivation(fixture.manifest)

        await #expect(throws: V2ClientSyncError.resetPending) {
            try await store.cacheDirectRoomIdentity(
                roomID: .init("00000000-0000-0000-0000-0000000002e5"),
                publicIdentity: .init(
                    userID: .init("00000000-0000-0000-0000-0000000002e6"),
                    handle: .init("prepared_fence"),
                    displayName: "准备阶段 fence",
                    accountKind: .regular
                )
            )
        }
        try await store.cancelReset(reset)
        try await store.cacheDirectRoomIdentity(
            roomID: .init("00000000-0000-0000-0000-0000000002e5"),
            publicIdentity: .init(
                userID: .init("00000000-0000-0000-0000-0000000002e6"),
                handle: .init("prepared_fence"),
                displayName: "准备阶段 fence",
                accountKind: .regular
            )
        )
    }
}

private actor FakeTransport: V2ClientSyncTransport {
    private let pullResult: V2ClientPullResult
    private var acknowledgementsLog: [Acknowledgement] = []
    private var snapshotAcknowledgements = 0

    init(pullResult: V2ClientPullResult) { self.pullResult = pullResult }
    func pull(syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool) -> V2ClientPullResult { pullResult }
    func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) { acknowledgementsLog.append(.init(generation: generation, sequence: highestContiguousSequence, receipt: receipt)) }
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest {
        try makeSnapshotFixture(reset: reset, pages: []).manifest
    }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index _: Int) throws -> V2ClientSnapshotPage {
        throw V2ClientSyncError.snapshotMismatch
    }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) { snapshotAcknowledgements += 1 }
    func acknowledgements() -> [Acknowledgement] { acknowledgementsLog }
    func snapshotAcknowledgementCount() -> Int { snapshotAcknowledgements }
}

private actor GroupEventTransportFake: V2ClientGroupEventTransport {
    private let page: V2ClientGroupEventPage
    private var cursors: [UInt64] = []

    init(page: V2ClientGroupEventPage) { self.page = page }

    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize _: Int) throws -> V2ClientGroupEventPage {
        guard roomID == page.roomID else { throw V2RealtimeTransportError.unexpectedResponse }
        cursors.append(afterRoomSequence)
        return page
    }

    func requestedCursors() -> [UInt64] { cursors }
}

private struct ForbiddenGroupEventTransport: V2ClientGroupEventTransport {
    func pullGroupEvents(roomID _: RoomID, afterRoomSequence _: UInt64, pageSize _: Int) throws -> V2ClientGroupEventPage {
        throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
    }
}

private actor BackgroundGroupEventStoreFake: V2LocalGroupEventStore {
    private var roomIDs: [RoomID]
    private var cursors: [RoomID: UInt64] = [:]
    private var backgroundCursor: RoomID?

    init(roomIDs: [RoomID]) {
        self.roomIDs = roomIDs
    }

    func knownRoomLogRoomIDs(after roomID: RoomID?, limit: Int) -> [RoomID] {
        let sorted = roomIDs.sorted { $0.rawValue < $1.rawValue }
        let matching = roomID.map { cursor in
            sorted.filter { $0.rawValue > cursor.rawValue }
        } ?? sorted
        return matching.prefix(limit).map { $0 }
    }
    func lastKnownRoomLogRoomID() -> RoomID? { roomIDs.max { $0.rawValue < $1.rawValue } }
    func hybridGroupBackgroundCursor() -> RoomID? { backgroundCursor }
    func setHybridGroupBackgroundCursor(_ roomID: RoomID?) { backgroundCursor = roomID }
    func isKnownRoomLogRoom(roomID: RoomID) -> Bool { roomIDs.contains(roomID) }
    func markRoomEventUnauthorized(roomID: RoomID) { roomIDs.removeAll { $0 == roomID } }
    func groupEventCursor(roomID: RoomID) -> UInt64 { cursors[roomID, default: 0] }
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) -> UInt64 {
        cursors[page.roomID] = page.nextRoomSequence
        return page.nextRoomSequence
    }
    func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) throws -> V2GroupEventPageCommit {
        let inserted = page.events.filter { $0.roomSequence > cursors[page.roomID, default: 0] }.count
        return try .init(appliedThrough: applyGroupEventPage(page), insertedEventCount: inserted)
    }
}

private actor BackgroundGroupEventTransportFake: V2ClientGroupEventTransport {
    private var requestedRooms: [RoomID] = []

    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize _: Int) throws -> V2ClientGroupEventPage {
        requestedRooms.append(roomID)
        return try .init(roomID: roomID, events: [], nextRoomSequence: afterRoomSequence + 1, hasMore: true)
    }

    func requestedRoomIDs() -> [RoomID] { requestedRooms }
}

private struct Acknowledgement: Equatable, Sendable {
    let generation: UInt64
    let sequence: UInt64
    let receipt: V2SyncReceipt
}

private actor SequencedTransport: V2ClientSyncTransport {
    private var results: [V2ClientPullResult]
    private var pulls = 0

    init(results: [V2ClientPullResult]) { self.results = results }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool) throws -> V2ClientPullResult {
        pulls += 1
        guard !results.isEmpty else { throw V2ClientSyncError.invalidRecordOrdering }
        return results.removeFirst()
    }

    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for _: V2ClientResetRequired) throws -> V2ClientSnapshotManifest { throw V2ClientSyncError.snapshotMismatch }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index _: Int) throws -> V2ClientSnapshotPage { throw V2ClientSyncError.snapshotMismatch }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
    func pullCount() -> Int { pulls }
}

private actor LostIncrementalACKTransport: V2ClientSyncTransport {
    enum Failure: Error { case responseLost }

    private let first: V2ClientSyncBatch
    private let retry: V2ClientSyncBatch
    private var pulls = 0
    private var tokens: [V2SyncToken?] = []
    private var receipts: [V2SyncReceipt] = []

    init(first: V2ClientSyncBatch, retry: V2ClientSyncBatch) {
        self.first = first
        self.retry = retry
    }

    func pull(syncToken: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool) -> V2ClientPullResult {
        tokens.append(syncToken)
        pulls += 1
        return .ready(pulls == 1 ? first : retry)
    }

    func acknowledge(
        generation _: UInt64,
        highestContiguousSequence _: UInt64,
        receipt: V2SyncReceipt
    ) throws {
        receipts.append(receipt)
        if receipts.count == 1 { throw Failure.responseLost }
    }

    func fetchSnapshotManifest(
        for _: V2ClientResetRequired
    ) throws -> V2ClientSnapshotManifest { throw V2ClientSyncError.snapshotMismatch }

    func fetchSnapshotPage(
        for _: V2ClientSnapshotManifest,
        index _: Int
    ) throws -> V2ClientSnapshotPage { throw V2ClientSyncError.snapshotMismatch }

    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
    func requestedTokens() -> [V2SyncToken?] { tokens }
    func acknowledgementReceipts() -> [V2SyncReceipt] { receipts }
}

private actor ExpiredSyncTokenTransport: V2ClientSyncTransport {
    private let batch: V2ClientSyncBatch
    private var tokens: [V2SyncToken?] = []

    init(batch: V2ClientSyncBatch) { self.batch = batch }

    func pull(syncToken: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool) throws -> V2ClientPullResult {
        tokens.append(syncToken)
        if syncToken != nil {
            throw V2RealtimeTransportError.server(
                code: "SYNC_TOKEN_INVALID",
                retryable: false,
                retryAfterSeconds: 0,
                currentRevision: nil
            )
        }
        return .ready(batch)
    }

    func acknowledge(
        generation _: UInt64,
        highestContiguousSequence _: UInt64,
        receipt _: V2SyncReceipt
    ) {}

    func fetchSnapshotManifest(
        for _: V2ClientResetRequired
    ) throws -> V2ClientSnapshotManifest { throw V2ClientSyncError.snapshotMismatch }

    func fetchSnapshotPage(
        for _: V2ClientSnapshotManifest,
        index _: Int
    ) throws -> V2ClientSnapshotPage { throw V2ClientSyncError.snapshotMismatch }

    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
    func requestedTokens() -> [V2SyncToken?] { tokens }
}

private enum SnapshotInterruption: Error { case once }

private actor ResumableSnapshotTransport: V2ClientSyncTransport {
    private let reset: V2ClientResetRequired
    private let fixture: SnapshotFixture
    private var didInterrupt = false
    private var requestedPages: [Int] = []
    private var acknowledgements = 0

    init(reset: V2ClientResetRequired) throws {
        self.reset = reset
        let target1 = "00000000-0000-0000-0000-000000000211"
        let target2 = "00000000-0000-0000-0000-000000000212"
        fixture = try makeSnapshotFixture(reset: reset, pages: [
            .init(items: [
                .init(
                    key: .init(projectionKind: "relationship", entityKey: target1),
                    sourceEventID: .init("00000000-0000-0000-0000-000000000213"),
                    sequence: 2,
                    payload: socialPayload([
                        "target_user_id": target1,
                        "state": "accepted",
                        "updated_at_ms": 1_750_000_000_000,
                    ])
                )
            ]),
            .init(items: [
                .init(
                    key: .init(projectionKind: "user_block", entityKey: target2),
                    sourceEventID: .init("00000000-0000-0000-0000-000000000214"),
                    sequence: 3,
                    payload: socialPayload([
                        "target_user_id": target2,
                        "is_blocked": true,
                        "updated_at_ms": 1_750_000_001_000,
                    ])
                )
            ]),
        ])
    }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool) -> V2ClientPullResult { .resetRequired(reset) }
    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for _: V2ClientResetRequired) -> V2ClientSnapshotManifest { fixture.manifest }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) throws -> V2ClientSnapshotPage {
        requestedPages.append(index)
        if index == 1, !didInterrupt {
            didInterrupt = true
            throw SnapshotInterruption.once
        }
        return fixture.pages[index]
    }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) { acknowledgements += 1 }
    func pageRequests() -> [Int] { requestedPages }
    func snapshotAcknowledgements() -> Int { acknowledgements }
}

private actor SnapshotCrashWindowTransport: V2ClientSyncTransport {
    private let reset: V2ClientResetRequired
    private let fixture: SnapshotFixture
    private let acknowledgementError: V2RealtimeTransportError?
    private var pulls = 0
    private var manifestRequests = 0
    private var snapshotAcknowledgements = 0

    init(
        reset: V2ClientResetRequired,
        acknowledgementError: V2RealtimeTransportError? = nil
    ) throws {
        self.reset = reset
        self.acknowledgementError = acknowledgementError
        fixture = try makeSnapshotFixture(reset: reset, pages: [])
    }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool) -> V2ClientPullResult {
        pulls += 1
        return .resetRequired(reset)
    }

    func acknowledge(
        generation _: UInt64,
        highestContiguousSequence _: UInt64,
        receipt _: V2SyncReceipt
    ) {}

    func fetchSnapshotManifest(for _: V2ClientResetRequired) -> V2ClientSnapshotManifest {
        manifestRequests += 1
        return fixture.manifest
    }

    func fetchSnapshotPage(
        for _: V2ClientSnapshotManifest,
        index _: Int
    ) throws -> V2ClientSnapshotPage {
        throw V2ClientSyncError.snapshotMismatch
    }

    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) throws {
        snapshotAcknowledgements += 1
        if let acknowledgementError { throw acknowledgementError }
    }

    func pullCount() -> Int { pulls }
    func manifestRequestCount() -> Int { manifestRequests }
    func snapshotAcknowledgementCount() -> Int { snapshotAcknowledgements }
}

private struct ProjectionSnapshotTransport: V2ClientSyncTransport {
    let reset: V2ClientResetRequired
    let fixture: SnapshotFixture

    init(reset: V2ClientResetRequired, pages: [V2SnapshotProjectionV3Page]) throws {
        self.reset = reset
        fixture = try makeSnapshotFixture(reset: reset, pages: pages)
    }

    func pull(syncToken _: V2SyncToken?, maxRecords _: Int, requireSnapshot _: Bool) -> V2ClientPullResult { .resetRequired(reset) }
    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for _: V2ClientResetRequired) -> V2ClientSnapshotManifest { fixture.manifest }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) -> V2ClientSnapshotPage { fixture.pages[index] }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
}

private enum AvailabilityStop: Error { case finished }

private actor OneHintThenStopSource: V2SyncAvailabilityHintSource {
    private var emitted = false

    func nextAvailabilityHint() throws -> V2SyncAvailabilityHint {
        guard !emitted else { throw AvailabilityStop.finished }
        emitted = true
        return .init(eventID: 1, highWatermark: 1)
    }
}

private actor AvailabilityFlushRecorder {
    private var flushes = 0
    func record() { flushes += 1 }
    func count() -> Int { flushes }
}

private struct SnapshotFixture {
    let manifest: V2ClientSnapshotManifest
    let pages: [V2ClientSnapshotPage]
}

private func makeSnapshotFixture(
    reset: V2ClientResetRequired,
    pages: [V2SnapshotProjectionV3Page],
    capabilityProfile: String = "base"
) throws -> SnapshotFixture {
    var rolling = V2SnapshotV3Digest.initial(
        baseSequence: reset.baseSequence,
        capabilityProfile: capabilityProfile
    )
    var totalBytes: UInt64 = 0
    var totalItems: UInt64 = 0
    var encoded: [(payload: Data, digest: String, page: V2SnapshotProjectionV3Page)] = []
    for (index, page) in pages.enumerated() {
        let payload = try V2SnapshotProjectionV3Codec.encode(page)
        let digest = V2SnapshotV3Digest.page(payload)
        rolling = V2SnapshotV3Digest.next(
            previous: rolling,
            pageIndex: UInt32(index),
            pageDigest: digest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: UInt32(page.items.count)
        )
        totalBytes += UInt64(payload.count)
        totalItems += UInt64(page.items.count)
        encoded.append((payload, digest, page))
    }
    let manifest = try V2ClientSnapshotManifest(
        reset: reset,
        rootDigest: rolling,
        pageCount: pages.count,
        totalItems: totalItems,
        totalBytes: totalBytes,
        nextSyncToken: .init("snapshot-v3-token"),
        receipt: .init("snapshot-v3-receipt"),
        capabilityProfile: capabilityProfile
    )
    return .init(
        manifest: manifest,
        pages: try encoded.enumerated().map { index, value in
            try .init(
                index: index,
                digest: value.digest,
                firstKey: value.page.firstKey,
                lastKey: value.page.lastKey,
                itemCount: value.page.items.count,
                payload: value.payload
            )
        }
    )
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "im-v2-client-\(UUID().uuidString).sqlite")
}

#if canImport(Darwin)
private func backupEligibleTestDirectory() throws -> URL {
    guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw CocoaError(.fileNoSuchFile)
    }
    let directory = applicationSupport
        .appendingPathComponent("IMV2ClientKitTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
#endif

private let testInstallationBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

private func messagePayload(roomID: String = "00000000-0000-0000-0000-000000000220", roomSequence: UInt64 = 1, messageID: String? = nil, text: String, mentionedUserIDs: [String] = [], mentionsEveryone: Bool = false, createdAtMilliseconds: Int64 = 1_750_000_000_000) -> Data {
    try! JSONEncoder().encode(TestMessagePayload(roomID: roomID, roomSequence: roomSequence, messageID: messageID, text: text, mentionedUserIDs: mentionedUserIDs, mentionsEveryone: mentionsEveryone, createdAtMilliseconds: createdAtMilliseconds))
}

private func socialPayload(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private struct TestMessagePayload: Encodable {
    let eventType = "message.accepted"
    let messageID: String
    let roomID: String
    let roomSequence: UInt64
    let messageRevision: UInt64 = 1
    let senderUserID = "00000000-0000-0000-0000-000000000222"
    let text: String
    let mentionedUserIDs: [String]
    let mentionsEveryone: Bool
    let serverCreatedAtMilliseconds: Int64

    init(roomID: String, roomSequence: UInt64, messageID: String?, text: String, mentionedUserIDs: [String], mentionsEveryone: Bool, createdAtMilliseconds: Int64) {
        self.messageID = messageID ?? String(format: "00000000-0000-0000-0000-%012llu", roomSequence)
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.text = text
        self.mentionedUserIDs = mentionedUserIDs
        self.mentionsEveryone = mentionsEveryone
        self.serverCreatedAtMilliseconds = createdAtMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case messageID = "message_id"
        case roomID = "room_id"
        case roomSequence = "room_sequence"
        case messageRevision = "message_revision"
        case senderUserID = "sender_user_id"
        case text
        case mentionedUserIDs = "mention_user_ids"
        case mentionsEveryone = "mentions_everyone"
        case serverCreatedAtMilliseconds = "server_created_at_ms"
    }
}

private func withdrawalPayload() -> Data {
    try! JSONEncoder().encode(TestWithdrawalPayload(eventType: "message.withdrawn"))
}

private func redactionPayload() -> Data {
    try! JSONEncoder().encode(TestWithdrawalPayload(eventType: "message.redacted"))
}

private func reactionPayload(action: String) -> Data {
    try! JSONEncoder().encode(TestReactionPayload(action: action))
}

private func editPayload(text: String, revision: UInt64) -> Data {
    try! JSONEncoder().encode(TestEditPayload(text: text, messageRevision: revision))
}

private struct TestEditPayload: Encodable {
    let eventType = "message.edited"
    let roomID = "00000000-0000-0000-0000-000000000220"
    let messageID = "00000000-0000-0000-0000-000000000001"
    let text: String
    let messageRevision: UInt64
    enum CodingKeys: String, CodingKey { case eventType = "event_type"; case roomID = "room_id"; case messageID = "message_id"; case text; case messageRevision = "message_revision" }
}

private struct TestReactionPayload: Encodable {
    let eventType = "message.reaction_changed"
    let roomID = "00000000-0000-0000-0000-000000000220"
    let messageID = "00000000-0000-0000-0000-000000000001"
    let actorUserID = "00000000-0000-0000-0000-000000000222"
    let reaction = "👍"
    let action: String
    let roomSequence: UInt64
    init(action: String) { self.action = action; roomSequence = action == "add" ? 2 : 3 }
    enum CodingKeys: String, CodingKey { case eventType = "event_type"; case roomID = "room_id"; case messageID = "message_id"; case actorUserID = "actor_user_id"; case reaction; case action; case roomSequence = "room_sequence" }
}

private struct TestWithdrawalPayload: Encodable {
    let eventType: String
    let roomID = "00000000-0000-0000-0000-000000000220"
    let messageID = "00000000-0000-0000-0000-000000000001"
    let messageRevision: UInt64 = 2

    init(eventType: String) { self.eventType = eventType }
    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case roomID = "room_id"
        case messageID = "message_id"
        case messageRevision = "message_revision"
    }
}

private func snapshotMessagePayload(
    messageID: String,
    roomID: String,
    text: String,
    revision: UInt64,
    isWithdrawn: Bool
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "event_type": "message.accepted",
        "message_id": messageID,
        "room_id": roomID,
        "room_sequence": 7,
        "timeline_sequence": 7,
        "message_revision": revision,
        "sender_user_id": "00000000-0000-0000-0000-000000000234",
        "text": text,
        "media_ids": [],
        "media_presentations": [],
        "mention_user_ids": [],
        "mentions_everyone": false,
        "entities": [],
        "server_created_at_ms": 1_750_000_000_000,
        "is_withdrawn": isWithdrawn,
    ], options: [.sortedKeys])
}

private actor RebuildSnapshotTransport: V2ClientSyncTransport {
    enum ResponseLost: Error { case firstResponse }
    private let reset: V2ClientResetRequired
    private let fixture: SnapshotFixture
    private var flags: [Bool] = []
    private var absentTokens = true
    init(reset: V2ClientResetRequired) throws { self.reset = reset; fixture = try makeSnapshotFixture(reset: reset, pages: []) }
    func pull(syncToken: V2SyncToken?, maxRecords _: Int, requireSnapshot: Bool) throws -> V2ClientPullResult {
        flags.append(requireSnapshot)
        absentTokens = absentTokens && syncToken == nil
        if flags.count == 1 { throw ResponseLost.firstResponse }
        return .resetRequired(reset)
    }
    func acknowledge(generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt) {}
    func fetchSnapshotManifest(for _: V2ClientResetRequired) -> V2ClientSnapshotManifest { fixture.manifest }
    func fetchSnapshotPage(for _: V2ClientSnapshotManifest, index: Int) -> V2ClientSnapshotPage { fixture.pages[index] }
    func acknowledgeSnapshot(_: V2ClientSnapshotManifest) {}
    func rebuildFlags() -> [Bool] { flags }
    func tokensWereAbsent() -> Bool { absentTokens }
}

extension V2SyncEngineTests {
    @Test("announcement effects converge across preview, personal and room feeds after restart", arguments: [false, true])
    func announcementCrossFeedOrder(previewFirst: Bool) async throws {
        let url = temporaryDatabaseURL()
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let latest = try announcementFact(sequence: 1, revision: 2, body: "new", roomSequence: 20)
        let preview = try announcementPage(latest, sequence: 20)
        if previewFirst { _ = try await store.applyForegroundGroupEventPreviewPage(preview) }
        _ = try await store.apply(announcementBatch([latest]))
        if !previewFirst { _ = try await store.applyForegroundGroupEventPreviewPage(preview) }
        let old = try announcementFact(sequence: 2, revision: 1, body: "old", roomSequence: 10)
        _ = try await store.applyGroupEventPage(announcementPage(old, sequence: 10))
        _ = try await store.applyGroupEventPage(preview)
        _ = try await store.apply(announcementBatch([old]))
        #expect(try await store.groupAnnouncement(roomID: announcementRoom)?.body == "new")
        #expect(try await store.groupEventCursor(roomID: announcementRoom) == 20)
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(old, sequence: 10))
        for invalid in [
            try announcementFact(sequence: 3, revision: 2, body: "conflict", roomSequence: 20, source: "another-source"),
            try announcementFact(sequence: 3, revision: 1, body: "altered old fact", roomSequence: 10),
        ] {
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.apply(announcementBatch([invalid])) }
        }
        #expect(try await store.cursor()?.appliedSequence == 2)
        #expect(try await store.groupAnnouncement(roomID: announcementRoom)?.body == "new")
        try await store.close()
        let database = try DatabasePool(path: url.path)
        #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_announcement_effects") } == 2)
        #expect(try await database.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_announcements") } == 20)
        try database.close()
    }

    @Test("legacy announcement source sequence stays unknown until supplied and cannot change")
    func announcementSourceBoundary() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let legacy = try announcementFact(sequence: 1, revision: 1, body: "legacy", roomSequence: nil)
        _ = try await store.apply(announcementBatch([legacy]))
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_announcements") } == nil)
        let enriched = try announcementFact(sequence: 1, revision: 1, body: "legacy", roomSequence: 10)
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(enriched, sequence: 10))
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(legacy, sequence: 10))
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_announcements") } == 10)
        let changed = try announcementFact(sequence: 1, revision: 1, body: "legacy", roomSequence: 11)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyForegroundGroupEventPreviewPage(announcementPage(changed, sequence: 11)) }
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyForegroundGroupEventPreviewPage(announcementPage(enriched, sequence: 11)) }
        let wrongRoom = try V2ClientGroupEventPage(roomID: try .init("00000000-0000-0000-0000-000000009999"), events: try announcementPage(enriched, sequence: 10).events, nextRoomSequence: 10, hasMore: false)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyGroupEventPage(wrongRoom) }
        var object = try #require(JSONSerialization.jsonObject(with: enriched.payload) as? [String: Any])
        let invalidFields: [(String, Any)] = [("revision", 0), ("revision", true), ("revision", UInt64.max), ("room_sequence", 0), ("server_created_at_ms", -1), ("body", String(repeating: "x", count: 4_097)), ("room_id", "invalid"), ("actor_user_id", "invalid")]
        for (key, value) in invalidFields {
            var invalid = object; invalid[key] = value
            let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: enriched.sourceEventID, projectionKind: "group_capability", payload: try JSONSerialization.data(withJSONObject: invalid))
            #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try V2LocalAnnouncementEffect(record: record) }
        }
        object["room_id"] = announcementRoom.rawValue.lowercased()
        let normalized = try V2ClientSyncRecord(sequence: 1, sourceEventID: enriched.sourceEventID, projectionKind: "group_capability", payload: try JSONSerialization.data(withJSONObject: object))
        #expect(try V2LocalAnnouncementEffect(record: normalized).digest == V2LocalAnnouncementEffect(record: enriched).digest)
        try db.close()
        try await store.close()
    }

    @Test("empty announcement snapshot keeps revision and eligible old effect receipts")
    func announcementSnapshotOrdering() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let old = try announcementFact(sequence: 1, revision: 1, body: "old", roomSequence: 10)
        _ = try await store.apply(announcementBatch([old]))
        let empty = try announcementFact(sequence: 8, revision: 3, body: "", roomSequence: 30)
        let reset = try V2ClientResetRequired(snapshotID: .init("announcement-snapshot"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "announcement:\(announcementRoom.rawValue)"), sourceEventID: empty.sourceEventID, sequence: empty.sequence, payload: empty.payload)
        let engine = V2SyncEngine(transport: try ProjectionSnapshotTransport(reset: reset, pages: [.init(items: [item])]), store: store, capabilityProfile: "base")
        _ = try await engine.synchronizeOnce()
        try await engine.completePendingReset()
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(old, sequence: 10))
        let late = try announcementFact(sequence: 1, revision: 2, body: "late", roomSequence: 20)
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(late, sequence: 20))
        #expect(try await store.groupAnnouncement(roomID: announcementRoom)?.body == "")
        #expect(try await store.groupAnnouncement(roomID: announcementRoom)?.revision == 3)
        let conflict = try announcementFact(sequence: 1, revision: 1, body: "conflicting old receipt", roomSequence: 10)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyForegroundGroupEventPreviewPage(announcementPage(conflict, sequence: 10)) }
        try await store.close()
    }

    @Test("announcement migration preserves unknown proof and outbox while reimporting old staging", arguments: [false, true])
    func announcementMigration(prepared: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let latest = try announcementFact(sequence: 1, revision: 2, body: "keep live", roomSequence: 20)
        _ = try await store.apply(announcementBatch([latest]))
        let removedRoom = try RoomID("00000000-0000-0000-0000-000000009999")
        var removedPayload = try #require(JSONSerialization.jsonObject(with: latest.payload) as? [String: Any])
        removedPayload["room_id"] = removedRoom.rawValue
        let removed = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("removed-announcement"), projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: removedPayload))
        _ = try await store.apply(announcementBatch([removed]))
        let pending = V2PendingMessageCommand(roomID: announcementRoom, clientMessageID: try .init("00000000-0000-0000-0000-00000000AAAA"), text: "keep outbox", state: .pending, attemptCount: 0, nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(pending)
        let reset = try V2ClientResetRequired(snapshotID: .init("announcement-upgrade"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let replacement = try announcementFact(sequence: 8, revision: 3, body: "new baseline", roomSequence: nil)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "announcement:\(announcementRoom.rawValue)"), sourceEventID: replacement.sourceEventID, sequence: replacement.sequence, payload: replacement.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        if prepared { try await store.prepareSnapshotActivation(fixture.manifest) }
        try await store.close()
        let legacy = try DatabasePool(path: url.path)
        try await legacy.write { db in
            for table in ["v2_group_announcements", "v2_snapshot_shadow_group_announcements"] {
                try db.execute(sql: "ALTER TABLE \(table) RENAME TO temporary_announcement")
                try db.execute(sql: "CREATE TABLE \(table) (room_id TEXT PRIMARY KEY, body TEXT NOT NULL, revision INTEGER NOT NULL CHECK (revision > 0), room_sequence INTEGER NOT NULL CHECK (room_sequence > 0), updated_at REAL NOT NULL)")
                try db.execute(sql: "INSERT INTO \(table) SELECT lower(room_id), body, revision, 999, updated_at FROM temporary_announcement")
                try db.execute(sql: "DROP TABLE temporary_announcement")
            }
            try db.execute(sql: "INSERT INTO v2_group_announcements VALUES ('00000000-0000-0000-0000-00000000abcd', 'unlogged legacy', 4, 999, 4)")
            try db.execute(sql: "DELETE FROM v2_group_announcements WHERE room_id = ?", arguments: [removedRoom.rawValue])
            try db.execute(sql: "DROP TABLE v2_announcement_effects")
            try db.execute(sql: "DROP TABLE v2_snapshot_shadow_announcement_effects")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'orderAnnouncementEffects'")
        }
        try legacy.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        #expect(try await reopened.cursor()?.pendingReset == reset)
        #expect(try await reopened.importedSnapshotManifest(for: reset) == nil)
        #expect(try await reopened.pendingMessageCommands() == [pending])
        #expect(try await reopened.groupAnnouncement(roomID: removedRoom) == nil)
        #expect(try await reopened.groupAnnouncement(roomID: announcementRoom)?.body == "keep live")
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_announcements WHERE room_id = ?", arguments: [announcementRoom.rawValue]) } == 20)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_announcements WHERE room_id = '00000000-0000-0000-0000-00000000ABCD'") } == nil)
        try db.close()
        try await reopened.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await reopened.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        try await reopened.prepareSnapshotActivation(fixture.manifest)
        try await reopened.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await reopened.groupAnnouncement(roomID: announcementRoom)?.body == "new baseline")
        #expect(try await reopened.pendingMessageCommands() == [pending])
        try await reopened.close()
    }
}

private let announcementRoom = try! RoomID("00000000-0000-0000-0000-000000ABCDEF")
private func announcementFact(sequence: UInt64, revision: Int, body: String, roomSequence: Int?, source: String? = nil) throws -> V2ClientSyncRecord {
    var value: [String: Any] = ["event_type": "group.announcement_changed", "room_id": announcementRoom.rawValue, "actor_user_id": "00000000-0000-0000-0000-000000000123", "revision": revision, "body": body, "server_created_at_ms": revision * 1_000]
    if let roomSequence { value["room_sequence"] = roomSequence }
    return try .init(sequence: sequence, sourceEventID: .init(source ?? "announcement-\(revision)"), projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: value))
}
private func announcementPage(_ record: V2ClientSyncRecord, sequence: UInt64) throws -> V2ClientGroupEventPage {
    try .init(roomID: announcementRoom, events: [try .init(sourceEventID: record.sourceEventID, roomSequence: sequence, projectionKind: record.projectionKind, payload: record.payload)], nextRoomSequence: sequence, hasMore: false)
}
private func announcementBatch(_ records: [V2ClientSyncRecord]) throws -> V2ClientSyncBatch {
    try .init(generation: 1, records: records, nextSyncToken: .init("announcement-token"), receipt: .init("announcement-receipt"), hasMore: false, capabilityProfile: "base")
}

extension V2SyncEngineTests {
    @Test("role policies preserve explicit empty values and independent ordering across feeds and restart", arguments: [false, true])
    func rolePolicyEffectOrdering(previewFirst: Bool) async throws {
        let url = temporaryDatabaseURL()
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).isEmpty)
        let empty = try rolePolicyFact(sequence: 1, revision: 5, permissions: [], roomSequence: 50)
        if previewFirst { _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(empty, sequence: 50)) }
        _ = try await store.apply(announcementBatch([empty]))
        if !previewFirst { _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(empty, sequence: 50)) }
        let admin = try rolePolicyFact(sequence: 2, revision: 4, role: "admin", permissions: ["invite_members"], roomSequence: 40)
        _ = try await store.apply(announcementBatch([admin]))
        let old = try rolePolicyFact(sequence: 3, revision: 2, permissions: ["send_messages"], roomSequence: 20)
        _ = try await store.applyGroupEventPage(announcementPage(old, sequence: 20))
        _ = try await store.applyGroupEventPage(announcementPage(empty, sequence: 50))
        _ = try await store.apply(announcementBatch([old]))
        var policies = try await store.groupRolePolicies(roomID: announcementRoom)
        #expect(policies.count == 2)
        #expect(policies.first(where: { $0.role == .member })?.permissions == [])
        #expect(policies.first(where: { $0.role == .admin })?.permissions == [.inviteMembers])
        #expect(policies.allSatisfy { $0.revision == 5 })
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        for invalid in [
            try rolePolicyFact(sequence: 4, revision: 5, permissions: ["send_messages"], roomSequence: 50, source: "another-policy"),
            try rolePolicyFact(sequence: 4, revision: 2, permissions: [], roomSequence: 20),
            try rolePolicyFact(sequence: 4, revision: 2, role: "admin", permissions: ["send_messages"], roomSequence: 20, source: old.sourceEventID.rawValue),
        ] {
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.apply(announcementBatch([invalid])) }
        }
        #expect(try await store.cursor()?.appliedSequence == 3)
        policies = try await store.groupRolePolicies(roomID: announcementRoom)
        #expect(policies.first(where: { $0.role == .member })?.permissions == [])
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_role_policy_effects") } == 3)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT revision FROM v2_group_role_policies WHERE role = 'admin'") } == 4)
        try db.close()
        try await store.close()
    }

    @Test("role policy facts validate source identity, numeric domains and room envelopes")
    func rolePolicySourceBoundary() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let legacy = try rolePolicyFact(sequence: 1, revision: 2, permissions: ["send_messages", "invite_members"], roomSequence: nil)
        _ = try await store.apply(announcementBatch([legacy]))
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_role_policies") } == nil)
        let enriched = try rolePolicyFact(sequence: 1, revision: 2, permissions: ["invite_members", "send_messages"], roomSequence: 20)
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(enriched, sequence: 20))
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(legacy, sequence: 20))
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_role_policies") } == 20)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.applyForegroundGroupEventPreviewPage(announcementPage(enriched, sequence: 21))
        }
        let changed = try rolePolicyFact(sequence: 1, revision: 2, permissions: ["send_messages", "invite_members"], roomSequence: 21)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await store.applyForegroundGroupEventPreviewPage(announcementPage(changed, sequence: 21))
        }
        let wrongRoom = try V2ClientGroupEventPage(roomID: try .init("00000000-0000-0000-0000-000000009999"), events: try announcementPage(enriched, sequence: 20).events, nextRoomSequence: 20, hasMore: false)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyGroupEventPage(wrongRoom) }
        var object = try #require(JSONSerialization.jsonObject(with: enriched.payload) as? [String: Any])
        let invalidFields: [(String, Any)] = [("revision", 0), ("revision", true), ("revision", UInt64.max), ("room_sequence", 0), ("room_sequence", UInt64.max), ("server_created_at_ms", -1), ("role", "owner"), ("role", "invalid"), ("permissions", ["unknown"]), ("permissions", ["send_messages", "send_messages"]), ("room_id", "invalid"), ("actor_user_id", "invalid")]
        for (key, value) in invalidFields {
            var invalid = object; invalid[key] = value
            let record = try V2ClientSyncRecord(sequence: 1, sourceEventID: enriched.sourceEventID, projectionKind: "group_capability", payload: try JSONSerialization.data(withJSONObject: invalid))
            #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try V2LocalRolePolicyEffect(record: record) }
        }
        object["room_id"] = announcementRoom.rawValue.lowercased()
        let normalized = try V2ClientSyncRecord(sequence: 1, sourceEventID: enriched.sourceEventID, projectionKind: "group_capability", payload: try JSONSerialization.data(withJSONObject: object))
        #expect(try V2LocalRolePolicyEffect(record: normalized).digest == V2LocalRolePolicyEffect(record: legacy).digest)
        try db.close()
        try await store.close()
    }

    @Test("policy snapshot retains empty states and old receipts without using global revision for role ordering")
    func rolePolicySnapshot() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let old = try rolePolicyFact(sequence: 1, revision: 2, permissions: ["send_messages"], roomSequence: 20)
        _ = try await store.apply(announcementBatch([old]))
        let empty = try rolePolicyFact(sequence: 8, revision: 5, permissions: [], roomSequence: 50)
        let admin = try rolePolicyFact(sequence: 9, revision: 4, role: "admin", permissions: ["invite_members"], roomSequence: 40)
        let reset = try V2ClientResetRequired(snapshotID: .init("policy-snapshot"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let items = try [empty, admin].map { record in
            let effect = try V2LocalRolePolicyEffect(record: record)
            return try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "permissions:\(announcementRoom.rawValue):\(effect.role.rawValue)"), sourceEventID: record.sourceEventID, sequence: record.sequence, payload: record.payload)
        }.sorted { $0.key.entityKey < $1.key.entityKey }
        let engine = V2SyncEngine(transport: try ProjectionSnapshotTransport(reset: reset, pages: [.init(items: items)]), store: store, capabilityProfile: "base")
        _ = try await engine.synchronizeOnce()
        try await engine.completePendingReset()
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(old, sequence: 20))
        let policies = try await store.groupRolePolicies(roomID: announcementRoom)
        #expect(policies.first(where: { $0.role == .member })?.permissions == [])
        #expect(policies.first(where: { $0.role == .admin })?.permissions == [.inviteMembers])
        #expect(policies.allSatisfy { $0.revision == 5 })
        let conflict = try rolePolicyFact(sequence: 1, revision: 2, permissions: [], roomSequence: 20)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyForegroundGroupEventPreviewPage(announcementPage(conflict, sequence: 20)) }
        try await store.close()
    }

    @Test("policy migration preserves observed legacy values and outbox but leaves missing roles unknown", arguments: [false, true])
    func rolePolicyMigration(prepared: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let admin = try rolePolicyFact(sequence: 1, revision: 4, role: "admin", permissions: ["invite_members"], roomSequence: 40)
        let empty = try rolePolicyFact(sequence: 2, revision: 5, permissions: [], roomSequence: 50)
        _ = try await store.apply(announcementBatch([admin, empty]))
        let pending = V2PendingMessageCommand(roomID: announcementRoom, clientMessageID: try .init("00000000-0000-0000-0000-00000000AAAA"), text: "keep policy outbox", state: .pending, attemptCount: 0, nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(pending)
        let reset = try V2ClientResetRequired(snapshotID: .init("policy-upgrade"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "permissions:\(announcementRoom.rawValue):member"), sourceEventID: empty.sourceEventID, sequence: empty.sequence, payload: empty.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        if prepared { try await store.prepareSnapshotActivation(fixture.manifest) }
        try await store.close()
        let db = try DatabasePool(path: url.path)
        try await db.write { db in
            try db.execute(sql: "DROP TABLE v2_group_role_policies; DROP TABLE v2_role_policy_effects; DROP TABLE v2_snapshot_shadow_group_role_policies; DROP TABLE v2_snapshot_shadow_role_policy_effects")
            try db.execute(sql: "CREATE TABLE v2_group_role_permissions (room_id TEXT NOT NULL, role TEXT NOT NULL, permission TEXT NOT NULL, revision INTEGER NOT NULL, room_sequence INTEGER NOT NULL, PRIMARY KEY(room_id, role, permission))")
            try db.execute(sql: "CREATE TABLE v2_snapshot_shadow_group_role_permissions AS SELECT * FROM v2_group_role_permissions")
            try db.execute(sql: "INSERT INTO v2_group_role_permissions VALUES (?, 'admin', 'invite_members', 4, 999)", arguments: [announcementRoom.rawValue.lowercased()])
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'orderRolePolicyEffects'")
        }
        try db.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let policies = try await reopened.groupRolePolicies(roomID: announcementRoom)
        #expect(policies.count == 1)
        #expect(policies.first?.role == .admin)
        #expect(policies.first?.permissions == [.inviteMembers])
        #expect(policies.first?.revision == 5)
        #expect(try await reopened.pendingMessageCommands() == [pending])
        #expect(try await reopened.cursor()?.pendingReset == reset)
        let check = try DatabasePool(path: url.path)
        #expect(try await check.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_role_policies") } == nil)
        #expect(try await check.read { try String.fetchOne($0, sql: "SELECT source_event_id FROM v2_group_role_policies") } == nil)
        #expect(try await check.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_snapshot_import") } == 0)
        #expect(try await check.read { try $0.tableExists("v2_snapshot_shadow_group_role_permissions") } == false)
        try check.close()
        try await reopened.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await reopened.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        try await reopened.prepareSnapshotActivation(fixture.manifest)
        try await reopened.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await reopened.groupRolePolicies(roomID: announcementRoom).first?.permissions == [])
        #expect(try await reopened.pendingMessageCommands() == [pending])
        try await reopened.close()
    }
}

private func rolePolicyFact(sequence: UInt64, revision: Int, role: String = "member", permissions: [String], roomSequence: Int?, source: String? = nil, room: RoomID = announcementRoom) throws -> V2ClientSyncRecord {
    var value: [String: Any] = ["event_type": "group.role_permissions_changed", "room_id": room.rawValue, "actor_user_id": "00000000-0000-0000-0000-000000000123", "revision": revision, "role": role, "permissions": permissions, "server_created_at_ms": revision * 1_000]
    if let roomSequence { value["room_sequence"] = roomSequence }
    return try .init(sequence: sequence, sourceEventID: .init(source ?? "policy-\(role)-\(revision)"), projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: value))
}

extension V2SyncEngineTests {
    @Test("snapshot cannot reuse an already observed policy source identity for a new version")
    func rolePolicySnapshotIdentityConflict() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let old = try rolePolicyFact(sequence: 1, revision: 2, permissions: ["send_messages"], roomSequence: 20)
        _ = try await store.apply(announcementBatch([old]))
        let reused = try rolePolicyFact(sequence: 8, revision: 5, permissions: [], roomSequence: 50, source: old.sourceEventID.rawValue)
        let reset = try V2ClientResetRequired(snapshotID: .init("policy-conflict-snapshot"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "permissions:\(announcementRoom.rawValue):member"), sourceEventID: reused.sourceEventID, sequence: reused.sequence, payload: reused.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.prepareSnapshotActivation(fixture.manifest) }
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).first?.permissions == [.sendMessages])
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).first?.revision == 2)
        #expect(try await store.cursor()?.pendingReset == reset)
        try await store.close()
    }
}

extension V2SyncEngineTests {
    @Test("policy reads reject corrupt revisions before merging baseline and event state")
    func policyProjectionRevisionBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-policy-projection-revision-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        do {
            _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
            _ = try await store.enqueueMissingRolePolicyBaselines(limit: 1)
            let request = try #require(try await store.pendingRolePolicyBaselineRequests().first)
            _ = try await store.apply(announcementBatch([rolePolicyFact(sequence: 2, revision: 9, role: "admin", permissions: ["invite_members"], roomSequence: 90)]))
            #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request))
            let original = try await store.groupRolePolicyState(roomID: announcementRoom)
            let pool = await store.databasePool
            let fields = [("v2_group_permission_revisions", "revision"), ("v2_group_role_policy_baselines", "permission_revision"), ("v2_group_role_policies", "revision")]
            for (table, column) in fields {
                let previous = try await pool.read { try #require(try Int64.fetchOne($0, sql: "SELECT \(column) FROM \(table)")) }
                let fractional = Double(previous) + 0.5
                try await pool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [fractional]) }
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.groupRolePolicies(roomID: announcementRoom) }
                await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.groupRolePolicyState(roomID: announcementRoom) }
                #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT \(column) FROM \(table)") } == fractional)
                try await pool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [previous]) }
                #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == original)
                for value in [Int64.min, -1, 0] {
                    try await pool.write { db in
                        try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                        defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                        try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value])
                    }
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.groupRolePolicies(roomID: announcementRoom) }
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.groupRolePolicyState(roomID: announcementRoom) }
                    #expect(try await pool.read { try Int64.fetchOne($0, sql: "SELECT \(column) FROM \(table)") } == value)
                }
                try await pool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [previous]) }
                #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == original)
            }
            for value in [Int64(1), Int64.max] {
                try await pool.write { db in
                    for (table, column) in fields { try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value]) }
                }
                let policies = try await store.groupRolePolicies(roomID: announcementRoom)
                #expect(policies.count == 2)
                #expect(policies.allSatisfy { $0.revision == UInt64(value) })
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("policy recovery survives restart and merges a complete observation with newer source facts")
    func durablePolicyRecovery() async throws {
        let url = temporaryDatabaseURL()
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        #expect(try await store.enqueueMissingRolePolicyBaselines(limit: 1) == 1)
        #expect(try await store.enqueueMissingRolePolicyBaselines(limit: 1) == 0)
        let request = try #require(try await store.pendingRolePolicyBaselineRequests().first)
        #expect(try await store.requestRolePolicyBaseline(roomID: announcementRoom) == request)
        let pending = V2PendingMessageCommand(roomID: announcementRoom, clientMessageID: try .init("00000000-0000-0000-0000-00000000AAAA"), text: "recover without dropping outbox", state: .pending, attemptCount: 0, nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(pending)
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        #expect(try await store.pendingRolePolicyBaselineRequests() == [request])
        let newer = try rolePolicyFact(sequence: 2, revision: 9, role: "admin", permissions: ["invite_members"], roomSequence: 90)
        _ = try await store.apply(announcementBatch([newer]))
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request))
        var policies = try await store.groupRolePolicies(roomID: announcementRoom)
        #expect(policies.count == 2)
        #expect(policies.first(where: { $0.role == .admin })?.permissions == [.inviteMembers])
        #expect(policies.first(where: { $0.role == .member })?.permissions == [])
        #expect(policies.allSatisfy { $0.revision == 9 })
        #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
        let old = try rolePolicyFact(sequence: 3, revision: 7, permissions: ["send_messages"], roomSequence: 70)
        _ = try await store.apply(announcementBatch([old]))
        let atFloor = try rolePolicyFact(sequence: 4, revision: 8, permissions: [], roomSequence: 80)
        _ = try await store.apply(announcementBatch([atFloor]))
        for conflict in [try rolePolicyFact(sequence: 5, revision: 8, permissions: ["send_messages"], roomSequence: 80, source: "conflicting-floor"), try rolePolicyFact(sequence: 5, revision: 7, permissions: [], roomSequence: 70)] {
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.apply(announcementBatch([conflict])) }
        }
        #expect(try await store.cursor()?.appliedSequence == 4)
        let refresh = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 6, member: [.sendMessages]), for: refresh) == false)
        #expect(try await store.pendingRolePolicyBaselineRequests() == [refresh])
        policies = try await store.groupRolePolicies(roomID: announcementRoom)
        #expect(policies.first(where: { $0.role == .member })?.permissions == [])
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_role_policies WHERE role = 'member'") } == 0)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT permission_revision FROM v2_group_role_policy_baselines") } == 8)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_role_policy_effects") } == 3)
        try db.close()
        #expect(try await store.pendingMessageCommands() == [pending])
        await #expect(throws: V2RolePolicyRecoveryError.invalidBaseline) {
            try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 9), for: refresh)
        }
        #expect(try await store.pendingRolePolicyBaselineRequests() == [refresh])
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 10), for: refresh))
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).allSatisfy { $0.permissions.isEmpty && $0.revision == 10 })
        try await store.close()
    }

    @Test("policy recovery rejects changed membership, self-removal and revoked room access")
    func policyRecoveryMembershipFences() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        let first = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 2, revision: 3)]))
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, membership: 3), for: first) == false)
        #expect(try await store.enqueueMissingRolePolicyBaselines() == 1)
        let second = try #require(try await store.pendingRolePolicyBaselineRequests().first)
        #expect(second != first)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, membership: 3), for: first) == false)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, membership: 3), for: second))
        let inFlight = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        // Server UUID text can be lowercase; self-removal must still purge.
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 3, revision: 4, action: "remove", lowercased: true)]))
        #expect(try await store.roomProfile(roomID: announcementRoom) == nil)
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).isEmpty)
        #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 4, revision: 5)]))
        let rejoined = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, membership: 5), for: inFlight) == false)
        #expect(try await store.pendingRolePolicyBaselineRequests() == [rejoined])
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, membership: 5), for: rejoined))
        let revoked = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        try await store.markRoomEventUnauthorized(roomID: announcementRoom)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, membership: 5), for: revoked) == false)
        #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
        await #expect(throws: V2RolePolicyRecoveryError.roomUnauthorized) { try await store.requestRolePolicyBaseline(roomID: announcementRoom) }
        try await store.close()
    }

    @Test("policy baseline rejects invalid observations and account or installation substitutions")
    func policyRecoveryObservationFences() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        let request = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        let wrongRoom = try V2GroupRolePolicyBaseline(roomID: .init("00000000-0000-0000-0000-000000009999"), permissionRevision: 8, membershipRevision: 2, roomSequence: 80, adminPermissions: [], memberPermissions: [])
        for invalid in [wrongRoom, try policyRecoveryBaseline(revision: 8, membership: 1)] {
            await #expect(throws: V2RolePolicyRecoveryError.invalidBaseline) { try await store.completeRolePolicyBaseline(invalid, for: request) }
        }
        #expect(try await store.pendingRolePolicyBaselineRequests() == [request])
        let db = try DatabasePool(path: url.path)
        try await db.write { try $0.execute(sql: "UPDATE v2_local_installation SET user_id = ?", arguments: ["00000000-0000-0000-0000-000000001111"]) }
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request) == false)
        try await db.write { try $0.execute(sql: "UPDATE v2_local_installation SET user_id = ?, binding = ?", arguments: [policyRecoveryUser.rawValue, UUID().uuidString]) }
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request) == false)
        try await db.write { try $0.execute(sql: "UPDATE v2_local_installation SET binding = ?", arguments: [testInstallationBinding.value.uuidString]) }
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request))
        let refresh = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        await #expect(throws: V2RolePolicyRecoveryError.invalidBaseline) { try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, member: [.sendMessages]), for: refresh) }
        let backward = try V2GroupRolePolicyBaseline(roomID: announcementRoom, permissionRevision: 9, membershipRevision: 2, roomSequence: 79, adminPermissions: [], memberPermissions: [])
        await #expect(throws: V2RolePolicyRecoveryError.invalidBaseline) { try await store.completeRolePolicyBaseline(backward, for: refresh) }
        #expect(try await store.pendingRolePolicyBaselineRequests() == [refresh])
        try db.close()
        try await store.close()
        let unbound = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        await #expect(throws: V2RolePolicyRecoveryError.accountUnavailable) { try await unbound.enqueueMissingRolePolicyBaselines() }
        await #expect(throws: V2RolePolicyRecoveryError.invalidLimit) { try await unbound.pendingRolePolicyBaselineRequests(limit: 0) }
        try await unbound.close()
    }

    @Test("snapshot fences recovery requests and preserves only eligible policy observations", arguments: [false, true])
    func policyRecoverySnapshotFences(removeRoom: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        let membership = try policyRecoveryMembership(sequence: 1, revision: 2)
        _ = try await store.apply(announcementBatch([membership]))
        let request = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request))
        let old = try rolePolicyFact(sequence: 2, revision: 7, permissions: ["send_messages"], roomSequence: 70)
        _ = try await store.apply(announcementBatch([old]))
        let inFlight = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        let reset = try V2ClientResetRequired(snapshotID: .init("policy-recovery-reset"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let roomItem = try V2SnapshotProjectionItem(key: .init(projectionKind: "room", entityKey: announcementRoom.rawValue), sourceEventID: membership.sourceEventID, sequence: 1, payload: membership.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: removeRoom ? [] : [.init(items: [roomItem])])
        try await store.beginReset(reset)
        await #expect(throws: V2ClientSyncError.resetPending) { try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: inFlight) }
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        for page in fixture.pages { try await store.applySnapshotPage(page, for: fixture.manifest) }
        try await store.prepareSnapshotActivation(fixture.manifest)
        try await store.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: inFlight) == false)
        let discovered = try await store.enqueueMissingRolePolicyBaselines()
        let policies = try await store.groupRolePolicies(roomID: announcementRoom)
        if removeRoom {
            #expect(policies.isEmpty)
            #expect(discovered == 0)
            #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
        } else {
            #expect(policies.count == 2)
            #expect(policies.allSatisfy { $0.permissions.isEmpty && $0.revision == 8 })
            #expect(discovered == 1)
            let current = try #require(try await store.pendingRolePolicyBaselineRequests().first)
            #expect(current != inFlight)
            let conflict = try rolePolicyFact(sequence: 1, revision: 7, permissions: [], roomSequence: 70)
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyForegroundGroupEventPreviewPage(announcementPage(conflict, sequence: 70)) }
            #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: current))
        }
        try await store.close()
    }
}

private let policyRecoveryUser = try! UserID("00000000-0000-0000-0000-000000ABC123")
private func policyRecoveryBaseline(revision: UInt64, membership: UInt64 = 2, admin: Set<V2GroupPermission> = [], member: Set<V2GroupPermission> = []) throws -> V2GroupRolePolicyBaseline {
    try .init(roomID: announcementRoom, permissionRevision: revision, membershipRevision: membership, roomSequence: revision * 10, adminPermissions: admin, memberPermissions: member)
}
private func policyRecoveryMembership(sequence: UInt64, revision: Int, action: String = "add", lowercased: Bool = false) throws -> V2ClientSyncRecord {
    let room = lowercased ? announcementRoom.rawValue.lowercased() : announcementRoom.rawValue
    let user = lowercased ? policyRecoveryUser.rawValue.lowercased() : policyRecoveryUser.rawValue
    return try .init(sequence: sequence, sourceEventID: .init("policy-membership-\(revision)"), projectionKind: "membership", payload: JSONSerialization.data(withJSONObject: ["event_type": "membership_changed", "room_id": room, "title": "Policy recovery", "owner_user_id": policyRecoveryUser.rawValue, "target_user_id": user, "action": action, "membership_revision": revision, "delivery_mode": "standard_fanout", "created_at_ms": 1_000, "server_created_at_ms": revision * 1_000]))
}

extension V2SyncEngineTests {
    @Test("policy recovery schema upgrade preserves pending reset and commands while rebuilding staging", arguments: [false, true])
    func policyRecoverySchemaUpgrade(prepared: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        let membership = try policyRecoveryMembership(sequence: 1, revision: 2)
        let policy = try rolePolicyFact(sequence: 2, revision: 4, permissions: ["send_messages"], roomSequence: 40)
        _ = try await store.apply(announcementBatch([membership, policy]))
        let pending = V2PendingMessageCommand(roomID: announcementRoom, clientMessageID: try .init("00000000-0000-0000-0000-00000000AAAA"), text: "keep during recovery upgrade", state: .pending, attemptCount: 0, nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(pending)
        let reset = try V2ClientResetRequired(snapshotID: .init("policy-recovery-upgrade"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "room", entityKey: announcementRoom.rawValue), sourceEventID: membership.sourceEventID, sequence: 1, payload: membership.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        if prepared { try await store.prepareSnapshotActivation(fixture.manifest) }
        try await store.close()
        let db = try DatabasePool(path: url.path)
        try await db.write { db in
            try db.execute(sql: "DROP TABLE v2_group_role_policy_baselines; DROP TABLE v2_snapshot_shadow_group_role_policy_baselines; DROP TABLE v2_role_policy_recovery_requests")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'recordRolePolicyRecovery'")
        }
        try db.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        #expect(try await reopened.cursor()?.pendingReset == reset)
        #expect(try await reopened.pendingMessageCommands() == [pending])
        #expect(try await reopened.groupRolePolicies(roomID: announcementRoom).first?.permissions == [.sendMessages])
        #expect(try await reopened.pendingRolePolicyBaselineRequests().isEmpty)
        let check = try DatabasePool(path: url.path)
        #expect(try await check.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_snapshot_import") } == 0)
        try check.close()
        try await reopened.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await reopened.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        try await reopened.prepareSnapshotActivation(fixture.manifest)
        try await reopened.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await reopened.enqueueMissingRolePolicyBaselines() == 1)
        let request = try #require(try await reopened.pendingRolePolicyBaselineRequests().first)
        #expect(try await reopened.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: request))
        #expect(try await reopened.groupRolePolicies(roomID: announcementRoom).count == 2)
        #expect(try await reopened.pendingMessageCommands() == [pending])
        try await reopened.close()
    }
}

extension V2SyncEngineTests {
    @Test("corrupt role policy retry counters are rejected without modifying the recovery request")
    func policyRecoveryCounterBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-policy-count-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        do {
            _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
            _ = try await store.enqueueMissingRolePolicyBaselines(limit: 1)
            let original = try #require(try await store.pendingRolePolicyBaselineRequests().first)
            let pool = await store.databasePool
            for value in [Int64.min, -1, 0, 1, Int64(Int32.max), Int64(Int32.max) + 1, Int64.max] {
                try await pool.write { db in
                    try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                    defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                    try db.execute(sql: "UPDATE v2_role_policy_recovery_requests SET attempt_count = ?", arguments: [value])
                }
                if value < 0 || value > Int32.max {
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.pendingRolePolicyBaselineRequests() }
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.dueRolePolicyBaselineRequests(at: Date(timeIntervalSince1970: 2_000)) }
                    await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.recordRolePolicyRecoveryFailure(.pause, for: original) }
                    #expect(try await pool.read { db in try Int64.fetchOne(db, sql: "SELECT attempt_count FROM v2_role_policy_recovery_requests") } == value)
                } else {
                    let request = try #require(try await store.pendingRolePolicyBaselineRequests().first)
                    #expect(request.requestID == original.requestID && request.attemptCount == Int(value))
                    #expect(try await store.recordRolePolicyRecoveryFailure(.retry(at: Date(timeIntervalSince1970: 1_000)), for: request))
                    let next = try #require(try await store.pendingRolePolicyBaselineRequests().first)
                    #expect(next.attemptCount == min(Int(Int32.max), Int(value) + 1))
                }
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("restored policy recovery fences reject nonpositive values without changing durable intent")
    func policyRecoveryFenceBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-policy-fence-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        do {
            _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
            _ = try await store.enqueueMissingRolePolicyBaselines(limit: 1)
            let original = try #require(try await store.pendingRolePolicyBaselineRequests().first)
            let pool = await store.databasePool
            for column in ["membership_revision", "generation"] {
                for value in [Int64.min, -1, 0, 1, Int64.max] {
                    try await pool.write { db in
                        try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                        defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                        try db.execute(sql: "UPDATE v2_role_policy_recovery_requests SET \(column) = ?", arguments: [value])
                    }
                    if value <= 0 {
                        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.pendingRolePolicyBaselineRequests() }
                        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.dueRolePolicyBaselineRequests(at: Date(timeIntervalSince1970: 2_000)) }
                        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.recordRolePolicyRecoveryFailure(.pause, for: original) }
                    } else {
                        let request = try #require(try await store.pendingRolePolicyBaselineRequests().first)
                        #expect(request.requestID == original.requestID)
                        #expect((column == "generation" ? request.generation : request.membershipRevision) == value)
                    }
                    #expect(try await pool.read { db in try Int64.fetchOne(db, sql: "SELECT \(column) FROM v2_role_policy_recovery_requests") } == value)
                }
                try await pool.write { db in
                    try db.execute(sql: "UPDATE v2_role_policy_recovery_requests SET \(column) = ?", arguments: [column == "generation" ? original.generation : original.membershipRevision])
                }
            }
            #expect(try await store.pendingRolePolicyBaselineRequests() == [original])
            #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: original))
            #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("policy retry rejects clock changes that cannot produce a future deadline", arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude])
    func policyRetryClockBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-policy-clock-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        do {
            _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
            _ = try await store.enqueueMissingRolePolicyBaselines(limit: 1)
            let original = try await store.pendingRolePolicyBaselineRequests()
            let before = try await store.rolePolicyRecoverySchedule().nextAttemptAt()
            let failure = V2RealtimeTransportError.server(code: "UNAVAILABLE", retryable: true, retryAfterSeconds: 0, currentRevision: nil)
            let transport = PolicyRunnerTransport(failures: [announcementRoom: [failure, failure]])
            let reads = Mutex(0)
            let runner = V2RolePolicyRecoveryRunner(store: store, transport: transport, now: {
                reads.withLock { count in
                    defer { count += 1 }
                    return Date(timeIntervalSince1970: count == 0 ? 1_000 : seconds)
                }
            })
            await #expect(throws: V2RolePolicyRecoveryError.invalidDate) { try await runner.recoverOnce() }
            #expect(try await store.pendingRolePolicyBaselineRequests() == original)
            #expect(try await store.rolePolicyRecoverySchedule().nextAttemptAt() == before)
            let recovered = V2RolePolicyRecoveryRunner(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            #expect(try await recovered.recoverOnce() == 1)
            #expect(try await store.pendingRolePolicyBaselineRequests().first?.attemptCount == 1)
            #expect(try await store.rolePolicyRecoverySchedule().nextAttemptAt() == Date(timeIntervalSince1970: 1_001))
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("policy runner defers one room durably without blocking another room")
    func policyRunnerRetriesIndependently() async throws {
        let url = temporaryDatabaseURL()
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        let other = try RoomID("00000000-0000-0000-0000-000000ABC124")
        let first = try policyRecoveryMembership(sequence: 1, revision: 2)
        var payload = try #require(JSONSerialization.jsonObject(with: first.payload) as? [String: Any]); payload["room_id"] = other.rawValue
        let second = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init("second-policy-room"), projectionKind: "membership", payload: JSONSerialization.data(withJSONObject: payload))
        _ = try await store.apply(announcementBatch([first, second]))
        let date = Date(timeIntervalSince1970: 1_000)
        let transport = PolicyRunnerTransport(failures: [announcementRoom: [.server(code: "ROOM_OWNER_CHANGED", retryable: true, retryAfterSeconds: 30, currentRevision: nil)]])
        let runner = V2RolePolicyRecoveryRunner(store: store, transport: transport, now: { date })
        #expect(try await runner.recoverOnce() == 2)
        let request = try #require(try await store.pendingRolePolicyBaselineRequests().first)
        #expect(request.roomID == announcementRoom && request.attemptCount == 1)
        #expect(try await store.groupRolePolicies(roomID: other).count == 2)
        #expect(try await store.rolePolicyRecoverySchedule().nextAttemptAt() == date.addingTimeInterval(30))
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        #expect(try await store.pendingRolePolicyBaselineRequests() == [request])
        #expect(try await store.dueRolePolicyBaselineRequests(at: date.addingTimeInterval(29)).isEmpty)
        let resumed = V2RolePolicyRecoveryRunner(store: store, transport: transport, now: { date.addingTimeInterval(30) })
        #expect(try await resumed.recoverOnce() == 1)
        #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).count == 2)
        try await store.close()
    }

    @Test("nonretryable policy responses pause until explicit retry while forbidden clears authority")
    func policyRunnerPausesAndRejects() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        let transport = PolicyRunnerTransport(failures: [announcementRoom: [.unexpectedResponse, .server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)]])
        let runner = V2RolePolicyRecoveryRunner(store: store, transport: transport)
        #expect(try await runner.recoverOnce() == 1)
        let paused = try #require(try await store.pendingRolePolicyBaselineRequests().first)
        #expect(paused.attemptCount == 1)
        #expect(try await store.rolePolicyRecoverySchedule().nextAttemptAt() == nil)
        #expect(try await runner.recoverOnce() == 0)
        let resumed = try await store.resumeRolePolicyBaseline(roomID: announcementRoom)
        #expect(resumed.requestID != paused.requestID)
        #expect(try await runner.recoverOnce() == 1)
        #expect(try await store.pendingRolePolicyBaselineRequests().isEmpty)
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).isEmpty)
        await #expect(throws: V2RolePolicyRecoveryError.roomUnauthorized) { try await store.requestRolePolicyBaseline(roomID: announcementRoom) }
        #expect(try await store.rolePolicyRecoverySchedule().nextAttemptAt() == nil)
        try await store.close()
    }

    @Test("cancelled or stale policy transport cannot commit success or revoke a replacement membership", arguments: [false, true])
    func policyRunnerLateResult(cancel: Bool) async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        let transport = BlockingPolicyRunnerTransport()
        let runner = V2RolePolicyRecoveryRunner(store: store, transport: transport)
        let task = Task { try await runner.recoverOnce() }
        await transport.waitUntilRequested()
        if cancel { task.cancel() }
        else {
            _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 2, revision: 3)]))
            _ = try await store.enqueueMissingRolePolicyBaselines()
        }
        let current = try #require(try await store.pendingRolePolicyBaselineRequests().first)
        await transport.release(forbidden: !cancel)
        if cancel { await #expect(throws: CancellationError.self) { try await task.value } }
        else { #expect(try await task.value == 1) }
        #expect(try await store.pendingRolePolicyBaselineRequests() == [current])
        #expect(try await store.groupRolePolicies(roomID: announcementRoom).isEmpty)
        #expect(try await store.requestRolePolicyBaseline(roomID: announcementRoom) == current)
        try await store.close()
    }

    @Test("policy runner observes a newly discovered room without a wake hint")
    func policyRunnerObservesDiscovery() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        #expect(try await store.rolePolicyRecoverySchedule().nextAttemptAt() == nil)
        let transport = BlockingPolicyRunnerTransport()
        let runner = V2RolePolicyRecoveryRunner(store: store, transport: transport)
        let task = Task { try await runner.run() }
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        await transport.waitUntilRequested()
        task.cancel()
        await transport.release(forbidden: false)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.pendingRolePolicyBaselineRequests().count == 1)
        try await store.close()
    }
}

private actor PolicyRunnerTransport: V2ClientGroupRolePolicyBaselineTransport {
    var failures: [RoomID: [V2RealtimeTransportError]]
    init(failures: [RoomID: [V2RealtimeTransportError]] = [:]) { self.failures = failures }
    func fetchRolePolicyBaseline(roomID: RoomID) throws -> V2GroupRolePolicyBaseline {
        if var queued = failures[roomID], !queued.isEmpty {
            let error = queued.removeFirst(); failures[roomID] = queued; throw error
        }
        return try .init(roomID: roomID, permissionRevision: 8, membershipRevision: 2, roomSequence: 80, adminPermissions: [], memberPermissions: [])
    }
}

/// Deliberately ignores cancellation to exercise the boundary after transport.
private actor BlockingPolicyRunnerTransport: V2ClientGroupRolePolicyBaselineTransport {
    var requested = false
    var observer: CheckedContinuation<Void, Never>?
    var response: CheckedContinuation<V2GroupRolePolicyBaseline, any Error>?
    func fetchRolePolicyBaseline(roomID: RoomID) async throws -> V2GroupRolePolicyBaseline {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            requested = true
            observer?.resume(); observer = nil
        }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release(forbidden: Bool) {
        if forbidden { response?.resume(throwing: V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)) }
        else { response?.resume(with: Result { try policyRecoveryBaseline(revision: 8) }) }
        response = nil
    }
}

extension V2SyncEngineTests {
    @Test("retry scheduling migration preserves an existing recovery request identity and fences")
    func policyRunnerScheduleMigration() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        let request = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        try await store.close()
        let db = try DatabasePool(path: url.path)
        try await db.write { db in
            try db.execute(sql: "ALTER TABLE v2_role_policy_recovery_requests RENAME TO temporary_policy_requests")
            try db.execute(sql: """
                CREATE TABLE v2_role_policy_recovery_requests (
                    room_id TEXT PRIMARY KEY, request_id TEXT NOT NULL,
                    installation_binding TEXT NOT NULL, user_id TEXT NOT NULL,
                    membership_revision INTEGER NOT NULL CHECK (membership_revision > 0),
                    membership_source_event_id TEXT NOT NULL,
                    generation INTEGER NOT NULL CHECK (generation > 0)
                )
                """)
            try db.execute(sql: "INSERT INTO v2_role_policy_recovery_requests SELECT room_id, request_id, installation_binding, user_id, membership_revision, membership_source_event_id, generation FROM temporary_policy_requests")
            try db.execute(sql: "DROP TABLE temporary_policy_requests")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'scheduleRolePolicyRecovery'")
        }
        try db.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        #expect(try await reopened.pendingRolePolicyBaselineRequests() == [request])
        #expect(try await reopened.dueRolePolicyBaselineRequests(at: Date(timeIntervalSince1970: 0)) == [request])
        let runner = V2RolePolicyRecoveryRunner(store: reopened, transport: PolicyRunnerTransport())
        #expect(try await runner.recoverOnce() == 1)
        #expect(try await reopened.pendingRolePolicyBaselineRequests().isEmpty)
        #expect(try await reopened.groupRolePolicies(roomID: announcementRoom).count == 2)
        try await reopened.close()
    }
}

extension V2SyncEngineTests {
    @Test("policy state distinguishes missing, delayed, paused, ready and unauthorized without dropping visible facts")
    func policyRecoveryVisibleState() async throws {
        let url = temporaryDatabaseURL()
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: [], recovery: .unavailable))
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2)]))
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: [], recovery: .needed))
        _ = try await store.apply(announcementBatch([rolePolicyFact(sequence: 2, revision: 4, permissions: [], roomSequence: 40)]))
        let visible = try await store.groupRolePolicies(roomID: announcementRoom)
        let first = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: visible, recovery: .pending(nextAttemptAt: Date(timeIntervalSince1970: 0))))
        let later = Date(timeIntervalSince1970: 5_000)
        #expect(try await store.recordRolePolicyRecoveryFailure(.retry(at: later), for: first))
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: visible, recovery: .pending(nextAttemptAt: later)))
        let retry = try #require(try await store.pendingRolePolicyBaselineRequests().first)
        #expect(try await store.recordRolePolicyRecoveryFailure(.pause, for: retry))
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: visible, recovery: .paused))
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: visible, recovery: .paused))
        let resumed = try await store.resumeRolePolicyBaseline(roomID: announcementRoom)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8), for: resumed))
        let ready = try await store.groupRolePolicyState(roomID: announcementRoom)
        #expect(ready.recovery == .ready && ready.policies.count == 2)
        #expect(ready.policies.allSatisfy { $0.permissions.isEmpty && $0.revision == 8 })
        let reset = try V2ClientResetRequired(snapshotID: .init("policy-state-reset"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        try await store.beginReset(reset)
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: ready.policies, recovery: .waitingForSynchronization))
        try await store.cancelReset(reset)
        let pending = try await store.requestRolePolicyBaseline(roomID: announcementRoom)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 3, revision: 3)]))
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom).recovery == .needed)
        #expect(try await store.completeRolePolicyBaseline(policyRecoveryBaseline(revision: 8, membership: 3), for: pending) == false)
        try await store.markRoomEventUnauthorized(roomID: announcementRoom)
        #expect(try await store.groupRolePolicyState(roomID: announcementRoom) == .init(policies: [], recovery: .unavailable))
        try await store.close()
    }

    @Test("visible policy recovery changes notify only conversation details without urgent refresh")
    func policyRecoveryNotificationScope() {
        for kind in [DatabaseEvent.Kind.insert, .update, .delete] {
            let change = V2ProjectionTransactionObserver.change(table: "v2_role_policy_recovery_requests", kind: kind)
            #expect(change.scopes == .conversationDetails)
            #expect(change.requiresImmediateRefresh == false)
        }
    }
}

extension V2SyncEngineTests {
    @Test("group snapshot UUID spelling may differ while kind, role and identity stay exact", arguments: ["pin", "announcement", "permissions", "member-role"])
    func groupSnapshotIdentitySpelling(kind: String) async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let target = "ABCDEF00-0000-0000-0000-00000000ABCD"
        var payload: [String: Any] = ["room_id": announcementRoom.rawValue, "server_created_at_ms": 1_000, "room_sequence": 20]
        let key: String
        switch kind {
        case "pin":
            payload["event_type"] = "message.pinned_changed"
            payload["message_id"] = target; payload["is_pinned"] = true
            key = "pin:\(announcementRoom.rawValue.lowercased()):\(target.lowercased())"
        case "announcement":
            payload["event_type"] = "group.announcement_changed"
            payload["body"] = "snapshot"; payload["revision"] = 1
            key = "announcement:\(announcementRoom.rawValue.lowercased())"
        case "permissions":
            payload["event_type"] = "group.role_permissions_changed"
            payload["role"] = "member"; payload["permissions"] = [String](); payload["revision"] = 2
            key = "permissions:\(announcementRoom.rawValue.lowercased()):member"
        default:
            payload["event_type"] = "group.member_role_changed"
            payload["target_user_id"] = target; payload["role"] = "admin"; payload["membership_revision"] = 2
            key = "member-role:\(announcementRoom.rawValue.lowercased()):\(target.lowercased())"
        }
        let reset = try V2ClientResetRequired(snapshotID: .init("identity-spelling"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: key), sourceEventID: .init("identity-spelling-fact"), sequence: 8, payload: JSONSerialization.data(withJSONObject: payload))
        let engine = V2SyncEngine(transport: try ProjectionSnapshotTransport(reset: reset, pages: [.init(items: [item])]), store: store, capabilityProfile: "base")
        _ = try await engine.synchronizeOnce()
        try await engine.completePendingReset()
        #expect(try await store.cursor()?.generation == 2)
        if kind == "pin" { #expect(try await store.pinnedMessageIDs(roomID: announcementRoom) == [MessageID(target)]) }
        if kind == "announcement" { #expect(try await store.groupAnnouncement(roomID: announcementRoom)?.body == "snapshot") }
        if kind == "permissions" { #expect(try await store.groupRolePolicies(roomID: announcementRoom).first?.permissions == []) }
        try await store.close()
    }

    @Test("group snapshot spelling normalization never accepts another object or malformed key", arguments: ["room", "message", "kind", "short", "extra", "role"])
    func groupSnapshotIdentityMismatch(scenario: String) async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let target = "ABCDEF00-0000-0000-0000-00000000ABCD"
        let other = "ABCDEF00-0000-0000-0000-00000000ABCE"
        var payload: [String: Any] = ["room_id": announcementRoom.rawValue, "event_type": "message.pinned_changed", "message_id": target, "is_pinned": false, "server_created_at_ms": 1_000, "room_sequence": 20]
        let key: String
        switch scenario {
        case "room": key = "pin:\(other):\(target)"
        case "message": key = "pin:\(announcementRoom.rawValue):\(other)"
        case "kind": key = "PIN:\(announcementRoom.rawValue):\(target)"
        case "short": key = "pin"
        case "extra": key = "pin:\(announcementRoom.rawValue):\(target):extra"
        default:
            payload["event_type"] = "group.role_permissions_changed"
            payload["role"] = "member"; payload["permissions"] = [String](); payload["revision"] = 2
            key = "permissions:\(announcementRoom.rawValue.lowercased()):admin"
        }
        let reset = try V2ClientResetRequired(snapshotID: .init("identity-mismatch"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: key), sourceEventID: .init("identity-mismatch-fact"), sequence: 8, payload: JSONSerialization.data(withJSONObject: payload))
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        await #expect(throws: V2ClientSyncError.snapshotProjectionConflict) {
            try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        }
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        try await store.close()
    }
}

private let pinMessage = try! MessageID("ABCDEF00-0000-0000-0000-00000000ABCD")
private func pinFact(sequence: UInt64, source: String, pinned: Bool, roomSequence: Int?, message: MessageID = pinMessage) throws -> V2ClientSyncRecord {
    var value: [String: Any] = ["event_type": "message.pinned_changed", "room_id": announcementRoom.rawValue, "message_id": message.rawValue, "is_pinned": pinned, "actor_user_id": "00000000-0000-0000-0000-000000000123", "server_created_at_ms": 1_000]
    if let roomSequence { value["room_sequence"] = roomSequence }
    return try .init(sequence: sequence, sourceEventID: .init(source), projectionKind: "group_capability", payload: JSONSerialization.data(withJSONObject: value))
}

extension V2SyncEngineTests {
    @Test("pin effects share ordering, negative state and identity across all incremental feeds and restart", arguments: [false, true])
    func pinEffectOrdering(previewFirst: Bool) async throws {
        let url = temporaryDatabaseURL()
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let latest = try pinFact(sequence: 1, source: "pin-latest", pinned: false, roomSequence: 50)
        if previewFirst { _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(latest, sequence: 50)) }
        _ = try await store.apply(announcementBatch([latest]))
        if !previewFirst { _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(latest, sequence: 50)) }
        let old = try pinFact(sequence: 2, source: "pin-old", pinned: true, roomSequence: 20)
        _ = try await store.applyGroupEventPage(announcementPage(old, sequence: 20))
        _ = try await store.applyGroupEventPage(announcementPage(latest, sequence: 50))
        _ = try await store.apply(announcementBatch([old]))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        let other = try MessageID("ABCDEF00-0000-0000-0000-00000000ABCE")
        _ = try await store.apply(announcementBatch([pinFact(sequence: 3, source: "pin-other", pinned: true, roomSequence: 30, message: other)]))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom) == [other])
        try await store.close()
        store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        for invalid in [
            try pinFact(sequence: 4, source: "pin-collision", pinned: true, roomSequence: 50),
            try pinFact(sequence: 4, source: "pin-old", pinned: false, roomSequence: 20),
            try pinFact(sequence: 4, source: "pin-old", pinned: true, roomSequence: 21),
            try pinFact(sequence: 4, source: "pin-old", pinned: true, roomSequence: 20, message: other),
        ] {
            await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.apply(announcementBatch([invalid])) }
        }
        #expect(try await store.cursor()?.appliedSequence == 3)
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom) == [other])
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_pin_effects") } == 3)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_pinned_messages WHERE message_id = ?", arguments: [pinMessage.rawValue]) } == 50)
        try db.close(); try await store.close()
    }

    @Test("a legacy pin receipt is reconsidered when the room log supplies its actual source version")
    func pinLegacySourceEnrichment() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let old = try pinFact(sequence: 1, source: "legacy-pin", pinned: true, roomSequence: nil)
        let newer = try pinFact(sequence: 2, source: "legacy-unpin", pinned: false, roomSequence: nil)
        _ = try await store.apply(announcementBatch([old, newer]))
        // Simulate replay after the old sync-log entry was cleaned. Its
        // independent effect receipt must still fence an unknown duplicate.
        let legacyLog = try DatabasePool(path: url.path)
        try await legacyLog.write { db in
            try db.execute(sql: "DELETE FROM v2_sync_events WHERE source_event_id = ?", arguments: [old.sourceEventID.rawValue])
        }
        try legacyLog.close()
        let replay = try V2ClientSyncRecord(sequence: 3, sourceEventID: old.sourceEventID, projectionKind: old.projectionKind, payload: old.payload)
        _ = try await store.apply(announcementBatch([replay]))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(old, sequence: 20))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom) == [pinMessage])
        _ = try await store.applyGroupEventPage(announcementPage(newer, sequence: 30))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(old, sequence: 20))
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyForegroundGroupEventPreviewPage(announcementPage(old, sequence: 21)) }
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_pinned_messages") } == 30)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_pin_effects WHERE room_sequence IS NOT NULL") } == 2)
        try db.close(); try await store.close()
    }

    @Test("pin source boundaries reject malformed identities, versions and room envelopes")
    func pinSourceBoundaries() async throws {
        let record = try pinFact(sequence: 999, source: "pin-boundary", pinned: false, roomSequence: 20)
        var object = try #require(JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        for (key, value) in [("room_sequence", 0 as Any), ("room_sequence", true), ("room_sequence", UInt64.max), ("server_created_at_ms", -1), ("is_pinned", "false"), ("room_id", "invalid"), ("message_id", "invalid"), ("actor_user_id", "invalid")] {
            var bad = object; bad[key] = value
            let invalid = try V2ClientSyncRecord(sequence: 1, sourceEventID: record.sourceEventID, projectionKind: record.projectionKind, payload: try JSONSerialization.data(withJSONObject: bad))
            #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try V2LocalPinnedMessageEffect(record: invalid) }
        }
        #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try V2LocalPinnedMessageEffect(record: record, expectedRoomSequence: 21) }
        #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try V2LocalPinnedMessageEffect(record: record, expectedRoomID: RoomID("00000000-0000-0000-0000-000000000999")) }
        let legacy = try pinFact(sequence: 999, source: "pin-boundary", pinned: false, roomSequence: nil)
        #expect(try V2LocalPinnedMessageEffect(record: legacy).roomSequence == nil)
        #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try V2LocalPinnedMessageEffect(record: legacy, expectedRoomSequence: UInt64.max) }
        object["room_id"] = announcementRoom.rawValue.lowercased(); object["message_id"] = pinMessage.rawValue.lowercased()
        let normalized = try V2ClientSyncRecord(sequence: 1, sourceEventID: record.sourceEventID, projectionKind: record.projectionKind, payload: try JSONSerialization.data(withJSONObject: object))
        #expect(try V2LocalPinnedMessageEffect(record: normalized).digest == V2LocalPinnedMessageEffect(record: legacy).digest)
        for kind in [DatabaseEvent.Kind.insert, .update, .delete] {
            #expect(V2ProjectionTransactionObserver.change(table: "v2_pin_effects", kind: kind) == .none)
        }
    }

    @Test("pin snapshot keeps negative state and old claims, while a hybrid room keeps newer source facts", arguments: [false, true])
    func pinSnapshotOrdering(hybrid: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let old = try pinFact(sequence: 1, source: "snapshot-pin-old", pinned: true, roomSequence: 20)
        let latest = try pinFact(sequence: 2, source: "snapshot-pin-new", pinned: false, roomSequence: 50)
        _ = try await store.apply(announcementBatch([old]))
        if hybrid { _ = try await store.applyGroupEventPage(announcementPage(latest, sequence: 50)) }
        let fact = hybrid ? old : latest
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "pin:\(announcementRoom.rawValue):\(pinMessage.rawValue)"), sourceEventID: fact.sourceEventID, sequence: 8, payload: fact.payload)
        var items = [item]
        if hybrid {
            let membership = try policyRecoveryMembership(sequence: 9, revision: 2)
            var value = try #require(JSONSerialization.jsonObject(with: membership.payload) as? [String: Any])
            value["delivery_mode"] = V2GroupDeliveryMode.largeGroupHybrid.rawValue
            items.append(try .init(key: .init(projectionKind: "room", entityKey: announcementRoom.rawValue), sourceEventID: membership.sourceEventID, sequence: 9, payload: JSONSerialization.data(withJSONObject: value)))
        }
        let reset = try V2ClientResetRequired(snapshotID: .init("pin-snapshot"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let engine = V2SyncEngine(transport: try ProjectionSnapshotTransport(reset: reset, pages: [.init(items: items)]), store: store, capabilityProfile: "base")
        _ = try await engine.synchronizeOnce(); try await engine.completePendingReset()
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        _ = try await store.applyForegroundGroupEventPreviewPage(announcementPage(old, sequence: 20))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        let conflict = try pinFact(sequence: 1, source: old.sourceEventID.rawValue, pinned: false, roomSequence: 20)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.applyForegroundGroupEventPreviewPage(announcementPage(conflict, sequence: 20)) }
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_pinned_messages") } == 50)
        try db.close(); try await store.close()
    }
}

extension V2SyncEngineTests {
    @Test("pin migration discards personal source guesses, preserves outbox and reimports staging", arguments: [false, true])
    func pinEffectMigration(prepared: Bool) async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let old = try pinFact(sequence: 1, source: "migration-pin", pinned: true, roomSequence: 20)
        let latest = try pinFact(sequence: 2, source: "migration-unpin", pinned: false, roomSequence: nil)
        _ = try await store.apply(announcementBatch([old, latest]))
        _ = try await store.applyGroupEventPage(announcementPage(latest, sequence: 50))
        let removedMessage = try MessageID("ABCDEF00-0000-0000-0000-000000001111")
        _ = try await store.apply(announcementBatch([pinFact(sequence: 3, source: "migration-purged", pinned: true, roomSequence: 15, message: removedMessage)]))
        let pending = V2PendingMessageCommand(roomID: announcementRoom, clientMessageID: try .init("00000000-0000-0000-0000-00000000AAAA"), text: "keep pin outbox", state: .pending, attemptCount: 0, nextAttemptAt: .distantPast, acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(pending)
        let reset = try V2ClientResetRequired(snapshotID: .init("pin-upgrade"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let incoming = try pinFact(sequence: 8, source: "migration-snapshot", pinned: true, roomSequence: 80)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "pin:\(announcementRoom.rawValue):\(pinMessage.rawValue)"), sourceEventID: incoming.sourceEventID, sequence: 8, payload: incoming.payload)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        if prepared { try await store.prepareSnapshotActivation(fixture.manifest) }
        try await store.close()
        let unknownMessage = "ABCDEF00-0000-0000-0000-000000002222"
        let db = try DatabasePool(path: url.path)
        try await db.write { db in
            for table in ["v2_group_pinned_messages", "v2_snapshot_shadow_group_pinned_messages"] {
                try db.execute(sql: "ALTER TABLE \(table) RENAME TO temporary_pins")
                try db.execute(sql: "CREATE TABLE \(table) (room_id TEXT NOT NULL, message_id TEXT NOT NULL, is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)), room_sequence INTEGER NOT NULL CHECK (room_sequence > 0), updated_at REAL NOT NULL, PRIMARY KEY (room_id, message_id))")
                try db.execute(sql: "INSERT INTO \(table) SELECT lower(room_id), lower(message_id), is_pinned, 999, updated_at FROM temporary_pins")
                try db.execute(sql: "DROP TABLE temporary_pins")
            }
            try db.execute(sql: "CREATE INDEX v2_group_pinned_messages_room_idx ON v2_group_pinned_messages (room_id, is_pinned DESC, updated_at DESC)")
            try db.execute(sql: "INSERT INTO v2_group_pinned_messages VALUES (?, ?, 1, 999, 1)", arguments: [announcementRoom.rawValue.lowercased(), unknownMessage.lowercased()])
            // Simulate a stale old last-arrival value. Trusted room-log source
            // 50 must beat the positive source 20 despite personal cursor 999.
            try db.execute(sql: "UPDATE v2_group_pinned_messages SET is_pinned = 1 WHERE message_id = ?", arguments: [pinMessage.rawValue.lowercased()])
            try db.execute(sql: "DELETE FROM v2_group_pinned_messages WHERE message_id = ?", arguments: [removedMessage.rawValue.lowercased()])
            try db.execute(sql: "DROP TABLE v2_pin_effects")
            try db.execute(sql: "DROP TABLE v2_snapshot_shadow_pin_effects")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'orderPinnedMessageEffects'")
        }
        try db.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        #expect(try await reopened.cursor()?.pendingReset == reset)
        #expect(try await reopened.importedSnapshotManifest(for: reset) == nil)
        #expect(try await reopened.pendingMessageCommands() == [pending])
        #expect(try await reopened.pinnedMessageIDs(roomID: announcementRoom) == [MessageID(unknownMessage)])
        let migrated = try DatabasePool(path: url.path)
        #expect(try await migrated.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_pinned_messages WHERE message_id = ?", arguments: [pinMessage.rawValue]) } == 50)
        #expect(try await migrated.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_pinned_messages WHERE message_id = ?", arguments: [unknownMessage]) } == nil)
        #expect(try await migrated.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_pin_effects WHERE message_id = ?", arguments: [removedMessage.rawValue]) } == 0)
        try migrated.close()
        try await reopened.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await reopened.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        try await reopened.prepareSnapshotActivation(fixture.manifest)
        try await reopened.activateAcknowledgedSnapshot(fixture.manifest)
        #expect(try await reopened.pinnedMessageIDs(roomID: announcementRoom) == [pinMessage])
        #expect(try await reopened.pendingMessageCommands() == [pending])
        try await reopened.close()
    }

    @Test("pin snapshot source reuse fails even if the previous message is absent from the new bank")
    func pinSnapshotSourceConflict() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryDatabaseURL(), installationBinding: testInstallationBinding)
        let old = try pinFact(sequence: 1, source: "snapshot-source", pinned: false, roomSequence: 20)
        _ = try await store.apply(announcementBatch([old]))
        let changed = try pinFact(sequence: 8, source: old.sourceEventID.rawValue, pinned: true, roomSequence: 30, message: MessageID("ABCDEF00-0000-0000-0000-000000003333"))
        let effect = try V2LocalPinnedMessageEffect(record: changed)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "pin:\(announcementRoom.rawValue):\(effect.messageID.rawValue)"), sourceEventID: changed.sourceEventID, sequence: 8, payload: changed.payload)
        let reset = try V2ClientResetRequired(snapshotID: .init("pin-source-conflict"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [.init(items: [item])])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.applySnapshotPage(fixture.pages[0], for: fixture.manifest)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await store.prepareSnapshotActivation(fixture.manifest) }
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        try await store.close()
    }
}

extension V2SyncEngineTests {
    @Test("a snapshot cannot downgrade known pin source metadata or retain a removed pin claim")
    func pinSnapshotMetadataAndRemoval() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let known = try pinFact(sequence: 1, source: "pin-metadata", pinned: false, roomSequence: 40)
        _ = try await store.apply(announcementBatch([known]))
        let legacy = try pinFact(sequence: 8, source: known.sourceEventID.rawValue, pinned: false, roomSequence: nil)
        let reset = try V2ClientResetRequired(snapshotID: .init("pin-metadata-reset"), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "group_capability", entityKey: "pin:\(announcementRoom.rawValue):\(pinMessage.rawValue)"), sourceEventID: legacy.sourceEventID, sequence: 8, payload: legacy.payload)
        let engine = V2SyncEngine(transport: try ProjectionSnapshotTransport(reset: reset, pages: [.init(items: [item])]), store: store, capabilityProfile: "base")
        _ = try await engine.synchronizeOnce(); try await engine.completePendingReset()
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT room_sequence FROM v2_group_pinned_messages") } == 40)
        let unknown = try pinFact(sequence: 11, source: "pin-unknown-late", pinned: true, roomSequence: nil)
        _ = try await store.apply(.init(generation: 2, records: [unknown], nextSyncToken: .init("pin-token"), receipt: .init("pin-receipt"), hasMore: false, capabilityProfile: "base"))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        let emptyReset = try V2ClientResetRequired(snapshotID: .init("pin-removed-reset"), generation: 3, baseSequence: 20, expiresAt: .distantFuture)
        let emptyEngine = V2SyncEngine(transport: try ProjectionSnapshotTransport(reset: emptyReset, pages: []), store: store, capabilityProfile: "base")
        _ = try await emptyEngine.synchronizeOnce(); try await emptyEngine.completePendingReset()
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_group_pinned_messages") } == 0)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_pin_effects") } == 0)
        try db.close(); try await store.close()
    }

    @Test("self removal purges pin state and receipts before rejoin")
    func pinSelfRemoval() async throws {
        let url = temporaryDatabaseURL()
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding, userID: policyRecoveryUser)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 1, revision: 2), pinFact(sequence: 2, source: "pin-before-leave", pinned: true, roomSequence: 20)]))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom) == [pinMessage])
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 3, revision: 3, action: "remove", lowercased: true)]))
        let db = try DatabasePool(path: url.path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_pin_effects") } == 0)
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        _ = try await store.apply(announcementBatch([policyRecoveryMembership(sequence: 4, revision: 4)]))
        #expect(try await store.pinnedMessageIDs(roomID: announcementRoom).isEmpty)
        try db.close(); try await store.close()
    }
}

private func completeEditPayload(origin: String, revision: UInt64 = 3) throws -> Data {
    var state = try #require(JSONSerialization.jsonObject(with: messagePayload(text: "authorized current")) as? [String: Any])
    state["message_revision"] = revision
    state["timeline_sequence"] = 1
    state["media_ids"] = [String]()
    state["media_presentations"] = [[String: Any]]()
    state["entities"] = [[String: Any]]()
    state["reply_to_message_id"] = NSNull()
    state["forwarded_from_message_id"] = NSNull()
    state["forwarded_from_user_id"] = NSNull()
    return try JSONSerialization.data(withJSONObject: ["event_type":"message.edited", "room_id":state["room_id"]!, "message_id":state["message_id"]!, "room_sequence":revision, "message_revision":revision, "text":"authorized current", "entities":[String](), "replacement":["schema_version":1, "accepted_event_id":origin, "accepted_membership_revision":0, "state":state]])
}

private func boundedSyncBatch(_ sequence: Int, hasMore: Bool) throws -> V2ClientSyncBatch {
    try .init(generation: 1, records: [try .init(sequence: UInt64(sequence), sourceEventID: .init(uuid: UUID()), projectionKind: "message", payload: messagePayload(roomSequence: UInt64(sequence), text: "bounded page"))], nextSyncToken: try .init("bounded-token-\(sequence)"), receipt: try .init("bounded-receipt-\(sequence)"), hasMore: hasMore, capabilityProfile: "base")
}

private actor BoundedSyncProbe: V2ClientSyncTransport {
    enum Failure: Error { case unexpectedRequest, waitTimedOut }
    private var results: [V2ClientPullResult]
    private let blocksFirstPull: Bool
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var tokens: [V2SyncToken?] = []
    private(set) var acknowledged: [UInt64] = []
    private(set) var snapshotRequests = 0
    init(results: [V2ClientPullResult], blocksFirstPull: Bool = false) {
        self.results = results
        self.blocksFirstPull = blocksFirstPull
    }
    func pull(syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool) async throws -> V2ClientPullResult {
        tokens.append(syncToken)
        if blocksFirstPull && tokens.count == 1 {
            await withCheckedContinuation { continuation in
                blocked = continuation
                for observer in observers { observer.resume() }
                observers.removeAll()
            }
        }
        guard !results.isEmpty else { throw Failure.unexpectedRequest }
        return results.removeFirst()
    }
    func waitForBlockedPull() async {
        if blocked != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func releasePull() { blocked?.resume(); blocked = nil }
    func acknowledge(generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt) { acknowledged.append(highestContiguousSequence) }
    func fetchSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest { snapshotRequests += 1; throw Failure.unexpectedRequest }
    func fetchSnapshotPage(for manifest: V2ClientSnapshotManifest, index: Int) throws -> V2ClientSnapshotPage { snapshotRequests += 1; throw Failure.unexpectedRequest }
    func acknowledgeSnapshot(_ manifest: V2ClientSnapshotManifest) { snapshotRequests += 1 }
}

private actor BoundedSyncConnection: V2RealtimeSessionConnecting {
    private let onDisconnect: @Sendable () async -> Void
    private(set) var connects = 0
    private(set) var disconnects = 0
    init(onDisconnect: @escaping @Sendable () async -> Void = {}) { self.onDisconnect = onDisconnect }
    func connect() throws -> V2AuthenticatedClientSession {
        connects += 1
        return .init(userID: try .init("bounded-user"), deviceID: try .init("bounded-device"), protocolVersion: UInt8(IMV2ProtocolVersion.current), capabilityProfile: "base", connectionID: UUID())
    }
    func disconnect() async { disconnects += 1; await onDisconnect() }
}
