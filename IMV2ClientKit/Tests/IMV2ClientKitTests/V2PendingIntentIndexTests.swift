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
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND (name LIKE 'v2_pending%intent_idx' OR name LIKE 'v2_pending%intent_with_delivery_mode_idx')"
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
            "v2_pending_group_room_creations_intent_with_delivery_mode_idx"
        ])
    }

    @Test("the local-store migration indexes terminal command expiry")
    func createsTerminalRetentionIndexes() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-terminal-retention-indexes-\(UUID().uuidString).sqlite")
        _ = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: .init(value: UUID(uuidString: "00000000-0000-0000-0000-000000000996")!)
        )
        let database = try DatabasePool(path: url.path)
        let actual = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'v2_pending%terminal_retention_idx'"
            )
        }
        #expect(Set(actual) == [
            "v2_pending_message_commands_terminal_retention_idx",
            "v2_pending_membership_commands_terminal_retention_idx",
            "v2_pending_message_withdrawals_terminal_retention_idx",
            "v2_pending_message_redactions_terminal_retention_idx",
            "v2_pending_member_mutes_terminal_retention_idx",
            "v2_pending_moderated_member_removals_terminal_retention_idx",
            "v2_pending_message_edits_terminal_retention_idx",
            "v2_pending_read_receipts_terminal_retention_idx",
            "v2_pending_message_reactions_terminal_retention_idx",
            "v2_pending_social_commands_terminal_retention_idx",
            "v2_pending_group_room_creations_terminal_retention_idx"
        ])
    }
}
