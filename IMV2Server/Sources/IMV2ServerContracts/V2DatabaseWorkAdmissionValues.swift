import Foundation

/// 数据库工作准入分类；原始字符串同时用作固定的指标标签。
/// Trusted server-side classification; never decoded from client input.
public enum V2InteractiveReadAdmissionPurpose: String, CaseIterable, Sendable {
    case ordinary
    case coverageAuthorization = "coverage_authorization"
}

public enum V2DatabaseWorkClass: String, CaseIterable, Sendable {
    /// 让客户端可见状态持久化的消息写入；拥有独立排队预算与前台容量预留。
    case foregroundWrite = "foreground_write"
    /// 打开私聊等控制面写入，与已打开会话的消息写入分开预留容量。
    case foregroundControlWrite = "foreground_control_write"
    /// 已打开界面需要及时返回的读取，例如房间日志拉取。
    case interactiveRead = "interactive_read"
    /// 同步工作，使用独立于三类前台工作的容量和队列。
    case sync
}

/// 准入队列等待时间的固定累积直方图桶，原始值为含端点的毫秒上界。
public enum V2DatabaseWorkAdmissionWaitBucket: Int, CaseIterable, Sendable {
    /// 等待时间不超过 1 毫秒的累计样本。
    case milliseconds1 = 1
    /// 等待时间不超过 5 毫秒的累计样本。
    case milliseconds5 = 5
    /// 等待时间不超过 10 毫秒的累计样本。
    case milliseconds10 = 10
    /// 等待时间不超过 25 毫秒的累计样本。
    case milliseconds25 = 25
    /// 等待时间不超过 50 毫秒的累计样本。
    case milliseconds50 = 50
    /// 等待时间不超过 100 毫秒的累计样本。
    case milliseconds100 = 100
    /// 等待时间不超过 250 毫秒的累计样本。
    case milliseconds250 = 250
    /// 等待时间不超过 500 毫秒的累计样本。
    case milliseconds500 = 500
    /// 等待时间不超过 1,000 毫秒的累计样本。
    case milliseconds1_000 = 1_000
    /// 等待时间不超过 5,000 毫秒的累计样本。
    case milliseconds5_000 = 5_000
}

/// 已离开准入等待队列的请求所形成的累计耗时统计。
///
/// 控制器对获准、超时和取消的排队请求都记录样本；立即获准或队列满拒绝不产生等待样本。
/// 各桶包含所有不超过其上界的样本，不是互斥的区间计数。
public struct V2DatabaseWorkAdmissionWaitSnapshot: Equatable, Sendable {
    /// 已完成等待的样本总数，包含超过最大有限桶上界的样本。
    public let samples: UInt64
    /// 等待耗时的累计完整毫秒数；控制器生成时采用饱和加法。
    public let sumMilliseconds: UInt64
    private let cumulativeBuckets: [V2DatabaseWorkAdmissionWaitBucket: UInt64]

    /// 从已汇总的数据构造快照，不校验样本数与各桶之间的一致性。
    ///
    /// - Parameters:
    ///   - samples: 已记录的总样本数。
    ///   - sumMilliseconds: 所有样本等待毫秒数之和。
    ///   - cumulativeBuckets: 各固定上界对应的累计样本数，缺失桶读取为零。
    public init(
        samples: UInt64,
        sumMilliseconds: UInt64,
        cumulativeBuckets: [V2DatabaseWorkAdmissionWaitBucket: UInt64]
    ) {
        self.samples = samples
        self.sumMilliseconds = sumMilliseconds
        self.cumulativeBuckets = cumulativeBuckets
    }

    /// 读取指定上界内的累计等待样本数。
    ///
    /// - Parameter bucket: 含端点的等待毫秒上界。
    /// - Returns: 对应的累计计数；构造时未提供该桶则返回零。
    public func count(atOrBelow bucket: V2DatabaseWorkAdmissionWaitBucket) -> UInt64 {
        cumulativeBuckets[bucket, default: 0]
    }
}

/// 请求尚未取得数据库工作许可时的拒绝原因。
public enum V2DatabaseWorkRejectionReason: String, CaseIterable, Sendable {
    /// 当前工作类别的有界排队预算已耗尽，请求未进入队列。
    case queueFull = "queue_full"
    /// 已排队请求在配置的等待期限内未取得许可。
    case timeout
}

/// 一次准入请求的终止结果；只有获准结果需要调用方配对释放许可。
public enum V2DatabaseWorkAdmissionResult: Equatable, Sendable {
    /// 已占用对应类别的一个在途许可，不代表数据库连接或事务已经取得。
    case admitted
    /// 未授予许可，关联值说明队列满或等待超时。
    case rejected(V2DatabaseWorkRejectionReason)
    /// 请求在等待队列中被取消，未授予许可。
    case cancelled
}

/// 进程内数据库工作准入的容量预留、排队预算与等待期限。
///
/// 三类前台预留值相加形成共享容量；同类在途数可通过借用空闲容量超过自身预留。
/// 同步容量独立，队列上限按类别分别执行。该策略不设置 PostgreSQL 连接池大小或查询超时。
public struct V2DatabaseWorkAdmissionPolicy: Equatable, Sendable {
    /// 消息写入的前台容量预留，必须为正数；存在可借容量时允许超过此值。
    public let maximumForegroundWriteInFlight: Int
    /// 控制写入的前台容量预留，允许为零；零预留不禁止借用空闲前台容量。
    public let maximumForegroundControlWriteInFlight: Int
    /// 交互读取的前台容量预留，必须为正数。
    public let maximumInteractiveReadInFlight: Int
    /// 同步工作在途许可的独立硬上限，必须为正数。
    public let maximumSyncInFlight: Int
    /// 消息写入允许排队的请求数上限，必须为正数。
    public let maximumForegroundWriteQueued: Int
    /// 控制写入允许排队的请求数上限；零表示不能等待，但仍可立即获准。
    public let maximumForegroundControlWriteQueued: Int
    /// 交互读取允许排队的请求数上限，必须为正数。
    public let maximumInteractiveReadQueued: Int
    /// 同步工作允许排队的请求数上限，必须为正数。
    public let maximumSyncQueued: Int
    /// 请求入队后的最大等待时长，必须为正数；不限制获准后的数据库工作耗时。
    public let timeout: Duration

    /// 创建准入配置。
    ///
    /// - Parameters:
    ///   - maximumForegroundWriteInFlight: 消息写入预留许可数。
    ///   - maximumForegroundControlWriteInFlight: 控制写入预留许可数，默认零。
    ///   - maximumInteractiveReadInFlight: 交互读取预留许可数。
    ///   - maximumSyncInFlight: 同步工作独立的在途上限。
    ///   - maximumForegroundWriteQueued: 消息写入队列长度上限。
    ///   - maximumForegroundControlWriteQueued: 控制写入队列长度上限，默认零。
    ///   - maximumInteractiveReadQueued: 交互读取队列长度上限。
    ///   - maximumSyncQueued: 同步工作队列长度上限。
    ///   - timeout: 入队等待期限。
    /// - Precondition: 控制写入的两个额度不得为负；其他额度和等待期限必须为正。
    ///   三个前台在途额度之和须可由 `Int` 表示，以供控制器计算总容量。
    public init(
        maximumForegroundWriteInFlight: Int,
        maximumForegroundControlWriteInFlight: Int = 0,
        maximumInteractiveReadInFlight: Int,
        maximumSyncInFlight: Int,
        maximumForegroundWriteQueued: Int,
        maximumForegroundControlWriteQueued: Int = 0,
        maximumInteractiveReadQueued: Int,
        maximumSyncQueued: Int,
        timeout: Duration
    ) {
        precondition(maximumForegroundWriteInFlight > 0)
        precondition(maximumForegroundControlWriteInFlight >= 0)
        precondition(maximumInteractiveReadInFlight > 0)
        precondition(maximumSyncInFlight > 0)
        precondition(maximumForegroundWriteQueued > 0)
        precondition(maximumForegroundControlWriteQueued >= 0)
        precondition(maximumInteractiveReadQueued > 0)
        precondition(maximumSyncQueued > 0)
        precondition(timeout > .zero)
        self.maximumForegroundWriteInFlight = maximumForegroundWriteInFlight
        self.maximumForegroundControlWriteInFlight = maximumForegroundControlWriteInFlight
        self.maximumInteractiveReadInFlight = maximumInteractiveReadInFlight
        self.maximumSyncInFlight = maximumSyncInFlight
        self.maximumForegroundWriteQueued = maximumForegroundWriteQueued
        self.maximumForegroundControlWriteQueued = maximumForegroundControlWriteQueued
        self.maximumInteractiveReadQueued = maximumInteractiveReadQueued
        self.maximumSyncQueued = maximumSyncQueued
        self.timeout = timeout
    }
}

/// 单类数据库工作的当前压力与控制器生命周期内的累计结果。
public struct V2DatabaseWorkAdmissionClassSnapshot: Equatable, Sendable {
    /// 已获准且尚未释放的许可数。
    public let inFlight: Int
    /// 仍在等待许可的请求数。
    public let queued: Int
    /// 立即获准和排队后获准的累计请求数，不等于业务成功数。
    public let admittedRequests: UInt64
    /// 未入队即因队列满而被拒绝的累计请求数。
    public let queueFullRejections: UInt64
    /// 排队后因等待超时而被拒绝的累计请求数。
    public let timeoutRejections: UInt64
    /// 从等待队列移除的取消请求累计数，不统计获准后的取消。
    public let cancelledRequests: UInt64
    /// 离开队列的所有请求的等待耗时分布。
    public let queueWait: V2DatabaseWorkAdmissionWaitSnapshot

    /// 从类别计数构造快照，不检查各计数之间的关系。
    ///
    /// - Parameters:
    ///   - inFlight: 当前在途许可数。
    ///   - queued: 当前排队请求数。
    ///   - admittedRequests: 累计获准请求数。
    ///   - queueFullRejections: 累计队列满拒绝数。
    ///   - timeoutRejections: 累计超时拒绝数。
    ///   - cancelledRequests: 累计排队取消数。
    ///   - queueWait: 等待耗时统计，默认空分布。
    public init(
        inFlight: Int,
        queued: Int,
        admittedRequests: UInt64,
        queueFullRejections: UInt64,
        timeoutRejections: UInt64,
        cancelledRequests: UInt64,
        queueWait: V2DatabaseWorkAdmissionWaitSnapshot = .init(
            samples: 0,
            sumMilliseconds: 0,
            cumulativeBuckets: [:]
        )
    ) {
        self.inFlight = inFlight
        self.queued = queued
        self.admittedRequests = admittedRequests
        self.queueFullRejections = queueFullRejections
        self.timeoutRejections = timeoutRejections
        self.cancelledRequests = cancelledRequests
        self.queueWait = queueWait
    }

    /// 队列满和超时拒绝之和，不包含取消；溢出时返回 `UInt64.max`。
    public var rejectedRequests: UInt64 {
        let sum = queueFullRejections.addingReportingOverflow(timeoutRejections)
        return sum.overflow ? .max : sum.partialValue
    }

    /// 所有即时计数、累计计数和等待样本均为零的类别快照。
    public static let empty = Self(
        inFlight: 0,
        queued: 0,
        admittedRequests: 0,
        queueFullRejections: 0,
        timeoutRejections: 0,
        cancelledRequests: 0
    )
}

/// 四类数据库工作的同一控制器状态快照，供压力反馈与指标导出使用。
public struct V2DatabaseWorkAdmissionSnapshot: Equatable, Sendable {
    /// 消息写入类别的压力与累计结果。
    public let foregroundWrite: V2DatabaseWorkAdmissionClassSnapshot
    /// 控制写入类别的压力与累计结果。
    public let foregroundControlWrite: V2DatabaseWorkAdmissionClassSnapshot
    /// 交互读取类别的压力与累计结果。
    public let interactiveRead: V2DatabaseWorkAdmissionClassSnapshot
    /// A partition of the aggregate interactiveRead counters and capacity.
    public let interactiveReadPurposes: [V2InteractiveReadAdmissionPurpose: V2DatabaseWorkAdmissionClassSnapshot]
    /// 独立同步类别的压力与累计结果。
    public let sync: V2DatabaseWorkAdmissionClassSnapshot

    /// 组合四个工作类别的观测值。
    ///
    /// - Parameters:
    ///   - foregroundWrite: 消息写入快照。
    ///   - foregroundControlWrite: 控制写入快照，未提供时为全零快照。
    ///   - interactiveRead: 交互读取快照。
    ///   - sync: 同步快照。
    public init(
        foregroundWrite: V2DatabaseWorkAdmissionClassSnapshot,
        foregroundControlWrite: V2DatabaseWorkAdmissionClassSnapshot = .empty,
        interactiveRead: V2DatabaseWorkAdmissionClassSnapshot,
        sync: V2DatabaseWorkAdmissionClassSnapshot,
        interactiveReadPurposes: [V2InteractiveReadAdmissionPurpose: V2DatabaseWorkAdmissionClassSnapshot]? = nil
    ) {
        self.foregroundWrite = foregroundWrite
        self.foregroundControlWrite = foregroundControlWrite
        self.interactiveRead = interactiveRead
        self.interactiveReadPurposes = interactiveReadPurposes ?? [
            .ordinary: interactiveRead, .coverageAuthorization: .empty
        ]
        self.sync = sync
    }

    /// 消息写入的当前在途许可数。
    public var foregroundWriteInFlight: Int { foregroundWrite.inFlight }
    /// 控制写入的当前在途许可数。
    public var foregroundControlWriteInFlight: Int { foregroundControlWrite.inFlight }
    /// 交互读取的当前在途许可数。
    public var interactiveReadInFlight: Int { interactiveRead.inFlight }
    /// 同步的当前在途许可数。
    public var syncInFlight: Int { sync.inFlight }
    /// 消息写入的当前等待请求数。
    public var foregroundWriteQueued: Int { foregroundWrite.queued }
    /// 控制写入的当前等待请求数。
    public var foregroundControlWriteQueued: Int { foregroundControlWrite.queued }
    /// 交互读取的当前等待请求数。
    public var interactiveReadQueued: Int { interactiveRead.queued }
    /// 同步的当前等待请求数。
    public var syncQueued: Int { sync.queued }
    /// 消息写入、控制写入与交互读取的在途许可总数，不包含同步工作。
    ///
    /// 持久化后台任务可用此值感知前台压力，避免只关注消息写入而忽略同池读取。
    public var foregroundInFlight: Int {
        foregroundWrite.inFlight + foregroundControlWrite.inFlight + interactiveRead.inFlight
    }
    /// 三类前台工作的等待总数，包含控制写入，不包含同步。
    public var foregroundQueued: Int {
        foregroundWrite.queued + foregroundControlWrite.queued + interactiveRead.queued
    }
    /// 消息写入、交互读取和同步的等待数之和；当前实现不包含控制写入队列。
    public var queued: Int { foregroundWrite.queued + interactiveRead.queued + sync.queued }
    /// 四类工作的队列满与超时拒绝总数，不包含取消；累加溢出时饱和到 `UInt64.max`。
    public var rejectedRequests: UInt64 {
        let foreground = foregroundWrite.rejectedRequests.addingReportingOverflow(
            foregroundControlWrite.rejectedRequests
        )
        guard !foreground.overflow else { return .max }
        let foregroundWithReads = foreground.partialValue.addingReportingOverflow(
            interactiveRead.rejectedRequests
        )
        guard !foregroundWithReads.overflow else { return .max }
        let total = foregroundWithReads.partialValue.addingReportingOverflow(sync.rejectedRequests)
        return total.overflow ? .max : total.partialValue
    }

    /// 按固定工作分类选取对应的类别快照。
    ///
    /// - Parameter workClass: 需要读取的准入类别。
    /// - Returns: 该类别的在途、排队、累计结果和等待分布。
    public func value(
        for workClass: V2DatabaseWorkClass
    ) -> V2DatabaseWorkAdmissionClassSnapshot {
        switch workClass {
        case .foregroundWrite: foregroundWrite
        case .foregroundControlWrite: foregroundControlWrite
        case .interactiveRead: interactiveRead
        case .sync: sync
        }
    }
}
