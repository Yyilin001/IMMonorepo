@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing
import Vapor

// Shared database topology and canonical room seed for the serialized room-write suite.
extension PostgresV2RoomWriteStoreIntegrationTests {
    /// SQL lifecycle fixture; byte verification belongs to adapter/service tests.
    internal func createResourceUpload(_ input: V2ResourceUploadRequest, device: DeviceID,
        store: PostgresV2ResourceLifecycleStore, expiresAt: Date, now: Date
    ) async throws -> V2PersistedResourceUpload {
        try await store.create(homeKind: "room", homeID: roomUUID, usageKind: "message_attachment", actor: senderUUID,
            device: device.uuidValue!, operation: input.operationID.uuidValue!, mediaID: input.mediaID.uuidValue!, contentType: input.contentType,
            byteCount: input.byteCount, requestJSON: String(decoding: JSONEncoder().encode(input), as: UTF8.self),
            allocate: { try .init(placementID: UUID(), binding: .init(id: "room-resource-fixture", configurationRevision: 1), handle: Data(input.mediaID.rawValue.utf8)) },
            expiresAt: expiresAt, now: now)
    }

    internal func prepareDownloadableResource(mediaID: MediaID, device: DeviceID, database: any Database) async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let uploads = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
        let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: mediaID, usage: .messageAttachment(roomID),
            contentType: "image/png", byteCount: 42, checksum: .init(value: String(repeating: "a", count: 64)))
        let upload = try await createResourceUpload(input, device: device, store: uploads, expiresAt: base.addingTimeInterval(600), now: base)
        let claim = try await uploads.claimFinalize(session: upload.sessionID, generation: 1, actor: senderUUID, device: device.uuidValue!, now: base)
        try await uploads.publish(claim, facts: .init(reference: claim.placement, byteCount: 42, sha256: Data(repeating: 0xaa, count: 32)),
            actor: senderUUID, device: device.uuidValue!, now: base)
        let scans = PostgresV2MediaScanStore(database: database)
        let lease = try #require(try await scans.claimPending(now: base, leaseDuration: 30, limit: 1).first)
        try await scans.complete(lease, result: .passed, now: base)
        let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database), capacityProfile: forwardImportTestProfile(), limits: .init(maxUTF8Bytes: 64), now: { base })
        guard case .accepted = try await sender.send(.init(roomID: roomID, actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "resource fixture", media: [.init(mediaID: mediaID)]))
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
    }

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

// Shared schema, projection, and acceptance assertions for all room-write shards.
extension PostgresV2RoomWriteStoreIntegrationTests {
    internal func installSchema(on sql: any SQLDatabase, schema: String = "im_v2") async throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repositoryRoot.appending(path: "IMV2/sql/schema.sql")
        let source = try String(contentsOf: schemaURL, encoding: .utf8)
            .replacingOccurrences(of: "im_v2", with: schema)
        for statement in postgresStatements(in: source) {
            guard !statement.isEmpty, statement != "BEGIN", statement != "COMMIT" else { continue }
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
        try await configureDefaultUserShardRoute(
            .init(bucket: "test-users", observedRouterEpoch: 9),
            now: Date(timeIntervalSince1970: 0),
            on: sql,
            schema: schema
        )
    }

    internal func configureDefaultUserShardRoute(
        _ route: V2UserShardRoute,
        now: Date,
        on sql: any SQLDatabase,
        schema: String = "im_v2"
    ) async throws {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).user_shard_router_configuration
                (configuration_key, router_epoch, default_write_bucket,
                 updated_at)
            VALUES
                (TRUE, \(bind: route.observedRouterEpoch), \(bind: route.bucket),
                 \(bind: now))
            ON CONFLICT (configuration_key) DO UPDATE
            SET router_epoch = EXCLUDED.router_epoch,
                default_write_bucket = EXCLUDED.default_write_bucket,
                updated_at = EXCLUDED.updated_at
            """).run()
    }

    internal func drainV3Projection(database: any Database) async throws {
        let worker = PostgresV2UserProjectionWorker(database: database, batchSize: 1_000)
        while try await worker.runOnce().claimed {
            try Task.checkCancellation()
        }
    }

    internal func currentV3ProjectionItems(
        sql: any SQLDatabase,
        userID: UserID,
        kind: String
    ) async throws -> [CurrentV3ProjectionAssertionRow] {
        guard let userUUID = UUID(uuidString: userID.rawValue) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try await sql.raw("""
            SELECT version.entity_key,
                   version.payload::text AS payload_json
            FROM im_v2.user_projection_versions AS version
            WHERE version.user_id = \(bind: userUUID)
              AND version.projection_kind = \(bind: kind)
              AND version.valid_to_sequence IS NULL
            ORDER BY version.entity_key
            """).all(decoding: CurrentV3ProjectionAssertionRow.self)
    }


    internal func scopedCount(_ schema: String, _ table: String, user: UUID, on sql: any SQLDatabase) async throws -> Int {
        let column = "user_id"
        let count = try await sql.raw("SELECT COUNT(*)::bigint AS value FROM \(unsafeRaw: schema).\(unsafeRaw: table) WHERE \(unsafeRaw: column) = \(bind: user)")
            .first(decoding: CountRow.self)?.value ?? 0
        guard let value = Int(exactly: count) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return value
    }

    internal func assertAllAcceptedMessagesHaveCompletions(sql: any SQLDatabase) async throws {
        let result = try #require(try await sql.raw("""
            SELECT NOT EXISTS (
                SELECT 1 FROM im_v2.messages AS message
                LEFT JOIN im_v2.message_send_completions AS completion
                  ON completion.room_id = message.room_id
                 AND completion.sender_user_id = message.sender_user_id
                 AND completion.client_message_id = message.client_message_id
                 AND completion.message_id = message.message_id
                 AND completion.room_sequence = message.room_sequence
                 AND completion.timeline_sequence = message.timeline_sequence
                 AND completion.created_at = message.created_at
                WHERE completion.message_id IS NULL
            ) AND NOT EXISTS (
                SELECT 1 FROM im_v2.message_send_completions AS completion
                LEFT JOIN im_v2.messages AS message ON message.message_id = completion.message_id
                WHERE message.message_id IS NULL
            ) AS exists
            """).first(decoding: ExistsRow.self))
        #expect(result.exists)
    }

    internal func assertSendCompletion(
        command: V2SendMessageCommand, accepted: V2AcceptedMessage, eventID: EventID,
        sql: any SQLDatabase
    ) async throws {
        let result = try #require(try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM im_v2.message_send_completions AS completion
                WHERE room_id = \(bind: command.roomID.uuidValue!)
                  AND sender_user_id = \(bind: command.senderUserID.uuidValue!)
                  AND client_message_id = \(bind: command.clientMessageID.uuidValue!)
                  AND fingerprint_version = \(bind: Int16(command.fingerprint.version))
                  AND request_fingerprint = \(bind: command.fingerprint.digest)
                  AND message_id = \(bind: accepted.messageID.uuidValue!)
                  AND event_id = \(bind: eventID.uuidValue!)
                  AND room_sequence = \(bind: Int64(accepted.roomSequence))
                  AND timeline_sequence = \(bind: Int64(accepted.timelineSequence))
                  AND created_at = \(bind: accepted.createdAt)
                  AND group_capacity_class IS NOT DISTINCT FROM \(bind: accepted.groupCapacityClass?.rawValue)
                  AND accepted_membership_revision = \(bind: Int64(accepted.acceptedMembershipRevision ?? 0))
                  AND NOT (to_jsonb(completion) ?| ARRAY['text_body', 'rich_entities', 'media_presentations'])
            ) AS exists
            """).first(decoding: ExistsRow.self))
        #expect(result.exists)
    }

    internal func assertSQLSchemaGate(_ expected: Bool, on sql: any SQLDatabase) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let statement = try String(contentsOf: root.appending(path: "IMV2/scripts/current_v2_schema_contract.sql"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let actual = try await sql.raw("SELECT (\(unsafeRaw: statement)) AS exists").first(decoding: ExistsRow.self)
        #expect(actual?.exists == expected)
    }
}

internal struct CurrentV3ProjectionAssertionRow: Decodable, Sendable {
    let entityKey: String
    let payloadJSON: String

    enum CodingKeys: String, CodingKey {
        case entityKey = "entity_key"
        case payloadJSON = "payload_json"
    }

    func string(_ key: String) -> String? { object()[key] as? String }
    func bool(_ key: String) -> Bool? { object()[key] as? Bool }
    func arrayCount(_ key: String) -> Int? { (object()[key] as? [Any])?.count }
    func arrayString(_ key: String, index: Int, key nestedKey: String) -> String? {
        guard let values = object()[key] as? [[String: Any]], values.indices.contains(index) else { return nil }
        return values[index][nestedKey] as? String
    }

    func object() -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any] else {
            return [:]
        }
        return value
    }
}
