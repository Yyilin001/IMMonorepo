import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 个人事件仅是发现提示；建立在线覆盖前，始终向当前房间所有者
/// 重新读取明确的授权结果。
struct V2AccountRoomMembershipChange: Sendable {
    let roomID: RoomID
    let removedThrough: UInt64?

    static func decode(_ item: V2SnapshotProjectionItem, userID: UserID) throws -> Self? {
        guard ["room", "membership", "direct_room_profile"].contains(item.key.projectionKind) else { return nil }
        var record = IMV2SyncRecord()
        record.projectionKind = item.key.projectionKind
        record.payload = item.payload
        // 快照将成员关系变更折叠到当前房间行中。
        if record.projectionKind == "room" {
            struct Event: Decodable {
                let eventType: String
                enum CodingKeys: String, CodingKey { case eventType = "event_type" }
            }
            if try JSONDecoder().decode(Event.self, from: item.payload).eventType == "membership_changed" {
                record.projectionKind = "membership"
            }
        }
        return try decode(record, userID: userID)
    }

    static func decode(_ record: IMV2SyncRecord, userID: UserID) throws -> Self? {
        guard ["room", "membership", "direct_room_profile"].contains(record.projectionKind) else { return nil }
        struct Wire: Decodable {
            let roomID: String
            let eventType: String?
            let targetUserID: String?
            let action: String?
            let membershipRevision: UInt64?
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id", eventType = "event_type", targetUserID = "target_user_id"
                case action, membershipRevision = "membership_revision"
            }
        }
        let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
        let room = try RoomID(wire.roomID)
        guard room.uuidValue != nil else { throw V2RoomRecoveryReadError.corruptPersistence }
        switch record.projectionKind {
        case "membership":
            guard wire.eventType == "membership_changed", let target = wire.targetUserID,
                  try UserID(target) == userID,
                  let action = wire.action.flatMap(V2RoomMembershipAction.init(rawValue:)),
                  let revision = wire.membershipRevision, revision > 0, revision <= UInt64(Int64.max)
            else { throw V2RoomRecoveryReadError.corruptPersistence }
            return .init(roomID: room, removedThrough: action == .remove ? revision : nil)
        case "room":
            guard wire.eventType == "room.created" else { throw V2RoomRecoveryReadError.corruptPersistence }
            return .init(roomID: room, removedThrough: nil)
        default:
            return .init(roomID: room, removedThrough: nil)
        }
    }
}
