import Foundation
@testable import IMV2Server
import Testing

@Suite("Pinned message snapshot boundaries")
struct V2PinnedMessageSnapshotEffectTests {
    private let room = "ABCDEF00-0000-0000-0000-000000000001"
    private let message = "ABCDEF00-0000-0000-0000-000000000002"

    private func payload(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["event_type": "message.pinned_changed", "room_id": room,
            "message_id": message, "is_pinned": false, "room_sequence": 8,
            "server_created_at_ms": 1_000]
        for (key, value) in changes { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("source room sequence orders pin and unpin regardless of wall time")
    func sourceOrder() throws {
        let old = try V2PinnedMessageSnapshotEffect(payload: payload(["room_sequence": 7, "is_pinned": true, "server_created_at_ms": 9_000]))
        let current = try V2PinnedMessageSnapshotEffect(payload: payload())
        let source = UUID(), oldSource = UUID()
        #expect(try current.shouldReplace(old, sourceEventID: source, priorSourceEventID: oldSource))
        #expect(try !old.shouldReplace(current, sourceEventID: oldSource, priorSourceEventID: source))
        #expect(try !current.shouldReplace(current, sourceEventID: source, priorSourceEventID: source))
        #expect(throws: V2UserProjectionWorkerError.invalidPayload) {
            try current.shouldReplace(current, sourceEventID: UUID(), priorSourceEventID: source)
        }
        #expect(throws: V2UserProjectionWorkerError.invalidPayload) {
            try old.shouldReplace(current, sourceEventID: source, priorSourceEventID: source)
        }
    }

    @Test("legacy observations retain unknown source order and cannot overwrite a known fence")
    func legacyCompatibility() throws {
        let legacy = try V2PinnedMessageSnapshotEffect(payload: payload(["room_sequence": NSNull(), "room_id": room.lowercased()]))
        let current = try V2PinnedMessageSnapshotEffect(payload: payload())
        let source = UUID()
        #expect(legacy.roomSequence == nil && legacy.entityKey == current.entityKey)
        #expect(try current.shouldReplace(legacy, sourceEventID: source, priorSourceEventID: source))
        #expect(try !legacy.shouldReplace(current, sourceEventID: source, priorSourceEventID: source))
        #expect(try !legacy.shouldReplace(current, sourceEventID: UUID(), priorSourceEventID: source))
        #expect(try legacy.shouldReplace(legacy, sourceEventID: UUID(), priorSourceEventID: source))
    }

    @Test("invalid pin payloads cannot enter snapshot state", arguments: ["room", "message", "actor", "kind", "boolean", "zero", "negative", "overflow", "boolean_sequence", "time"])
    func invalidPayload(scenario: String) throws {
        let changes: [String: Any]
        switch scenario {
        case "room": changes = ["room_id": "invalid"]
        case "message": changes = ["message_id": "invalid"]
        case "actor": changes = ["actor_user_id": "invalid"]
        case "kind": changes = ["event_type": "other"]
        case "boolean": changes = ["is_pinned": "false"]
        case "zero": changes = ["room_sequence": 0]
        case "negative": changes = ["room_sequence": -1]
        case "overflow": changes = ["room_sequence": UInt64.max]
        case "boolean_sequence": changes = ["room_sequence": true]
        default: changes = ["server_created_at_ms": -1]
        }
        #expect(throws: V2UserProjectionWorkerError.invalidPayload) {
            try V2PinnedMessageSnapshotEffect(payload: payload(changes))
        }
    }
}
