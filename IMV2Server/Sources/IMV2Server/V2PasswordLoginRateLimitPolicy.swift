import Foundation

/// 账号标识登录失败限流策略，参数由部署方提供。
///
/// 代码刻意不提供默认值：运维必须按自身恢复流程与支持策略选择合适参数，
/// 以免默认值掩盖未配置的部署。
public struct V2PasswordLoginRateLimitPolicy: Equatable, Sendable {
    /// 窗口内允许的最大失败次数。
    public let maximumFailures: Int
    /// 失败计数窗口长度。
    public let window: TimeInterval
    /// 达到上限后的锁定时长。
    public let lockout: TimeInterval

    /// 校验并保存限流策略。
    ///
    /// - Parameters:
    ///   - maximumFailures: 窗口内允许的最大失败次数，需大于零且不超过 `Int32.max`。
    ///   - window: 失败计数窗口长度，需可表示为整秒且能编码为 PostgreSQL 时间戳。
    ///   - lockout: 锁定时长，需可表示为整秒且能编码为 PostgreSQL 时间戳。
    /// - Throws: 任一参数越界时抛出 ``V2PasswordLoginRateLimitError/invalidPolicy``。
    public init(maximumFailures: Int, window: TimeInterval, lockout: TimeInterval) throws {
        guard maximumFailures > 0, maximumFailures <= Int(Int32.max),
              v2RateLimitDurationIsRepresentable(window),
              v2RateLimitDurationIsRepresentable(lockout) else {
            throw V2PasswordLoginRateLimitError.invalidPolicy
        }
        self.maximumFailures = maximumFailures
        self.window = window
        self.lockout = lockout
    }
}

/// 账号标识登录限流错误。
public enum V2PasswordLoginRateLimitError: Error, Equatable, Sendable {
    /// 策略参数不满足取值范围要求。
    case invalidPolicy
    /// 限流存储当前不可用，调用方不能据此放行登录。
    case unavailable
}
