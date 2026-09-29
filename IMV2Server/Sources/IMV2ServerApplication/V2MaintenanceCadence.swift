import IMV2ServerContracts
/// 根据单调时钟为非实时维护任务计算固定调度周期。
///
/// 该值类型只判断到期时间，不启动任务、休眠或访问数据库。调度基于每轮开始时刻，
/// 因此一轮耗时超过间隔时，下一轮可以立即执行；调用方负责保存下一次截止时间。
/// 使用单调时钟可避免系统时间校准改变维护频率，持久化数据的过期判断仍应使用绝对日期。
public struct V2MaintenanceCadence: Equatable, Sendable {
    private let interval: Duration

    /// 创建固定周期的维护调度策略。
    ///
    /// - Parameter intervalMilliseconds: 严格大于零的轮次间隔，单位为毫秒。
    /// - Throws: 间隔不大于零时抛出 ``V2MaintenanceCadenceError/invalidInterval``。
    public init(intervalMilliseconds: Int) throws {
        guard intervalMilliseconds > 0 else { throw V2MaintenanceCadenceError.invalidInterval }
        interval = .milliseconds(intervalMilliseconds)
    }

    /// 判断维护任务是否应开始下一轮。
    ///
    /// - Parameters:
    ///   - now: 当前单调时钟时刻。
    ///   - nextScheduledAt: 调用方保存的下次截止时间；`nil` 表示尚未调度的首次执行。
    /// - Returns: 首次执行，或当前时刻已达到、超过截止时间时返回 `true`。
    ///
    /// 本方法不修改调度状态，也不会因返回 `true` 自动推进截止时间。
    public func isDue(now: ContinuousClock.Instant, nextScheduledAt: ContinuousClock.Instant?) -> Bool {
        guard let nextScheduledAt else { return true }
        return now >= nextScheduledAt
    }

    /// 从本轮开始时刻计算下轮的调度时间。
    ///
    /// - Parameter startedAt: 本轮实际开始的单调时钟时刻，而非本轮完成时间。
    /// - Returns: 在开始时刻上增加配置间隔所得的截止时间。
    public func nextScheduledAt(after startedAt: ContinuousClock.Instant) -> ContinuousClock.Instant {
        startedAt.advanced(by: interval)
    }
}

/// 固定维护周期的配置错误。
public enum V2MaintenanceCadenceError: Error, Equatable, Sendable {
    /// 周期间隔为零或负数，无法创建调度策略。
    case invalidInterval
}
