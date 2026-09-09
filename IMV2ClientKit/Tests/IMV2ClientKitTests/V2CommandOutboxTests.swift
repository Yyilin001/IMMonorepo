import Foundation
import Synchronization
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 local command outbox")
struct V2CommandOutboxTests {
    @Test("invalid query clocks neither hide nor prematurely send pending messages", arguments: [Double.nan, .infinity, -.infinity, 999, 1_000, 1_001])
    func dueQueryClockBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-command-query-clock-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let transport = ScriptedMessageTransport(results: [.accepted])
            let normal = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await normal.enqueueMessage(roomID: .init(uuid: UUID()), text: "query clock recovery")
            let candidate = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: seconds) })
            if seconds.isFinite {
                #expect(try await candidate.flushOnce() == (seconds < 1_000 ? .idle : .accepted(command.clientMessageID)))
            } else {
                await #expect(throws: V2ClientCommandError.commandConflict) { try await candidate.flushOnce() }
            }
            if !seconds.isFinite || seconds < 1_000 {
                #expect(await transport.clientMessageIDs().isEmpty)
                #expect(try await store.pendingMessageCommands() == [command])
                #expect(try await normal.flushOnce() == .accepted(command.clientMessageID))
            }
            #expect(await transport.clientMessageIDs() == [command.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("retry counters remain exact and reject corruption or overflow without altering intent", arguments: [Int64.min, -1, 0, 1, Int64.max - 1, Int64.max])
    func retryCounterBounds(count: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-command-retry-count-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let transport = ScriptedMessageTransport(results: [.accepted])
            let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await engine.enqueueMessage(roomID: .init(uuid: UUID()), text: "counter recovery")
            let pool = await store.databasePool
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_pending_message_commands SET attempt_count = ?", arguments: [count])
            }
            if count < 0 {
                await #expect(throws: V2ClientCommandError.commandConflict) { try await store.pendingMessageCommands() }
            } else {
                #expect(try await store.pendingMessageCommands().first?.attemptCount == Int(count))
            }
            let invalid = count < 0 || count == Int64.max
            if invalid {
                await #expect(throws: V2ClientCommandError.commandConflict) {
                    try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: Date(timeIntervalSince1970: 2_000))
                }
            } else {
                try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: Date(timeIntervalSince1970: 2_000))
            }
            let expected = invalid ? count : count + 1
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT CAST(attempt_count AS TEXT) FROM v2_pending_message_commands") } == String(expected))
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT typeof(attempt_count) FROM v2_pending_message_commands") } == "integer")
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT next_attempt_at FROM v2_pending_message_commands") } == (invalid ? 1_000 : 2_000))
            try await pool.write { try $0.execute(sql: "UPDATE v2_pending_message_commands SET attempt_count = 0, next_attempt_at = 1000") }
            #expect(try await engine.flushOnce() == .accepted(command.clientMessageID))
            #expect(await transport.clientMessageIDs() == [command.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("restored noninteger retry counters fail safely and can resume after data repair", arguments: [1.5, Double(Int64.max)])
    func nonintegerRetryCounter(count: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-command-retry-real-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let transport = ScriptedMessageTransport(results: [.accepted])
            let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await engine.enqueueMessage(roomID: .init(uuid: UUID()), text: "restored counter")
            let pool = await store.databasePool
            try await pool.write { try $0.execute(sql: "UPDATE v2_pending_message_commands SET attempt_count = ?", arguments: [count]) }
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT typeof(attempt_count) FROM v2_pending_message_commands") } == "real")
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.pendingMessageCommands() }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await engine.flushOnce() }
            await #expect(throws: V2ClientCommandError.commandConflict) {
                try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: Date(timeIntervalSince1970: 2_000))
            }
            #expect(await transport.clientMessageIDs().isEmpty)
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT attempt_count FROM v2_pending_message_commands") } == count)
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT next_attempt_at FROM v2_pending_message_commands") } == 1_000)
            try await pool.write { try $0.execute(sql: "UPDATE v2_pending_message_commands SET attempt_count = 0") }
            #expect(try await engine.flushOnce() == .accepted(command.clientMessageID))
            #expect(await transport.clientMessageIDs() == [command.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("retry persistence rejects nonfinite dates without advancing counters", arguments: [Double.nan, .infinity, -.infinity, -1, 0, 2_000, Double.greatestFiniteMagnitude])
    func retryPersistenceDateBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-command-retry-date-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let transport = ScriptedMessageTransport(results: [.accepted])
            let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await engine.enqueueMessage(roomID: .init(uuid: UUID()), text: "retry date recovery")
            let date = Date(timeIntervalSince1970: seconds)
            if seconds.isFinite {
                try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: date)
                let updated = try #require(try await store.pendingMessageCommands().first)
                #expect(updated.clientMessageID == command.clientMessageID)
                #expect(updated.attemptCount == 1)
                #expect(updated.nextAttemptAt == date)
                try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: Date(timeIntervalSince1970: 1_000))
            } else {
                await #expect(throws: V2ClientCommandError.commandConflict) {
                    try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: date)
                }
                #expect(try await store.pendingMessageCommands() == [command])
            }
            #expect(try await engine.flushOnce() == .accepted(command.clientMessageID))
            #expect(await transport.clientMessageIDs() == [command.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("reopening rejects nonfinite stored retry dates and preserves the original command", arguments: [Double.infinity, -.infinity])
    func restoredRetryDateBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-command-restored-date-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "state.sqlite")
        var store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        do {
            let transport = ScriptedMessageTransport(results: [.accepted])
            let originalEngine = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await originalEngine.enqueueMessage(roomID: .init(uuid: UUID()), text: "restored date")
            let originalPool = await store.databasePool
            try await originalPool.write { try $0.execute(sql: "UPDATE v2_pending_message_commands SET next_attempt_at = ?", arguments: [seconds]) }
            try await store.close()
            store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.pendingMessageCommands() }
            let pool = await store.databasePool
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT next_attempt_at FROM v2_pending_message_commands") } == seconds)
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT attempt_count FROM v2_pending_message_commands") } == 0)
            try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: Date(timeIntervalSince1970: 1_000))
            let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            #expect(try await engine.flushOnce() == .accepted(command.clientMessageID))
            #expect(await transport.clientMessageIDs() == [command.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("initial enqueue rejects invalid clock values without leaving an unreadable command", arguments: [Double.nan, .infinity, -.infinity, -1, 0, 2_000, Double.greatestFiniteMagnitude])
    func enqueueClockBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-command-enqueue-date-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let transport = ScriptedMessageTransport(results: [.accepted])
            let identifier = UUID(), room = RoomID(uuid: UUID())
            let engine = V2CommandOutboxEngine(store: store, transport: transport, makeUUID: { identifier }, now: { Date(timeIntervalSince1970: seconds) })
            if seconds.isFinite {
                let command = try await engine.enqueueMessage(roomID: room, text: "enqueue clock recovery")
                #expect(command.nextAttemptAt == Date(timeIntervalSince1970: seconds))
                #expect(try await store.pendingMessageCommands() == [command])
                try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: Date(timeIntervalSince1970: 1_000))
            } else {
                await #expect(throws: V2ClientCommandError.commandConflict) { try await engine.enqueueMessage(roomID: room, text: "enqueue clock recovery") }
                let pool = await store.databasePool
                #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_pending_message_commands") } == 0)
            }
            let recovered = V2CommandOutboxEngine(store: store, transport: transport, makeUUID: { identifier }, now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await recovered.enqueueMessage(roomID: room, text: "enqueue clock recovery")
            #expect(try await recovered.flushOnce() == .accepted(command.clientMessageID))
            #expect(await transport.clientMessageIDs() == [command.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("invalid retry clocks preserve the pending message and its idempotency key", arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude])
    func retryClockBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-message-retry-clock-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: testInstallationBinding)
        do {
            let transport = ScriptedMessageTransport(results: [.retryableFailure, .accepted])
            let normal = V2CommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await normal.enqueueMessage(roomID: .init(uuid: UUID()), text: "retry after clock recovery")
            let reads = Mutex(0)
            let invalid = V2CommandOutboxEngine(store: store, transport: transport, now: {
                reads.withLock { count in
                    defer { count += 1 }
                    return Date(timeIntervalSince1970: count == 0 ? 1_000 : seconds)
                }
            })
            await #expect(throws: V2CommandRetrySchedulerError.invalidDate) { try await invalid.flushOnce() }
            #expect(try await store.pendingMessageCommands() == [command])
            #expect(try await normal.flushOnce() == .accepted(command.clientMessageID))
            #expect(await transport.clientMessageIDs() == [command.clientMessageID, command.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("canonical acceptance can complete twice but cannot change or become pending again")
    func repeatedCanonicalAcceptanceIsIdempotent() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let engine = V2CommandOutboxEngine(store: store, transport: ScriptedMessageTransport(results: [.accepted]))
        let command = try await engine.enqueueMessage(roomID: .init(uuid: UUID()), text: "same completion")
        let messageID = MessageID(uuid: UUID())
        try await store.markMessageAccepted(clientMessageID: command.clientMessageID, messageID: messageID, roomSequence: 1)
        try await store.markMessageAccepted(clientMessageID: command.clientMessageID, messageID: messageID, roomSequence: 1)
        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await store.markMessageAccepted(clientMessageID: command.clientMessageID, messageID: messageID, roomSequence: 2)
        }
        await #expect(throws: V2ClientCommandError.commandNotPending) {
            try await store.scheduleMessageRetry(clientMessageID: command.clientMessageID, nextAttemptAt: Date())
        }
        let row = try #require(await store.pendingMessageCommands().first)
        #expect(row.state == .accepted)
        #expect(row.acceptedRoomSequence == 1)
    }

    @Test("twenty concurrent flush calls share one send even when one UI waiter cancels")
    func concurrentFlushesShareOneSend() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let transport = LateSuccessMessageTransport()
        let engine = V2CommandOutboxEngine(store: store, transport: transport)
        let command = try await engine.enqueueMessage(roomID: .init(uuid: UUID()), text: "one durable send")
        let first = Task { try await engine.flushOnce() }
        await transport.waitUntilResponseIsPending()
        let callers = (0..<19).map { _ in Task { try await engine.flushOnce() } }
        first.cancel()
        await transport.resumeAccepted()
        await #expect(throws: CancellationError.self) { try await first.value }
        for caller in callers { _ = try await caller.value }
        #expect(await transport.sendCalls == 1)
        let completed = try #require(await store.pendingMessageCommands().first)
        #expect(completed.state == .accepted)
        #expect(completed.clientMessageID == command.clientMessageID)
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("network retry survives store restart and preserves the original client message ID")
    func retrySurvivesRestart() async throws {
        let url = temporaryOutboxDatabaseURL()
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000501")
        let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        let transport = ScriptedMessageTransport(results: [.retryableFailure, .accepted])
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let firstEngine = V2CommandOutboxEngine(store: firstStore, transport: transport, makeUUID: { clientID }, now: { started })

        let command = try await firstEngine.enqueueMessage(roomID: roomID, text: "offline message")
        #expect(command.clientMessageID.rawValue == clientID.uuidString)
        #expect(try await firstEngine.flushOnce() == .retryScheduled(command.clientMessageID))
        let retry = try #require(await firstStore.pendingMessageCommands().first)
        #expect(retry.state == .pending)
        #expect(retry.attemptCount == 1)

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let restartedEngine = V2CommandOutboxEngine(store: restartedStore, transport: transport, now: { started.addingTimeInterval(1) })
        #expect(try await restartedEngine.flushOnce() == .accepted(command.clientMessageID))
        let completed = try #require(await restartedStore.pendingMessageCommands().first)
        #expect(completed.clientMessageID == command.clientMessageID)
        #expect(completed.state == .accepted)
        #expect(completed.acceptedMessageID?.rawValue == "00000000-0000-0000-0000-000000000503")
        #expect(completed.acceptedRoomSequence == 1)
        #expect(await transport.clientMessageIDs() == [command.clientMessageID, command.clientMessageID])
    }

    @Test("response loss after remote acceptance retries the original durable idempotency key")
    func responseLossAfterAcceptanceSurvivesRestart() async throws {
        let url = temporaryOutboxDatabaseURL()
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ScriptedMessageTransport(results: [.acceptedThenResponseLost, .accepted])
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let firstEngine = V2CommandOutboxEngine(
            store: firstStore,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000508")! },
            now: { started }
        )
        let command = try await firstEngine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000509"), text: "accepted before response loss")

        #expect(try await firstEngine.flushOnce() == .retryScheduled(command.clientMessageID))
        #expect(await transport.remotelyAcceptedIDs() == [command.clientMessageID])
        let retrying = try #require(await firstStore.pendingMessageCommands().first)
        #expect(retrying.state == .pending)
        #expect(retrying.acceptedMessageID == nil)

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: testInstallationBinding)
        let restartedEngine = V2CommandOutboxEngine(store: restartedStore, transport: transport, now: { started.addingTimeInterval(1) })
        #expect(try await restartedEngine.flushOnce() == .accepted(command.clientMessageID))
        let completed = try #require(await restartedStore.pendingMessageCommands().first)
        #expect(completed.clientMessageID == command.clientMessageID)
        #expect(completed.state == .accepted)
        #expect(completed.acceptedMessageID?.rawValue == "00000000-0000-0000-0000-000000000503")
        #expect(await transport.clientMessageIDs() == [command.clientMessageID, command.clientMessageID])
        #expect(await transport.remotelyAcceptedIDs() == [command.clientMessageID])
    }

    @Test("terminal server conflict is recorded and never rescheduled")
    func terminalConflictIsNotRetried() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let engine = V2CommandOutboxEngine(store: store, transport: ScriptedMessageTransport(results: [.terminalConflict]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000504")! }, now: { now })
        let command = try await engine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000505"), text: "conflict")

        #expect(try await engine.flushOnce() == .rejected(command.clientMessageID, code: "IDEMPOTENCY_CONFLICT"))
        let rejected = try #require(await store.pendingMessageCommands().first)
        #expect(rejected.state == .rejected)
        #expect(rejected.terminalCode == "IDEMPOTENCY_CONFLICT")
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("rate limit rejects the current send and never silently replays its content")
    func rateLimitIsRejectedInsteadOfBeingRescheduled() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryOutboxDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ScriptedMessageTransport(results: [.rateLimited])
        let engine = V2CommandOutboxEngine(
            store: store,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000515")! },
            now: { now }
        )
        let command = try await engine.enqueueMessage(
            roomID: .init("00000000-0000-0000-0000-000000000516"),
            text: "do not silently retry"
        )

        #expect(try await engine.flushOnce() == .rejected(command.clientMessageID, code: "RATE_LIMITED"))
        let rejected = try #require(await store.pendingMessageCommands().first)
        #expect(rejected.state == .rejected)
        #expect(rejected.terminalCode == "RATE_LIMITED")
        #expect(rejected.attemptCount == 0)
        #expect(try await engine.flushOnce() == .idle)
        #expect(await transport.clientMessageIDs() == [command.clientMessageID])
    }

    @Test("an out-of-range accepted sequence leaves the durable command pending")
    func rejectsUnpersistableAcceptanceSequence() async throws {
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let engine = V2CommandOutboxEngine(store: store, transport: ScriptedMessageTransport(results: [.accepted]))
        let command = try await engine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000506"), text: "range")

        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await store.markMessageAccepted(
                clientMessageID: command.clientMessageID,
                messageID: .init("00000000-0000-0000-0000-000000000507"),
                roomSequence: UInt64(Int64.max) + 1
            )
        }
        let pending = try #require(await store.pendingMessageCommands().first)
        #expect(pending.state == .pending)
        #expect(pending.acceptedRoomSequence == nil)
    }

    @Test("attachments and mentions survive durable retry and reach the transport unchanged")
    func attachmentsAndMentionsSurviveRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let media = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000510"))
        let mention: V2MentionTarget = .user(try .init("00000000-0000-0000-0000-000000000512"))
        let transport = ScriptedMessageTransport(results: [.retryableFailure, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: temporaryOutboxDatabaseURL(), installationBinding: testInstallationBinding)
        let engine = V2CommandOutboxEngine(store: store, transport: transport, now: { now })
        let command = try await engine.enqueueMessage(roomID: .init("00000000-0000-0000-0000-000000000511"), text: "", media: [media], mentions: [mention])

        #expect(command.media == [media])
        #expect(command.mentions == [mention])
        #expect(try await engine.flushOnce() == .retryScheduled(command.clientMessageID))
        #expect(try #require(await store.pendingMessageCommands().first).media == [media])
        #expect(try #require(await store.pendingMessageCommands().first).mentions == [mention])
        let retrying = V2CommandOutboxEngine(store: store, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await retrying.flushOnce() == .accepted(command.clientMessageID))
        #expect(await transport.receivedMedia() == [[media], [media]])
        #expect(await transport.receivedMentions() == [[mention], [mention]])
    }

    @Test("runtime 停止后忽略非协作传输的迟到成功，保留同一 durable 命令")
    func cancellationAfterLateTransportSuccessDoesNotPersistAcceptance() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryOutboxDatabaseURL(),
            installationBinding: testInstallationBinding
        )
        let transport = LateSuccessMessageTransport()
        let engine = V2CommandOutboxEngine(store: store, transport: transport)
        let command = try await engine.enqueueMessage(
            roomID: .init("00000000-0000-0000-0000-000000000513"),
            text: "cancel after remote success"
        )

        let flush = Task { try await engine.flushOnce() }
        await transport.waitUntilResponseIsPending()
        await engine.suspendCommandFlushing()
        await transport.resumeAccepted()

        await #expect(throws: CancellationError.self) {
            _ = try await flush.value
        }
        let pending = try #require(await store.pendingMessageCommands().first)
        #expect(pending.clientMessageID == command.clientMessageID)
        #expect(pending.state == .pending)
        #expect(pending.attemptCount == 0)
        #expect(pending.acceptedMessageID == nil)
    }
}

private actor ScriptedMessageTransport: V2ClientMessageTransport {
    enum Result: Sendable { case retryableFailure, terminalConflict, rateLimited, acceptedThenResponseLost, accepted }
    private var results: [Result]
    private var receivedIDs: [ClientMessageID] = []
    private var remoteAcceptedIDs: [ClientMessageID] = []
    private var receivedAttachments: [[V2MediaReference]] = []
    private var receivedMentionTargets: [[V2MentionTarget]] = []

    init(results: [Result]) { self.results = results }

    func sendMessage(roomID: RoomID, clientMessageID: ClientMessageID, text _: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities _: [V2MessageEntity], replyTo _: V2MessageReplyReference?) throws -> V2ClientMessageAcceptance {
        receivedIDs.append(clientMessageID)
        receivedAttachments.append(media)
        receivedMentionTargets.append(mentions)
        switch results.removeFirst() {
        case .retryableFailure: throw V2RealtimeTransportError.unexpectedResponse
        case .terminalConflict: throw V2RealtimeTransportError.server(code: "IDEMPOTENCY_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        case .rateLimited: throw V2RealtimeTransportError.server(code: "RATE_LIMITED", retryable: true, retryAfterSeconds: 30, currentRevision: nil)
        case .acceptedThenResponseLost:
            remoteAcceptedIDs.append(clientMessageID)
            throw V2RealtimeTransportError.unexpectedResponse
        case .accepted:
            if !remoteAcceptedIDs.contains(clientMessageID) {
                remoteAcceptedIDs.append(clientMessageID)
            }
            return try .init(messageID: .init("00000000-0000-0000-0000-000000000503"), roomID: roomID, roomSequence: 1, createdAt: .distantPast)
        }
    }

    func clientMessageIDs() -> [ClientMessageID] { receivedIDs }
    func remotelyAcceptedIDs() -> [ClientMessageID] { remoteAcceptedIDs }
    func receivedMedia() -> [[V2MediaReference]] { receivedAttachments }
    func receivedMentions() -> [[V2MentionTarget]] { receivedMentionTargets }
}

/// Models a transport that cannot observe cancellation until it has already
/// received a valid remote response. The outbox must fence its local write at
/// that boundary and preserve the original idempotency key for the next run.
private actor LateSuccessMessageTransport: V2ClientMessageTransport {
    private(set) var sendCalls = 0
    private var responseWaiter: CheckedContinuation<V2ClientMessageAcceptance, Never>?
    private var responseReadyWaiter: CheckedContinuation<Void, Never>?
    private var pendingAcceptance: V2ClientMessageAcceptance?

    func sendMessage(
        roomID: RoomID,
        clientMessageID _: ClientMessageID,
        text _: String,
        media _: [V2MediaReference],
        mentions _: [V2MentionTarget],
        entities _: [V2MessageEntity],
        replyTo _: V2MessageReplyReference?
    ) async throws -> V2ClientMessageAcceptance {
        sendCalls += 1
        let acceptance = try V2ClientMessageAcceptance(
            messageID: .init("00000000-0000-0000-0000-000000000514"),
            roomID: roomID,
            roomSequence: 1,
            createdAt: .distantPast
        )
        return await withCheckedContinuation { continuation in
            pendingAcceptance = acceptance
            responseWaiter = continuation
            responseReadyWaiter?.resume()
            responseReadyWaiter = nil
        }
    }

    func waitUntilResponseIsPending() async {
        guard responseWaiter == nil else { return }
        await withCheckedContinuation { responseReadyWaiter = $0 }
    }

    func resumeAccepted() {
        guard let acceptance = pendingAcceptance, let responseWaiter else { return }
        pendingAcceptance = nil
        self.responseWaiter = nil
        responseWaiter.resume(returning: acceptance)
    }
}

private func temporaryOutboxDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "im-v2-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "state.sqlite")
}

private let testInstallationBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
