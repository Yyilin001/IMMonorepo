import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Complete edit replacement contract")
struct V2MessageEditReplacementTests {
    @Test("complete state and acceptance identity round trip while malformed envelopes fail", arguments: ["valid", "schema", "origin", "membership", "fractional", "sequence", "text", "media", "nullable", "withdrawn", "null", "room"])
    func validatesReplacement(_ defect: String) throws {
        let message = UUID().uuidString, room = UUID().uuidString
        var state: [String: Any] = ["event_type":"message.accepted", "message_id":message, "room_id":room, "room_sequence":1, "timeline_sequence":1, "sender_user_id":UUID().uuidString, "server_created_at_ms":1_750_000_000_000, "message_revision":3, "text":"current", "media_ids":[String](), "media_presentations":[String](), "mention_user_ids":[String](), "mentions_everyone":false, "entities":[String](), "reply_to_message_id":NSNull(), "forwarded_from_message_id":NSNull(), "forwarded_from_user_id":NSNull()]
        var replacement: [String: Any] = ["schema_version":1, "accepted_event_id":UUID().uuidString, "accepted_membership_revision":0]
        var event: [String: Any] = ["message_id":message, "room_id":room, "room_sequence":3, "message_revision":3, "text":"current", "entities":[String]()]
        switch defect {
        case "schema": replacement["schema_version"] = 2
        case "origin": replacement["accepted_event_id"] = ""
        case "membership": replacement["accepted_membership_revision"] = -1
        case "fractional": event["message_revision"] = 3.5
        case "sequence": event["room_sequence"] = 1
        case "text": state["text"] = "other"
        case "media": state.removeValue(forKey: "media_presentations")
        case "nullable": state.removeValue(forKey: "reply_to_message_id")
        case "withdrawn": state["is_withdrawn"] = true
        case "room": state["room_id"] = UUID().uuidString
        default: break
        }
        replacement["state"] = state
        event["replacement"] = defect == "null" ? NSNull() : replacement
        if defect == "valid" {
            let parsed = try #require(try V2MessageEditReplacement.decodeIfPresent(in: event))
            #expect(parsed.state.messageRevision == 3 && parsed.state.acceptedRoomSequence == 1)
            #expect(try JSONDecoder().decode(V2MessageEditReplacement.self, from: Data(parsed.encodedJSON().utf8)) == parsed)
        } else {
            #expect(throws: V2MessageProjectionStateError.invalidPayload) { _ = try V2MessageEditReplacement.decodeIfPresent(in: event) }
        }
    }
}
