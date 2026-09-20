import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("Room owner migration preparation", .serialized)
struct V2RoomOwnerMigrationPreparationTests {
    @Test func sourceMarkerFencesSharedOwnerWritesAndSurvivesStoreRecreation() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let now = Date(timeIntervalSince1970: 1_750_000_000), room = RoomID(uuid: UUID())
            let request = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room,
                source: .init(shardID: "a", epoch: 7), targetShardID: "b")
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms (room_id, room_shard_id, owner_epoch, capacity_profile_id) VALUES (\(bind: room.uuidValue!), 'a', 7, 'standard')").run()
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_owner_routes VALUES (\(bind: room.uuidValue!), 'a', 7, \(bind: now), \(bind: now))").run()
            let control = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: ["a", "b"], schema: schema)
            let prepared = try await control.prepare(request, now: now)
            let owner = PostgresV2RoomMigrationWriteFence(database: database, schema: schema)
            await #expect(throws: V2RoomOwnerMigrationError.invalidPhase) { try await owner.install(for: prepared) }
            try await v2RequireRoomOwner(roomID: room.uuidValue!, route: request.source, sql: sql, schema: schema)
            let freezing = try await control.beginFreezing(request, now: now)
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch = 8").run()
            await #expect(throws: V2RoomOwnerMigrationError.sourceChanged) { try await owner.install(for: freezing) }
            try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch = 7").run()
            async let first: Void = owner.install(for: freezing)
            async let second: Void = owner.install(for: freezing)
            _ = try await (first, second)
            try await PostgresV2RoomMigrationWriteFence(database: database, schema: schema).install(for: freezing)
            await #expect(throws: V2RoomOwnerFenceError.ownerChanged) {
                try await v2RequireRoomOwner(roomID: room.uuidValue!, route: request.source, sql: sql, schema: schema)
            }
            let other = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room, source: request.source, targetShardID: "b")
            let conflicting = V2RoomOwnerMigrationRecord(request: other, phase: .freezing, createdAt: now, updatedAt: now)
            await #expect(throws: V2RoomOwnerMigrationError.requestConflict) { try await owner.install(for: conflicting) }
            #expect(try await control.record(migrationID: request.migrationID)?.phase == .freezing)
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).rooms WHERE migration_fence_id = \(bind: request.migrationID) AND owner_epoch = 7 AND room_sequence = 0").first(decoding: MigrationCount.self)?.value == 1)
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("ALTER TABLE \(unsafeRaw: schema).rooms DROP COLUMN migration_fence_id").run()
            await #expect(throws: V2SchemaReadinessError.self) { try await V2SchemaReadiness.verify(database: database, schema: schema) }
        }
    }

    @Test func freezingIntentIsResumableAndExcludesCancellation() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let now = Date(timeIntervalSince1970: 1_750_000_000), room = RoomID(uuid: UUID())
            let request = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room,
                source: .init(shardID: "a", epoch: 7), targetShardID: "b")
            let store = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: ["a", "b"], schema: schema)
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_owner_routes VALUES (\(bind: room.uuidValue!), 'a', 7, \(bind: now), \(bind: now))").run()
            _ = try await store.prepare(request, now: now)
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_owner_routes SET route_epoch = 8").run()
            await #expect(throws: V2RoomOwnerMigrationError.sourceChanged) { try await store.beginFreezing(request, now: now) }
            #expect(try await store.record(migrationID: request.migrationID)?.phase == .prepared)
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_owner_routes SET route_epoch = 7").run()
            for seconds in [Double.nan, .infinity, now.timeIntervalSince1970 - 1] {
                await #expect(throws: V2RoomOwnerMigrationError.invalidRequest) {
                    try await store.beginFreezing(request, now: .init(timeIntervalSince1970: seconds))
                }
            }
            async let first = store.beginFreezing(request, now: now.addingTimeInterval(1))
            async let second = store.beginFreezing(request, now: now.addingTimeInterval(2))
            let (one, two) = try await (first, second)
            #expect(one == two && one.phase == .freezing)
            let restarted = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: ["a", "b"], schema: schema)
            #expect(try await restarted.beginFreezing(request, now: .init(timeIntervalSince1970: .nan)) == one)
            await #expect(throws: V2RoomOwnerMigrationError.invalidPhase) { try await restarted.abortPreparation(request, now: now.addingTimeInterval(3)) }
            #expect(try await restarted.prepare(request, now: now) == one)
            // Exercise the actual cancellation/start row-lock race on a new
            // prepared task. Exactly one terminal decision may win.
            let otherRoom = RoomID(uuid: UUID())
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_owner_routes VALUES (\(bind: otherRoom.uuidValue!), 'a', 7, \(bind: now), \(bind: now))").run()
            let other = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: otherRoom, source: request.source, targetShardID: "b")
            _ = try await store.prepare(other, now: now)
            @Sendable func attempt(abort: Bool) async throws -> Bool {
                do {
                    if abort { _ = try await store.abortPreparation(other, now: now.addingTimeInterval(1)) }
                    else { _ = try await store.beginFreezing(other, now: now.addingTimeInterval(1)) }
                    return true
                } catch V2RoomOwnerMigrationError.invalidPhase { return false }
            }
            async let aborted = attempt(abort: true)
            async let freezing = attempt(abort: false)
            let (abortWon, freezeWon) = try await (aborted, freezing)
            #expect(abortWon != freezeWon)
            #expect(try await store.record(migrationID: other.migrationID)?.phase == (abortWon ? .aborted : .freezing))
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).room_owner_routes WHERE room_shard_id = 'a' AND route_epoch = 7").first(decoding: MigrationCount.self)?.value == 2)
        }
    }

    @Test func restoredPreparationCanBeAbortedWithoutRevivingItsIdentity() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let now = Date(timeIntervalSince1970: 1_750_000_000), room = RoomID(uuid: UUID())
            let source = try V2RoomShardRoute(shardID: "a", epoch: 7)
            let request = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room, source: source, targetShardID: "b")
            let store = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: ["a", "b", "c"], schema: schema)
            #expect(try await store.record(migrationID: request.migrationID) == nil)
            await #expect(throws: V2RoomOwnerMigrationError.migrationNotFound) { try await store.abortPreparation(request, now: now) }
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_owner_routes VALUES (\(bind: room.uuidValue!), 'a', 7, \(bind: now), \(bind: now))").run()
            let original = try await store.prepare(request, now: now)
            let restored = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: [], schema: schema)
            #expect(try await restored.record(migrationID: request.migrationID) == original)
            let conflict = try V2RoomOwnerMigrationPreparation(migrationID: request.migrationID, roomID: room, source: source, targetShardID: "c")
            await #expect(throws: V2RoomOwnerMigrationError.requestConflict) { try await restored.abortPreparation(conflict, now: now) }
            for seconds in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, now.timeIntervalSince1970 - 1] {
                await #expect(throws: V2RoomOwnerMigrationError.invalidRequest) {
                    try await restored.abortPreparation(request, now: .init(timeIntervalSince1970: seconds))
                }
                #expect(try await restored.record(migrationID: request.migrationID) == original)
            }
            async let left = restored.abortPreparation(request, now: now.addingTimeInterval(1))
            async let right = restored.abortPreparation(request, now: now.addingTimeInterval(2))
            let (one, two) = try await (left, right)
            #expect(one == two && one.phase == .aborted && one.request == request)
            #expect(try await restored.abortPreparation(request, now: .init(timeIntervalSince1970: .nan)) == one)
            #expect(try await store.prepare(request, now: now) == one)
            let fresh = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room, source: source, targetShardID: "c")
            #expect(try await store.prepare(fresh, now: now.addingTimeInterval(3)).phase == .prepared)
            #expect(try await restored.abortPreparation(request, now: now.addingTimeInterval(4)) == one)
            #expect(try await store.record(migrationID: fresh.migrationID)?.phase == .prepared)
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).room_owner_routes WHERE room_id = \(bind: room.uuidValue!) AND room_shard_id = 'a' AND route_epoch = 7").first(decoding: MigrationCount.self)?.value == 1)
            // These are controlled future-phase fixtures, not execution of
            // freezing/copying/publication, which remain unimplemented.
            for phase in ["freezing", "frozen", "copying", "copied", "verified", "published", "retaining", "completed"] {
                try await sql.raw("UPDATE \(unsafeRaw: schema).room_owner_migrations SET phase = \(bind: phase) WHERE migration_id = \(bind: fresh.migrationID)").run()
                await #expect(throws: V2RoomOwnerMigrationError.invalidPhase) { try await store.abortPreparation(fresh, now: now.addingTimeInterval(5)) }
                #expect(try await store.record(migrationID: fresh.migrationID)?.phase.rawValue == phase)
            }
        }
    }

    @Test func rejectsSameShardAndEpochOverflow() throws {
        let room = RoomID(uuid: UUID())
        for epoch in [Int64(0), 7, Int64.max - 1] {
            let request = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room,
                source: .init(shardID: "a", epoch: epoch), targetShardID: " b ")
            #expect(request.target.epoch == epoch + 1 && request.target.shardID == "b")
        }
        #expect(throws: V2RoomOwnerMigrationError.invalidRequest) {
            try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room,
                source: .init(shardID: "a", epoch: Int64.max), targetShardID: "b")
        }
        #expect(throws: V2RoomOwnerMigrationError.invalidRequest) {
            try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room,
                source: .init(shardID: "a", epoch: 0), targetShardID: " a ")
        }
    }

    @Test func durableIdempotencyAndExclusiveRoomPreparation() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID()), now = Date(timeIntervalSince1970: 1_750_000_000)
            let source = try V2RoomShardRoute(shardID: "a", epoch: 7)
            let request = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room, source: source, targetShardID: "b")
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_owner_routes VALUES (\(bind: room.uuidValue!), 'a', 7, \(bind: now), \(bind: now))").run()
            let store = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: ["a", "b", "c"], schema: schema)
            async let first = store.prepare(request, now: now)
            async let second = store.prepare(request, now: now.addingTimeInterval(1))
            let (one, two) = try await (first, second)
            #expect(one == two && one.phase == .prepared && one.request.target.epoch == 8)
            let reopened = PostgresV2RoomOwnerMigrationPreparationStore(database: database, registeredShardIDs: ["a", "b", "c"], schema: schema)
            #expect(try await reopened.prepare(request, now: .init(timeIntervalSince1970: .nan)) == one)
            let conflict = try V2RoomOwnerMigrationPreparation(migrationID: request.migrationID, roomID: room, source: source, targetShardID: "c")
            await #expect(throws: V2RoomOwnerMigrationError.requestConflict) { try await store.prepare(conflict, now: now) }
            let competitor = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room, source: source, targetShardID: "c")
            await #expect(throws: V2RoomOwnerMigrationError.migrationInProgress) { try await store.prepare(competitor, now: now) }
            let unknown = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room, source: source, targetShardID: "unknown")
            await #expect(throws: V2RoomOwnerMigrationError.unknownShard) { try await store.prepare(unknown, now: now) }
            let stale = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: room,
                source: .init(shardID: "a", epoch: 6), targetShardID: "b")
            await #expect(throws: V2RoomOwnerMigrationError.sourceChanged) { try await store.prepare(stale, now: now) }
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).room_owner_migrations").first(decoding: MigrationCount.self)?.value == 1)
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).room_owner_routes WHERE room_id = \(bind: room.uuidValue!) AND room_shard_id = 'a' AND route_epoch = 7").first(decoding: MigrationCount.self)?.value == 1)
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE \(unsafeRaw: schema).room_owner_migrations SET target_shard_id = 'c'").run()
            }
            #expect(try await reopened.prepare(request, now: now) == one)
            let otherRoom = RoomID(uuid: UUID())
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).room_owner_routes VALUES (\(bind: otherRoom.uuidValue!), 'a', 7, \(bind: now), \(bind: now))").run()
            let left = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: otherRoom, source: source, targetShardID: "b")
            let right = try V2RoomOwnerMigrationPreparation(migrationID: UUID(), roomID: otherRoom, source: source, targetShardID: "c")
            @Sendable func attempt(_ value: V2RoomOwnerMigrationPreparation) async throws -> Bool {
                do { _ = try await store.prepare(value, now: now); return true }
                catch V2RoomOwnerMigrationError.migrationInProgress { return false }
            }
            async let leftResult = attempt(left)
            async let rightResult = attempt(right)
            let (leftWon, rightWon) = try await (leftResult, rightResult)
            #expect(leftWon != rightWon)
            #expect(try await sql.raw("SELECT count(*) AS value FROM \(unsafeRaw: schema).room_owner_migrations WHERE room_id = \(bind: otherRoom.uuidValue!)").first(decoding: MigrationCount.self)?.value == 1)
            try await V2SchemaReadiness.verify(database: database, schema: schema)
            try await sql.raw("DROP INDEX \(unsafeRaw: schema).room_owner_migrations_active_room_key").run()
            await #expect(throws: V2SchemaReadinessError.self) { try await V2SchemaReadiness.verify(database: database, schema: schema) }
        }
    }
}
private struct MigrationCount: Decodable { let value: Int64 }
