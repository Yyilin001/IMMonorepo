import Foundation
import GRDB
@testable import IMV2ClientKit
import Testing

@Suite("V2 local schema contract")
struct V2LocalSchemaContractTests {
    @Test("a fresh store installs only the canonical primary and search schemas")
    func freshSchemaMatchesCurrentContract() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-current-schema-\(UUID().uuidString).sqlite")
        _ = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000997")!)
        )
        let primary = try DatabasePool(path: url.path)
        let search = try DatabasePool(path: url.deletingPathExtension().appendingPathExtension("search.sqlite").path)

        #expect(try migrationIdentifiers(in: primary) == ["addForwardChunkCompletionDigest", "bindForwardSourceReferences", "createCurrentV2Schema", "orderAnnouncementEffects", "orderPinnedMessageEffects", "orderReactionEffects", "orderRolePolicyEffects", "recordPushIntent", "recordRolePolicyRecovery", "recordSharedMessageEffects", "recordSnapshotRebuildIntent", "scheduleRolePolicyRecovery", "useUUIDForwardChunkIdentities"])
        #expect(try migrationIdentifiers(in: search) == ["createCurrentV2MessageSearchSchema"])
        #expect(try schemaObjectCount(in: primary) == 173)
        #expect(try schemaFingerprint(in: primary) == 0xd39d3ac5c9ce1b60)
        #expect(try schemaObjectCount(in: search) == 5)
        #expect(try schemaFingerprint(in: search) == 0x39f4_35c6_3f7a_01b5)

        #expect(try schemaObjectExists(named: "v2_message_char_fts", in: primary) == false)
        #expect(try schemaObjectExists(named: "v2_message_char_fts", in: search))
    }

    @Test("current identity and room-profile columns enforce their complete domains")
    func currentDomainConstraintsRejectMalformedRows() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-current-constraints-\(UUID().uuidString).sqlite")
        _ = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000998")!)
        )
        let database = try DatabasePool(path: url.path)

        #expect(rejects(database, sql: """
            INSERT INTO v2_direct_room_identities
                (room_id, target_user_id, public_handle, display_name, account_kind, updated_at)
            VALUES ('room-identity', 'user-identity', 'identity_user', 'Identity', 'invalid', 1)
            """))
        #expect(rejects(database, sql: """
            INSERT INTO v2_direct_room_profile_projections
                (room_id, source_event_id, target_user_id, public_handle, display_name, account_kind, revision, updated_at)
            VALUES ('room-profile', 'event-profile', 'user-profile', 'profile_user', 'Profile', 'invalid', 1, 1)
            """))
        #expect(rejects(database, sql: """
            INSERT INTO v2_profile_views
                (user_id, public_handle, display_name, account_kind, state, revision, visibility_revision, updated_at)
            VALUES ('user-view', 'view_user', 'View', 'invalid', 'active', 1, 1, 1)
            """))
        #expect(rejects(database, sql: """
            INSERT INTO v2_room_profile_projections
                (room_id, source_event_id, title, owner_user_id, membership_revision, delivery_mode, created_at)
            VALUES ('room-profile', 'event-room', 'Room', 'owner', 1, NULL, 1)
            """))
    }

    private func migrationIdentifiers(in database: DatabasePool) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    private func schemaObjectCount(in database: DatabasePool) throws -> Int {
        try schemaRows(in: database).count
    }

    private func schemaObjectExists(named name: String, in database: DatabasePool) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = ?)",
                arguments: [name]
            ) ?? false
        }
    }

    private func schemaFingerprint(in database: DatabasePool) throws -> UInt64 {
        let value = try schemaRows(in: database)
            .map { "\($0.type)\0\($0.name)\0\($0.sql)" }
            .joined(separator: "\0")
        return value.utf8.reduce(0xcbf2_9ce4_8422_2325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    private func schemaRows(in database: DatabasePool) throws -> [(type: String, name: String, sql: String)] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT type, name, sql
                FROM sqlite_master
                WHERE sql IS NOT NULL
                  AND name <> 'grdb_migrations'
                  AND NOT (
                    type = 'table'
                    AND (
                      (name <> 'v2_contact_profile_search' AND name GLOB 'v2_contact_profile_search_*')
                      OR (name <> 'v2_message_char_fts' AND name GLOB 'v2_message_char_fts_*')
                    )
                  )
                ORDER BY type, name
                """).map { row in
                    (type: row["type"], name: row["name"], sql: row["sql"])
                }
        }
    }

    private func rejects(_ database: DatabasePool, sql: String) -> Bool {
        do {
            try database.write { db in try db.execute(sql: sql) }
            return false
        } catch {
            return true
        }
    }
}
