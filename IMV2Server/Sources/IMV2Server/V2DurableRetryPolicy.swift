import Foundation

/// 持久化扇出工作在遇到可重试的工作器失败时的退避策略。
///
/// 重试次数耗尽只会把该行置为暂停并等待运维重放，
/// 不会把投递转成终态跳过，也不会释放来源房间的准入容量。
public struct V2DurableRetryPolicy: Sendable {
    /// 首次重试的基础延迟秒数。
    public let initialDelay: TimeInterval
    /// 单次重试延迟的上限秒数。
    public let maximumDelay: TimeInterval
    /// 允许的最大尝试次数，达到后暂停该行。
    public let maximumAttempts: Int
    /// 抖动比例，取值为 0 到 1。
    public let jitterFraction: Double

    /// 构造重试策略。
    ///
    /// - Parameters:
    ///   - initialDelay: 首次重试的基础延迟，需为正的有限值。
    ///   - maximumDelay: 延迟上限，需不小于 `initialDelay` 且为有限值。
    ///   - maximumAttempts: 最大尝试次数，需大于零。
    ///   - jitterFraction: 抖动比例，需落在 `0...1`。
    ///
    /// 参数不满足上述约束时直接失败，避免非法退避进入运行路径。
    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60,
        maximumAttempts: Int = 10,
        jitterFraction: Double = 0.2
    ) {
        precondition(initialDelay > 0 && initialDelay.isFinite)
        precondition(maximumDelay >= initialDelay && maximumDelay.isFinite)
        precondition(maximumAttempts > 0)
        precondition((0...1).contains(jitterFraction) && jitterFraction.isFinite)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
        self.jitterFraction = jitterFraction
    }

    /// 默认策略：1 秒起退避至 60 秒，最多 10 次，抖动 20%。
    public static let standard = Self()

    /// 按当前尝试次数给出下一步处置。
    ///
    /// 延迟以指数退避增长并按上限截断，再叠加由认领令牌决定的确定性抖动，
    /// 使同一行的多次重试保持可预测而不同行之间错开。
    ///
    /// - Parameters:
    ///   - attempt: 已失败的尝试次数，需大于零。
    ///   - claimToken: 本次认领令牌，用于计算确定性抖动。
    ///   - now: 本次失败时刻。
    /// - Returns: 下一次重试时刻，或达到最大尝试次数后的暂停处置。
    public func disposition(attempt: Int, claimToken: UUID, now: Date) -> V2DurableRetryDisposition {
        precondition(attempt > 0)
        guard attempt < maximumAttempts else { return .pause }
        let exponent = min(attempt - 1, 30)
        let exponential = initialDelay * Double(1 << exponent)
        let baseDelay = min(maximumDelay, exponential)
        let centeredJitter = (jitterUnit(for: claimToken) * 2) - 1
        let jitteredDelay = baseDelay * (1 + (centeredJitter * jitterFraction))
        return .retry(at: now.addingTimeInterval(min(maximumDelay, max(0.001, jitteredDelay))))
    }

    /// 由认领令牌前两字节导出的抖动系数，取值落在 `0...1`。
    ///
    /// - Parameter token: 本次认领令牌。
    /// - Returns: 归一化的抖动系数。
    private func jitterUnit(for token: UUID) -> Double {
        let bytes = token.uuid
        let value = UInt16(bytes.0) << 8 | UInt16(bytes.1)
        return Double(value) / Double(UInt16.max)
    }
}

/// 持久化工作的下一步处置。
public enum V2DurableRetryDisposition: Equatable, Sendable {
    /// 在指定时刻重试。
    case retry(at: Date)
    /// 暂停该行，等待运维重放。
    case pause
}
