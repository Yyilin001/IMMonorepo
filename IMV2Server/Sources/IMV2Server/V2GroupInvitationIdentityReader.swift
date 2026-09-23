import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 邀请流程读取到的用户身份快照。
public struct V2GroupInvitationIdentity: Equatable, Sendable {
    /// 该用户的公开身份资料。
    public let profile: V2PublicIdentity
    /// 账号当前是否有效可授权新操作。
    public let isActive: Bool

    /// 保存身份快照。
    ///
    /// - Parameters:
    ///   - profile: 公开身份资料。
    ///   - isActive: 账号是否有效。
    public init(profile: V2PublicIdentity, isActive: Bool) {
        self.profile = profile
        self.isActive = isActive
    }
}

/// 在房间归属事务之外执行的有界控制面身份读取。
///
/// 缺失或已失效的身份不能授权新的房间操作；已存在的请求记录在资料被停用或删除后
/// 仍保留其原身份快照。
public protocol V2GroupInvitationIdentityReading: Sendable {
    /// 批量读取用户身份快照。
    ///
    /// - Parameter userIDs: 需要读取的用户标识集合。
    /// - Returns: 以用户标识为键的身份映射；不存在或不可见的用户不会出现在结果中。
    /// - Throws: 标识非法、超出批量上限或持久化状态损坏时抛出。
    func read(userIDs: Set<UserID>) async throws -> [UserID: V2GroupInvitationIdentity]
}

/// 基于公共资料表的邀请身份读取实现。
public struct PostgresV2GroupInvitationIdentityReader: V2GroupInvitationIdentityReading {
    private let database: any Database
    /// 组合公共资料数据库。
    ///
    /// - Parameter database: 提供公共用户资料的数据源。
    public init(database: any Database) { self.database = database }

    /// 批量读取用户身份快照。
    ///
    /// - Parameter userIDs: 最多 100 个的用户标识集合；为空时直接返回空映射。
    /// - Returns: 以用户标识为键的身份映射。
    /// - Throws: 标识无法解析、批量超过 100、连接不支持 SQL 或账号类型无法解码时抛出
    ///   ``V2GroupInvitationServiceError/invalidRequest`` 或
    ///   ``V2GroupInvitationServiceError/corruptPersistenceState``。
    public func read(userIDs: Set<UserID>) async throws -> [UserID: V2GroupInvitationIdentity] {
        guard userIDs.count <= 100 else { throw V2GroupInvitationServiceError.invalidRequest }
        if userIDs.isEmpty { return [:] }
        let ids = try userIDs.map { id -> UUID in
            guard let uuid = id.uuidValue else { throw V2GroupInvitationServiceError.invalidRequest }
            return uuid
        }
        guard let sql = database as? any SQLDatabase else { throw V2GroupInvitationServiceError.corruptPersistenceState }
        let rows = try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.account_kind,
                   (p.state = 'active' AND NOT EXISTS (
                       SELECT 1 FROM im_v2.account_disables d WHERE d.user_id = p.user_id
                   )) AS is_active
            FROM im_v2.public_user_profiles p WHERE p.user_id = ANY(\(bind: ids)::uuid[])
            """).all(decoding: InvitationIdentityRow.self)
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            guard let kind = V2AccountKind(rawValue: row.accountKind) else { throw V2GroupInvitationServiceError.corruptPersistenceState }
            let id = UserID(uuid: row.userID)
            return (id, .init(profile: try .init(userID: id, handle: .init(row.publicHandle), displayName: row.displayName, accountKind: kind), isActive: row.isActive))
        })
    }
}

private struct InvitationIdentityRow: Decodable {
    let userID: UUID
    let publicHandle: String, displayName: String, accountKind: String
    let isActive: Bool
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", publicHandle = "public_handle", displayName = "display_name"
        case accountKind = "account_kind", isActive = "is_active"
    }
}
