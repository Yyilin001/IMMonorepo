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

/// 根据前台压力与连续饱和轮次，调整进程内扇出投递的领取并发度。
///
/// 初始并发度采用前台安全上限；没有前台压力且连续领取量达到阈值时，每次增加一条通道。
/// 观察到前台在途工作、排队工作或失败时立即恢复安全上限，并清空扩容计数。
/// 此控制器只提供数值决策，不创建任务、不取消在途任务，也不修改部署配置上限。
public struct V2AdaptiveFanoutDeliveryConcurrency: Equatable, Sendable {
    /// 部署配置允许的并发度硬上限。
    public let configuredMaximum: Int
    /// 有前台压力时采用的并发度，初始化时被截取为不超过部署上限。
    public let foregroundSafeMaximum: Int
    /// 增加一条投递通道前所需的连续饱和轮次数。
    public let saturatedPassesBeforeScaleUp: Int

    /// 非空闲轮次使用的当前并发度；空闲探测返回一条通道时可以保留此值。
    public private(set) var activeConcurrency: Int
    private var consecutiveSaturatedPasses = 0

    /// 创建前台压力感知的并发度控制器。
    ///
    /// - Parameters:
    ///   - configuredMaximum: 部署允许的最大通道数，必须大于零。
    ///   - foregroundSafeMaximum: 前台安全通道数，默认 4；超过部署上限时按部署上限保存。
    ///   - saturatedPassesBeforeScaleUp: 连续饱和多少轮后增加一条通道，默认 3。
    /// - Precondition: 所有参数必须大于零。
    public init(
        configuredMaximum: Int,
        foregroundSafeMaximum: Int = 4,
        saturatedPassesBeforeScaleUp: Int = 3
    ) {
        precondition(configuredMaximum > 0)
        precondition(foregroundSafeMaximum > 0)
        precondition(saturatedPassesBeforeScaleUp > 0)
        self.configuredMaximum = configuredMaximum
        self.foregroundSafeMaximum = min(configuredMaximum, foregroundSafeMaximum)
        self.saturatedPassesBeforeScaleUp = saturatedPassesBeforeScaleUp
        activeConcurrency = min(configuredMaximum, foregroundSafeMaximum)
    }

    /// 根据空闲状态和当前前台压力选择本轮领取并发度。
    ///
    /// 前台压力包含已准入的在途请求与排队请求，任一计数为正都会重置并发度及扩容计数。
    /// 空闲时返回单通道探测值；若没有前台压力，单纯空闲不会降低保存的当前并发度。
    ///
    /// - Parameters:
    ///   - isIdle: 是否正在进行空闲探测。
    ///   - foregroundInFlight: 当前已准入但尚未结束的前台工作数。
    ///   - foregroundQueued: 当前等待准入的前台工作数。
    /// - Returns: 空闲时为 `1`，否则为压力调整后的当前并发度。
    /// - Precondition: 两个前台计数均不得为负数。
    public mutating func concurrencyForPass(
        isIdle: Bool,
        foregroundInFlight: Int,
        foregroundQueued: Int
    ) -> Int {
        precondition(foregroundInFlight >= 0)
        precondition(foregroundQueued >= 0)
        if foregroundInFlight > 0 || foregroundQueued > 0 {
            activeConcurrency = foregroundSafeMaximum
            consecutiveSaturatedPasses = 0
        }
        return isIdle ? 1 : activeConcurrency
    }

    /// 根据已完成轮次的领取量和压力观测更新后续并发度。
    ///
    /// 只有本轮选用并发度等于当前并发度、尚未达到部署上限，且总领取量达到
    /// `selectedConcurrency * perLaneSaturationCount` 时，才累计一次饱和观测。
    /// 达到连续轮次门槛后增加一条通道并清零计数；稀疏轮次或不匹配的并发度会清零计数。
    /// 任意失败或前台压力会同时恢复前台安全并发度。
    ///
    /// - Parameters:
    ///   - selectedConcurrency: 本轮实际选择的领取通道数，必须大于零。
    ///   - claimedCount: 本轮所有通道合计领取的记录数，不得为负数。
    ///   - perLaneSaturationCount: 每条通道达到饱和所需的记录数，必须大于零。
    ///   - foregroundInFlight: 观测时已准入的前台工作数，不得为负数。
    ///   - foregroundQueued: 观测时排队的前台工作数，不得为负数。
    ///   - failed: 本轮是否失败，默认 `false`；失败不作为扩容依据。
    /// - Precondition: 计数满足上述约束，且通道数与单通道饱和记录数的乘积可由 `Int` 表示。
    public mutating func observePass(
        selectedConcurrency: Int,
        claimedCount: Int,
        perLaneSaturationCount: Int,
        foregroundInFlight: Int,
        foregroundQueued: Int,
        failed: Bool = false
    ) {
        precondition(selectedConcurrency > 0)
        precondition(claimedCount >= 0)
        precondition(perLaneSaturationCount > 0)
        precondition(foregroundInFlight >= 0)
        precondition(foregroundQueued >= 0)

        guard !failed, foregroundInFlight == 0, foregroundQueued == 0 else {
            activeConcurrency = foregroundSafeMaximum
            consecutiveSaturatedPasses = 0
            return
        }
        guard selectedConcurrency == activeConcurrency,
              activeConcurrency < configuredMaximum,
              claimedCount >= selectedConcurrency * perLaneSaturationCount
        else {
            consecutiveSaturatedPasses = 0
            return
        }
        consecutiveSaturatedPasses += 1
        guard consecutiveSaturatedPasses >= saturatedPassesBeforeScaleUp else { return }
        activeConcurrency += 1
        consecutiveSaturatedPasses = 0
    }
}
