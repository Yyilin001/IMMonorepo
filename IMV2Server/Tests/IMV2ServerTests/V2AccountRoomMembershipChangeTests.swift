import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Personal membership coverage decoding")
struct V2AccountRoomMembershipChangeTests {
    @Test(arguments: ["add", "remove"])
    func membership(action: String) throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let input = try record(user: user, room: room, action: action)
        let decoded = try V2AccountRoomMembershipChange.decode(input, userID: user)
        let value = try #require(decoded)
        #expect(value.roomID == room)
        #expect(value.removedThrough == (action == "remove" ? 2 : nil))
    }

    @Test(arguments: ["target", "action", "revision", "event"])
    func invalidMembership(field: String) throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        var value = try record(user: user, room: room, action: "remove")
        var payload = try #require(JSONSerialization.jsonObject(with: value.payload) as? [String: Any])
        switch field {
        case "target": payload["target_user_id"] = UUID().uuidString
        case "action": payload["action"] = "unknown"
        case "revision": payload["membership_revision"] = 0
        default: payload["event_type"] = "unexpected"
        }
        value.payload = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
            try V2AccountRoomMembershipChange.decode(value, userID: user)
        }
    }

    @Test("snapshot room rows retain removal semantics", arguments: ["add", "remove"])
    func snapshotMembership(action: String) throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let record = try record(user: user, room: room, action: action)
        let item = try V2SnapshotProjectionItem(key: .init(projectionKind: "room", entityKey: room.rawValue),
            sourceEventID: .init(uuid: UUID()), sequence: 1, payload: record.payload)
        let decoded = try V2AccountRoomMembershipChange.decode(item, userID: user)
        let value = try #require(decoded)
        #expect(value.roomID == room)
        #expect(value.removedThrough == (action == "remove" ? 2 : nil))
    }

    @Test func unrelatedPersonalEventsDoNotRequireRoomPayloads() throws {
        var record = IMV2SyncRecord()
        record.projectionKind = "preferences"
        record.payload = Data("{}".utf8)
        #expect(try V2AccountRoomMembershipChange.decode(record, userID: .init(uuid: UUID())) == nil)
    }

    private func record(user: UserID, room: RoomID, action: String) throws -> IMV2SyncRecord {
        var value = IMV2SyncRecord()
        value.projectionKind = "membership"
        value.payload = try JSONSerialization.data(withJSONObject: [
            "event_type": "membership_changed", "room_id": room.rawValue,
            "target_user_id": user.rawValue, "action": action, "membership_revision": 2
        ])
        return value
    }
}
