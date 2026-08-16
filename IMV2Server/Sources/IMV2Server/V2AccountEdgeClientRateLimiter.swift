import Fluent
import Foundation
import SQLKit

public enum V2AccountEdgeClientRateLimitResult: Equatable, Sendable {
    case allowed
    case rateLimited(retryAfterSeconds: Int)
}

/// Cross-replica account-edge request budget. The input is an authenticated
/// edge address and persistence stores only its keyed digest.
public protocol V2AccountEdgeClientRateLimiting: Sendable {
    func consume(address: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult
}

public struct V2PostgresAccountEdgeClientRateLimiter: V2AccountEdgeClientRateLimiting, Sendable {
    private let database: any Database
    private let policy: V2AccountEdgeClientRateLimitPolicy
    private let key: V2AccountEdgeClientRateLimitKey
    private let now: @Sendable () -> Date

    public init(
        database: any Database,
        policy: V2AccountEdgeClientRateLimitPolicy,
        key: V2AccountEdgeClientRateLimitKey,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.policy = policy
        self.key = key
        self.now = now
    }

    public func consume(
        address: V2AccountEdgeClientAddress
    ) async throws -> V2AccountEdgeClientRateLimitResult {
        let clientKey = key.digest(address)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2AccountEdgeClientRateLimitError.unavailable
            }
            let current = now()
            let lockKey = "v2-account-edge-client-rate:" + clientKey
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            guard let existing = try await sql.raw("SELECT window_started_at, request_count FROM im_v2.account_edge_client_rate_limits WHERE client_key = \(bind: clientKey) FOR UPDATE").first(decoding: RateLimitRow.self) else {
                try await sql.raw("INSERT INTO im_v2.account_edge_client_rate_limits (client_key, window_started_at, request_count, updated_at) VALUES (\(bind: clientKey), \(bind: current), 1, \(bind: current))").run()
                return .allowed
            }

            let elapsed = current.timeIntervalSince(existing.windowStartedAt)
            if elapsed >= policy.window {
                try await sql.raw("UPDATE im_v2.account_edge_client_rate_limits SET window_started_at = \(bind: current), request_count = 1, updated_at = \(bind: current) WHERE client_key = \(bind: clientKey)").run()
                return .allowed
            }
            guard existing.requestCount < policy.maximumRequests else {
                return .rateLimited(
                    retryAfterSeconds: max(1, Int(ceil(policy.window - elapsed)))
                )
            }
            try await sql.raw("UPDATE im_v2.account_edge_client_rate_limits SET request_count = request_count + 1, updated_at = \(bind: current) WHERE client_key = \(bind: clientKey)").run()
            return .allowed
        }
    }

    /// High-cardinality pseudonymous keys are reclaimed independently from
    /// request latency. Multiple replicas may run this bounded sweep.
    @discardableResult
    public func purgeExpired(limit: Int) async throws -> Int {
        guard limit > 0, let sql = database as? any SQLDatabase else {
            throw V2AccountEdgeClientRateLimitError.unavailable
        }
        let expiredBefore = now().addingTimeInterval(-policy.window)
        let row = try await sql.raw("""
            WITH expired AS (
                SELECT client_key
                FROM im_v2.account_edge_client_rate_limits
                WHERE updated_at < \(bind: expiredBefore)
                ORDER BY updated_at
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            ), deleted AS (
                DELETE FROM im_v2.account_edge_client_rate_limits AS rate
                USING expired
                WHERE rate.client_key = expired.client_key
                RETURNING 1
            )
            SELECT COUNT(*)::bigint AS value FROM deleted
            """).first(decoding: RateLimitCountRow.self)
        return Int(row?.value ?? 0)
    }
}

private struct RateLimitRow: Decodable {
    let windowStartedAt: Date
    let requestCount: Int

    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case requestCount = "request_count"
    }
}

private struct RateLimitCountRow: Decodable { let value: Int64 }
