import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 在单次控制面快照中读取两个全局身份事实。
///
/// 账号停用仍作为认证与会话栅栏；该检查只是防止新增成员时引用不存在或已停用的身份。
public struct V2PostgresMembershipIdentitySnapshotValidator:
    V2MembershipIdentitySnapshotValidating {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 提供公开资料与账号状态的控制面数据库。
    public init(database: any Database) { self.database = database }

    /// 读取发起者与目标用户的身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    /// - Returns: 两个身份事实的快照。
    /// - Throws: 标识非法或连接不支持 SQL 时抛出
    ///   ``V2RoomMembershipStoreError/corruptPersistenceState``。
    public func snapshot(
        actorUserID: UserID,
        targetUserID: UserID
    ) async throws -> V2MembershipIdentitySnapshot {
        guard let actorUUID = UUID(uuidString: actorUserID.rawValue),
              let targetUUID = UUID(uuidString: targetUserID.rawValue),
              let sql = database as? any SQLDatabase
        else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        let active = try await sql.raw("""
            SELECT profile.user_id
            FROM im_v2.public_user_profiles AS profile
            WHERE profile.user_id = ANY(
                \(bind: [actorUUID, targetUUID])::uuid[]
            )
              AND profile.state = 'active'
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.account_disables AS disabled
                  WHERE disabled.user_id = profile.user_id
              )
            """).all(decoding: ActiveIdentityRow.self)
        let activeIDs = Set(active.map(\.userID))
        return .init(
            actorUserID: actorUserID,
            targetUserID: targetUserID,
            actorIsActive: activeIDs.contains(actorUUID),
            targetIsActive: activeIDs.contains(targetUUID)
        )
    }
}

private struct ActiveIdentityRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}
