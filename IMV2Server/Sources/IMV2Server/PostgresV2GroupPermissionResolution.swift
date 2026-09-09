import Foundation
import IMV2Core
import SQLKit

/// Resolves a group's effective role policy without conflating an older group
/// with no policy rows and a deliberate empty policy. The current policy marker
/// survives operation-receipt cleanup; the materialized permission table
/// intentionally has no rows for an explicit deny-all policy.
func v2ResolvedGroupPermissions(
    roomID: UUID,
    role: V2RoomMembershipRole,
    sql: any SQLDatabase
) async throws -> Set<V2GroupPermission>? {
    guard role != .owner else { return nil }

    let rows = try await sql.raw("SELECT permission FROM im_v2.group_role_permissions WHERE room_id = \(bind: roomID) AND role = \(bind: role.rawValue)").all(decoding: V2StoredGroupPermissionRow.self)
    guard rows.allSatisfy({ V2GroupPermission(rawValue: $0.permission) != nil }) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }

    let permissions = Set(rows.compactMap { V2GroupPermission(rawValue: $0.permission) })
    guard permissions.isEmpty else { return permissions }

    let hasExplicitPolicy = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.group_role_policies WHERE room_id = \(bind: roomID) AND role = \(bind: role.rawValue)) AS value").first(decoding: V2GroupPermissionPolicyMarker.self)?.value ?? false
    return hasExplicitPolicy ? [] : nil
}

private struct V2StoredGroupPermissionRow: Decodable {
    let permission: String
}

private struct V2GroupPermissionPolicyMarker: Decodable {
    let value: Bool
}
