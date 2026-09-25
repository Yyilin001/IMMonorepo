import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 用于把授权事实桥接进房间归属事务的控制面身份快照。
///
/// 归属存储仍会自行完成全部房间内角色、修订与成员关系校验，
/// 该快照不会替代这些检查。
public struct V2MembershipIdentitySnapshot: Equatable, Sendable {
    /// 发起者用户。
    public let actorUserID: UserID
    /// 目标用户。
    public let targetUserID: UserID
    /// 发起者账号是否有效。
    public let actorIsActive: Bool
    /// 目标账号是否有效。
    public let targetIsActive: Bool

    /// 保存身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    ///   - actorIsActive: 发起者账号是否有效。
    ///   - targetIsActive: 目标账号是否有效。
    public init(
        actorUserID: UserID,
        targetUserID: UserID,
        actorIsActive: Bool,
        targetIsActive: Bool
    ) {
        self.actorUserID = actorUserID
        self.targetUserID = targetUserID
        self.actorIsActive = actorIsActive
        self.targetIsActive = targetIsActive
    }
}

/// 成员身份快照读取能力。
public protocol V2MembershipIdentitySnapshotValidating: Sendable {
    /// 读取一次成员身份快照。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起者用户。
    ///   - targetUserID: 目标用户。
    /// - Returns: 两个身份事实的快照。
    /// - Throws: 控制面存储不可用时抛出。
    func snapshot(
        actorUserID: UserID,
        targetUserID: UserID
    ) async throws -> V2MembershipIdentitySnapshot
}

/// 支持控制面校验的成员变更存储。
public protocol V2ControlValidatedRoomMembershipStore:
    V2RoomMembershipStore {
    /// 以控制面身份快照与房间归属执行成员变更。
    ///
    /// - Parameters:
    ///   - command: 成员变更命令。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - identitySnapshot: 控制面提供的身份快照。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 归属不符、身份失效、无权限或持久化失败时抛出。
    func changeControlValidated(
        command: V2ChangeRoomMembershipCommand,
        ownerRoute: V2RoomShardRoute,
        identitySnapshot: V2MembershipIdentitySnapshot,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome
}

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
