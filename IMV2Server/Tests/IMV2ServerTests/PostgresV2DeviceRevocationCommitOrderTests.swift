import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing
import Vapor

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("revocation IDs serialize before allocation and remain visible to both consumers", arguments: [false, true])
    func deviceRevocationCommitOrder(rollbackFirst: Bool) async throws {
        guard let url = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            try await installSchema(on: sql)
            let users = [UUID(), UUID(), UUID()]
            let devices = [UUID(), UUID(), UUID()]
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            for index in users.indices {
                try await sql.raw("""
                    INSERT INTO im_v2.auth_devices (user_id, device_id, created_at, last_active_at)
                    VALUES (\(bind: users[index]), \(bind: devices[index]), \(bind: now), \(bind: now))
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
                VALUES (\(bind: users[0]), \(bind: devices[0]), \(bind: now))
                """).run()
            let allocated = RevocationTransactionGate()
            let release = RevocationTransactionGate()
            let first = Task {
                do {
                    return try await database.transaction { transaction -> Int64 in
                        let writer = try #require(transaction as? any SQLDatabase)
                        let row = try #require(try await writer.raw("""
                            INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
                            VALUES (\(bind: users[1]), \(bind: devices[1]), \(bind: now)) RETURNING event_id
                            """).first())
                        let id = try row.decode(column: "event_id", as: Int64.self)
                        await allocated.open()
                        await release.wait()
                        if rollbackFirst { throw RevocationTransactionRollback.expected }
                        return id
                    }
                } catch {
                    await allocated.open()
                    throw error
                }
            }
            await allocated.wait()
            let second = Task {
                try await sql.raw("""
                    WITH revoked_device AS MATERIALIZED (
                        UPDATE im_v2.auth_devices SET revoked_at = \(bind: now)
                        WHERE user_id = \(bind: users[2]) AND device_id = \(bind: devices[2])
                        RETURNING user_id, device_id
                    )
                    INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
                    SELECT user_id, device_id, \(bind: now) FROM revoked_device
                    """).run()
            }
            do {
                // Observe a real second backend blocked by the statement trigger,
                // rather than relying on scheduler timing to manufacture the race.
                var waiting = false
                for _ in 0..<500 {
                    let row = try #require(try await sql.raw("""
                        SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory'
                          AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
                          AND classid = 743204 AND objid = 1 AND objsubid = 2 AND NOT granted) AS waiting
                        """).first())
                    if try row.decode(column: "waiting", as: Bool.self) { waiting = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(waiting, "The competing INSERT must wait until the first transaction ends")
                let sequence = try #require(try await sql.raw("SELECT last_value FROM im_v2.device_revocation_events_event_id_seq").first())
                #expect(try sequence.decode(column: "last_value", as: Int64.self) == 2,
                        "The waiting INSERT must not allocate an identity before acquiring the transaction lock")
                let gateway = V2PostgresDeviceRevocationEventStore(database: database)
                let cleanup = V2PostgresDeviceRevocationEventStore.projectionCleanup(database: database)
                let node = "commit-order-gateway"
                try await gateway.initializeCursorIfNeeded(nodeID: node, now: now)
                try await cleanup.initializeCursorAtBeginningIfNeeded(nodeID: "cluster", now: now)
                #expect(try await gateway.events(afterCursorFor: node, limit: 1).isEmpty)
                await release.open()
                switch await first.result {
                case .success(let id): #expect(!rollbackFirst && id == 2)
                case .failure(let error):
                    guard rollbackFirst, error is RevocationTransactionRollback else { throw error }
                }
                try await second.value
                let expected = rollbackFirst ? [devices[2]] : [devices[1], devices[2]]
                for (store, consumer, expectedDevices) in [
                    (gateway, node, expected), (cleanup, "cluster", [devices[0]] + expected)
                ] {
                    for device in expectedDevices {
                        let page = try await store.events(afterCursorFor: consumer, limit: 1)
                        let event = try #require(page.first)
                        #expect(page.count == 1 && event.deviceID.uuidValue == device)
                        try await store.markProcessed(eventID: event.eventID, nodeID: consumer, now: now)
                    }
                    #expect(try await store.events(afterCursorFor: consumer, limit: 1).isEmpty)
                }
                try await gateway.initializeCursorIfNeeded(nodeID: node, now: now)
                #expect(try await gateway.events(afterCursorFor: node, limit: 1).isEmpty)
            } catch {
                await release.open()
                _ = await first.result
                _ = await second.result
                throw error
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            if let sql = resources.database(.psql) as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            }
            try? await resources.shutdown()
            throw error
        }
    }
}

extension PostgresV2RoomRecoverySchemaTests {
    @Test("readiness rejects any loss of the revocation commit-order fence",
          arguments: ["trigger", "disabled", "row", "body", "cache", "reverse"])
    func revocationReadinessRejectsCommitOrderDrift(target: String) async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            switch target {
            case "trigger", "row":
                try await sql.raw("DROP TRIGGER device_revocation_events_commit_order ON \(unsafeRaw: schema).device_revocation_events").run()
                if target == "row" {
                    try await sql.raw("""
                        CREATE TRIGGER device_revocation_events_commit_order
                        BEFORE INSERT ON \(unsafeRaw: schema).device_revocation_events FOR EACH ROW
                        EXECUTE FUNCTION \(unsafeRaw: schema).serialize_device_revocation_events()
                        """).run()
                }
            case "disabled":
                try await sql.raw("ALTER TABLE \(unsafeRaw: schema).device_revocation_events DISABLE TRIGGER device_revocation_events_commit_order").run()
            case "body":
                try await sql.raw("""
                    CREATE OR REPLACE FUNCTION \(unsafeRaw: schema).serialize_device_revocation_events()
                    RETURNS trigger LANGUAGE plpgsql VOLATILE AS $$ BEGIN RETURN NULL; END; $$
                    """).run()
            case "cache":
                try await sql.raw("ALTER SEQUENCE \(unsafeRaw: schema).device_revocation_events_event_id_seq CACHE 8").run()
            default:
                try await sql.raw("ALTER SEQUENCE \(unsafeRaw: schema).device_revocation_events_event_id_seq INCREMENT BY -1 MINVALUE -9223372036854775808").run()
            }
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".device_revocation_events.commit_order")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }
}

private enum RevocationTransactionRollback: Error { case expected }

private actor RevocationTransactionGate {
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
