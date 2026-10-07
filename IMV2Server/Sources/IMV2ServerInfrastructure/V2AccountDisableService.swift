import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit


/// 基于 PostgreSQL 的账号停用实现。
public struct V2PostgresAccountDisableService: V2AccountDisabling, Sendable {
    private let database: any Database
    private var policyOwners: (any V2PolicyMutationExecuting)? = nil
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

    package func usingPolicyOwners(_ owners: any V2PolicyMutationExecuting) -> Self {
        var copy = self; copy.policyOwners = owners; return copy
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
        if let policyOwners {
            do {
                let execution = try await policyOwners.changeExecution(.disable(.init(command: command, operatorPrincipal: operatorPrincipal)))
                guard case .disable(let receipt) = execution.result else { throw V2AccountDisableError.unavailable }
                if execution.replayed, receipt.kind == .disabled { return .idempotent(disabledAt: receipt.disabledAt) }
                return receipt.outcome
            } catch V2PolicyAuthorizationLifecycleError.identityConflict { throw V2AccountDisableError.operationConflict }
        }
        return try await database.transaction { transaction in
            try await applyDisable(command, userUUID: userUUID, transaction: transaction, occurredAt: now(), policyMutation: nil)
        }
    }

    package func applyPolicyOperation(_ command: V2AccountDisableCommand, occurredAt: Date,
                                      context: V2PolicyMutationContext) async throws -> V2AccountDisableOutcome {
        let mutation = V2DurablePolicyMutation.disable(.init(command: command, operatorPrincipal: operatorPrincipal))
        try context.require(scope: mutation.scope, operationKey: mutation.operationKey, fingerprint: mutation.fingerprint)
        guard let user = command.userID.uuidValue else { throw V2AccountDisableError.invalidUserID }
        return try await applyDisable(command, userUUID: user, transaction: context.transaction,
            occurredAt: occurredAt, policyMutation: context)
    }

    private func applyDisable(_ command: V2AccountDisableCommand, userUUID: UUID, transaction: any Database,
        occurredAt: Date, policyMutation: V2PolicyMutationContext?) async throws -> V2AccountDisableOutcome {
            guard let sql = transaction as? any SQLDatabase else { throw V2AccountDisableError.unavailable }
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
                if policyMutation != nil {
                    guard try await PostgresV2DirectAuthorizationIntentStore(database: transaction)
                        .held(in: .user(userUUID), limit: 1, transaction: transaction).isEmpty else {
                        throw V2DirectAuthorizationCoordinationError.revocationIncomplete
                    }
                } else {
                    try await v2DrainDirectAuthorizations(.user(userUUID), coordinator: authorizationCoordinator, transaction: transaction, now: occurredAt)
                }
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
