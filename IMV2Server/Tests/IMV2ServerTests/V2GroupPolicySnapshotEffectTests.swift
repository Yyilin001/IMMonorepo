import Foundation
@testable import IMV2Server
import Testing

@Suite("Group policy snapshot fact boundaries")
struct V2GroupPolicySnapshotEffectTests {
    private let room = "ABCDEF00-0000-0000-0000-000000000001"
    private func payload(_ overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["event_type": "group.role_permissions_changed", "room_id": room,
            "revision": 2, "role": "member", "permissions": ["send_messages", "invite_members"]]
        for (key, replacement) in overrides { value[key] = replacement }
        return try JSONSerialization.data(withJSONObject: value)
    }

    @Test("legacy metadata and permission set order do not change the domain fact")
    func legacyFact() throws {
        let old = try V2GroupPolicySnapshotEffect(payload: payload())
        let current = try V2GroupPolicySnapshotEffect(payload: payload(["permissions": ["invite_members", "send_messages"], "room_id": room.lowercased(), "room_sequence": 9]))
        #expect(old.representsSameFact(as: current))
        #expect(old.entityKey == current.entityKey)
        let different = try V2GroupPolicySnapshotEffect(payload: payload(["permissions": []]))
        #expect(!old.representsSameFact(as: different))
        let conflictingSequence = try V2GroupPolicySnapshotEffect(payload: payload(["room_sequence": 10]))
        #expect(!current.representsSameFact(as: conflictingSequence))
    }

    @Test("malformed policy cannot become a default or an empty grant", arguments: ["duplicate", "unknown", "owner", "zero", "overflow", "negative_source", "boolean_revision"])
    func invalidPolicy(scenario: String) throws {
        let changes: [String: Any]
        switch scenario {
        case "duplicate": changes = ["permissions": ["send_messages", "send_messages"]]
        case "unknown": changes = ["permissions": ["unknown_permission"]]
        case "owner": changes = ["role": "owner"]
        case "zero": changes = ["revision": 0]
        case "overflow": changes = ["revision": UInt64.max]
        case "negative_source": changes = ["room_sequence": -1]
        default: changes = ["revision": true]
        }
        #expect(throws: V2UserProjectionWorkerError.invalidPayload) { try V2GroupPolicySnapshotEffect(payload: payload(changes)) }
    }

    @Test("empty announcement replacement retains a version but oversized content is invalid")
    func announcementBoundary() throws {
        let empty = try V2GroupPolicySnapshotEffect(payload: payload(["event_type": "group.announcement_changed", "body": "", "server_created_at_ms": 1]))
        #expect(empty.value == .announcement(body: "", updatedAtMilliseconds: 1))
        #expect(throws: V2UserProjectionWorkerError.invalidPayload) {
            try V2GroupPolicySnapshotEffect(payload: payload(["event_type": "group.announcement_changed", "body": String(repeating: "a", count: 4_097), "server_created_at_ms": 1]))
        }
    }
}

extension V2GroupPolicySnapshotEffectTests {
    @Test("member roles use membership revision and normalized target identity")
    func memberRoleFact() throws {
        let target = "ABCDEF00-0000-0000-0000-000000000002"
        let role = try V2GroupPolicySnapshotEffect(payload: payload(["event_type": "group.member_role_changed", "target_user_id": target, "role": "admin", "membership_revision": 4, "revision": 999]))
        let legacy = try V2GroupPolicySnapshotEffect(payload: payload(["event_type": "group.member_role_changed", "room_id": room.lowercased(), "target_user_id": target.lowercased(), "role": "admin", "membership_revision": 4, "room_sequence": 20]))
        #expect(role.revision == 4)
        #expect(role.entityKey == "member-role:\(room):\(target)")
        #expect(role.representsSameFact(as: legacy))
        let changed = try V2GroupPolicySnapshotEffect(payload: payload(["event_type": "group.member_role_changed", "target_user_id": target, "role": "member", "membership_revision": 4]))
        #expect(!role.representsSameFact(as: changed))
    }

    @Test("invalid member role facts cannot enter snapshot state", arguments: ["target", "missing_target", "owner", "role", "zero", "negative", "overflow", "boolean", "missing_revision", "source", "time"])
    func invalidMemberRole(scenario: String) throws {
        var changes: [String: Any] = ["event_type": "group.member_role_changed", "target_user_id": "ABCDEF00-0000-0000-0000-000000000002", "role": "admin", "membership_revision": 4]
        switch scenario {
        case "target": changes["target_user_id"] = "invalid"
        case "missing_target": changes["target_user_id"] = NSNull()
        case "owner": changes["role"] = "owner"
        case "role": changes["role"] = "invalid"
        case "zero": changes["membership_revision"] = 0
        case "negative": changes["membership_revision"] = -1
        case "overflow": changes["membership_revision"] = UInt64.max
        case "boolean": changes["membership_revision"] = true
        case "missing_revision": changes["membership_revision"] = NSNull()
        case "source": changes["room_sequence"] = 0
        default: changes["server_created_at_ms"] = -1
        }
        #expect(throws: V2UserProjectionWorkerError.invalidPayload) { try V2GroupPolicySnapshotEffect(payload: payload(changes)) }
    }
}
