import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Synchronization
import Testing
import Vapor

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("sync cursor authority uses a fresh snapshot after device or retention lock waiting",
          arguments: ["revocation", "firstCursor", "retention"])
    func syncCursorAuthorityAfterLockWaiting(scenario: String) async throws {
        guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
              ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        var ownsSchema = false
        do {
            resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            let exists = try #require(try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS present").first())
            let schemaPresent = try exists.decode(column: "present", as: Bool.self)
            try #require(!schemaPresent)
            ownsSchema = true
            try await installSchema(on: sql)
            let userUUID = UUID(), deviceUUID = UUID(), now = Date()
            let user = UserID(uuid: userUUID), device = DeviceID(uuid: deviceUUID)
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: userUUID), \(bind: deviceUUID), \(bind: now), \(bind: now))
                """).run()
            let store = PostgresV2SyncStore(database: database)
            if scenario != "firstCursor" {
                _ = try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 10, now: now)
            }
            if scenario == "retention" {
                try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userUUID), 1)").run()
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_log
                        (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                    VALUES (\(bind: userUUID), 1, \(bind: UUID()), 'stranger_message_permission',
                        '{"allows_stranger_messages":true,"revision":1,"updated_at_ms":1750000000000}'::jsonb, \(bind: now))
                    """).run()
                try await drainV3Projection(database: database)
                try await sql.raw("""
                    INSERT INTO im_v2.user_sync_retention (user_id, compacted_through_sequence, updated_at)
                    VALUES (\(bind: userUUID), 0, \(bind: now)) ON CONFLICT (user_id) DO NOTHING
                    """).run()
            }
            let acquired = SyncCursorAuthorityGate(), release = SyncCursorAuthorityGate()
            let holderPID = Mutex<Int32?>(nil)
            let holder = Task {
                do {
                    try await database.transaction { transaction in
                        let writer = try #require(transaction as? any SQLDatabase)
                        let pidRow = try #require(try await writer.raw("SELECT pg_backend_pid() AS pid").first())
                        holderPID.withLock { $0 = try? pidRow.decode(column: "pid", as: Int32.self) }
                        if scenario == "retention" {
                            try await writer.raw("""
                                UPDATE im_v2.user_sync_retention SET compacted_through_sequence = 1
                                WHERE user_id = \(bind: userUUID)
                                """).run()
                        } else {
                            try await writer.raw("""
                                SELECT pg_advisory_xact_lock(hashtextextended(
                                    CONCAT(\(bind: userUUID), ':', \(bind: deviceUUID)), 684927))
                                """).run()
                        }
                        await acquired.open()
                        await release.wait()
                        if scenario == "revocation" {
                            // Exercise the actual cleaner on this borrowed connection. Its
                            // nested transaction keeps the same advisory lock until outer COMMIT.
                            try await V2PostgresRevokedDeviceProjectionStore(database: transaction)
                                .clean(userID: user, deviceID: device, revokedAt: now)
                        }
                    }
                } catch { await acquired.open(); throw error }
            }
            await acquired.wait()
            let count = scenario == "firstCursor" ? 2 : 1
            let pulls = (0..<count).map { _ in Task {
                try await store.pull(userID: user, deviceID: device, syncToken: nil, maxRecords: 10, now: now)
            } }
            do {
                let pid = try #require(holderPID.withLock { $0 })
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var actualWaiting = false
                while ContinuousClock.now < deadline {
                    let row = try #require(try await sql.raw("""
                        SELECT count(*) AS waiting FROM pg_stat_activity
                        WHERE datname = current_database() AND \(bind: pid) = ANY(pg_blocking_pids(pid))
                        """).first())
                    if try row.decode(column: "waiting", as: Int64.self) >= Int64(count) {
                        actualWaiting = true; break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(actualWaiting, "Every real pull must be waiting on the held database lock")
                await release.open()
                try await holder.value
                for pull in pulls {
                    if scenario == "revocation" {
                        do {
                            _ = try await pull.value
                            Issue.record("A pull queued behind committed revocation must reject")
                        } catch {
                            #expect(error as? V2SyncStoreError == .deviceRevoked)
                        }
                    } else {
                        let result = try await pull.value
                        if scenario == "retention" {
                            guard case .resetPreparing(_, let generation, _) = result else {
                                Issue.record("Latest locked retention floor must force reset"); continue
                            }
                            #expect(generation == 2)
                        } else {
                            guard case .ready(let generation, let records, _, _, _) = result else {
                                Issue.record("Both first pulls must observe the initialized cursor"); continue
                            }
                            #expect(generation == 1 && records.isEmpty)
                        }
                    }
                }
                let cursorRow = try #require(try await sql.raw("""
                    SELECT count(*) AS value FROM im_v2.device_sync_cursors
                    WHERE user_id = \(bind: userUUID) AND device_id = \(bind: deviceUUID)
                    """).first())
                #expect(try cursorRow.decode(column: "value", as: Int64.self) == (scenario == "revocation" ? 0 : 1))
                if scenario == "firstCursor" {
                    let receipts = try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.sync_receipts").first())
                    #expect(try receipts.decode(column: "value", as: Int64.self) == 2)
                }
            } catch {
                await release.open()
                _ = await holder.result
                for pull in pulls { _ = await pull.result }
                throw error
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if ownsSchema, let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }
}

private actor SyncCursorAuthorityGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
