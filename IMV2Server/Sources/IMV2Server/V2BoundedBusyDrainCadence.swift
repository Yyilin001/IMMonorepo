import Foundation

/// 一轮后台工作完成后，调用方应执行的调度动作。
///
/// 决策本身不执行休眠或让出操作；工作循环负责落实该动作并处理取消。
public enum V2WorkerCadenceDecision: Equatable, Sendable {
    /// 立即开始下一轮有界工作，不插入定时等待。
    case continueImmediately
    /// 先协作式让出执行机会，再继续工作；不保证其他任务一定先执行。
    case yield
    /// 本轮未报告有效工作，按关联的有界退避时长休眠。
    case sleep(Duration)
}

/// 为持续积压和空闲轮询选择不同的后台工作节奏。
///
/// 有效工作之后立即继续下一轮，避免在每个数据库批次之间插入空闲等待而限制吞吐。
/// 连续繁忙轮次达到次数或累计耗时预算时返回让出决策，未发现工作时采用指数退避。
/// 调用方仍须保证每轮事务和领取批次有界，并在轮次之间释放数据库连接。
/// 本类型只累计传入的耗时，不读取时钟，也不限制单轮任务本身的执行时间。
public struct V2BoundedBusyDrainCadence: Equatable, Sendable {
    /// 每个繁忙窗口允许的最大连续轮数；达到该值的轮次结束后让出。
    public let maximumConsecutiveBusyPasses: Int
    /// 每个繁忙窗口允许的累计轮次耗时；达到该值时让出。
    public let maximumConsecutiveBusyDuration: Duration

    private var idleCadence: V2AdaptiveWorkerCadence
    private var consecutiveBusyPasses = 0
    private var consecutiveBusyDuration: Duration = .zero

    /// 创建繁忙预算与空闲退避策略。
    ///
    /// - Parameters:
    ///   - minimumIdleIntervalMilliseconds: 首次空闲等待的毫秒数，必须大于零。
    ///   - maximumIdleIntervalMilliseconds: 空闲退避上限，必须不小于最小间隔，默认 2,000 毫秒。
    ///   - maximumConsecutiveBusyPasses: 让出前的连续繁忙轮数上限，必须大于零。
    ///   - maximumConsecutiveBusyDurationMilliseconds: 让出前的累计繁忙耗时上限，必须大于零。
    /// - Precondition: 上述间隔与预算满足约束；无效配置触发前置条件失败。
    public init(
        minimumIdleIntervalMilliseconds: Int,
        maximumIdleIntervalMilliseconds: Int = 2_000,
        maximumConsecutiveBusyPasses: Int,
        maximumConsecutiveBusyDurationMilliseconds: Int
    ) {
        precondition(maximumConsecutiveBusyPasses > 0)
        precondition(maximumConsecutiveBusyDurationMilliseconds > 0)
        idleCadence = .init(
            minimumIntervalMilliseconds: minimumIdleIntervalMilliseconds,
            maximumIdleIntervalMilliseconds: maximumIdleIntervalMilliseconds
        )
        self.maximumConsecutiveBusyPasses = maximumConsecutiveBusyPasses
        maximumConsecutiveBusyDuration = .milliseconds(
            maximumConsecutiveBusyDurationMilliseconds
        )
    }

    /// 记录本轮结果并返回下一步调度动作。
    ///
    /// 有工作时立即重置空闲退避，并累计繁忙轮数与耗时；任一预算达到上限即清空繁忙窗口
    /// 并返回让出决策。无工作时清空繁忙窗口，增加空闲退避，不累计该轮耗时。
    ///
    /// - Parameters:
    ///   - didWork: 本轮是否完成了调用方认可的有效工作。
    ///   - passDuration: 本轮测得的非负耗时，建议来自单调时钟。
    /// - Returns: 立即继续、协作式让出，或携带等待时长的休眠决策。
    /// - Precondition: `passDuration` 不得为负数。
    public mutating func decisionAfterPass(
        didWork: Bool,
        passDuration: Duration
    ) -> V2WorkerCadenceDecision {
        precondition(passDuration >= .zero)
        guard didWork else {
            resetBusyWindow()
            return .sleep(idleCadence.delayAfterPass(didWork: false))
        }

        // Reset an idle backoff immediately, but do not use its nonzero busy
        // delay: a busy pass is followed by another bounded claim.
        _ = idleCadence.delayAfterPass(didWork: true)
        if consecutiveBusyPasses < Int.max {
            consecutiveBusyPasses += 1
        }
        consecutiveBusyDuration += passDuration
        guard consecutiveBusyPasses >= maximumConsecutiveBusyPasses ||
                consecutiveBusyDuration >= maximumConsecutiveBusyDuration
        else {
            return .continueImmediately
        }
        resetBusyWindow()
        return .yield
    }

    /// 清空繁忙预算的累计值，保留独立的空闲退避状态。
    private mutating func resetBusyWindow() {
        consecutiveBusyPasses = 0
        consecutiveBusyDuration = .zero
    }
}
