import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// 发送与编辑共用的内容发布策略检查。
///
/// 调用方必须持有房间行（或等效的授权栅栏）直到本次写入提交；角色、禁言、成员关系与
/// 房间冻结变更都会获取同一把房间锁，因此这里的检查不会与并发变更错位。
/// 全局账号身份由控制面边界提供，本函数不做账号级判断。
///
/// 检查顺序为：房间未冻结、发起者账号有效且房间角色可解析、
/// 群聊按角色解析后的权限允许发送消息、发起者未被禁言。
///
/// - Parameters:
///   - roomID: 目标房间。
///   - isGroup: 目标房间是否为群聊；为 `false` 时不查询群权限。
///   - frozenAt: 房间冻结时刻；非空表示房间已被冻结。
///   - actorIsActive: 账号是否处于有效状态。
///   - actorRole: 发起者在房间内的角色原始值。
///   - isMuted: 发起者是否处于禁言状态。
///   - sql: 当前写入事务使用的数据库连接。
/// - Throws: 房间冻结抛出 ``V2RoomWriteStoreError/roomFrozen``；账号无效、角色无法解析
///   或角色权限不允许发送消息抛出 ``V2RoomWriteStoreError/actorNotEligible``；处于禁言抛出
///   ``V2RoomWriteStoreError/actorMuted``；权限行无法解码抛出
///   ``V2RoomWriteStoreError/corruptPersistenceState``。
func v2AuthorizeContentWrite(
    roomID: UUID,
    isGroup: Bool,
    frozenAt: Date?,
    actorIsActive: Bool,
    actorRole: String?,
    isMuted: Bool,
    sql: any SQLDatabase
) async throws {
    guard frozenAt == nil else { throw V2RoomWriteStoreError.roomFrozen }
    guard actorIsActive, let actorRole,
          let role = V2RoomMembershipRole(rawValue: actorRole)
    else { throw V2RoomWriteStoreError.actorNotEligible }
    if isGroup {
        let permissions = try await v2ResolvedGroupPermissions(roomID: roomID, role: role, sql: sql)
        guard V2GroupPermissionDefaults.allows(role: role, permission: .sendMessages, configured: permissions)
        else { throw V2RoomWriteStoreError.actorNotEligible }
    }
    guard !isMuted else { throw V2RoomWriteStoreError.actorMuted }
}
