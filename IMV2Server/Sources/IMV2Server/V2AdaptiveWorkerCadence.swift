import Foundation

/// 为持久化后台任务计算有上限的指数退避，并缩小空闲时的探测批次。
///
/// 消息通知仅用于提前唤醒；即使通知丢失，调用方仍通过有界轮询发现持久化工作。
/// 有工作时恢复最小间隔，连续无工作时逐次加倍等待。该类型不监听通知、不执行等待，
/// 也不捕获错误；调用方自行决定失败轮次是否作为 `didWork: false` 反馈。
public struct V2AdaptiveWorkerCadence: Equatable, Sendable {
    /// 有工作后及首次无工作后采用的等待毫秒数。
    public let minimumIntervalMilliseconds: Int
    /// 连续空闲时的最大等待毫秒数；轮询不会因空闲而被永久停用。
    public let maximumIdleIntervalMilliseconds: Int

    private var consecutiveIdlePasses = 0

    /// 创建空闲退避策略，初始状态视为非空闲。
    ///
    /// - Parameters:
    ///   - minimumIntervalMilliseconds: 基础等待毫秒数，必须大于零。
    ///   - maximumIdleIntervalMilliseconds: 最大空闲等待毫秒数，默认 2,000。
    /// - Precondition: 最大等待时间必须不小于基础等待时间，基础等待时间必须为正数。
    public init(
        minimumIntervalMilliseconds: Int,
        maximumIdleIntervalMilliseconds: Int = 2_000
    ) {
        precondition(minimumIntervalMilliseconds > 0)
        precondition(maximumIdleIntervalMilliseconds >= minimumIntervalMilliseconds)
        self.minimumIntervalMilliseconds = minimumIntervalMilliseconds
        self.maximumIdleIntervalMilliseconds = maximumIdleIntervalMilliseconds
    }

    /// 最近一次反馈是否为无工作轮次；创建时和报告有效工作后均为 `false`。
    ///
    /// 调用方可据此将空闲探测并发度缩为一条领取通道；该属性自身不会调整并发度。
    public var isIdle: Bool { consecutiveIdlePasses > 0 }

    /// 计算本轮领取批次上限，使空闲恢复时先用单条记录探测积压。
    ///
    /// 仅降低并发度仍可能让一条通道领取大批记录，直到整批完成才报告工作。
    /// 单条探测可使调用方在下一轮尽早恢复正常批次与并发度。
    ///
    /// - Parameter configuredLimit: 非空闲时允许领取的记录数上限，必须大于零。
    /// - Returns: 空闲时返回 `1`，否则返回原配置值；不改变当前退避状态。
    /// - Precondition: `configuredLimit` 必须大于零。
    public func claimLimit(configuredLimit: Int) -> Int {
        precondition(configuredLimit > 0)
        return isIdle ? 1 : configuredLimit
    }

    /// 根据本轮是否有工作推进退避状态，并计算下一次轮询延迟。
    ///
    /// 第一次无工作返回基础间隔，之后按 2 倍增长，指数最大为 20，并受最大间隔限制。
    /// 乘法溢出时直接采用最大间隔。报告有效工作会立即清空连续空闲计数。
    ///
    /// - Parameter didWork: 本轮是否完成有效工作；错误是否算作无工作由调用方决定。
    /// - Returns: 不超过最大空闲间隔的等待时长；本方法不会实际休眠。
    public mutating func delayAfterPass(didWork: Bool) -> Duration {
        if didWork {
            consecutiveIdlePasses = 0
            return .milliseconds(minimumIntervalMilliseconds)
        }

        consecutiveIdlePasses = min(consecutiveIdlePasses + 1, 30)
        let exponent = min(consecutiveIdlePasses - 1, 20)
        let multiplier = 1 << exponent
        let (candidate, overflowed) = minimumIntervalMilliseconds.multipliedReportingOverflow(by: multiplier)
        return .milliseconds(min(overflowed ? maximumIdleIntervalMilliseconds : candidate, maximumIdleIntervalMilliseconds))
    }
}
