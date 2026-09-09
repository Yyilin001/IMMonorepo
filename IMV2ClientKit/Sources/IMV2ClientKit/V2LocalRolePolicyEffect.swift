import Crypto
import Foundation
import IMV2Core

/// A revision belongs to one role's source event. It must not be inferred
/// from the room-wide command revision or a recipient's personal cursor.
struct V2LocalRolePolicyEffect {
    let sourceEventID: EventID
    let roomID: RoomID
    let role: V2RoomMembershipRole
    let revision: Int64
    let permissions: Set<V2GroupPermission>
    let encodedPermissions: Data
    let roomSequence: Int64?
    let digest: Data

    init(record: V2ClientSyncRecord, expectedRoomSequence: UInt64? = nil, expectedRoomID: RoomID? = nil) throws {
        struct Wire: Decodable {
            let event_type: String; let room_id: String; let revision: Int64
            let role: String; let permissions: [String]
            let actor_user_id: String?; let server_created_at_ms: Int64?; let room_sequence: Int64?
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "group_capability", wire.event_type == "group.role_permissions_changed",
                  UUID(uuidString: wire.room_id) != nil, wire.revision > 0,
                  let parsedRole = V2RoomMembershipRole(rawValue: wire.role), parsedRole != .owner,
                  wire.actor_user_id.map({ UUID(uuidString: $0) != nil }) ?? true,
                  wire.server_created_at_ms.map({ $0 >= 0 }) ?? true,
                  wire.room_sequence.map({ $0 > 0 }) ?? true
            else { throw V2ClientProjectionError.invalidMessagePayload }
            let parsedPermissions = Set(wire.permissions.compactMap(V2GroupPermission.init(rawValue:)))
            guard parsedPermissions.count == wire.permissions.count else { throw V2ClientProjectionError.invalidMessagePayload }
            roomID = try .init(wire.room_id)
            guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
            if let expectedRoomSequence, let sequence = wire.room_sequence {
                guard UInt64(sequence) == expectedRoomSequence else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            sourceEventID = record.sourceEventID
            role = parsedRole
            revision = wire.revision
            permissions = parsedPermissions
            roomSequence = wire.room_sequence
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encodedPermissions = try encoder.encode(parsedPermissions.map(\.rawValue).sorted())
            struct Canonical: Encodable {
                let version = 1
                let room: String; let role: String; let revision: Int64; let permissions: [String]
                let actor: String?; let createdAt: Int64?
            }
            digest = Data(SHA256.hash(data: try encoder.encode(Canonical(
                room: roomID.rawValue, role: role.rawValue, revision: revision,
                permissions: parsedPermissions.map(\.rawValue).sorted(),
                actor: try wire.actor_user_id.map(UserID.init)?.rawValue, createdAt: wire.server_created_at_ms
            ))))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
