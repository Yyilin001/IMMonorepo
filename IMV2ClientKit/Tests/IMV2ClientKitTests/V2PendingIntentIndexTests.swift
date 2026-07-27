import Foundation
import GRDB
@testable import IMV2ClientKit
import Testing

@Suite("V2 pending-intent lookup indexes")
struct V2PendingIntentIndexTests {
    @Test("the local-store migration creates every semantic pending-intent index")
    func createsSemanticIntentIndexes() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-pending-intent-indexes-\(UUID().uuidString).sqlite")
        _ = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000990")!)
        )
        let database = try DatabasePool(path: url.path)
        let actual = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'v2_pending%intent_idx'"
            )
        }
        #expect(Set(actual) == [
            "v2_pending_membership_intent_idx",
            "v2_pending_message_withdrawals_intent_idx",
            "v2_pending_message_redactions_intent_idx",
            "v2_pending_member_mutes_intent_idx",
            "v2_pending_moderated_member_removals_intent_idx",
            "v2_pending_message_edits_intent_idx",
            "v2_pending_message_reactions_intent_idx",
            "v2_pending_social_commands_intent_idx",
            "v2_pending_group_room_creations_intent_idx"
        ])
    }
}
