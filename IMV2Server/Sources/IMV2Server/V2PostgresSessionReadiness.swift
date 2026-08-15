import Fluent
import SQLKit

public enum V2PostgresSessionReadinessError: Error, Equatable, Sendable {
    case unsupportedDatabase
    case policyMismatch(
        statementTimeoutMilliseconds: Int,
        lockTimeoutMilliseconds: Int,
        idleTransactionTimeoutMilliseconds: Int
    )
}

/// Fails startup if the PostgreSQL server did not accept the session timeout
/// policy. The policy is installed in every connection's startup packet; this
/// probe makes a proxy/server that discards those settings observable before
/// a public listener opens.
public enum V2PostgresSessionReadiness {
    public static func verify(
        database: any Database,
        policy: V2PostgresRuntimePolicy
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2PostgresSessionReadinessError.unsupportedDatabase
        }
        guard let settings = try await sql.raw("""
            SELECT (SELECT setting::integer FROM pg_settings WHERE name = 'statement_timeout')
                       AS statement_timeout_ms,
                   (SELECT setting::integer FROM pg_settings WHERE name = 'lock_timeout')
                       AS lock_timeout_ms,
                   (SELECT setting::integer FROM pg_settings WHERE name = 'idle_in_transaction_session_timeout')
                       AS idle_transaction_timeout_ms
            """).first(decoding: V2PostgresSessionSettings.self),
              settings.statementTimeoutMilliseconds == policy.statementTimeoutMilliseconds,
              settings.lockTimeoutMilliseconds == policy.lockTimeoutMilliseconds,
              settings.idleTransactionTimeoutMilliseconds == policy.idleTransactionTimeoutMilliseconds
        else {
            throw V2PostgresSessionReadinessError.policyMismatch(
                statementTimeoutMilliseconds: policy.statementTimeoutMilliseconds,
                lockTimeoutMilliseconds: policy.lockTimeoutMilliseconds,
                idleTransactionTimeoutMilliseconds: policy.idleTransactionTimeoutMilliseconds
            )
        }
    }
}

private struct V2PostgresSessionSettings: Decodable {
    let statementTimeoutMilliseconds: Int
    let lockTimeoutMilliseconds: Int
    let idleTransactionTimeoutMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case statementTimeoutMilliseconds = "statement_timeout_ms"
        case lockTimeoutMilliseconds = "lock_timeout_ms"
        case idleTransactionTimeoutMilliseconds = "idle_transaction_timeout_ms"
    }
}
