import IMV2ServerContracts
import Foundation


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
        let purpose: V2InteractiveReadAdmissionPurpose
        let continuation: CheckedContinuation<V2DatabaseWorkAdmissionResult, Never>
        let enqueuedAt: ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
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
    /// 供上游共享排队器沿用同一等待预算，避免进入本控制器时重新起算。
    public nonisolated let maximumQueueWait: Duration
    /// Scheduling demand may cover this capacity, but only acquire() grants
    /// permission to consume it. Other work classes keep their reservations.
    public nonisolated let maximumForegroundCapacity: Int
    private let clock = ContinuousClock()
    private var foregroundWrite = Lane()
    private var foregroundControlWrite = Lane()
    private var interactiveRead = Lane()
    private var interactiveOrdinary = Lane()
    private var interactiveCoverage = Lane()
    private var nextInteractivePurpose: V2InteractiveReadAdmissionPurpose = .coverageAuthorization
    private let interactiveReadCoverageReservedQueued: Int
    private var sync = Lane()
    private var waiters: [UUID: Waiter] = [:]
    /// 下一次同优先级选择的轮转起点；只在候选类别已经按预留需求筛选后使用。
    private var nextForegroundTieBreak: V2DatabaseWorkClass = .foregroundWrite

    /// 创建所有类别均为空的准入控制器。
    ///
    /// - Parameter policy: 生命周期内固定使用的容量、排队上限和等待期限。
    public init(policy: V2DatabaseWorkAdmissionPolicy, interactiveReadCoverageReservedQueued: Int = 0) {
        precondition(interactiveReadCoverageReservedQueued >= 0
            && interactiveReadCoverageReservedQueued <= max(0, policy.maximumInteractiveReadQueued - 1))
        self.interactiveReadCoverageReservedQueued = interactiveReadCoverageReservedQueued
        self.policy = policy
        self.maximumQueueWait = policy.timeout
        self.maximumForegroundCapacity = policy.maximumForegroundWriteInFlight
            + policy.maximumForegroundControlWriteInFlight + policy.maximumInteractiveReadInFlight
    }

    /// 为指定类别申请一个数据库工作许可，必要时进入有界 FIFO 队列等待。
    ///
    /// 有可用容量且本类无人排队时立即获准；否则先检查队列上限，再安装等待与取消处理。
    /// 取消仅作用于仍在队列中的请求：立即获准路径不检查取消，已授予许可也不会自动撤回。
    /// 因此调用方无论随后成功、失败还是取消，只要结果为获准，都必须配对释放一次。
    ///
    /// 调用方可提供原始单调截止时间；排队预算取该时间与策略等待期限中较早者。
    /// 截止时刻已过的请求不会占用许可或进入数据库工作。
    /// - Parameter workClass: 本次工作所属类别，后续释放必须使用同一类别。
    /// - Parameter callerDeadline: 原始调用截止时间，不从入队时重新计算。
    /// - Returns: 获准、队列满或超时拒绝，或排队期间取消；本方法不抛出取消错误。
    public func acquire(
        _ workClass: V2DatabaseWorkClass,
        callerDeadline: ContinuousClock.Instant? = nil,
        interactiveReadPurpose: V2InteractiveReadAdmissionPurpose = .ordinary
    ) async -> V2DatabaseWorkAdmissionResult {
        precondition(workClass == .interactiveRead || interactiveReadPurpose == .ordinary)
        let purpose = interactiveReadPurpose
        let policyDeadline = clock.now.advanced(by: policy.timeout)
        let deadline = callerDeadline.map { min($0, policyDeadline) } ?? policyDeadline
        guard deadline > clock.now else {
            mutateAccounting(for: workClass, purpose: purpose) { $0.timeoutRejections = saturatingIncrement($0.timeoutRejections) }
            return .rejected(.timeout)
        }
        if canAcquire(workClass), lane(for: workClass).queued == 0 {
            admit(workClass, purpose: purpose)
            return .admitted
        }
        let queueLimit = maximumQueued(for: workClass) -
            (workClass == .interactiveRead && purpose == .ordinary ? interactiveReadCoverageReservedQueued : 0)
        guard lane(for: workClass).queued < maximumQueued(for: workClass),
              workClass != .interactiveRead || purpose != .ordinary || interactiveOrdinary.queued < queueLimit else {
            mutateAccounting(for: workClass, purpose: purpose) { lane in
                lane.queueFullRejections = saturatingIncrement(lane.queueFullRejections)
            }
            return .rejected(.queueFull)
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(waiterID, workClass: workClass, purpose: purpose, deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            // 取消处理器是同步的。此有界任务只向所属 Actor 转发一条消息，
            // 没有独立生命周期或副作用。
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
    public func release(_ workClass: V2DatabaseWorkClass,
        interactiveReadPurpose: V2InteractiveReadAdmissionPurpose = .ordinary) {
        precondition(workClass == .interactiveRead || interactiveReadPurpose == .ordinary)
        if workClass == .interactiveRead {
            precondition(queueLane(for: workClass, purpose: interactiveReadPurpose).inFlight > 0)
        }
        precondition(lane(for: workClass).inFlight > 0)
        mutateAccounting(for: workClass, purpose: interactiveReadPurpose) { $0.inFlight -= 1 }
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
            sync: snapshot(sync),
            interactiveReadPurposes: [.ordinary: snapshot(interactiveOrdinary),
                .coverageAuthorization: snapshot(interactiveCoverage)]
        )
    }

    /// 将等待者加入对应类别队尾，创建超时任务，并处理入队时已经收到的取消信号。
    private func enqueue(
        _ waiterID: UUID,
        workClass: V2DatabaseWorkClass,
        purpose: V2InteractiveReadAdmissionPurpose,
        deadline: ContinuousClock.Instant,
        continuation: CheckedContinuation<V2DatabaseWorkAdmissionResult, Never>
    ) {
        guard deadline > clock.now else {
            mutateAccounting(for: workClass, purpose: purpose) { $0.timeoutRejections = saturatingIncrement($0.timeoutRejections) }
            continuation.resume(returning: .rejected(.timeout))
            return
        }
        let previous = queueLane(for: workClass, purpose: purpose).tail
        waiters[waiterID] = .init(
            workClass: workClass,
            purpose: purpose,
            continuation: continuation,
            enqueuedAt: clock.now,
            deadline: deadline,
            previous: previous,
            next: nil,
            timeoutTask: nil
        )
        if let previous {
            waiters[previous]?.next = waiterID
        }
        mutateQueueLane(for: workClass, purpose: purpose) { lane in
            if lane.head == nil { lane.head = waiterID }
            lane.tail = waiterID
            lane.queued += 1
        }
        if workClass == .interactiveRead { interactiveRead.queued += 1 }
        let timeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
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
        while canAcquire(workClass), let waiterID = nextWaiterID(for: workClass) {
            guard let waiter = waiters[waiterID] else { return }
            if waiter.deadline <= clock.now { timeOut(waiterID); continue }
            guard let granted = removeWaiter(waiterID) else { return }
            admit(workClass, purpose: granted.purpose)
            if workClass == .interactiveRead {
                nextInteractivePurpose = granted.purpose == .ordinary ? .coverageAuthorization : .ordinary
            }
            granted.timeoutTask?.cancel()
            granted.continuation.resume(returning: .admitted)
            return
        }
    }

    /// 将一个可用前台许可授予所选类别的队首，预留需求优先，同级类别轮转。
    ///
    /// 该调度只分配已释放容量，不取消在途操作；移除等待者后先计入获准，再恢复调用方。
    private func grantNextForegroundIfPossible() {
        while foregroundInFlight < foregroundCapacity,
              let workClass = nextForegroundWorkClass(),
              let waiterID = nextWaiterID(for: workClass) {
            guard let waiter = waiters[waiterID] else { return }
            if waiter.deadline <= clock.now { timeOut(waiterID); continue }
            guard let granted = removeWaiter(waiterID) else { return }
            admit(workClass, purpose: granted.purpose)
            if workClass == .interactiveRead {
                nextInteractivePurpose = granted.purpose == .ordinary ? .coverageAuthorization : .ordinary
            }
            granted.timeoutTask?.cancel()
            granted.continuation.resume(returning: .admitted)
            return
        }
    }

    /// 移除仍在队列中的超时请求，记录拒绝并恢复等待方；已完成请求保持不变。
    private func timeOut(_ waiterID: UUID) {
        guard let waiter = removeWaiter(waiterID) else { return }
        mutateAccounting(for: waiter.workClass, purpose: waiter.purpose) { lane in
            lane.timeoutRejections = saturatingIncrement(lane.timeoutRejections)
        }
        waiter.continuation.resume(returning: .rejected(.timeout))
    }

    /// 移除仍在队列中的取消请求，同时取消其超时任务并返回取消结果。
    private func cancel(_ waiterID: UUID) {
        guard let waiter = removeWaiter(waiterID) else { return }
        mutateAccounting(for: waiter.workClass, purpose: waiter.purpose) { lane in
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
            mutateQueueLane(for: waiter.workClass, purpose: waiter.purpose) { $0.head = waiter.next }
        }
        if let next = waiter.next {
            waiters[next]?.previous = waiter.previous
        } else {
            mutateQueueLane(for: waiter.workClass, purpose: waiter.purpose) { $0.tail = waiter.previous }
        }
        mutateQueueLane(for: waiter.workClass, purpose: waiter.purpose) { lane in
            precondition(lane.queued > 0)
            lane.queued -= 1
        }
        if waiter.workClass == .interactiveRead { interactiveRead.queued -= 1 }
        return waiter
    }

    /// 检查容量与借用规则；不检查本类队列是否为空，也不实际占用许可。
    private func canAcquire(_ workClass: V2DatabaseWorkClass) -> Bool {
        switch workClass {
        case .foregroundWrite:
            guard foregroundInFlight < foregroundCapacity else { return false }
            // 写入保留自身的预留容量。超出该份额后，
            // 只有其他类别没有排队时，才可借用其空闲容量。
            return foregroundWrite.inFlight < policy.maximumForegroundWriteInFlight ||
                !hasQueuedForegroundPeer(of: .foregroundWrite)
        case .foregroundControlWrite:
            guard foregroundInFlight < foregroundCapacity else { return false }
            return foregroundControlWrite.inFlight < policy.maximumForegroundControlWriteInFlight ||
                !hasQueuedForegroundPeer(of: .foregroundControlWrite)
        case .interactiveRead:
            guard foregroundInFlight < foregroundCapacity else { return false }
            // 对称借用可防止大量发送突发流量让房间日志恢复长期容量不足。
            return interactiveRead.inFlight < policy.maximumInteractiveReadInFlight ||
                !hasQueuedForegroundPeer(of: .interactiveRead)
        case .sync:
            return sync.inFlight < policy.maximumSyncInFlight
        }
    }

    /// 三个前台类别预留之和形成的共享容量硬上限。
    private var foregroundCapacity: Int {
        maximumForegroundCapacity
    }

    /// 三个前台类别当前占用的总许可数，用于共享容量检查。
    private var foregroundInFlight: Int {
        foregroundWrite.inFlight + foregroundControlWrite.inFlight + interactiveRead.inFlight
    }

    /// 优先选择尚未达到预留的非空前台队列；没有此类队列时在全部非空前台队列中轮转。
    private func nextForegroundWorkClass() -> V2DatabaseWorkClass? {
        let queued = foregroundWorkClasses.filter { lane(for: $0).queued > 0 }
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
    private func admit(_ workClass: V2DatabaseWorkClass, purpose: V2InteractiveReadAdmissionPurpose) {
        mutateAccounting(for: workClass, purpose: purpose) { lane in
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

    private func nextWaiterID(for workClass: V2DatabaseWorkClass) -> UUID? {
        guard workClass == .interactiveRead else { return lane(for: workClass).head }
        if interactiveOrdinary.head != nil && interactiveCoverage.head != nil {
            return nextInteractivePurpose == .ordinary ? interactiveOrdinary.head : interactiveCoverage.head
        }
        return interactiveCoverage.head ?? interactiveOrdinary.head
    }

    private func queueLane(for workClass: V2DatabaseWorkClass,
        purpose: V2InteractiveReadAdmissionPurpose) -> Lane {
        guard workClass == .interactiveRead else { return lane(for: workClass) }
        return purpose == .ordinary ? interactiveOrdinary : interactiveCoverage
    }

    private func mutateQueueLane(for workClass: V2DatabaseWorkClass,
        purpose: V2InteractiveReadAdmissionPurpose, _ mutation: (inout Lane) -> Void) {
        guard workClass == .interactiveRead else { mutateLane(for: workClass, mutation); return }
        if purpose == .ordinary { mutation(&interactiveOrdinary) }
        else { mutation(&interactiveCoverage) }
    }

    private func mutateAccounting(for workClass: V2DatabaseWorkClass,
        purpose: V2InteractiveReadAdmissionPurpose, _ mutation: (inout Lane) -> Void) {
        mutateLane(for: workClass, mutation)
        if workClass == .interactiveRead { mutateQueueLane(for: workClass, purpose: purpose, mutation) }
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
        mutateAccounting(for: waiter.workClass, purpose: waiter.purpose) { lane in
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
