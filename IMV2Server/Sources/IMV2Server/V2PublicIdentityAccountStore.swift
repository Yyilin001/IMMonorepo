import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 公开身份目录错误。
public enum V2PublicIdentityDirectoryError: Error, Equatable, Sendable {
    /// 目录或数据库当前不可用。
    case unavailable
    /// 查询预算已用尽，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
}

/// 按公开账号名解析身份的能力。
public protocol V2PublicIdentityDirectoryReading: Sendable {
    /// 解析公开账号名对应的身份。
    ///
    /// - Parameters:
    ///   - handle: 公开账号名。
    ///   - actorUserID: 发起查询的用户。
    /// - Returns: 对应身份；账号不存在、未生效或对方拉黑了发起者时返回 `nil`。
    /// - Throws: 存储不可用或触发限流时抛出。
    func resolve(handle: V2PublicHandle, actorUserID: UserID) async throws -> V2PublicIdentity?
}

/// 公开身份的读取与管理能力。
public protocol V2PublicIdentityAccountManaging: V2PublicIdentityDirectoryReading {
    /// 读取指定用户的公开身份。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 公开身份；账号不存在或未生效时返回 `nil`。
    /// - Throws: 存储不可用时抛出。
    func profile(for userID: UserID) async throws -> V2PublicIdentity?

    /// 更新指定用户的展示名称。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - displayName: 新的展示名称。
    /// - Returns: 更新后（或未变化时原样返回）的公开身份。
    /// - Throws: 名称不合法或存储不可用时抛出。
    func updateDisplayName(for userID: UserID, displayName: String) async throws -> V2PublicIdentity
}

/// 仅基于公开资料数据的账号边缘目录。
///
/// 已拉黑调用方的目标会与不存在的账号名一样解析为 `nil`；
/// 而调用方自己发起的拉黑刻意不做隐藏，以便之后可以撤销。
public struct V2PostgresPublicIdentityDirectory: V2PublicIdentityAccountManaging, Sendable {
    private let database: any Database
    private let policy: V2PublicIdentityLookupRateLimitPolicy
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// 组合数据库、查询预算策略与标识、授时来源。
    ///
    /// - Parameters:
    ///   - database: 存放公开资料与查询预算的数据库。
    ///   - policy: 公开身份查询的限流策略。
    ///   - makeUUID: 传播源记录标识生成方式。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        database: any Database,
        policy: V2PublicIdentityLookupRateLimitPolicy,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.policy = policy
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 按公开账号名解析身份。
    ///
    /// 预算消耗是一条独立提交的原子语句；随后的查询是只读的，不需要共享快照，
    /// 显式事务只会增加往返，并可能在读失败时错误回滚已经计费的查询。
    /// 对方拉黑调用方时结果与账号不存在完全一致，避免泄漏拉黑关系。
    ///
    /// - Parameters:
    ///   - handle: 公开账号名。
    ///   - actorUserID: 发起查询的用户。
    /// - Returns: 对应身份；不满足条件时返回 `nil`。
    /// - Throws: 标识非法、连接不支持 SQL、时刻不可编码或超出预算时抛出
    ///   ``V2PublicIdentityDirectoryError/unavailable`` 或
    ///   ``V2PublicIdentityDirectoryError/rateLimited(retryAfterSeconds:)``。
    public func resolve(
        handle: V2PublicHandle,
        actorUserID: UserID
    ) async throws -> V2PublicIdentity? {
        guard let actorUUID = UUID(uuidString: actorUserID.rawValue) else {
            throw V2PublicIdentityDirectoryError.unavailable
        }
        guard let sql = database as? any SQLDatabase else {
            throw V2PublicIdentityDirectoryError.unavailable
        }
        // Budget consumption is an atomic, independently committed statement.
        // The following lookup is read-only and needs no shared snapshot; an
        // explicit transaction would add BEGIN/COMMIT round trips and could
        // incorrectly roll back an already-attempted lookup on read failure.
        try await consumeLookupBudget(sql: sql, actorUserID: actorUUID)
        guard let row = try await sql.raw("""
            SELECT p.user_id, p.public_handle, p.display_name, p.account_kind
            FROM im_v2.public_user_profiles p
            WHERE p.public_handle = \(bind: handle.rawValue)
              AND p.state = 'active'
              AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables d WHERE d.user_id = p.user_id)
              AND NOT EXISTS (
                SELECT 1 FROM im_v2.user_blocks b
                WHERE b.blocker_user_id = p.user_id
                  AND b.blocked_user_id = \(bind: actorUUID)
              )
            """).first(decoding: PublicIdentityRow.self),
            let userID = try? UserID(row.userID.uuidString),
            let accountKind = V2AccountKind(rawValue: row.accountKind),
            let profile = try? V2PublicIdentity(
                userID: userID,
                handle: .init(row.handle),
                displayName: row.displayName,
                accountKind: accountKind
            )
        else { return nil }
        return profile
    }

    /// 读取指定用户的公开身份。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 公开身份；账号不存在或已停用时返回 `nil`。
    /// - Throws: 标识非法或连接不支持 SQL 时抛出
    ///   ``V2PublicIdentityDirectoryError/unavailable``。
    public func profile(for userID: UserID) async throws -> V2PublicIdentity? {
        guard let userUUID = UUID(uuidString: userID.rawValue),
              let sql = database as? any SQLDatabase
        else { throw V2PublicIdentityDirectoryError.unavailable }
        return try await profile(sql: sql, userID: userUUID)
    }

    /// 更新用户的展示名称。
    ///
    /// 设置为同名是空操作；名称确实变化时，会在同一事务内为既有私聊对端写入
    /// 持久化的传播源记录。若名称需要变化但更新语句未命中（例如修订计数已饱和），
    /// 则报错而不是返回旧身份冒充成功。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - displayName: 新的展示名称。
    /// - Returns: 更新后的公开身份；名称未变化时返回原身份。
    /// - Throws: 标识非法、名称不合法、账号不可用、时刻不可编码或更新未生效时抛出
    ///   ``V2PublicIdentityDirectoryError/unavailable``。
    public func updateDisplayName(
        for userID: UserID,
        displayName: String
    ) async throws -> V2PublicIdentity {
        guard let userUUID = UUID(uuidString: userID.rawValue) else {
            throw V2PublicIdentityDirectoryError.unavailable
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let current = try await profile(sql: sql, userID: userUUID, forUpdate: true)
            else { throw V2PublicIdentityDirectoryError.unavailable }
            let validated: V2PublicIdentity
            do {
                validated = try .init(
                    userID: userID,
                    handle: current.handle,
                    displayName: displayName,
                    accountKind: current.accountKind
                )
            } catch {
                throw V2PublicIdentityDirectoryError.unavailable
            }
            guard current.displayName != validated.displayName else { return current }
            let changedAt = now()
            guard v2PostgresTimestampCanEncode(changedAt) else {
                throw V2PublicIdentityDirectoryError.unavailable
            }
            guard let updated = try await sql.raw("""
                UPDATE im_v2.public_user_profiles
                SET display_name = \(bind: validated.displayName), revision = revision + 1,
                    visibility_revision = visibility_revision + 1, updated_at = \(bind: changedAt)
                WHERE user_id = \(bind: userUUID) AND state = 'active'
                  AND display_name IS DISTINCT FROM \(bind: validated.displayName)
                  AND revision < \(bind: Int64.max)
                  AND visibility_revision < \(bind: Int64.max)
                RETURNING revision, updated_at
                """).first(decoding: UpdatedPublicIdentityRow.self) else {
                // The row is locked and its name requires a change. A
                // skipped update must not report the old identity as success.
                throw V2PublicIdentityDirectoryError.unavailable
            }
            try await sql.raw("""
                INSERT INTO im_v2.public_profile_update_outbox
                    (source_event_id, source_user_id, public_handle, display_name, account_kind, profile_state, revision, profile_updated_at, created_at)
                VALUES (\(bind: makeUUID()), \(bind: userUUID), \(bind: validated.handle.rawValue),
                    \(bind: validated.displayName), \(bind: validated.accountKind.rawValue), 'active',
                    \(bind: updated.revision), \(bind: updated.updatedAt), \(bind: changedAt))
                """).run()
            return validated
        }
    }

    /// 消耗一次公开身份查询预算。
    ///
    /// 唯一键冲突时的行锁即串行化边界，窗口过期则以本次时刻开启新窗口；
    /// 超过预算时写入饱和哨兵值并抛出限流错误，附上建议重试秒数。
    ///
    /// - Parameters:
    ///   - sql: 当前使用的数据库连接。
    ///   - actorUserID: 发起查询的用户。
    /// - Throws: 窗口起点不可编码或查询无结果时抛出
    ///   ``V2PublicIdentityDirectoryError/unavailable``；超出预算时抛出
    ///   ``V2PublicIdentityDirectoryError/rateLimited(retryAfterSeconds:)``。
    private func consumeLookupBudget(sql: any SQLDatabase, actorUserID: UUID) async throws {
        let current = now()
        guard let expiredBefore = v2PostgresPastTimestamp(now: current, interval: policy.window) else {
            throw V2PublicIdentityDirectoryError.unavailable
        }
        let saturatedCount = policy.maximumQueries + 1
        guard let row = try await sql.raw("""
            INSERT INTO im_v2.public_identity_lookup_rate_limits AS rate
                (actor_user_id, window_started_at, query_count, updated_at)
            VALUES (\(bind: actorUserID), \(bind: current), 1, \(bind: current))
            ON CONFLICT (actor_user_id) DO UPDATE
            SET window_started_at = CASE
                    WHEN rate.window_started_at <= \(bind: expiredBefore) THEN \(bind: current)
                    ELSE rate.window_started_at
                END,
                query_count = CASE
                    WHEN rate.window_started_at <= \(bind: expiredBefore) THEN 1
                    WHEN rate.query_count < \(bind: policy.maximumQueries)
                        THEN rate.query_count + 1
                    ELSE \(bind: saturatedCount)
                END,
                updated_at = \(bind: current)
            RETURNING window_started_at, query_count
            """).first(decoding: LookupRateLimitRow.self)
        else { throw V2PublicIdentityDirectoryError.unavailable }
        guard row.queryCount <= policy.maximumQueries else {
            guard let retryAfter = v2RateLimitRetryAfterSeconds(
                windowStartedAt: row.windowStartedAt, now: current, window: policy.window
            ) else { throw V2PublicIdentityDirectoryError.unavailable }
            throw V2PublicIdentityDirectoryError.rateLimited(
                retryAfterSeconds: retryAfter
            )
        }
    }

    /// 读取公开资料行并构造身份。
    ///
    /// - Parameters:
    ///   - sql: 当前使用的数据库连接。
    ///   - userID: 目标用户。
    ///   - forUpdate: 是否对资料行加锁。
    /// - Returns: 公开身份；账号不存在、已停用或字段无法解码时返回 `nil`。
    /// - Throws: 查询失败时抛出。
    private func profile(sql: any SQLDatabase, userID: UUID, forUpdate: Bool = false) async throws -> V2PublicIdentity? {
        guard let row = try await sql.raw("""
            SELECT user_id, public_handle, display_name, account_kind
            FROM im_v2.public_user_profiles
            WHERE user_id = \(bind: userID) AND state = 'active'
              AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables WHERE user_id = \(bind: userID))
            \(unsafeRaw: forUpdate ? "FOR UPDATE" : "")
            """).first(decoding: PublicIdentityRow.self),
              let profileUserID = try? UserID(row.userID.uuidString),
              let accountKind = V2AccountKind(rawValue: row.accountKind),
              let profile = try? V2PublicIdentity(
                  userID: profileUserID,
                  handle: .init(row.handle),
                  displayName: row.displayName,
                  accountKind: accountKind
              )
        else { return nil }
        return profile
    }
}

private struct PublicIdentityRow: Decodable {
    let userID: UUID
    let handle: String
    let displayName: String
    let accountKind: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case handle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
    }
}

private struct UpdatedPublicIdentityRow: Decodable {
    let revision: Int64
    let updatedAt: V2PostgresTimestamp

    enum CodingKeys: String, CodingKey {
        case revision
        case updatedAt = "updated_at"
    }
}

private struct LookupRateLimitRow: Decodable {
    let queryCount: Int
    let windowStartedAt: V2PostgresTimestamp

    enum CodingKeys: String, CodingKey {
        case queryCount = "query_count"
        case windowStartedAt = "window_started_at"
    }
}
