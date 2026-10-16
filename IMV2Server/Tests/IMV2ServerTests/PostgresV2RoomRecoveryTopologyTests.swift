@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Transactional room recovery topology")
struct PostgresV2RoomRecoveryTopologyTests {
    @Test("route changes invalidate scans atomically; unrelated updates do not")
    func routingFence() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let source = try makeSource(database, schema)
            let initial = try await source.generation()
            let room = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: room), 'a', 0, now(), now())
                """).run()
            #expect(try await source.generation() == initial)
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).room_owner_routes SET updated_at = now() WHERE room_id = \(bind: room)
                """).run()
            #expect(try await source.generation() == initial)
            await #expect(throws: TopologyTestRollback.self) {
                try await database.transaction { transaction in
                    let txSQL = try #require(transaction as? any SQLDatabase)
                    try await txSQL.raw("""
                        UPDATE \(unsafeRaw: schema).room_owner_routes
                        SET room_shard_id = 'b', route_epoch = 1 WHERE room_id = \(bind: room)
                        """).run()
                    let changed = try await makeSource(transaction, schema).generation()
                    #expect(changed != initial)
                    throw TopologyTestRollback()
                }
            }
            #expect(try await source.generation() == initial)
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).room_owner_routes
                SET room_shard_id = 'b', route_epoch = 1 WHERE room_id = \(bind: room)
                """).run()
            let changed = try await source.generation()
            #expect(changed != initial)
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_owner_routes WHERE room_id = \(bind: room)").run()
            #expect(try await source.generation() != changed)
        }
    }

    @Test("import, truncate and deployment changes invalidate directory tokens")
    func resets() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let source = try makeSource(database, schema)
            let initial = try await source.generation()
            let configured = try makeSource(database, schema, identity: "different-store")
            #expect(try await configured.generation() != initial)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_owner_routes
                    (room_id, room_shard_id, route_epoch, created_at, updated_at)
                VALUES (\(bind: UUID()), 'b', 4, now(), now())
                """).run()
            let imported = try await source.generation()
            #expect(imported != initial)
            try await sql.raw("TRUNCATE \(unsafeRaw: schema).room_owner_routes").run()
            #expect(try await source.generation() != imported)
        }
    }

    @Test("a missing fence fails closed for reads and route changes")
    func missingFence() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let source = try makeSource(database, schema)
            try await sql.raw("DELETE FROM \(unsafeRaw: schema).room_recovery_topology").run()
            await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
                try await source.generation()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_owner_routes
                        (room_id, room_shard_id, route_epoch, created_at, updated_at)
                    VALUES (\(bind: UUID()), 'b', 1, now(), now())
                    """).run()
            }
        }
    }

    @Test("startup rejects a disabled routing invalidation trigger")
    func readinessFence() async throws {
        try await withUserEventDatabase { database, sql, schema in
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("""
                ALTER TABLE \(unsafeRaw: schema).room_owner_routes
                DISABLE TRIGGER room_owner_routes_recovery_fence
                """).run()
            await #expect(throws: V2SchemaReadinessError.unavailableTable(schema + ".room_recovery_topology[fence]")) {
                try await V2SchemaReadiness.verify(database: database, schema: schema)
            }
        }
    }
}

private func makeSource(_ database: any Database, _ schema: String, identity: String = "store") throws -> PostgresV2RoomRecoveryTopology {
    try .init(database: database, schema: schema,
        stores: [PostgresV2RoomRecoveryStore(database: database, schema: schema)], orderedStoreIdentities: [identity], atomicStores: [:])
}

private struct TopologyTestRollback: Error {}
