import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 由单独认证的运维控制面提供的有界、可审计原因。
///
/// 自由文本的运维记录应留在外部工单系统，永远不进入账号数据库。
public enum V2AccountDisableReason: String, Codable, CaseIterable, Sendable {
    /// 用户本人请求停用。
    case userRequested = "user_requested"
    /// 凭据疑似泄漏。
    case credentialCompromise = "credential_compromise"
    /// 依据策略执行。
    case policyEnforcement = "policy_enforcement"
}

/// 一次账号停用命令。
public struct V2AccountDisableCommand: Sendable {
    /// 目标用户。
    public let userID: UserID
    /// 本次停用的幂等操作标识。
    public let operationID: UUID
    /// 停用原因。
    public let reason: V2AccountDisableReason

    /// 校验并保存停用命令。
    ///
    /// - Parameters:
    ///   - userID: 目标用户，需可解析为 UUID。
    ///   - operationID: 幂等操作标识。
    ///   - reason: 停用原因。
    /// - Throws: 用户标识非法时抛出 ``V2AccountDisableError/invalidUserID``。
    public init(userID: UserID, operationID: UUID, reason: V2AccountDisableReason) throws {
        guard UUID(uuidString: userID.rawValue) != nil else { throw V2AccountDisableError.invalidUserID }
        self.userID = userID
        self.operationID = operationID
        self.reason = reason
    }
}

/// 账号停用结果。
public enum V2AccountDisableOutcome: Equatable, Sendable {
    /// 本次调用实际停用了账号。
    case disabled(disabledAt: Date)
    /// 同一操作此前已执行，返回其原有停用时刻。
    case idempotent(disabledAt: Date)
    /// 账号此前已因其他原因停用，返回既有停用时刻。
    case alreadyDisabled(disabledAt: Date)
}

/// 账号停用错误。
public enum V2AccountDisableError: Error, Equatable, Sendable {
    /// 用户标识不是合法 UUID。
    case invalidUserID
    /// 运维主体标识不满足格式要求。
    case invalidOperatorPrincipal
    /// 同一操作标识已用于其他账号。
    case operationConflict
    /// 数据库或时刻编码当前不可用。
    case unavailable
}

/// 运维边界刻意只包含一个破坏性动作：永久停用单个账号。
///
/// 它不能重新启用账号、删除保留数据，也不接受原始 SQL 或批量操作；
/// 恢复流程由单独定义的产品与审计工作流负责。
public protocol V2AccountDisabling: Sendable {
    /// 停用指定账号。
    ///
    /// - Parameter command: 已校验的停用命令。
    /// - Returns: 停用结果。
    /// - Throws: 操作冲突或存储不可用时抛出。
    func disable(_ command: V2AccountDisableCommand) async throws -> V2AccountDisableOutcome
}

/// 基于 PostgreSQL 的账号停用实现。
public struct V2PostgresAccountDisableService: V2AccountDisabling, Sendable {
    private let database: any Database
    private let authorizationCoordinator: V2DirectAuthorizationCoordinator?
    private let operatorPrincipal: String
    private let now: @Sendable () -> Date

    /// 组合数据库与固定的运维主体。
    ///
    /// - Parameters:
    ///   - database: 存放账号状态、设备会话与公开资料的数据库。
    ///   - operatorPrincipal: 运维主体标识，需符合通用运维主体格式。
    ///   - now: 可注入的当前时刻读取函数。
    /// - Throws: 运维主体格式非法时抛出
    ///   ``V2AccountDisableError/invalidOperatorPrincipal``。
    public init(
        database: any Database,
        operatorPrincipal: String,
        authorizationCoordinator: V2DirectAuthorizationCoordinator? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(operatorPrincipal) else {
            throw V2AccountDisableError.invalidOperatorPrincipal
        }
        self.database = database
        self.authorizationCoordinator = authorizationCoordinator
        self.operatorPrincipal = operatorPrincipal
        self.now = now
    }

    /// 在单个事务内停用账号并吊销其全部凭据。
    ///
    /// 凭据签发与刷新会先获取同一账号状态锁后才返回凭据，因此顺序保证：
    /// 要么新签发的凭据被本事务吊销，要么签发流程观察到停用状态而拒绝签发。
    /// 事务内依次处理操作幂等、账号既有停用、停用记录写入、直发策略修订递增、
    /// 设备与令牌吊销、公开资料暂停及传播发件箱写入，最后登记设备吊销事件，
    /// 让各网关副本关闭已建立的连接。
    ///
    /// - Parameter command: 已校验的停用命令。
    /// - Returns: 停用结果。
    /// - Throws: 用户标识非法时抛出 ``V2AccountDisableError/invalidUserID``；
    ///   同一操作标识已用于其他账号时抛出 ``V2AccountDisableError/operationConflict``；
    ///   连接不可用、时刻不可编码、计数已饱和或资料暂停未生效时抛出
    ///   ``V2AccountDisableError/unavailable``。
    public func disable(_ command: V2AccountDisableCommand) async throws -> V2AccountDisableOutcome {
        guard let userUUID = UUID(uuidString: command.userID.rawValue) else {
            throw V2AccountDisableError.invalidUserID
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2AccountDisableError.unavailable }
            let occurredAt = now()
            // 凭据签发和刷新在返回凭据前使用同一把锁。
            // 此顺序保证：新签发的凭据要么被本事务撤销，
            // 要么签发过程看到账号已禁用而不返回凭据。
            try await lockOperation(sql, operationID: command.operationID)
            try await lockAccountState(sql, userID: userUUID)

            if let prior = try await sql.raw("SELECT user_id, disabled_at FROM im_v2.account_disables WHERE operation_id = \(bind: command.operationID)").first(decoding: DisableRecord.self) {
                guard prior.userID == userUUID else { throw V2AccountDisableError.operationConflict }
                return .idempotent(disabledAt: prior.disabledAt)
            }
            if let prior = try await sql.raw("SELECT user_id, disabled_at FROM im_v2.account_disables WHERE user_id = \(bind: userUUID)").first(decoding: DisableRecord.self) {
                return .alreadyDisabled(disabledAt: prior.disabledAt)
            }

            guard v2PostgresTimestampCanEncode(occurredAt) else { throw V2AccountDisableError.unavailable }
            do {
                try await v2DrainDirectAuthorizations(.user(userUUID), coordinator: authorizationCoordinator, transaction: transaction, now: occurredAt)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw V2AccountDisableError.unavailable
            }

            guard let persisted = try await sql.raw("""
                INSERT INTO im_v2.account_disables (user_id, operation_id, reason, operator_principal, disabled_at)
                VALUES (\(bind: userUUID), \(bind: command.operationID), \(bind: command.reason.rawValue), \(bind: operatorPrincipal), \(bind: occurredAt))
                RETURNING user_id, disabled_at
                """).first(decoding: DisableRecord.self) else { throw V2AccountDisableError.unavailable }
            guard try await sql.raw("""
                INSERT INTO im_v2.user_direct_send_policy_versions AS version (user_id, revision, updated_at)
                VALUES (\(bind: userUUID), 2, \(bind: occurredAt))
                ON CONFLICT (user_id) DO UPDATE
                SET revision = version.revision + 1, updated_at = EXCLUDED.updated_at
                WHERE version.revision < \(bind: Int64.max)
                RETURNING user_id
                """).first() != nil else { throw V2AccountDisableError.unavailable }
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            try await sql.raw("UPDATE im_v2.device_refresh_sessions SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            try await sql.raw("UPDATE im_v2.device_access_tokens SET revoked_at = COALESCE(revoked_at, \(bind: occurredAt)) WHERE user_id = \(bind: userUUID)").run()
            if let profile = try await sql.raw("""
                WITH candidate AS MATERIALIZED (
                    SELECT user_id, public_handle, display_name, account_kind
                    FROM im_v2.public_user_profiles
                    WHERE user_id = \(bind: userUUID) AND state <> 'deleted'
                      AND state <> 'suspended'
                    FOR UPDATE
                ), updated AS (
                    UPDATE im_v2.public_user_profiles AS profile
                    SET state = 'suspended', avatar_media_id = NULL,
                        revision = profile.revision + 1,
                        visibility_revision = profile.visibility_revision + 1,
                        updated_at = \(bind: occurredAt)
                    FROM candidate
                    WHERE profile.user_id = candidate.user_id
                      AND profile.revision < \(bind: Int64.max)
                      AND profile.visibility_revision < \(bind: Int64.max)
                    RETURNING profile.revision
                )
                SELECT candidate.public_handle, candidate.display_name,
                       candidate.account_kind, updated.revision
                FROM candidate LEFT JOIN updated ON TRUE
                """).first(decoding: DisabledProfileRow.self) {
                // 符合条件的资料必须实际被停用。修订号缺失时须区分
                // 计数器耗尽与无需变更资料状态的情形。
                guard let revision = profile.revision else { throw V2AccountDisableError.unavailable }
                try await sql.raw("""
                    INSERT INTO im_v2.public_profile_update_outbox
                        (source_event_id, source_user_id, public_handle,
                         display_name, account_kind, profile_state, revision,
                         profile_updated_at, created_at)
                    VALUES (\(bind: command.operationID), \(bind: userUUID),
                            \(bind: profile.publicHandle), \(bind: profile.displayName),
                            \(bind: profile.accountKind), 'suspended',
                            \(bind: revision), \(bind: occurredAt), \(bind: occurredAt))
                    """).run()
            }
            // 持久化网关工作器在每个网关副本上消费这条逐设备事件流，
            // 并关闭已认证的套接字。
            try await sql.raw("INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at) SELECT user_id, device_id, \(bind: occurredAt) FROM im_v2.auth_devices WHERE user_id = \(bind: userUUID) ON CONFLICT (device_id) DO NOTHING").run()
            // 保留上方的原生时间绑定，同时返回后续重放
            // 会解码出的确切已提交回执时间。
            return .disabled(disabledAt: persisted.disabledAt)
        }
    }

    /// 取得账号状态咨询锁。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - userID: 目标用户。
    /// - Throws: 加锁失败时抛出。
    private func lockAccountState(_ sql: any SQLDatabase, userID: UUID) async throws {
        let key = "account-state:" + userID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    /// 取得停用操作咨询锁。
    ///
    /// - Parameters:
    ///   - sql: 当前事务使用的数据库连接。
    ///   - operationID: 操作标识。
    /// - Throws: 加锁失败时抛出。
    private func lockOperation(_ sql: any SQLDatabase, operationID: UUID) async throws {
        let key = "account-disable-operation:" + operationID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }
}

private struct DisableRecord: Decodable {
    let userID: UUID
    let disabledAt: Date
    enum CodingKeys: String, CodingKey { case userID = "user_id"; case disabledAt = "disabled_at" }
}

private struct DisabledProfileRow: Decodable {
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let revision: Int64?
    enum CodingKeys: String, CodingKey {
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case revision
    }
}
