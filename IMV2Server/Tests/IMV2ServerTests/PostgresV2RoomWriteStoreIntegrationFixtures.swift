import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing
import Vapor

// Shared database topology and canonical room seed for the serialized room-write suite.
extension PostgresV2RoomWriteStoreIntegrationTests {
    internal func withForwardOwnerDatabases(mode: V2GroupCapacityClass,
        _ operation: (any Database, any Database, any SQLDatabase, any SQLDatabase, RoomID) async throws -> Void
    ) async throws {
        guard let primary = Environment.get("IMV2_POSTGRES_TEST_DATABASE_URL"),
              let secondary = Environment.get("IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"),
              primary != secondary, Environment.get("IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE") == "1" else { return }
        let resources = makeV2DatabaseTestResources()
        let secondaryID = DatabaseID(string: "forward-import-target")
        do {
            resources.databases.use(try .postgres(url: primary, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            resources.databases.use(try .postgres(url: secondary, maxConnectionsPerEventLoop: 4), as: secondaryID)
            let sourceDB = resources.database(.psql), targetDB = resources.database(secondaryID)
            let sourceSQL = try #require(sourceDB as? any SQLDatabase), targetSQL = try #require(targetDB as? any SQLDatabase)
            for sql in [sourceSQL, targetSQL] {
                guard (try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS exists").first(decoding: ExistsRow.self))?.exists == false else { throw TestConfigurationError.schemaAlreadyExists }
                try await installSchema(on: sql)
            }
            let target = RoomID(uuid: UUID())
            try await seedRoom(capacityClass: mode, on: sourceSQL)
            try await seedRoom(capacityClass: mode, roomID: target.uuidValue!, shardID: "room-b", on: targetSQL)
            try await operation(sourceDB, targetDB, sourceSQL, targetSQL, target)
            for sql in [sourceSQL, targetSQL] { try await sql.raw("DROP SCHEMA im_v2 CASCADE").run() }
            try await resources.shutdown()
        } catch {
            for database in [resources.database(.psql), resources.database(secondaryID)] {
                if let sql = database as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() }
            }
            try? await resources.shutdown(); throw error
        }
    }

    internal func seedRoom(
        capacityClass: V2GroupCapacityClass = .standard,
        roomID: UUID = roomUUID,
        shardID: String = "room-a",
        on sql: any SQLDatabase
    ) async throws {
        let seededAt = Date(timeIntervalSince1970: 1_750_000_000)
        try await sql.raw("""
            INSERT INTO im_v2.public_user_profiles
                (user_id, public_handle, display_name, revision, created_at, updated_at)
            VALUES
                (\(bind: senderUUID), 'sender012', '发送者', 1, \(bind: seededAt), \(bind: seededAt)),
                (\(bind: memberTwoUUID), 'member015', '成员二', 1, \(bind: seededAt), \(bind: seededAt)),
                (\(bind: memberThreeUUID), 'member016', '成员三', 1, \(bind: seededAt), \(bind: seededAt))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.rooms
                (room_id, room_shard_id, capacity_profile_id, capacity_class)
            VALUES
                (\(bind: roomID), \(bind: shardID), 'standard', \(bind: capacityClass.rawValue))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_owner_routes (room_id, room_shard_id, route_epoch, created_at, updated_at)
            VALUES (\(bind: roomID), \(bind: shardID), 0, \(bind: seededAt), \(bind: seededAt))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
            VALUES (\(bind: roomID), \(bind: senderUUID), '集成测试群', \(bind: Date(timeIntervalSince1970: 1_750_000_000)))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.shard_admission_pools
                (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
            VALUES (\(bind: shardID), 'standard', \(bind: leaseUUID), 1, \(bind: Date(timeIntervalSince1970: 1_750_000_100)), 10)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_admission
                (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
            VALUES (\(bind: roomID), 3, 10, \(bind: leaseUUID), 1)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
            VALUES (\(bind: roomID), \(bind: senderUUID), 0)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
            VALUES (\(bind: roomID), \(bind: memberTwoUUID), 0),
                   (\(bind: roomID), \(bind: memberThreeUUID), 0)
            """).run()
    }

    internal func count(_ table: String, on sql: any SQLDatabase) async throws -> Int64 {
        try #require(try await sql.raw("SELECT COUNT(*) AS value FROM \(unsafeRaw: table)").first(decoding: CountRow.self)).value
    }

    internal func directWriteArtifactCounts(
        sql: any SQLDatabase
    ) async throws -> DirectWriteArtifactCounts {
        try #require(try await sql.raw("""
            SELECT
                (SELECT COUNT(*)::bigint FROM im_v2.messages) AS messages,
                (SELECT COUNT(*)::bigint FROM im_v2.room_events) AS events,
                (SELECT COUNT(*)::bigint FROM im_v2.message_projection_states) AS message_states
            """).first(decoding: DirectWriteArtifactCounts.self))
    }
}

internal struct DirectWriteArtifactCounts: Decodable, Equatable {
    let messages: Int64
    let events: Int64
    let messageStates: Int64

    enum CodingKeys: String, CodingKey {
        case messages, events
        case messageStates = "message_states"
    }
}
