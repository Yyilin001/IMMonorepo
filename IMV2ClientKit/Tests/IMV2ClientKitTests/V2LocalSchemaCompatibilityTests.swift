import Foundation
import GRDB
@testable import IMV2ClientKit
import Testing

@Suite("V2 local schema compatibility")
struct V2LocalSchemaCompatibilityTests {
    @Test("special account-kind migration preserves enum constraints")
    func rejectsInvalidSpecialAccountKinds() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-account-kind-schema-\(UUID().uuidString).sqlite")
        _ = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000997")!)
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
    }

    private func rejects(_ database: DatabasePool, sql: String) -> Bool {
        do {
            try database.write { db in
                try db.execute(sql: sql)
            }
            return false
        } catch {
            return true
        }
    }
}
