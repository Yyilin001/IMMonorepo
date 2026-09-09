import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2GroupRolePolicyBaselineStore: V2GroupRolePolicyBaselineReading {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupRolePolicyBaseline {
        guard let sql = database as? any SQLDatabase,
              let room = UUID(uuidString: roomID.rawValue), let actor = UUID(uuidString: actorUserID.rawValue)
        else { throw V2GroupRolePolicyBaselineError.corruptPersistenceState }
        // One SQL statement provides one MVCC read point for membership,
        // revision, durable explicit-policy markers and permission values.
        // Neither replay receipts nor filtered room history are read here.
        guard let row = try await sql.raw("""
            SELECT room.group_permission_revision, room.membership_revision, room.room_sequence,
                   EXISTS (
                       SELECT 1 FROM im_v2.room_memberships AS membership
                       WHERE membership.room_id = room.room_id AND membership.user_id = \(bind: actor)
                         AND membership.joined_revision <= room.membership_revision
                         AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision)
                   ) AS actor_is_member,
                   (SELECT jsonb_agg(policy.role ORDER BY policy.role)::text
                    FROM im_v2.group_role_policies AS policy WHERE policy.room_id = room.room_id) AS explicit_roles,
                   (SELECT jsonb_agg(jsonb_build_object('role', permission.role, 'permission', permission.permission)
                                     ORDER BY permission.role, permission.permission)::text
                    FROM im_v2.group_role_permissions AS permission WHERE permission.room_id = room.room_id) AS permissions
            FROM im_v2.rooms AS room
            WHERE room.room_id = \(bind: room) AND room.room_kind = 'group'
            """).first(decoding: PolicyBaselineRow.self)
        else { throw V2GroupRolePolicyBaselineError.roomNotFound }
        guard row.actorIsMember else { throw V2GroupRolePolicyBaselineError.actorNotMember }
        do {
            guard row.permissionRevision > 0, row.membershipRevision >= 0, row.roomSequence >= 0 else {
                throw V2GroupRolePolicyBaselineError.corruptPersistenceState
            }
            let rawRoles = try JSONDecoder().decode([String].self, from: Data((row.explicitRoles ?? "[]").utf8))
            let permissions = try JSONDecoder().decode([PolicyPermission].self, from: Data((row.permissions ?? "[]").utf8))
            let allowedRoles: Set<String> = [V2RoomMembershipRole.admin.rawValue, V2RoomMembershipRole.member.rawValue]
            guard Set(rawRoles).count == rawRoles.count, Set(rawRoles).isSubset(of: allowedRoles),
                  permissions.allSatisfy({ allowedRoles.contains($0.role) && V2GroupPermission(rawValue: $0.permission) != nil })
            else { throw V2GroupRolePolicyBaselineError.corruptPersistenceState }
            let values = Dictionary(grouping: permissions, by: \.role)
            func effective(_ role: V2RoomMembershipRole) throws -> Set<V2GroupPermission> {
                let rows = values[role.rawValue] ?? []
                let decoded = Set(rows.compactMap { V2GroupPermission(rawValue: $0.permission) })
                guard decoded.count == rows.count else { throw V2GroupRolePolicyBaselineError.corruptPersistenceState }
                // Nonempty rows predate durable markers in supported history.
                // No rows plus a marker is deliberately empty, not defaults.
                if !rows.isEmpty || rawRoles.contains(role.rawValue) { return decoded }
                return V2GroupPermissionDefaults.permissions(for: role)
            }
            return try .init(roomID: roomID, permissionRevision: UInt64(row.permissionRevision), membershipRevision: UInt64(row.membershipRevision), roomSequence: UInt64(row.roomSequence), adminPermissions: effective(.admin), memberPermissions: effective(.member))
        } catch { throw V2GroupRolePolicyBaselineError.corruptPersistenceState }
    }
}

private struct PolicyPermission: Decodable {
    let role: String
    let permission: String
}

private struct PolicyBaselineRow: Decodable {
    let permissionRevision: Int64
    let membershipRevision: Int64
    let roomSequence: Int64
    let actorIsMember: Bool
    let explicitRoles: String?
    let permissions: String?
    enum CodingKeys: String, CodingKey {
        case permissionRevision = "group_permission_revision", membershipRevision = "membership_revision"
        case roomSequence = "room_sequence", actorIsMember = "actor_is_member"
        case explicitRoles = "explicit_roles", permissions
    }
}
