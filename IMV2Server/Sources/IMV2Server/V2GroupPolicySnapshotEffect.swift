import Foundation
import IMV2Core

/// Group control revisions order their own objects, including each member's
/// role. They never use a recipient's sync cursor as an object version.
struct V2GroupPolicySnapshotEffect: Equatable {
    enum Value: Equatable {
        case announcement(body: String, updatedAtMilliseconds: Int64)
        case permissions(role: V2RoomMembershipRole, values: Set<V2GroupPermission>)
        case memberRole(target: UUID, role: V2RoomMembershipRole, updatedAtMilliseconds: Int64?)
    }

    let roomID: UUID
    let revision: Int64
    let value: Value
    let actorID: UUID?
    let roomSequence: Int64?

    var entityKey: String {
        switch value {
        case .announcement: "announcement:\(roomID.uuidString)"
        case .permissions(let role, _): "permissions:\(roomID.uuidString):\(role.rawValue)"
        case .memberRole(let target, _, _): "member-role:\(roomID.uuidString):\(target.uuidString)"
        }
    }

    init(payload: Data) throws {
        struct Wire: Decodable {
            let eventType: String; let roomID: UUID; let revision: Int64?
            let membershipRevision: Int64?; let targetUserID: UUID?
            let body: String?; let role: String?; let permissions: [String]?
            let updatedAt: Int64?; let actorID: UUID?; let roomSequence: Int64?
            enum CodingKeys: String, CodingKey {
                case eventType = "event_type", roomID = "room_id", revision, body, role, permissions
                case updatedAt = "server_created_at_ms", actorID = "actor_user_id", roomSequence = "room_sequence"
                case membershipRevision = "membership_revision", targetUserID = "target_user_id"
            }
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: payload)
            let objectRevision = wire.eventType == "group.member_role_changed" ? wire.membershipRevision : wire.revision
            guard let objectRevision, objectRevision > 0, wire.roomSequence.map({ $0 > 0 }) ?? true,
                  wire.updatedAt.map({ $0 >= 0 }) ?? true
            else { throw V2UserProjectionWorkerError.invalidPayload }
            roomID = wire.roomID
            revision = objectRevision
            actorID = wire.actorID
            roomSequence = wire.roomSequence
            switch wire.eventType {
            case "group.announcement_changed":
                guard let body = wire.body, body.utf8.count <= V2GroupAnnouncementCommand.maximumUTF8Bytes,
                      let updatedAt = wire.updatedAt
                else { throw V2UserProjectionWorkerError.invalidPayload }
                // Empty legacy/replacement facts also carry a revision. Their
                // absence cannot fence an older nonempty announcement.
                value = .announcement(body: body, updatedAtMilliseconds: updatedAt)
            case "group.role_permissions_changed":
                guard let rawRole = wire.role, let role = V2RoomMembershipRole(rawValue: rawRole), role != .owner,
                      let rawPermissions = wire.permissions,
                      Set(rawPermissions).count == rawPermissions.count
                else { throw V2UserProjectionWorkerError.invalidPayload }
                let permissions = Set(rawPermissions.compactMap(V2GroupPermission.init(rawValue:)))
                guard permissions.count == rawPermissions.count else { throw V2UserProjectionWorkerError.invalidPayload }
                value = .permissions(role: role, values: permissions)
            case "group.member_role_changed":
                guard let target = wire.targetUserID, let rawRole = wire.role,
                      let role = V2RoomMembershipRole(rawValue: rawRole), role != .owner
                else { throw V2UserProjectionWorkerError.invalidPayload }
                value = .memberRole(target: target, role: role, updatedAtMilliseconds: wire.updatedAt)
            default: throw V2UserProjectionWorkerError.invalidPayload
            }
        } catch {
            throw V2UserProjectionWorkerError.invalidPayload
        }
    }

    /// Source sequence was added later. Missing metadata on the same legacy
    /// fact is compatible; two explicit but different source versions are not.
    func representsSameFact(as other: Self) -> Bool {
        roomID == other.roomID && revision == other.revision && value == other.value && actorID == other.actorID
            && (roomSequence == nil || other.roomSequence == nil || roomSequence == other.roomSequence)
    }
}
