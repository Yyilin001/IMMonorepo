import Foundation
import GRDB
@testable import IMV2ClientKit
import Testing

struct V2PendingCommandRecoveryBoundsTests {
    @Test(arguments: [
        "edit.expected_message_revision", "edit.resulting_message_revision", "edit.resulting_room_sequence", "edit.terminal_current_revision",
        "withdrawal.expected_message_revision", "withdrawal.resulting_message_revision", "withdrawal.resulting_room_sequence", "withdrawal.terminal_current_revision",
        "membership.expected_membership_revision", "membership.resulting_membership_revision", "membership.resulting_room_sequence", "membership.terminal_current_revision",
        "receipt.read_through_room_sequence", "receipt.resulting_room_sequence"
    ], [Int64.min, -1, 0, 1, Int64.max])
    func storedIntegers(scenario: String, value: Int64) throws {
        let parts = scenario.split(separator: ".").map(String.init)
        let kind = parts[0], field = parts[1]
        var columns: [String: (any DatabaseValueConvertible)?] = [
            "room_id": UUID().uuidString, "operation_id": UUID().uuidString,
            "message_id": UUID().uuidString, "target_user_id": UUID().uuidString,
            "action": "add", "state": "pending", "attempt_count": 0, "next_attempt_at": 1.0,
            "text_body": "text", "expected_message_revision": 1, "expected_membership_revision": 1,
            "read_through_room_sequence": 1, "resulting_message_revision": nil,
            "resulting_membership_revision": nil, "resulting_room_sequence": nil,
            "terminal_code": nil, "terminal_current_revision": nil
        ]
        if field.hasPrefix("resulting") {
            columns["state"] = "acknowledged"
            columns["resulting_room_sequence"] = 1
            if kind == "membership" { columns["resulting_membership_revision"] = 1 }
            if kind == "edit" || kind == "withdrawal" { columns["resulting_message_revision"] = 1 }
        } else if field.hasPrefix("terminal") {
            columns["state"] = "rejected"
            columns["terminal_code"] = "revision_conflict"
        }
        columns[field] = value
        let row = Row(columns)
        func decodedValue() throws -> UInt64? {
            switch kind {
            case "edit":
                let item = try GRDBV2LocalSyncStore.decodePendingMessageEdit(row)
                return ["expected_message_revision": item.expectedMessageRevision, "resulting_message_revision": item.resultingMessageRevision,
                        "resulting_room_sequence": item.resultingRoomSequence, "terminal_current_revision": item.terminalCurrentRevision][field] ?? nil
            case "withdrawal":
                let item = try GRDBV2LocalSyncStore.decodePendingMessageWithdrawal(row)
                return ["expected_message_revision": item.expectedMessageRevision, "resulting_message_revision": item.resultingMessageRevision,
                        "resulting_room_sequence": item.resultingRoomSequence, "terminal_current_revision": item.terminalCurrentRevision][field] ?? nil
            case "membership":
                let item = try GRDBV2LocalSyncStore.decodePendingMembershipCommand(row)
                return ["expected_membership_revision": item.expectedMembershipRevision, "resulting_membership_revision": item.resultingMembershipRevision,
                        "resulting_room_sequence": item.resultingRoomSequence, "terminal_current_revision": item.terminalCurrentRevision][field] ?? nil
            default:
                let item = try GRDBV2LocalSyncStore.decodePendingReadReceipt(row)
                return field == "read_through_room_sequence" ? item.readThroughRoomSequence : item.resultingRoomSequence
            }
        }
        if value < 0 {
            #expect(throws: V2ClientCommandError.commandConflict) { _ = try decodedValue() }
        } else {
            #expect(try decodedValue() == UInt64(value))
        }
    }
}
