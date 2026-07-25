import Fluent
import IMV2Server
import SQLKit
import Vapor

public enum V2AccountEdgeClientRateLimitResult: Equatable, Sendable {
    case allowed
    case rateLimited(retryAfterSeconds: Int)
}

/// Side-effect boundary for a cross-replica account-edge request budget.
/// The input is already an authenticated-edge address and the persistence key
/// is a keyed digest, not that address itself.
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

    public func consume(address: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult {
        let clientKey = key.digest(address)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2AccountEdgeClientRateLimitError.unavailable
            }
            let current = now()
            // An edge-derived address can create a high-cardinality key. Keep
            // only active fixed-window rows with a bounded, SKIP LOCKED sweep;
            // this is intentionally part of the request transaction so the
            // account process needs no unmanaged cleanup task to uphold the
            // privacy/retention boundary.
            let expiredBefore = current.addingTimeInterval(-policy.window)
            try await sql.raw("""
                DELETE FROM im_v2.account_edge_client_rate_limits
                WHERE client_key IN (
                    SELECT client_key
                    FROM im_v2.account_edge_client_rate_limits
                    WHERE updated_at < \(bind: expiredBefore)
                    ORDER BY updated_at
                    LIMIT 100
                    FOR UPDATE SKIP LOCKED
                )
                """).run()
            let lockKey = "v2-account-edge-client-rate:" + clientKey
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            guard let existing = try await sql.raw("SELECT window_started_at, request_count FROM im_v2.account_edge_client_rate_limits WHERE client_key = \(bind: clientKey) FOR UPDATE").first(decoding: V2AccountEdgeClientRateLimitRow.self) else {
                try await sql.raw("INSERT INTO im_v2.account_edge_client_rate_limits (client_key, window_started_at, request_count, updated_at) VALUES (\(bind: clientKey), \(bind: current), 1, \(bind: current))").run()
                return .allowed
            }

            let elapsed = current.timeIntervalSince(existing.windowStartedAt)
            if elapsed >= policy.window {
                try await sql.raw("UPDATE im_v2.account_edge_client_rate_limits SET window_started_at = \(bind: current), request_count = 1, updated_at = \(bind: current) WHERE client_key = \(bind: clientKey)").run()
                return .allowed
            }
            guard existing.requestCount < policy.maximumRequests else {
                return .rateLimited(retryAfterSeconds: max(1, Int(ceil(policy.window - elapsed))))
            }
            try await sql.raw("UPDATE im_v2.account_edge_client_rate_limits SET request_count = request_count + 1, updated_at = \(bind: current) WHERE client_key = \(bind: clientKey)").run()
            return .allowed
        }
    }
}

/// Runs after `V2AccountEdgeAuthenticationMiddleware`. A route cannot reach
/// bcrypt, token parsing, or database business logic unless Caddy both proves
/// itself and supplies one syntactically valid client address.
public struct V2AccountEdgeClientRateLimitMiddleware: AsyncMiddleware, Sendable {
    private let limiter: any V2AccountEdgeClientRateLimiting

    public init(limiter: any V2AccountEdgeClientRateLimiting) {
        self.limiter = limiter
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let address = request.storage[V2AccountEdgeClientAddressStorageKey.self] else {
            throw Abort(.forbidden)
        }
        let result: V2AccountEdgeClientRateLimitResult
        do {
            result = try await limiter.consume(address: address)
        } catch is V2AccountEdgeClientRateLimitError {
            throw Abort(.serviceUnavailable)
        } catch {
            throw Abort(.serviceUnavailable)
        }
        switch result {
        case .allowed:
            // Deliberately outside the persistence-error mapping: a route's
            // public 4xx/5xx contract must retain its original status.
            return try await next.respond(to: request)
        case .rateLimited(let retryAfterSeconds):
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "Pragma", value: "no-cache")
            headers.replaceOrAdd(name: "Retry-After", value: String(retryAfterSeconds))
            return .init(status: .tooManyRequests, headers: headers)
        }
    }
}

struct V2AccountEdgeClientAddressStorageKey: StorageKey {
    typealias Value = V2AccountEdgeClientAddress
}

private struct V2AccountEdgeClientRateLimitRow: Decodable {
    let windowStartedAt: Date
    let requestCount: Int

    enum CodingKeys: String, CodingKey {
        case windowStartedAt = "window_started_at"
        case requestCount = "request_count"
    }
}
