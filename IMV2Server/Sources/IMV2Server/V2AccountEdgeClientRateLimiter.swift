import Fluent
import Foundation
import IMV2Core
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

public protocol V2AuthenticatedAccountRateLimiting: Sendable {
    func consume(
        identity: V2AuthenticatedConnection,
        scope: String,
        cost: Int
    ) async throws -> V2AccountEdgeClientRateLimitResult
}

public struct V2PostgresAccountEdgeClientRateLimiter: V2AccountEdgeClientRateLimiting, V2AuthenticatedAccountRateLimiting, Sendable {
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
        try await consume(clientKey: key.digest(address), cost: 1)
    }

    public func consume(
        identity: V2AuthenticatedConnection,
        scope: String,
        cost: Int
    ) async throws -> V2AccountEdgeClientRateLimitResult {
        guard cost > 0, cost <= policy.maximumRequests else {
            throw V2AccountEdgeClientRateLimitError.invalidPolicy
        }
        return try await consume(
            clientKey: key.digest(identity: identity, scope: scope),
            cost: cost
        )
    }

    private func consume(
        clientKey: String,
        cost: Int
    ) async throws -> V2AccountEdgeClientRateLimitResult {
        guard let sql = database as? any SQLDatabase else {
            throw V2AccountEdgeClientRateLimitError.unavailable
        }
        let current = now()
        let expiredBefore = current.addingTimeInterval(-policy.window)
        let maximumBeforeCharge = policy.maximumRequests - cost
        let saturatedCount = policy.maximumRequests + 1
        // The unique-key conflict row lock is the serialization boundary. A
        // saturated sentinel records denial without consuming an advisory
        // lock, SELECT FOR UPDATE, and a separate UPDATE round trip.
        guard let row = try await sql.raw("""
            INSERT INTO im_v2.account_edge_client_rate_limits AS rate
                (client_key, window_started_at, request_count, updated_at)
            VALUES
                (\(bind: clientKey), \(bind: current), \(bind: cost), \(bind: current))
            ON CONFLICT (client_key) DO UPDATE
            SET window_started_at = CASE
                    WHEN rate.window_started_at <= \(bind: expiredBefore) THEN \(bind: current)
                    ELSE rate.window_started_at
                END,
                request_count = CASE
                    WHEN rate.window_started_at <= \(bind: expiredBefore) THEN \(bind: cost)
                    WHEN rate.request_count <= \(bind: maximumBeforeCharge)
                        THEN rate.request_count + \(bind: cost)
                    ELSE \(bind: saturatedCount)
                END,
                updated_at = \(bind: current)
            RETURNING window_started_at, request_count
            """).first(decoding: RateLimitRow.self)
        else { throw V2AccountEdgeClientRateLimitError.unavailable }

        guard row.requestCount <= policy.maximumRequests else {
            let elapsed = max(0, current.timeIntervalSince(row.windowStartedAt))
            return .rateLimited(
                retryAfterSeconds: max(1, Int(ceil(policy.window - elapsed)))
            )
        }
        return .allowed
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
