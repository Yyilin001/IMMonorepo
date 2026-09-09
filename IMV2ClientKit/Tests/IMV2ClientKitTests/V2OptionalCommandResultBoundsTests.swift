import Foundation
import GRDB
@testable import IMV2ClientKit
import Testing

struct V2OptionalCommandResultBoundsTests {
    @Test(arguments: ["send", "redactionRevision", "redactionSequence", "mute", "removalRevision", "removalSequence", "reaction"],
          [nil, Int64.min, -1, 0, 1, Int64.max] as [Int64?])
    func persistedResults(kind: String, value: Int64?) throws {
        let field: String
        switch kind {
        case "send": field = "accepted_room_sequence"
        case "redactionRevision": field = "resulting_message_revision"
        case "removalRevision": field = "resulting_membership_revision"
        default: field = "resulting_room_sequence"
        }
        var columns: [String: (any DatabaseValueConvertible)?] = [
            "room_id": UUID().uuidString, "operation_id": UUID().uuidString, "message_id": UUID().uuidString,
            "target_user_id": UUID().uuidString, "client_message_id": UUID().uuidString,
            "accepted_message_id": value == nil ? nil : UUID().uuidString,
            "state": value == nil ? "pending" : (kind == "send" ? "accepted" : "acknowledged"),
            "action": "add", "reaction": "👍", "reason_code": "test_reason", "mute_until": 100.0,
            "attempt_count": 0, "next_attempt_at": 1.0, "text": "text",
            "media_ids": "[]", "mention_targets": "[]", "entities": "[]", "reply_to_message_id": nil,
            "terminal_code": nil, "accepted_room_sequence": nil, "resulting_room_sequence": nil,
            "resulting_message_revision": nil, "resulting_membership_revision": nil
        ]
        if value != nil {
            columns["resulting_room_sequence"] = 1
            columns["resulting_message_revision"] = 2
            columns["resulting_membership_revision"] = 2
        }
        columns.updateValue(value, forKey: field)
        let row = Row(columns)
        func decodedValue() throws -> UInt64? {
            switch kind {
            case "send": return try GRDBV2LocalSyncStore.decodePendingCommand(row).acceptedRoomSequence
            case "redactionRevision": return try GRDBV2LocalSyncStore.decodePendingMessageRedaction(row).resultingMessageRevision
            case "redactionSequence": return try GRDBV2LocalSyncStore.decodePendingMessageRedaction(row).resultingRoomSequence
            case "mute": return try GRDBV2LocalSyncStore.decodePendingMemberMute(row).resultingRoomSequence
            case "removalRevision": return try GRDBV2LocalSyncStore.decodePendingModeratedMemberRemoval(row).resultingMembershipRevision
            case "removalSequence": return try GRDBV2LocalSyncStore.decodePendingModeratedMemberRemoval(row).resultingRoomSequence
            default: return try GRDBV2LocalSyncStore.decodePendingMessageReaction(row).resultingRoomSequence
            }
        }
        if let value, value < 0 {
            #expect(throws: V2ClientCommandError.commandConflict) { _ = try decodedValue() }
        } else {
            #expect(try decodedValue() == value.map(UInt64.init))
        }
    }
}
