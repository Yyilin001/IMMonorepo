import Foundation

/// 数据库工作准入分类；原始字符串同时用作固定的指标标签。
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
        sync: V2DatabaseWorkAdmissionClassSnapshot
    ) {
        self.foregroundWrite = foregroundWrite
        self.foregroundControlWrite = foregroundControlWrite
        self.interactiveRead = interactiveRead
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

/// 在进入 Fluent 连接池等待之前，按工作类别实施进程内有界准入。
///
/// 消息写入、控制写入与交互读取分别排队，但共享三类预留之和形成的前台容量。
/// 允许借用空闲预留；释放许可时优先照顾尚未达到预留的排队类别，同等条件下轮转选择。
/// 同步工作使用独立容量。不会为重新平衡而抢占或取消已经获准的数据库操作。
///
/// 每类等待队列在 actor 内以双向链表维护，等待者由 UUID 索引。授予、超时和取消都先
/// 移除等待者再恢复 continuation，后到的终止事件找不到记录时不再恢复，避免重复完成。
/// 因此授予、超时与取消都是 O(1)，即便在 2,000+ 等待者的压测上限下依然如此。
/// 控制器只管理许可，数据库操作与每次获准后的配对释放由调用方负责。
public actor V2DatabaseWorkAdmissionController {
    /// 一个排队请求及其链表位置；超时任务仅在请求仍排队时有效。
    private struct Waiter: Sendable {
        let workClass: V2DatabaseWorkClass
        let continuation: CheckedContinuation<V2DatabaseWorkAdmissionResult, Never>
        let enqueuedAt: ContinuousClock.Instant
        var previous: UUID?
        var next: UUID?
        var timeoutTask: Task<Void, Never>?
    }

    /// 单个类别的链表端点、压力计数和累计指标，全部由所属 actor 隔离。
    private struct Lane: Sendable {
        var inFlight = 0
        var head: UUID?
        var tail: UUID?
        var queued = 0
        var admittedRequests: UInt64 = 0
        var queueFullRejections: UInt64 = 0
        var timeoutRejections: UInt64 = 0
        var cancelledRequests: UInt64 = 0
        var queueWaitSamples: UInt64 = 0
        var queueWaitMillisecondsSum: UInt64 = 0
        var queueWaitBuckets: [V2DatabaseWorkAdmissionWaitBucket: UInt64] = [:]
    }

    private let policy: V2DatabaseWorkAdmissionPolicy
    private let clock = ContinuousClock()
    private var foregroundWrite = Lane()
    private var foregroundControlWrite = Lane()
    private var interactiveRead = Lane()
    private var sync = Lane()
    private var waiters: [UUID: Waiter] = [:]
    /// 下一次同优先级选择的轮转起点；只在候选类别已经按预留需求筛选后使用。
    private var nextForegroundTieBreak: V2DatabaseWorkClass = .foregroundWrite

    /// 创建所有类别均为空的准入控制器。
    ///
    /// - Parameter policy: 生命周期内固定使用的容量、排队上限和等待期限。
    public init(policy: V2DatabaseWorkAdmissionPolicy) {
        self.policy = policy
    }

    /// 为指定类别申请一个数据库工作许可，必要时进入有界 FIFO 队列等待。
    ///
    /// 有可用容量且本类无人排队时立即获准；否则先检查队列上限，再安装等待与取消处理。
    /// 取消仅作用于仍在队列中的请求：立即获准路径不检查取消，已授予许可也不会自动撤回。
    /// 因此调用方无论随后成功、失败还是取消，只要结果为获准，都必须配对释放一次。
    ///
    /// - Parameter workClass: 本次工作所属类别，后续释放必须使用同一类别。
    /// - Returns: 获准、队列满或超时拒绝，或排队期间取消；本方法不抛出取消错误。
    public func acquire(
        _ workClass: V2DatabaseWorkClass
    ) async -> V2DatabaseWorkAdmissionResult {
        if canAcquire(workClass), lane(for: workClass).queued == 0 {
            admit(workClass)
            return .admitted
        }
        guard lane(for: workClass).queued < maximumQueued(for: workClass) else {
            mutateLane(for: workClass) { lane in
                lane.queueFullRejections = saturatingIncrement(lane.queueFullRejections)
            }
            return .rejected(.queueFull)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(waiterID, workClass: workClass, continuation: continuation)
            }
        } onCancel: {
            // Cancellation handlers are synchronous. This bounded task only
            // forwards one message to the owning actor and has no independent
            // lifecycle or side effect.
            Task { await self.cancel(waiterID) }
        }
    }

    /// 释放一个已持有许可，并尝试将容量交给下一位等待者。
    ///
    /// 释放前台类别时在三类前台队列间选择下一位；释放同步类别时只服务同步队列。
    /// 本方法不验证许可所有者，重复释放可能错误扣除其他请求的在途数，调用方必须保证配对。
    ///
    /// - Parameter workClass: 此前返回获准结果的工作类别。
    /// - Precondition: 对应类别的在途数必须大于零；每个获准结果恰好释放一次。
    public func release(_ workClass: V2DatabaseWorkClass) {
        precondition(lane(for: workClass).inFlight > 0)
        mutateLane(for: workClass) { $0.inFlight -= 1 }
        switch workClass {
        case .foregroundWrite, .foregroundControlWrite, .interactiveRead:
            grantNextForegroundIfPossible()
        case .sync:
            grantNextIfPossible(.sync)
        }
    }

    /// 读取当前 actor 内四类工作的统一状态，不重置累计计数。
    ///
    /// - Returns: 本次同步读取时的在途数、队列长度、累计结果与等待分布。
    public func snapshot() -> V2DatabaseWorkAdmissionSnapshot {
        .init(
            foregroundWrite: snapshot(foregroundWrite),
            foregroundControlWrite: snapshot(foregroundControlWrite),
            interactiveRead: snapshot(interactiveRead),
            sync: snapshot(sync)
        )
    }

    /// 将等待者加入对应类别队尾，创建超时任务，并处理入队时已经收到的取消信号。
    private func enqueue(
        _ waiterID: UUID,
        workClass: V2DatabaseWorkClass,
        continuation: CheckedContinuation<V2DatabaseWorkAdmissionResult, Never>
    ) {
        let previous = lane(for: workClass).tail
        waiters[waiterID] = .init(
            workClass: workClass,
            continuation: continuation,
            enqueuedAt: clock.now,
            previous: previous,
            next: nil,
            timeoutTask: nil
        )
        if let previous {
            waiters[previous]?.next = waiterID
        }
        mutateLane(for: workClass) { lane in
            if lane.head == nil { lane.head = waiterID }
            lane.tail = waiterID
            lane.queued += 1
        }
        let timeout = policy.timeout
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOut(waiterID)
        }
        waiters[waiterID]?.timeoutTask = timeoutTask
        if Task.isCancelled {
            cancel(waiterID)
        }
    }

    /// 在指定类别可取得容量时授予其队首一个许可，并取消该等待者的超时任务。
    private func grantNextIfPossible(_ workClass: V2DatabaseWorkClass) {
        guard canAcquire(workClass), let waiterID = lane(for: workClass).head,
              let waiter = removeWaiter(waiterID)
        else { return }
        admit(workClass)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .admitted)
    }

    /// 将一个可用前台许可授予所选类别的队首，预留需求优先，同级类别轮转。
    ///
    /// 该调度只分配已释放容量，不取消在途操作；移除等待者后先计入获准，再恢复调用方。
    private func grantNextForegroundIfPossible() {
        guard foregroundInFlight < foregroundCapacity,
              let workClass = nextForegroundWorkClass(),
              let waiterID = lane(for: workClass).head,
              let waiter = removeWaiter(waiterID)
        else { return }
        admit(workClass)
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .admitted)
    }

    /// 移除仍在队列中的超时请求，记录拒绝并恢复等待方；已完成请求保持不变。
    private func timeOut(_ waiterID: UUID) {
        guard let waiter = removeWaiter(waiterID) else { return }
        mutateLane(for: waiter.workClass) { lane in
            lane.timeoutRejections = saturatingIncrement(lane.timeoutRejections)
        }
        waiter.continuation.resume(returning: .rejected(.timeout))
    }

    /// 移除仍在队列中的取消请求，同时取消其超时任务并返回取消结果。
    private func cancel(_ waiterID: UUID) {
        guard let waiter = removeWaiter(waiterID) else { return }
        mutateLane(for: waiter.workClass) { lane in
            lane.cancelledRequests = saturatingIncrement(lane.cancelledRequests)
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .cancelled)
    }

    /// 按标识移除等待者、修复双向链表并记录等待耗时；已移除时返回 `nil`。
    private func removeWaiter(_ waiterID: UUID) -> Waiter? {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return nil }
        recordQueueWait(for: waiter)
        if let previous = waiter.previous {
            waiters[previous]?.next = waiter.next
        } else {
            mutateLane(for: waiter.workClass) { $0.head = waiter.next }
        }
        if let next = waiter.next {
            waiters[next]?.previous = waiter.previous
        } else {
            mutateLane(for: waiter.workClass) { $0.tail = waiter.previous }
        }
        mutateLane(for: waiter.workClass) { lane in
            precondition(lane.queued > 0)
            lane.queued -= 1
        }
        return waiter
    }

    /// 检查容量与借用规则；不检查本类队列是否为空，也不实际占用许可。
    private func canAcquire(_ workClass: V2DatabaseWorkClass) -> Bool {
        switch workClass {
        case .foregroundWrite:
            guard foregroundInFlight < foregroundCapacity else { return false }
            // A write keeps its own reservation. Above it, write work can use
            // otherwise idle peer capacity only while no peer is queued.
            return foregroundWrite.inFlight < policy.maximumForegroundWriteInFlight ||
                !hasQueuedForegroundPeer(of: .foregroundWrite)
        case .foregroundControlWrite:
            guard foregroundInFlight < foregroundCapacity else { return false }
            return foregroundControlWrite.inFlight < policy.maximumForegroundControlWriteInFlight ||
                !hasQueuedForegroundPeer(of: .foregroundControlWrite)
        case .interactiveRead:
            guard foregroundInFlight < foregroundCapacity else { return false }
            // Symmetric borrowing prevents a large send burst from leaving
            // room-log recovery permanently under-provisioned.
            return interactiveRead.inFlight < policy.maximumInteractiveReadInFlight ||
                !hasQueuedForegroundPeer(of: .interactiveRead)
        case .sync:
            return sync.inFlight < policy.maximumSyncInFlight
        }
    }

    /// 三个前台类别预留之和形成的共享容量硬上限。
    private var foregroundCapacity: Int {
        policy.maximumForegroundWriteInFlight +
            policy.maximumForegroundControlWriteInFlight +
            policy.maximumInteractiveReadInFlight
    }

    /// 三个前台类别当前占用的总许可数，用于共享容量检查。
    private var foregroundInFlight: Int {
        foregroundWrite.inFlight + foregroundControlWrite.inFlight + interactiveRead.inFlight
    }

    /// 优先选择尚未达到预留的非空前台队列；没有此类队列时在全部非空前台队列中轮转。
    private func nextForegroundWorkClass() -> V2DatabaseWorkClass? {
        let queued = foregroundWorkClasses.filter { lane(for: $0).head != nil }
        guard !queued.isEmpty else { return nil }
        let belowReservation = queued.filter {
            foregroundInFlight(for: $0) < foregroundReservation(for: $0)
        }
        return nextForegroundTieBreakClass(
            candidates: belowReservation.isEmpty ? queued : belowReservation
        )
    }

    /// 共享前台容量的固定类别顺序，也用于同级候选的轮转。
    private let foregroundWorkClasses: [V2DatabaseWorkClass] = [
        .foregroundWrite,
        .foregroundControlWrite,
        .interactiveRead
    ]

    /// 从轮转起点选择候选类别并推进起点；候选必须非空且至少包含一个已知前台类别。
    private func nextForegroundTieBreakClass(
        candidates: [V2DatabaseWorkClass]
    ) -> V2DatabaseWorkClass {
        precondition(!candidates.isEmpty)
        let start = foregroundWorkClasses.firstIndex(of: nextForegroundTieBreak) ?? 0
        for offset in 0..<foregroundWorkClasses.count {
            let candidate = foregroundWorkClasses[(start + offset) % foregroundWorkClasses.count]
            if candidates.contains(candidate) {
                let next = (foregroundWorkClasses.firstIndex(of: candidate)! + 1) % foregroundWorkClasses.count
                nextForegroundTieBreak = foregroundWorkClasses[next]
                return candidate
            }
        }
        preconditionFailure("foreground admission candidates must be known classes")
    }

    /// 读取指定类别的在途数，供前台候选的预留判断使用。
    private func foregroundInFlight(for workClass: V2DatabaseWorkClass) -> Int {
        lane(for: workClass).inFlight
    }

    /// 读取前台类别预留；同步类别不参与共享前台容量，传入会触发前置条件失败。
    private func foregroundReservation(for workClass: V2DatabaseWorkClass) -> Int {
        switch workClass {
        case .foregroundWrite: policy.maximumForegroundWriteInFlight
        case .foregroundControlWrite: policy.maximumForegroundControlWriteInFlight
        case .interactiveRead: policy.maximumInteractiveReadInFlight
        case .sync: preconditionFailure("Sync does not share foreground capacity")
        }
    }

    /// 判断除当前类别外是否有其他前台队列等待，用于限制超预留借用。
    private func hasQueuedForegroundPeer(of workClass: V2DatabaseWorkClass) -> Bool {
        foregroundWorkClasses.contains { $0 != workClass && lane(for: $0).queued > 0 }
    }

    /// 占用一个在途许可并以饱和方式增加累计获准计数；调用方须先检查容量。
    private func admit(_ workClass: V2DatabaseWorkClass) {
        mutateLane(for: workClass) { lane in
            lane.inFlight += 1
            lane.admittedRequests = saturatingIncrement(lane.admittedRequests)
        }
    }

    /// 按类别读取独立的队列长度上限。
    private func maximumQueued(for workClass: V2DatabaseWorkClass) -> Int {
        switch workClass {
        case .foregroundWrite: policy.maximumForegroundWriteQueued
        case .foregroundControlWrite: policy.maximumForegroundControlWriteQueued
        case .interactiveRead: policy.maximumInteractiveReadQueued
        case .sync: policy.maximumSyncQueued
        }
    }

    /// 读取指定类别当前的值类型状态副本。
    private func lane(for workClass: V2DatabaseWorkClass) -> Lane {
        switch workClass {
        case .foregroundWrite: foregroundWrite
        case .foregroundControlWrite: foregroundControlWrite
        case .interactiveRead: interactiveRead
        case .sync: sync
        }
    }

    /// 在当前 actor 隔离范围内同步修改指定类别状态，不跨越异步挂起点。
    private func mutateLane(
        for workClass: V2DatabaseWorkClass,
        _ mutation: (inout Lane) -> Void
    ) {
        switch workClass {
        case .foregroundWrite: mutation(&foregroundWrite)
        case .foregroundControlWrite: mutation(&foregroundControlWrite)
        case .interactiveRead: mutation(&interactiveRead)
        case .sync: mutation(&sync)
        }
    }

    /// 将单类内部状态复制为可跨并发域传递的指标快照。
    private func snapshot(_ lane: Lane) -> V2DatabaseWorkAdmissionClassSnapshot {
        .init(
            inFlight: lane.inFlight,
            queued: lane.queued,
            admittedRequests: lane.admittedRequests,
            queueFullRejections: lane.queueFullRejections,
            timeoutRejections: lane.timeoutRejections,
            cancelledRequests: lane.cancelledRequests,
            queueWait: .init(
                samples: lane.queueWaitSamples,
                sumMilliseconds: lane.queueWaitMillisecondsSum,
                cumulativeBuckets: lane.queueWaitBuckets
            )
        )
    }

    /// 对离队请求记录一次完整毫秒等待样本，并增加所有覆盖该值的累计桶。
    private func recordQueueWait(for waiter: Waiter) {
        let milliseconds = queueWaitMilliseconds(since: waiter.enqueuedAt)
        mutateLane(for: waiter.workClass) { lane in
            lane.queueWaitSamples = saturatingIncrement(lane.queueWaitSamples)
            lane.queueWaitMillisecondsSum = saturatingAdd(
                lane.queueWaitMillisecondsSum,
                milliseconds
            )
            for bucket in V2DatabaseWorkAdmissionWaitBucket.allCases where milliseconds <= UInt64(bucket.rawValue) {
                lane.queueWaitBuckets[bucket] = saturatingIncrement(
                    lane.queueWaitBuckets[bucket, default: 0]
                )
            }
        }
    }

    /// 计算从入队到当前单调时钟的完整毫秒数；非正耗时返回零，整数溢出饱和到最大值。
    private func queueWaitMilliseconds(since instant: ContinuousClock.Instant) -> UInt64 {
        let components = instant.duration(to: clock.now).components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let wholeSeconds = UInt64(components.seconds)
        let secondsMilliseconds = wholeSeconds.multipliedReportingOverflow(by: 1_000)
        guard !secondsMilliseconds.overflow else { return .max }
        let fractionalMilliseconds = UInt64(components.attoseconds / 1_000_000_000_000_000)
        return saturatingAdd(secondsMilliseconds.partialValue, fractionalMilliseconds)
    }

    /// 将累计指标递增一；达到 `UInt64.max` 后保持最大值。
    private func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    /// 将两个累计指标相加；溢出时返回 `UInt64.max`。
    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }
}
