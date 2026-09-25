import Foundation

/// 公开身份目录查询的限流策略。
///
/// 它描述单个时间窗口内允许的最大查询次数，作为公开身份检索的准入上限。
public struct V2PublicIdentityLookupRateLimitPolicy: Equatable, Sendable {
    /// 单个窗口内允许的最大查询次数。
    ///
    /// 必须为正，且严格小于 `Int32.max`。
    public let maximumQueries: Int
    /// 限流窗口长度，必须能被 PostgreSQL 的区间类型表示。
    public let window: TimeInterval

    /// 创建限流策略。
    ///
    /// PostgreSQL 以有符号 32 位整数存储 `query_count`，
    /// 因此在预算之上保留一个取值，用作「已饱和/已拒绝」的哨兵值。
    ///
    /// - Parameters:
    ///   - maximumQueries: 单个窗口内允许的最大查询次数。
    ///   - window: 限流窗口长度。
    /// - Throws: 次数非正、过大或窗口无法表示时抛出 `invalidPolicy`。
    public init(maximumQueries: Int, window: TimeInterval) throws {
        // PostgreSQL 以有符号 32 位整数存储 query_count。
        // 在预算之上保留一个值，作为达到上限／拒绝的哨兵值。
        guard maximumQueries > 0,
              maximumQueries < Int(Int32.max),
              v2RateLimitDurationIsRepresentable(window)
        else { throw V2PublicIdentityLookupRateLimitError.invalidPolicy }
        self.maximumQueries = maximumQueries
        self.window = window
    }
}

/// 公开身份目录限流策略的错误分类。
public enum V2PublicIdentityLookupRateLimitError: Error, Equatable, Sendable {
    /// 策略非法：次数非正、过大，或窗口无法被 PostgreSQL 区间表示。
    case invalidPolicy
}
