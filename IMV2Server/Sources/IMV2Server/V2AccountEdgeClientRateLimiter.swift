import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 账号边缘限流判定结果。
public enum V2AccountEdgeClientRateLimitResult: Equatable, Sendable {
    /// 本次请求被允许并已计入窗口。
    case allowed
    /// 本次请求被拒绝，并给出建议重试秒数。
    case rateLimited(retryAfterSeconds: Int)
}

/// 跨副本共享的账号边缘请求预算能力。
///
/// 输入是已通过认证的边缘地址或连接身份，持久化只保存其带密钥摘要。
public protocol V2AccountEdgeClientRateLimiting: Sendable {
    /// 消耗一次按客户端地址计费的额度。
    ///
    /// - Parameter address: 已通过边缘校验的客户端地址。
    /// - Returns: 允许或限流结果。
    /// - Throws: 密钥派生、时刻编码或存储不可用时抛出。
    func consume(address: V2AccountEdgeClientAddress) async throws -> V2AccountEdgeClientRateLimitResult
}

/// 跨副本共享的已认证账号请求预算能力。
public protocol V2AuthenticatedAccountRateLimiting: Sendable {
    /// 消耗指定作用域与代价的已认证额度。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接的用户与设备身份。
    ///   - scope: 计费作用域，例如某类账号接口。
    ///   - cost: 本次消耗的额度，需大于零且不超过窗口上限。
    /// - Returns: 允许或限流结果。
    /// - Throws: 作用域或代价非法、时刻编码失败或存储不可用时抛出。
    func consume(
        identity: V2AuthenticatedConnection,
        scope: String,
        cost: Int
    ) async throws -> V2AccountEdgeClientRateLimitResult
}

/// 基于 PostgreSQL 的账号边缘限流实现。
///
/// 高基数假名键的回收与请求延迟相互独立，可由多个副本并发执行。
public struct V2PostgresAccountEdgeClientRateLimiter: V2AccountEdgeClientRateLimiting, V2AuthenticatedAccountRateLimiting, Sendable {
    private let database: any Database
    private let policy: V2AccountEdgeClientRateLimitPolicy
    private let key: V2AccountEdgeClientRateLimitKey
    private let now: @Sendable () -> Date

    /// 组合数据库、限流预算与假名化密钥。
    ///
    /// - Parameters:
    ///   - database: 存放限流窗口的数据库。
    ///   - policy: 固定窗口预算策略。
    ///   - key: 地址与身份的假名化密钥。
    ///   - now: 可注入的当前时刻读取函数。
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

    /// 按客户端地址消耗一次额度。
    ///
    /// - Parameter address: 已通过边缘校验的客户端地址。
    /// - Returns: 允许或限流结果。
    /// - Throws: 存储不可用或时刻编码失败时抛出
    ///   ``V2AccountEdgeClientRateLimitError/unavailable``。
    public func consume(
        address: V2AccountEdgeClientAddress
    ) async throws -> V2AccountEdgeClientRateLimitResult {
        try await consume(clientKey: key.digest(address), cost: 1)
    }

    /// 按已认证身份与作用域消耗指定代价的额度。
    ///
    /// - Parameters:
    ///   - identity: 已认证连接身份。
    ///   - scope: 计费作用域。
    ///   - cost: 本次消耗的额度，需大于零且不超过窗口上限。
    /// - Returns: 允许或限流结果。
    /// - Throws: 代价越界时抛出
    ///   ``V2AccountEdgeClientRateLimitError/invalidPolicy``；其余错误同地址计费路径。
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

    /// 以假名键执行一次窗口内计费。
    ///
    /// 唯一键冲突时的行锁即是串行化边界：饱和哨兵值只记录拒绝，
    /// 不再额外消耗咨询锁、`SELECT FOR UPDATE` 与单独的更新往返。
    /// 窗口已过期时以本次时刻开启新窗口并把计数重置为本次代价。
    ///
    /// - Parameters:
    ///   - clientKey: 已派生的假名键。
    ///   - cost: 本次消耗的额度。
    /// - Returns: 允许或限流结果。
    /// - Throws: 连接不支持 SQL、窗口起点不可编码或查询无结果时抛出
    ///   ``V2AccountEdgeClientRateLimitError/unavailable``。
    private func consume(
        clientKey: String,
        cost: Int
    ) async throws -> V2AccountEdgeClientRateLimitResult {
        guard let sql = database as? any SQLDatabase else {
            throw V2AccountEdgeClientRateLimitError.unavailable
        }
        let current = now()
        guard let expiredBefore = v2PostgresPastTimestamp(now: current, interval: policy.window) else {
            throw V2AccountEdgeClientRateLimitError.unavailable
        }
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
            guard let retryAfter = v2RateLimitRetryAfterSeconds(
                windowStartedAt: row.windowStartedAt, now: current, window: policy.window
            ) else { throw V2AccountEdgeClientRateLimitError.unavailable }
            return .rateLimited(
                retryAfterSeconds: retryAfter
            )
        }
        return .allowed
    }

    /// 回收已过期的假名键。
    ///
    /// 回收与请求延迟相互独立，多个副本可安全并行执行这一有界扫描。
    ///
    /// - Parameter limit: 本轮最多删除的键数量，需大于零。
    /// - Returns: 实际删除的键数量。
    /// - Throws: 上限非正、连接不支持 SQL 或窗口起点不可编码时抛出
    ///   ``V2AccountEdgeClientRateLimitError/unavailable``。
    @discardableResult
    public func purgeExpired(limit: Int) async throws -> Int {
        guard limit > 0, let sql = database as? any SQLDatabase else {
            throw V2AccountEdgeClientRateLimitError.unavailable
        }
        guard let expiredBefore = v2PostgresPastTimestamp(now: now(), interval: policy.window) else {
            throw V2AccountEdgeClientRateLimitError.unavailable
        }
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
    let requestCount: Int
    let windowStartedAt: V2PostgresTimestamp

    enum CodingKeys: String, CodingKey {
        case requestCount = "request_count"
        case windowStartedAt = "window_started_at"
    }
}

private struct RateLimitCountRow: Decodable { let value: Int64 }
