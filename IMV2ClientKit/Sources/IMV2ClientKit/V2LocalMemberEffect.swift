import Crypto
import Foundation
import IMV2Core

/// A member's version belongs to its source event, independently of the viewer's membership.
struct V2LocalMemberEffect {
    let source: String
    let room: String
    let user: String
    let revision: Int64
    let action: String
    let role: String?
    let roomSequence: Int64?
    let projectionSequence: Int64
    let digest: Data

    enum OwnershipMember { case previousOwner, newOwner }

    init(record: V2ClientSyncRecord, ownershipMember: OwnershipMember? = nil, expectedRoomID: RoomID? = nil, expectedRoomSequence: UInt64? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let target_user_id: String?
            let previous_owner_user_id: String?; let owner_user_id: String?
            let membership_revision: Int64; let action: String?; let role: String?
            let room_sequence: Int64?; let actor_user_id: String?; let server_created_at_ms: Int64?
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            let memberID: String
            let ownershipRole: String?
            if let ownershipMember {
                guard record.projectionKind == "membership", wire.event_type == "group.ownership_transferred", wire.action == "transfer",
                      let previous = wire.previous_owner_user_id, let owner = wire.owner_user_id,
                      let previousUUID = UUID(uuidString: previous), let ownerUUID = UUID(uuidString: owner), previousUUID != ownerUUID,
                      wire.actor_user_id.flatMap(UUID.init(uuidString:)) == previousUUID else { throw V2ClientProjectionError.invalidMessagePayload }
                memberID = ownershipMember == .previousOwner ? previous : owner
                ownershipRole = ownershipMember == .previousOwner ? "member" : "owner"
            } else {
                guard let target = wire.target_user_id else { throw V2ClientProjectionError.invalidMessagePayload }
                memberID = target; ownershipRole = nil
            }
            guard UUID(uuidString: wire.room_id) != nil, UUID(uuidString: memberID) != nil,
                  wire.membership_revision > 0, wire.room_sequence.map({ $0 > 0 }) ?? true,
                  wire.actor_user_id.map({ UUID(uuidString: $0) != nil }) ?? true,
                  wire.server_created_at_ms.map({ $0 >= 0 }) ?? true,
                  let projection = Int64(exactly: record.sequence), projection > 0
            else { throw V2ClientProjectionError.invalidMessagePayload }
            let parsedRoom = try RoomID(wire.room_id)
            guard expectedRoomID == nil || expectedRoomID == parsedRoom else { throw V2ClientProjectionError.invalidMessagePayload }
            if let expectedRoomSequence {
                guard let sequence = Int64(exactly: expectedRoomSequence), sequence > 0,
                      wire.room_sequence == nil || wire.room_sequence == sequence
                else { throw V2ClientProjectionError.invalidMessagePayload }
                roomSequence = sequence
            } else { roomSequence = wire.room_sequence }
            if let ownershipRole { action = "role"; role = ownershipRole }
            else if record.projectionKind == "membership", wire.event_type == "membership_changed",
               let change = wire.action, change == "add" || change == "remove" {
                action = change; role = nil
            } else if record.projectionKind == "group_capability", wire.event_type == "group.member_role_changed",
                      let value = wire.role, value == "admin" || value == "member" {
                action = "role"; role = value
            } else { throw V2ClientProjectionError.invalidMessagePayload }
            source = record.sourceEventID.rawValue
            room = parsedRoom.rawValue
            user = try UserID(memberID).rawValue
            revision = wire.membership_revision
            projectionSequence = projection
            struct Canonical: Encodable {
                let version = 1
                let room: String; let user: String; let revision: Int64
                let action: String; let role: String?; let actor: String?; let createdAt: Int64?
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            digest = Data(SHA256.hash(data: try encoder.encode(Canonical(room: room, user: user,
                revision: revision, action: action, role: role,
                actor: try wire.actor_user_id.map(UserID.init)?.rawValue, createdAt: wire.server_created_at_ms))))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
