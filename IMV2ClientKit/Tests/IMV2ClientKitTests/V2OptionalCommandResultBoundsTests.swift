import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2OptionalCommandResultBoundsTests {
    @Test("member administration persisted proofs require complete bounded integers",
          arguments: ["muteSequence", "muteRevision", "removalSequence", "removalRevision"],
          [nil, Int64.min, -1, 0, 1, Int64.max] as [Int64?])
    func memberAdministrationProof(kind: String, value: Int64?) throws {
        let removal = kind.hasPrefix("removal")
        let intent = try V2MemberAdministrationIntent(roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()),
            operationID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()),
            action: removal ? .remove : .mute(untilMilliseconds: 2_000), reasonCode: .init("test_reason"),
            expectedMembershipRevision: 0, confirmedUntilMilliseconds: 1_000)
        let outcome: V2MemberAdministrationTerminalOutcome = removal
            ? .applied(.removed(membershipRevision: 1, roomSequence: 1, eventID: .init(uuid: UUID())))
            : .applied(.muted(untilMilliseconds: 2_000, membershipRevision: 0, roomSequence: 1, eventID: .init(uuid: UUID())))
        let receipt = try V2MemberAdministrationReceipt(identity: intent.identity, fingerprint: intent.fingerprint,
            outcome: outcome, resolvedAtMilliseconds: 900)
        let field = kind.hasSuffix("Revision") ? "membershipRevision" : "roomSequence"
        let encoded = try JSONEncoder().encode(receipt)
        func replace(_ object: Any) -> Any {
            guard let dictionary = object as? [String: Any] else { return object }
            var result = dictionary.mapValues(replace)
            if dictionary[field] != nil {
                if let value { result[field] = NSNumber(value: value) }
                else { result[field] = NSNull() }
            }
            return result
        }
        let bytes = try JSONSerialization.data(withJSONObject: replace(JSONSerialization.jsonObject(with: encoded)))
        if let value, value > 0 || (value == 0 && kind == "muteRevision") {
            let decoded = try JSONDecoder().decode(V2MemberAdministrationReceipt.self, from: bytes)
            switch decoded.outcome {
            case .applied(.muted(_, let revision, let sequence, _)), .applied(.removed(let revision, let sequence, _)):
                #expect((kind.hasSuffix("Revision") ? revision : sequence) == UInt64(value))
            default: Issue.record("Expected a complete applied proof")
            }
        } else {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2MemberAdministrationReceipt.self, from: bytes) }
        }
    }

    @Test(arguments: ["send", "reaction"],
          [nil, Int64.min, -1, 0, 1, Int64.max] as [Int64?])
    func persistedResults(kind: String, value: Int64?) throws {
        let field: String
        switch kind {
        case "send": field = "accepted_room_sequence"
        case "redactionRevision": field = "resulting_message_revision"
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
        func decodedValue() throws -> UInt64? {
            switch kind {
            case "send":
                guard let value else { return nil }
                return try V2MessageOperationAcceptance(messageID:.init(uuid:UUID()),roomSequence:UInt64(exactly:value) ?? 0).roomSequence
            default:
                guard let value else { return nil }
                return try V2MessageReactionEventProof(roomSequence:UInt64(exactly:value) ?? 0,eventID:.init(uuid:UUID())).roomSequence
            }
        }
        if let value, value < 0 || (["send","reaction"].contains(kind) && value==0) {
            if ["send","reaction"].contains(kind) { #expect(throws:(any Error).self) { _ = try decodedValue() } }
            else { #expect(throws:V2ClientCommandError.commandConflict) { _ = try decodedValue() } }
        } else {
            #expect(try decodedValue() == value.map(UInt64.init))
        }
    }
}
