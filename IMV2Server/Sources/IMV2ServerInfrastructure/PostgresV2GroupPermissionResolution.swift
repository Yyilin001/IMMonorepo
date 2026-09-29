import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// 解析群聊某个角色的生效权限策略，不把「历史群无策略行」与「显式清空策略」混为一谈。
///
/// 策略标记行不会随操作回执清理而删除，因此可据此区分两种状态：
/// 返回 `nil` 表示角色为群主或没有显式策略，调用方应使用内建默认权限；
/// 返回空集合表示存在显式策略且该策略拒绝全部权限。
///
/// - Parameters:
///   - roomID: 目标房间。
///   - role: 待解析的角色；群主直接返回 `nil`。
///   - sql: 当前事务使用的数据库连接。
/// - Returns: 显式配置的权限集合；无显式策略时为 `nil`。
/// - Throws: 权限行包含未知权限值时抛出
///   ``V2RoomWriteStoreError/corruptPersistenceState``。
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
