import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import SQLKit

/// PostgreSQL 会话参数就绪检查错误。
public enum V2PostgresSessionReadinessError: Error, Equatable, Sendable {
    /// 当前数据库适配器不支持 SQL 查询。
    case unsupportedDatabase
    /// A proxy or server did not preserve the native Host session marker.
    case applicationNameMismatch
    /// 服务端实际生效的超时参数与期望策略不一致，参数为期望值。
    case policyMismatch(
        statementTimeoutMilliseconds: Int,
        lockTimeoutMilliseconds: Int,
        idleTransactionTimeoutMilliseconds: Int
    )
}

/// PostgreSQL 会话策略就绪探针。
///
/// 若服务端未接受会话超时策略则让启动失败。策略随每个连接的启动包下发，
/// 该探针可在监听端口开放前发现丢弃这些设置的代理或服务端。
public enum V2PostgresSessionReadiness {
    /// 校验服务端实际生效的会话超时参数与策略一致。
    ///
    /// 比较的是服务端 `pg_settings` 中的真实取值，而不是客户端下发的参数，
    /// 因此可发现被代理丢弃或覆盖的配置。
    ///
    /// - Parameters:
    ///   - database: 待检查的数据库连接。
    ///   - policy: 期望生效的运行时策略。
    /// - Throws: 连接不支持 SQL 时抛出
    ///   ``V2PostgresSessionReadinessError/unsupportedDatabase``；
    ///   三项超时参数任一与策略不同、或查询结果无法解码时抛出
    ///   ``V2PostgresSessionReadinessError/policyMismatch(statementTimeoutMilliseconds:lockTimeoutMilliseconds:idleTransactionTimeoutMilliseconds:)``。
    public static func verify(
        database: any Database,
        policy: V2PostgresRuntimePolicy,
        applicationName: String? = nil
    ) async throws {
        try await verify(database: database,
            statementMilliseconds: policy.statementTimeoutMilliseconds,
            lockMilliseconds: policy.lockTimeoutMilliseconds,
            idleMilliseconds: policy.idleTransactionTimeoutMilliseconds, applicationName: applicationName)
    }

    public static func verify(database: any Database, timeouts: V2RoomActivationSQLTimeouts,
                              applicationName: String? = nil) async throws {
        try await verify(database: database, statementMilliseconds: timeouts.statementMilliseconds,
            lockMilliseconds: timeouts.lockMilliseconds, idleMilliseconds: timeouts.idleTransactionMilliseconds,
            applicationName: applicationName)
    }

    private static func verify(database: any Database, statementMilliseconds: Int,
        lockMilliseconds: Int, idleMilliseconds: Int, applicationName: String?) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2PostgresSessionReadinessError.unsupportedDatabase
        }
        guard let settings = try await sql.raw("""
            SELECT (SELECT setting::integer FROM pg_settings WHERE name = 'statement_timeout')
                       AS statement_timeout_ms,
                   (SELECT setting::integer FROM pg_settings WHERE name = 'lock_timeout')
                       AS lock_timeout_ms,
                   (SELECT setting::integer FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout')
                       AS idle_transaction_timeout_ms,
                   current_setting('application_name') AS application_name
            """).first(decoding: V2PostgresSessionSettings.self),
              settings.statementTimeoutMilliseconds == statementMilliseconds,
              settings.lockTimeoutMilliseconds == lockMilliseconds,
              settings.idleTransactionTimeoutMilliseconds == idleMilliseconds
        else {
            throw V2PostgresSessionReadinessError.policyMismatch(
                statementTimeoutMilliseconds: statementMilliseconds,
                lockTimeoutMilliseconds: lockMilliseconds,
                idleTransactionTimeoutMilliseconds: idleMilliseconds
            )
        }
        if let applicationName, settings.applicationName != applicationName {
            throw V2PostgresSessionReadinessError.applicationNameMismatch
        }
    }
}

private struct V2PostgresSessionSettings: Decodable {
    let statementTimeoutMilliseconds: Int
    let lockTimeoutMilliseconds: Int
    let idleTransactionTimeoutMilliseconds: Int
    let applicationName: String

    enum CodingKeys: String, CodingKey {
        case statementTimeoutMilliseconds = "statement_timeout_ms"
        case lockTimeoutMilliseconds = "lock_timeout_ms"
        case idleTransactionTimeoutMilliseconds = "idle_transaction_timeout_ms"
        case applicationName = "application_name"
    }
}
