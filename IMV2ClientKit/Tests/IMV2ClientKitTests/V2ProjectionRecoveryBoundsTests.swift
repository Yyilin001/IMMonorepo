import Foundation
import GRDB
@testable import IMV2ClientKit
import Testing

struct V2ProjectionRecoveryBoundsTests {
    @Test(arguments: ["room_sequence", "timeline_sequence", "message_revision", "control_sequence"],
          [Int64.min, -1, 1, Int64.max])
    func storedIntegers(field: String, value: Int64) throws {
        var columns: [String: (any DatabaseValueConvertible)?] = [
            "source_event_id": UUID().uuidString, "message_id": UUID().uuidString,
            "room_id": UUID().uuidString, "sender_user_id": UUID().uuidString, "actor_user_id": UUID().uuidString,
            "text_body": "text", "room_sequence": 1, "timeline_sequence": 1, "message_revision": 1,
            "media_ids": "[]", "media_presentations": "[]", "mention_targets": "[]", "entities": "[]",
            "reply_to_message_id": nil, "forwarded_from_message_id": nil, "forwarded_from_user_id": nil,
            "server_created_at": 1.0, "is_withdrawn": 0, "is_frozen": false
        ]
        columns[field == "control_sequence" ? "room_sequence" : field] = value
        let row = Row(columns)
        func decodedValue() throws -> UInt64 {
            if field == "control_sequence" { return try GRDBV2LocalSyncStore.decodeRoomControlProjection(row).roomSequence }
            let item = try GRDBV2LocalSyncStore.decodeMessageProjection(row)
            switch field {
            case "room_sequence": return item.roomSequence
            case "timeline_sequence": return item.timelineSequence
            default: return item.messageRevision
            }
        }
        if value < 0 {
            #expect(throws: V2ClientProjectionError.invalidMessagePayload) { _ = try decodedValue() }
        } else {
            #expect(try decodedValue() == UInt64(value))
        }
    }
}
