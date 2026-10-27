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

        #expect(try migrationIdentifiers(in: primary) == ["createCurrentV2Schema"])
        #expect(try migrationIdentifiers(in: search) == ["createCurrentV2MessageSearchSchema"])
        let primaryObjectCount = try schemaObjectCount(in: primary)
        #expect(primaryObjectCount == 278)
        #expect(try schemaObjectExists(named: "v2_room_unread_directory", in: primary) == false)
        #expect(try schemaObjectExists(named: "v2_room_unread_rotation", in: primary) == false)
        #expect(try schemaObjectExists(named: "v2_hybrid_group_background_state", in: primary) == false)
        #expect(try schemaObjectExists(named: "v2_pending_forward_messages", in: primary) == false)
        // The current schema adds the common work/dependency journal and the
        // durable domain intents, message payloads and native background mappings.
        for table in ["v2_operation_work", "v2_member_administration_intents", "v2_member_administration_ready", "v2_member_administration_order", "v2_operation_dependencies", "v2_profile_intents", "v2_own_profile_snapshot", "v2_personal_preference_intents", "v2_personal_preference_confirmed", "v2_name_operations", "v2_name_confirmed", "v2_contact_alias_invalidations", "v2_message_send_operations", "v2_message_mutation_operations", "v2_message_reaction_intents", "v2_forward_plan_operations", "v2_resource_import_active_admission", "v2_resource_transfer_active_admission", "v2_background_transfer_session", "v2_background_transfer_tasks"] {
            #expect(try schemaObjectExists(named: table, in: primary))
        }
        #expect(try schemaObjectExists(named: "v2_pending_conversation_states", in: primary) == false)
        #expect(try schemaObjectExists(named: "v2_pending_message_favorites", in: primary) == false)
        for table in ["v2_pending_member_mutes", "v2_pending_moderated_member_removals", "v2_forward_message_plans", "v2_forward_message_chunks", "v2_pending_message_commands", "v2_pending_message_edits", "v2_pending_message_withdrawals", "v2_pending_read_receipts", "v2_pending_message_reactions"] {
            #expect(try schemaObjectExists(named: table, in: primary) == false)
        }
        let primaryFingerprint = try schemaFingerprint(in: primary)
        // Canonical resource catalog, file ownership, transfer demands and local
        // direct messages, including avatar import edges and the room directory index, share one baseline.
        #expect(primaryFingerprint == 0x9ccf1b1e332de3d0)
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

        #expect(rejects(database, sql: "INSERT INTO v2_member_effects VALUES ('source', 'room', 'user', 0, 'remove', NULL, 1, 1, zeroblob(32))"))
        #expect(rejects(database, sql: "INSERT INTO v2_member_effects VALUES ('source', 'room', 'user', 1, 'role', NULL, 1, 1, zeroblob(32))"))
        #expect(rejects(database, sql: "INSERT INTO v2_member_effects VALUES ('source', 'room', 'user', 1, 'remove', 'admin', 1, 1, zeroblob(32))"))
        #expect(rejects(database, sql: "INSERT INTO v2_member_effects VALUES ('source', 'room', 'user', 1, 'role', 'owner', 1, 1, zeroblob(32))"))
        #expect(rejects(database, sql: "INSERT INTO v2_member_effects VALUES ('source', 'room', 'user', 1, 'add', NULL, 0, 1, zeroblob(32))"))
        #expect(rejects(database, sql: "INSERT INTO v2_member_effects VALUES ('source', 'room', 'user', 1, 'add', NULL, 1, 1, zeroblob(31))"))
        #expect(rejects(database, sql: "INSERT INTO v2_room_membership_states VALUES ('room', 0, 'event', 1)"))
        #expect(rejects(database, sql: "INSERT INTO v2_room_membership_states VALUES ('room', 1, 'event', 2)"))
        #expect(rejects(database, sql: """
            INSERT INTO v2_direct_room_identities
                (room_id, target_user_id, public_handle, display_name, account_kind, updated_at, room_created_at)
            VALUES ('room-identity', 'user-identity', 'identity_user', 'Identity', 'invalid', 1, 1)
            """))
        #expect(rejects(database, sql: """
            INSERT INTO v2_direct_room_profile_projections
                (room_id, source_event_id, target_user_id, public_handle, display_name, account_kind, revision, updated_at, room_created_at)
            VALUES ('room-profile', 'event-profile', 'user-profile', 'profile_user', 'Profile', 'invalid', 1, 1, 1)
            """))
        #expect(rejects(database, sql: """
            INSERT INTO v2_profile_views
                (user_id, public_handle, display_name, account_kind, state, revision, visibility_revision, updated_at)
            VALUES ('user-view', 'view_user', 'View', 'invalid', 'active', 1, 1, 1)
            """))
        #expect(rejects(database, sql: """
            INSERT INTO v2_room_profile_projections
                (room_id, source_event_id, title, owner_user_id, membership_revision, capacity_class, created_at)
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
