import Foundation
import IMV2Core
import IMV2ActorContracts
import Synchronization

/// 面向可选进程本地投递加速的不挂起提交后边界。
///
/// 观察者只会收到数据库工作已成功完成的结果。
/// 它必须有界入队后立即返回；
/// 持久房间日志的可见性与请求成功从不依赖该观察者。
public protocol V2CommittedMessageBatchObserving: Sendable {
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome])
}

/// 由按房间建键的准入通道共享的单一内存上限。
///
/// 每条通道的 FIFO actor 仍各自负责排序与批次选择。
/// 只共享「保留请求数」可使一个不均匀但仍合法的房间哈希分布不会一边拒绝工作、
/// 一边让兄弟通道白白闲置大部分已配置的进程预算。
final class V2SharedSendMessagePendingCapacity: Sendable {
    private let maximum: Int
    /// 该计数器只是容量令牌，它不发布也不保护请求内存，因此使用 relaxed 内存序即可。
    ///
    /// CAS 循环在保持硬上限的同时，
    /// 又不至于让每条通道在入队和出队两端都经过一个存在竞争的睡眠互斥锁。
    private let reserved = Atomic<Int>(0)

    init(maximum: Int) {
        precondition(maximum > 0)
        self.maximum = maximum
    }

    func tryReserve() -> Bool {
        var current = reserved.load(ordering: .relaxed)
        while current < maximum {
            let result = reserved.compareExchange(
                expected: current,
                desired: current + 1,
                ordering: .relaxed
            )
            if result.exchanged { return true }
            current = result.original
        }
        return false
    }

    func release() {
        let result = reserved.wrappingSubtract(1, ordering: .relaxed)
        precondition(result.oldValue > 0, "shared pending capacity released twice")
    }
}

/// 所有发送通道共享一份所有者级的精确激活标识预算。
/// 最后一次 SQL 请求完成后，令牌仍保持预留，因为所有者的额度池
/// 可保留未用额度，直至该精确标识被正式退役。
final class V2SharedSendMessageActivationCapacity: Sendable {
    private let maximum: Int
    private let tokens = Mutex<Set<V2RoomActivationToken>>([])

    init(maximum: Int) {
        precondition(maximum > 0)
        self.maximum = maximum
    }

    func tryReserve(_ token: V2RoomActivationToken) -> Bool {
        tokens.withLock { reserved in
            // 一个房间始终路由到同一通道。该通道的 Actor 持有此槽位，
            // 直到所有待处理或执行中的请求结束，或精确退役将其清除。
            precondition(!reserved.contains(token), "activation reserved twice")
            guard reserved.count < maximum else { return false }
            reserved.insert(token)
            return true
        }
    }

    func release(_ token: V2RoomActivationToken) {
        tokens.withLock { reserved in
            precondition(reserved.remove(token) != nil, "activation released twice")
        }
    }
}

/// 命令接受的有界 FIFO 批处理边界。
///
/// 批处理器不持有任何房间状态，且在其持久路径报告命令完成之前，
/// 绝不会先行确认该命令。一个兼容子集可以共享同一个 `V2AtomicRoomWriteBatchStore` 事务，
/// 而预先分类为独立的房间走常规路径。
/// PostgreSQL 实现必须在 SQL 批次内保持每房间顺序。
/// 独立房间可以并行，但在首个批次提交或失败之前，不会有房间被接纳进第二个在途批次。
public actor V2SendMessageAdmissionBatcher: V2SendMessageAdmission {
    public struct Snapshot: Equatable, Sendable {
        public let pendingRequests: Int
        public let inFlightBatches: Int
        public let activeRooms: Int
        /// 该快照所代表的、彼此隔离的批处理通道数量。
        ///
        /// 单个 actor 报告 1；按房间建键的路由器会汇总其各通道，并在下方同时报告最繁忙通道。
        public let laneCount: Int
        public let busiestLanePendingRequests: Int
        public let busiestLaneInFlightBatches: Int
        /// 单调的阶段耗时，用于揭示延迟是累积在出队之前，还是在批次开始持久执行路径之后。
        public let dequeuedRequests: UInt64
        public let queueWaitMillisecondsTotal: UInt64
        public let queueWaitMillisecondsMax: UInt64
        public let completedBatches: UInt64
        public let batchExecutionMillisecondsTotal: UInt64
        public let batchExecutionMillisecondsMax: UInt64
        public let stagingQueueFullRejections: UInt64
        public let cancelledPendingRequests: UInt64
        /// 使用常规交互延迟预算的延迟刷新次数。
        ///
        /// 它刻意统计实际触发的计时器数量，而不是请求数，
        /// 使运维遥测不会把取消或整批刷新误当成额外的排队延迟。
        public let baseDelayFlushes: UInt64
        /// 在有界到达率检测器被满足之后，使用显式配置的高活跃预算的延迟刷新次数。
        public let highActivityDelayFlushes: UInt64
        /// 当前暂存的首个请求是否正以高活跃预算等待。
        ///
        /// 它仅供诊断；硬性延迟上限仍由已排定的计时器持有。
        public let highActivityDelayScheduled: Bool
        /// 包含两个或更多独立房间的原子追加尝试次数。
        ///
        /// 这些计数器刻意区分成功的集合写入与形态回退，
        /// 使运维可以衡量真实的 SQL 合并程度，而不是仅凭暂存延迟去推断。
        public let atomicBatchAttempts: UInt64
        public let atomicBatchCommitted: UInt64
        public let atomicBatchFallbacks: UInt64
        public let atomicBatchCommittedRequests: UInt64
        public let atomicBatchFallbackRequests: UInt64
        /// 权威存储在某个原子子集于任何持久提交之前回滚时所报告的、有界的原因计数。
        public let atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64]
        /// 同一房间中刻意排在首条命令之后、并在后续唯一房间波次中执行的命令数。
        public let sameRoomDeferredRequests: UInt64
        /// 在原子尝试之前就已确知需要走常规持久路径的请求。
        ///
        /// 它们不会让一个本可兼容的批次放弃其共享事务。
        public let atomicPreclassifiedIndividualRequests: UInt64
        /// 延迟后仍不足量的批次会直接派发，而不会先从存储抛出预期的不支持形态错误。
        public let singletonDispatches: UInt64

        public init(
            pendingRequests: Int,
            inFlightBatches: Int,
            activeRooms: Int,
            laneCount: Int = 1,
            busiestLanePendingRequests: Int? = nil,
            busiestLaneInFlightBatches: Int? = nil,
            dequeuedRequests: UInt64 = 0,
            queueWaitMillisecondsTotal: UInt64 = 0,
            queueWaitMillisecondsMax: UInt64 = 0,
            completedBatches: UInt64 = 0,
            batchExecutionMillisecondsTotal: UInt64 = 0,
            batchExecutionMillisecondsMax: UInt64 = 0,
            stagingQueueFullRejections: UInt64,
            cancelledPendingRequests: UInt64,
            baseDelayFlushes: UInt64,
            highActivityDelayFlushes: UInt64,
            highActivityDelayScheduled: Bool,
            atomicBatchAttempts: UInt64 = 0,
            atomicBatchCommitted: UInt64 = 0,
            atomicBatchFallbacks: UInt64 = 0,
            atomicBatchCommittedRequests: UInt64 = 0,
            atomicBatchFallbackRequests: UInt64 = 0,
            atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64] = [:],
            sameRoomDeferredRequests: UInt64 = 0,
            atomicPreclassifiedIndividualRequests: UInt64 = 0,
            singletonDispatches: UInt64 = 0
        ) {
            self.pendingRequests = pendingRequests
            self.inFlightBatches = inFlightBatches
            self.activeRooms = activeRooms
            self.laneCount = laneCount
            self.busiestLanePendingRequests = busiestLanePendingRequests ?? pendingRequests
            self.busiestLaneInFlightBatches = busiestLaneInFlightBatches ?? inFlightBatches
            self.dequeuedRequests = dequeuedRequests
            self.queueWaitMillisecondsTotal = queueWaitMillisecondsTotal
            self.queueWaitMillisecondsMax = queueWaitMillisecondsMax
            self.completedBatches = completedBatches
            self.batchExecutionMillisecondsTotal = batchExecutionMillisecondsTotal
            self.batchExecutionMillisecondsMax = batchExecutionMillisecondsMax
            self.stagingQueueFullRejections = stagingQueueFullRejections
            self.cancelledPendingRequests = cancelledPendingRequests
            self.baseDelayFlushes = baseDelayFlushes
            self.highActivityDelayFlushes = highActivityDelayFlushes
            self.highActivityDelayScheduled = highActivityDelayScheduled
            self.atomicBatchAttempts = atomicBatchAttempts
            self.atomicBatchCommitted = atomicBatchCommitted
            self.atomicBatchFallbacks = atomicBatchFallbacks
            self.atomicBatchCommittedRequests = atomicBatchCommittedRequests
            self.atomicBatchFallbackRequests = atomicBatchFallbackRequests
            self.atomicBatchFallbackReasons = atomicBatchFallbackReasons
            self.sameRoomDeferredRequests = sameRoomDeferredRequests
            self.atomicPreclassifiedIndividualRequests = atomicPreclassifiedIndividualRequests
            self.singletonDispatches = singletonDispatches
        }
    }

    public struct Configuration: Equatable, Sendable {
        /// 一个有界的进程本地检测器，只有持续到达之后才允许稍长一点的等待。
        ///
        /// 它绝不改变 FIFO、房间串行化、暂存上限或持久写入契约。
        public struct AdaptiveDelayPolicy: Equatable, Sendable {
            public let highActivityMaximumDelay: Duration
            public let minimumRequestsInWindow: Int
            public let observationWindow: Duration

            public init(
                highActivityMaximumDelay: Duration,
                minimumRequestsInWindow: Int,
                observationWindow: Duration
            ) {
                precondition(highActivityMaximumDelay > .zero)
                precondition(minimumRequestsInWindow > 0)
                precondition(observationWindow > .zero)
                self.highActivityMaximumDelay = highActivityMaximumDelay
                self.minimumRequestsInWindow = minimumRequestsInWindow
                self.observationWindow = observationWindow
            }
        }

        public let maximumBatchSize: Int
        public let maximumDelay: Duration
        /// 为 `nil` 时保留引入该策略之前完全相同的固定延迟行为。
        ///
        /// 配置的高活跃延迟必须严格长于基础延迟，
        /// 否则就是一条具有误导性、且不会带来任何批处理收益的配置。
        public let adaptiveDelayPolicy: AdaptiveDelayPolicy?
        public let maximumInFlightBatches: Int
        /// 等待成批的命令仍会保留在网关内存中。
        ///
        /// 必须对它单独设界：把数据库准入移到批次边界，
        /// 不能等于用一个无界队列替换一个原本有界的队列。
        public let maximumPendingRequests: Int
        /// 此批处理器保留的激活标识上限。获准通道会保留已完成的标识，
        /// 直到宿主执行器关闭额度池并明确退役该精确令牌。
        public let maximumTrackedActivations: Int

        public init(
            maximumBatchSize: Int,
            maximumDelay: Duration,
            adaptiveDelayPolicy: AdaptiveDelayPolicy? = nil,
            maximumInFlightBatches: Int = 1,
            maximumPendingRequests: Int = 1_024,
            maximumTrackedActivations: Int = 16_384
        ) {
            // 取值为一时兼容禁用追加批处理的部署：获准路径仍为每次写入设置围栏，
            // 但不会合并请求。
            precondition((1 ... 128).contains(maximumBatchSize))
            precondition(maximumDelay > .zero)
            precondition((1 ... 128).contains(maximumInFlightBatches))
            precondition(maximumPendingRequests > 0)
            precondition((1 ... 65_536).contains(maximumTrackedActivations))
            if let adaptiveDelayPolicy {
                precondition(adaptiveDelayPolicy.highActivityMaximumDelay > maximumDelay)
                precondition(adaptiveDelayPolicy.minimumRequestsInWindow <= maximumPendingRequests)
            }
            self.maximumBatchSize = maximumBatchSize
            self.maximumDelay = maximumDelay
            self.adaptiveDelayPolicy = adaptiveDelayPolicy
            self.maximumInFlightBatches = maximumInFlightBatches
            self.maximumPendingRequests = maximumPendingRequests
            self.maximumTrackedActivations = maximumTrackedActivations
        }
    }

    /// 以引用方式持有的队列节点。
    ///
    /// `V2RoomWriteRequest` 会保留数个写时复制的值，而续体本身也是引用计数的。
    /// 若把该节点作为值存进侵入式字典，
    /// 每次更新邻居链接都会复制整个请求并对那些字段做 retain/release。
    /// 该节点在仍被链接时绝不会离开本 actor，
    /// 因此就地修改两个链接能在不产生这些热路径 ARC 开销的前提下，保持相同的所有权与 FIFO 契约。
    // 出队后，Actor 会先清除两个可变链接，再将节点交给子任务。
    // 已链接的节点不会跨越隔离边界，已脱链的节点也不会再被修改，
    // 因而此处范围受限的非检查式遵循是安全的。
    private final class Pending: @unchecked Sendable {
        let id: UInt64
        let request: V2RoomWriteRequest
        let continuation: CheckedContinuation<V2SendMessageOutcome, any Error>?
        let granted: GrantedItem?
        let enqueuedAt: ContinuousClock.Instant
        var previousID: UInt64?
        var nextID: UInt64?

        init(
            id: UInt64,
            request: consuming V2RoomWriteRequest,
            continuation: CheckedContinuation<V2SendMessageOutcome, any Error>?,
            granted: GrantedItem? = nil,
            enqueuedAt: ContinuousClock.Instant,
            previousID: UInt64?,
            nextID: UInt64?
        ) {
            self.id = id
            self.request = request
            self.continuation = continuation
            self.granted = granted
            self.enqueuedAt = enqueuedAt
            self.previousID = previousID
            self.nextID = nextID
        }
    }

    private enum ScheduledDelay: Equatable, Sendable {
        case base
        case highActivity
        case granted
    }

    private struct GrantedItem: Sendable {
        let turnID: UUID
        let index: Int
        let token: V2RoomActivationToken
        let callDeadline: ContinuousClock.Instant
    }

    private struct GrantedTurn {
        let continuation: CheckedContinuation<[Result<V2SendMessageOutcome, any Error>], any Error>
        var results: [Result<V2SendMessageOutcome, any Error>?]
        var remaining: Int
    }

    private let store: any V2AtomicRoomWriteBatchStore
    private let actorGrantedStoreFactory: (@Sendable ([V2RoomActivationToken]) throws -> any V2AtomicRoomWriteBatchStore)?
    private let configuration: Configuration
    private let sharedPendingCapacity: V2SharedSendMessagePendingCapacity?
    private let sharedActivationCapacity: V2SharedSendMessageActivationCapacity?
    /// 侵入式 FIFO 存储让入队与取消保持 O(1)。
    ///
    /// 批次选择仍按到达顺序遍历暂存请求，
    /// 但不再为每个事务复制一到两次整个队列。
    private var pendingByID: [UInt64: Pending] = [:]
    private var pendingHeadID: UInt64?
    private var pendingTailID: UInt64?
    /// 队列节点标识绝不会离开本 actor，也不会跨重启存活。
    ///
    /// 单调递增值已经够用，并可避免仅为支持 O(1) 取消就为每条消息向操作系统索取安全熵。
    private var nextPendingID: UInt64 = 0
    private var pendingCount = 0
    private var flushTask: Task<Void, Never>?
    private var flushDeadline: ContinuousClock.Instant?
    private var flushGeneration: UInt64 = 0
    private var grantedTurns: [UUID: GrantedTurn] = [:]
    private var trackedActivations: [V2RoomActivationToken: Int] = [:]
    private var quarantinedActivations: Set<V2RoomActivationToken> = []
    private var retiringActivations: Set<V2RoomActivationToken> = []
    private var inFlightBatchCount = 0
    private var activeRoomIDs: Set<RoomID> = []
    private var stagingQueueFullRejections: UInt64 = 0
    private var cancelledPendingRequests: UInt64 = 0
    private var baseDelayFlushes: UInt64 = 0
    private var highActivityDelayFlushes: UInt64 = 0
    private var scheduledDelay: ScheduledDelay?
    private var atomicBatchAttempts: UInt64 = 0
    private var atomicBatchCommitted: UInt64 = 0
    private var atomicBatchFallbacks: UInt64 = 0
    private var atomicBatchCommittedRequests: UInt64 = 0
    private var atomicBatchFallbackRequests: UInt64 = 0
    private var atomicBatchFallbackReasons: [V2AtomicRoomWriteBatchError.Reason: UInt64] = [:]
    private var sameRoomDeferredRequests: UInt64 = 0
    private var atomicPreclassifiedIndividualRequests: UInt64 = 0
    private var singletonDispatches: UInt64 = 0
    private var dequeuedRequests: UInt64 = 0
    private var queueWaitMillisecondsTotal: UInt64 = 0
    private var queueWaitMillisecondsMax: UInt64 = 0
    private var completedBatches: UInt64 = 0
    private var batchExecutionMillisecondsTotal: UInt64 = 0
    private var batchExecutionMillisecondsMax: UInt64 = 0
    /// 使用单调时钟，使一次墙上时钟校正不会意外把批处理器置入高活跃模式，或让它永久停留其中。
    private let clock = ContinuousClock()
    private var recentArrivalInstants: [ContinuousClock.Instant] = []
    /// 有界到达窗口的逻辑头部。推进它是 O(1)；
    /// 偶发的压缩用来取代每次热追加都执行 `Array.removeFirst`。
    private var recentArrivalHead = 0

    /// 通用网关命令处理器不得在本批处理器拥有的请求之外再获取第二次前台写入许可。
    ///
    /// 真正的原子批次只会在其数据库事务开始之前，恰好获取一个许可。
    nonisolated public let managesForegroundWriteAdmission: Bool
    nonisolated public let publishesCommittedGroupEvents: Bool
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private let committedMessageObserver: (any V2CommittedMessageBatchObserving)?

    public init(
        store: any V2AtomicRoomWriteBatchStore,
        configuration: Configuration,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
        committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil,
        actorGrantedStore: PostgresV2RoomWriteStore? = nil
    ) {
        self.store = store
        if let actorGrantedStore {
            actorGrantedStoreFactory = { tokens in
                let scope = try V2RoomActivationWriteScope(tokens: tokens)
                return actorGrantedStore.usingActivationScope(scope)
            }
        } else {
            actorGrantedStoreFactory = nil
        }
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        self.committedMessageObserver = committedMessageObserver
        sharedPendingCapacity = nil
        sharedActivationCapacity = nil
        managesForegroundWriteAdmission = databaseWorkAdmission != nil
        publishesCommittedGroupEvents = committedMessageObserver != nil
    }

    /// 面向按房间建键路由器的内部构造路径。
    ///
    /// 把共享限流器排除在公开 API 之外，
    /// 使调用方不可能意外地把本应彼此独立的批处理器耦合在一起。
    ///
    /// - Parameters:
    ///   - store: 原子房间写入批次存储。
    ///   - configuration: 批处理配置。
    ///   - databaseWorkAdmission: 可选的数据库工作准入控制器。
    ///   - sharedPendingCapacity: 由各通道共享的待处理容量。
    ///   - committedMessageObserver: 可选的提交消息观察者。
    init(
        store: any V2AtomicRoomWriteBatchStore,
        configuration: Configuration,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController?,
        sharedPendingCapacity: V2SharedSendMessagePendingCapacity,
        sharedActivationCapacity: V2SharedSendMessageActivationCapacity,
        committedMessageObserver: (any V2CommittedMessageBatchObserving)?,
        actorGrantedStoreFactory: (@Sendable ([V2RoomActivationToken]) throws -> any V2AtomicRoomWriteBatchStore)?
    ) {
        self.store = store
        self.actorGrantedStoreFactory = actorGrantedStoreFactory
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
        self.committedMessageObserver = committedMessageObserver
        self.sharedPendingCapacity = sharedPendingCapacity
        self.sharedActivationCapacity = sharedActivationCapacity
        managesForegroundWriteAdmission = databaseWorkAdmission != nil
        publishesCommittedGroupEvents = committedMessageObserver != nil
    }

    /// 内部注入点使获准轮次的批次选择无需 PostgreSQL 即可测试。
    init(
        store: any V2AtomicRoomWriteBatchStore,
        configuration: Configuration,
        actorGrantedStoreFactory: @escaping @Sendable ([V2RoomActivationToken]) throws -> any V2AtomicRoomWriteBatchStore
    ) {
        self.store = store
        self.configuration = configuration
        self.actorGrantedStoreFactory = actorGrantedStoreFactory
        sharedPendingCapacity = nil
        sharedActivationCapacity = nil
        databaseWorkAdmission = nil
        committedMessageObserver = nil
        managesForegroundWriteAdmission = false
        publishesCommittedGroupEvents = false
    }

    deinit {
        flushTask?.cancel()
    }

    public func snapshot() async -> Snapshot {
        .init(
            pendingRequests: pendingCount,
            inFlightBatches: inFlightBatchCount,
            activeRooms: activeRoomIDs.count,
            dequeuedRequests: dequeuedRequests,
            queueWaitMillisecondsTotal: queueWaitMillisecondsTotal,
            queueWaitMillisecondsMax: queueWaitMillisecondsMax,
            completedBatches: completedBatches,
            batchExecutionMillisecondsTotal: batchExecutionMillisecondsTotal,
            batchExecutionMillisecondsMax: batchExecutionMillisecondsMax,
            stagingQueueFullRejections: stagingQueueFullRejections,
            cancelledPendingRequests: cancelledPendingRequests,
            baseDelayFlushes: baseDelayFlushes,
            highActivityDelayFlushes: highActivityDelayFlushes,
            highActivityDelayScheduled: scheduledDelay == .highActivity,
            atomicBatchAttempts: atomicBatchAttempts,
            atomicBatchCommitted: atomicBatchCommitted,
            atomicBatchFallbacks: atomicBatchFallbacks,
            atomicBatchCommittedRequests: atomicBatchCommittedRequests,
            atomicBatchFallbackRequests: atomicBatchFallbackRequests,
            atomicBatchFallbackReasons: atomicBatchFallbackReasons,
            sameRoomDeferredRequests: sameRoomDeferredRequests,
            atomicPreclassifiedIndividualRequests: atomicPreclassifiedIndividualRequests,
            singletonDispatches: singletonDispatches
        )
    }

    public func accept(
        _ request: consuming V2RoomWriteRequest
    ) async throws -> V2SendMessageOutcome {
        let ownedRequest = consume request
        try Task.checkCancellation()
        nextPendingID &+= 1
        precondition(nextPendingID != 0, "pending request identity exhausted")
        let pendingID = nextPendingID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reserved = if let sharedPendingCapacity {
                    sharedPendingCapacity.tryReserve()
                } else {
                    pendingCount < configuration.maximumPendingRequests
                }
                guard reserved else {
                    stagingQueueFullRejections &+= 1
                    continuation.resume(throwing: V2SendMessageAdmissionBatcherError.serverBusy)
                    return
                }
                enqueuePending(.init(
                    id: pendingID,
                    request: ownedRequest,
                    continuation: continuation,
                    enqueuedAt: clock.now,
                    previousID: nil,
                    nextID: nil
                ))
                recordArrival()
                if pendingCount == 1 {
                    scheduleDelayedFlush()
                }
                if pendingCount >= configuration.maximumBatchSize {
                    cancelDelayedFlush()
                    startAvailableBatchesIfPossible()
                }
                if Task.isCancelled {
                    cancelPendingRequest(pendingID)
                }
            }
        } onCancel: {
            // 取消处理器不能等待 Actor。此任务只请求所有者移除尚未开始
            // 持久化写入的请求，不会产生脱离所有者的业务副作用。
            Task { await self.cancelPendingRequest(pendingID) }
        }
    }

    /// 无需额外跨越 Actor 边界，即可将一个已获准的房间轮次入队。
    /// 即使同轮次后续 SQL 分区失败，返回的结果序列仍保留各项持久化结果。
    /// 接受后调用方的取消不能撤销可能已开始执行的写入。
    public func acceptGrantedTurn(
        _ sends: [V2PreparedActorSend],
        batchDeadline: ContinuousClock.Instant,
        callDeadline: ContinuousClock.Instant? = nil
    ) async throws -> [Result<V2SendMessageOutcome, any Error>] {
        try Task.checkCancellation()
        let effectiveCallDeadline = callDeadline ?? clock.now + .seconds(10)
        guard effectiveCallDeadline > clock.now else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        guard actorGrantedStoreFactory != nil,
              !sends.isEmpty,
              sends.count <= 128,
              let first = sends.first,
              sends.allSatisfy({
                  $0.token == first.token &&
                  $0.token.roomID == $0.request.command.roomID
              })
        else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        if quarantinedActivations.contains(first.token) {
            throw V2RoomCallFailure.outcomeUnknown
        }
        if retiringActivations.contains(first.token) {
            throw V2RoomCallFailure.notAccepted(.retired)
        }
        if trackedActivations[first.token] == nil &&
           trackedActivations.count >= configuration.maximumTrackedActivations {
            throw V2SendMessageAdmissionBatcherError.serverBusy
        }
        guard sends.count <= configuration.maximumPendingRequests else {
            throw V2SendMessageAdmissionBatcherError.serverBusy
        }
        return try await withCheckedThrowingContinuation { continuation in
            var reserved = 0
            if let sharedPendingCapacity {
                while reserved < sends.count && sharedPendingCapacity.tryReserve() { reserved += 1 }
                guard reserved == sends.count else {
                    for _ in 0..<reserved { sharedPendingCapacity.release() }
                    stagingQueueFullRejections &+= 1
                    continuation.resume(throwing: V2SendMessageAdmissionBatcherError.serverBusy)
                    return
                }
            } else if pendingCount > configuration.maximumPendingRequests - sends.count {
                stagingQueueFullRejections &+= 1
                continuation.resume(throwing: V2SendMessageAdmissionBatcherError.serverBusy)
                return
            }
            if trackedActivations[first.token] == nil,
               let sharedActivationCapacity,
               !sharedActivationCapacity.tryReserve(first.token) {
                for _ in 0..<reserved { sharedPendingCapacity?.release() }
                continuation.resume(throwing: V2SendMessageAdmissionBatcherError.serverBusy)
                return
            }
            let turnID = UUID()
            trackedActivations[first.token, default: 0] += sends.count
            grantedTurns[turnID] = .init(
                continuation: continuation,
                results: Array(repeating: nil, count: sends.count),
                remaining: sends.count
            )
            let enqueuedAt = clock.now
            for (index, send) in sends.enumerated() {
                nextPendingID &+= 1
                precondition(nextPendingID != 0, "pending request identity exhausted")
                enqueuePending(.init(
                    id: nextPendingID,
                    request: send.request,
                    continuation: nil,
                    granted: .init(turnID: turnID, index: index, token: send.token,
                        callDeadline: effectiveCallDeadline),
                    enqueuedAt: enqueuedAt,
                    previousID: nil,
                    nextID: nil
                ))
                recordArrival()
            }
            let hardDeadline = min(batchDeadline, effectiveCallDeadline)
            if pendingCount >= configuration.maximumBatchSize || hardDeadline <= clock.now {
                cancelDelayedFlush()
                startAvailableBatchesIfPossible()
            } else {
                let highActivity = isHighActivity()
                let localDelay = highActivity
                    ? configuration.adaptiveDelayPolicy!.highActivityMaximumDelay
                    : configuration.maximumDelay
                let localDeadline = clock.now + localDelay
                let selectedDeadline = min(localDeadline, hardDeadline)
                if flushDeadline == nil || selectedDeadline < flushDeadline! {
                    cancelDelayedFlush()
                    let reason: ScheduledDelay = selectedDeadline == hardDeadline
                        ? .granted : highActivity ? .highActivity : .base
                    installDelayedFlush(reason, until: selectedDeadline)
                }
            }
        }
    }

    /// 宿主执行器关闭或围栏化令牌并停止接受新调用后，调用此方法。
    /// 已排队的工作以结果未知结束；执行中的 SQL 会保留槽位直至完成。
    /// 宿主必须在关闭后拦截新调用，因为为保持标识表有界，
    /// 此处会移除已结算的令牌状态。
    public func retireActivation(_ token: V2RoomActivationToken) {
        guard trackedActivations[token] != nil else { return }
        retiringActivations.insert(token)
        purgeQueuedRequests(for: Set([token]))
        if trackedActivations[token] == 0 {
            trackedActivations.removeValue(forKey: token)
            quarantinedActivations.remove(token)
            retiringActivations.remove(token)
            sharedActivationCapacity?.release(token)
        }
    }

    private func scheduleDelayedFlush() {
        let selectedDelay: ScheduledDelay
        let delay: Duration
        if isHighActivity() {
            selectedDelay = .highActivity
            delay = configuration.adaptiveDelayPolicy!.highActivityMaximumDelay
        } else {
            selectedDelay = .base
            delay = configuration.maximumDelay
        }
        installDelayedFlush(selectedDelay, after: delay)
    }

    private func installDelayedFlush(
        _ selectedDelay: ScheduledDelay,
        after delay: Duration
    ) {
        installDelayedFlush(selectedDelay, until: clock.now + delay)
    }

    private func installDelayedFlush(
        _ selectedDelay: ScheduledDelay,
        until deadline: ContinuousClock.Instant
    ) {
        scheduledDelay = selectedDelay
        flushDeadline = deadline
        flushGeneration &+= 1
        let generation = flushGeneration
        flushTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch {
                return
            }
            await self?.delayedFlushFired(generation: generation)
        }
    }

    private func cancelDelayedFlush() {
        flushTask?.cancel()
        flushTask = nil
        flushDeadline = nil
        scheduledDelay = nil
        flushGeneration &+= 1
    }

    /// 在需要时缩短高活跃后继批次的刷新等待。
    ///
    /// 持续流量常会在前驱仍处于 PostgreSQL 时就开始填充后继。
    /// 高活跃计时器从那次首次到达就开始计时，
    /// 但若让后继在房间可用之后仍等满剩余时间，
    /// 就会给每次 ACK 增加数据库延迟以及近一整个聚合窗口。
    /// 因此改为保留一个小而有界的完成后再聚合机会：
    /// 生产使用常规交互延迟（当前为 2 ms），而真正装满的批次仍会经既有入队路径立即开始。
    private func shortenHighActivitySuccessorFlushIfNeeded() {
        guard pendingCount > 0,
              scheduledDelay == .highActivity,
              flushTask != nil,
              let existingDeadline = flushDeadline
        else { return }
        cancelDelayedFlush()
        installDelayedFlush(.highActivity,
            until: min(existingDeadline, clock.now + configuration.maximumDelay))
    }

    private func delayedFlushFired(generation: UInt64) {
        guard generation == flushGeneration else { return }
        flushTask = nil
        flushDeadline = nil
        switch scheduledDelay {
        case .base: baseDelayFlushes &+= 1
        case .highActivity: highActivityDelayFlushes &+= 1
        case .granted: break
        case nil:
            // 已取消的计时器不能安全地启动第二批次。
            // 此检查也防止过期任务污染诊断信息。
            return
        }
        scheduledDelay = nil
        startAvailableBatchesIfPossible()
    }

    private func recordArrival() {
        guard configuration.adaptiveDelayPolicy != nil else { return }
        recentArrivalInstants.append(clock.now)
        pruneArrivalHistory()
    }

    private func isHighActivity() -> Bool {
        guard let policy = configuration.adaptiveDelayPolicy else { return false }
        pruneArrivalHistory()
        return recentArrivalInstants.count - recentArrivalHead
            >= policy.minimumRequestsInWindow
    }

    private func pruneArrivalHistory() {
        guard let policy = configuration.adaptiveDelayPolicy else {
            recentArrivalInstants.removeAll(keepingCapacity: false)
            recentArrivalHead = 0
            return
        }
        let cutoff = clock.now - policy.observationWindow
        while recentArrivalHead < recentArrivalInstants.count,
              recentArrivalInstants[recentArrivalHead] < cutoff {
            recentArrivalHead += 1
        }
        // 达到阈值后，窗口内更早的样本不再影响决策。
        // 只保留最近的阈值数量，即使网关承受刻意施加的高负载，内存也保持有界。
        let maximumSamples = policy.minimumRequestsInWindow
        let retainedCount = recentArrivalInstants.count - recentArrivalHead
        if retainedCount > maximumSamples {
            recentArrivalHead += retainedCount - maximumSamples
        }
        // 限制过期数据占用，避免每次到达都移动数组元素。
        if recentArrivalHead >= 256,
           recentArrivalHead * 2 >= recentArrivalInstants.count {
            recentArrivalInstants.removeFirst(recentArrivalHead)
            recentArrivalHead = 0
        }
    }

    private func startAvailableBatchesIfPossible() {
        // 前一批次执行期间到达的请求已设置常规或自适应刷新计时器。
        // 前一批次完成时，不能绕过计时器立即处理尚未装满的后续批次；
        // 否则实际聚合窗口会变成数据库延迟，而非配置的上限。
        // 满批次仍会在 `accept` 中取消计时器并立即启动，
        // 因此此检查不会延迟达到硬性批处理阈值的工作。
        guard flushTask == nil || pendingCount >= configuration.maximumBatchSize
        else { return }
        while inFlightBatchCount < configuration.maximumInFlightBatches {
            guard let batch = dequeueNextBatch() else { return }
            let batchRoomIDs = Set(batch.map(\.request.command.roomID))
            inFlightBatchCount += 1
            activeRoomIDs.formUnion(batchRoomIDs)
            start(batch: batch, roomIDs: batchRoomIDs)
        }
    }

    /// 挑选下一个批次。
    ///
    /// 同一房间的命令不能越过更早的命令。
    /// 第一轮优先照顾独立且未活跃的房间，
    /// 第二轮再把剩余的批次容量用于这些房间中较晚的命令。
    /// 这对热单聊很重要：严格「每批一个房间」的选择器会让最需要摊销的那条写通道
    /// 永远停留在单命令事务上；反过来，若让热房间逐槽填满首批，
    /// 又会把它无关的会话饿死在后。
    ///
    /// PostgreSQL 批次存储会按到达顺序串行化相同的房间 ID，并在单个事务中推进它们的房间序号。
    /// 已被在途批次占有的房间会留在 `remaining` 中，从而在跨事务时保持既有的「不可越过」规则。
    ///
    /// - Returns: 本批选中的待处理请求；没有可选项时为 `nil`。
    private func dequeueNextBatch() -> [Pending]? {
        guard pendingCount > 0 else { return nil }

        var anchorID = pendingHeadID
        var anchor: Pending?
        while let itemID = anchorID, let item = pendingByID[itemID] {
            anchorID = item.nextID
            if !activeRoomIDs.contains(item.request.command.roomID) {
                anchor = item
                break
            }
        }
        guard let anchor else { return nil }
        if configuration.maximumBatchSize == 1 {
            // 第一个未处于活动状态的房间是唯一可选槽位。
            // 通过常规路径移除它时，也会归还共享的待处理容量。
            guard let removed = removePending(anchor.id) else { return nil }
            let batch = [removed]
            recordDequeued(batch)
            return batch
        }
        func compatible(_ item: Pending) -> Bool {
            switch (anchor.granted, item.granted) {
            case (nil, nil): true
            case (.some(let lhs), .some(let rhs)):
                lhs.token.owner.shardID == rhs.token.owner.shardID
            default: false
            }
        }

        var selected: [Pending] = []
        defer { recordDequeued(selected) }
        var seenRoomIDs = activeRoomIDs
        selected.reserveCapacity(configuration.maximumBatchSize)

        // 公平性遍历：先从每个非活动房间至多选取一条命令。
        var cursor = pendingHeadID
        while let itemID = cursor,
              let item = pendingByID[itemID],
              selected.count < configuration.maximumBatchSize
        {
            cursor = item.nextID
            guard seenRoomIDs.insert(item.request.command.roomID).inserted else { continue }
            if compatible(item), let removed = removePending(itemID) {
                selected.append(removed)
            }
        }
        // 热房间遍历：所有已选房间都有机会进入此事务后，
        // 只用这些房间的命令填充剩余容量。新出现房间的命令留在
        // `remaining` 中，以便在下一个事务的首轮遍历中获得优先权。
        guard selected.count < configuration.maximumBatchSize else { return selected }
        let batchRoomIDs = Set(selected.map(\.request.command.roomID))
        let selectedTokens = Dictionary(uniqueKeysWithValues: selected.compactMap { item in
            item.granted.map { (item.request.command.roomID, $0.token) }
        })
        var blockedHotRooms: Set<RoomID> = []
        cursor = pendingHeadID
        while let itemID = cursor,
              let item = pendingByID[itemID],
              selected.count < configuration.maximumBatchSize
        {
            cursor = item.nextID
            let roomID = item.request.command.roomID
            guard batchRoomIDs.contains(roomID), !blockedHotRooms.contains(roomID) else { continue }
            guard compatible(item),
                  item.granted == nil || selectedTokens[roomID] == item.granted?.token
            else {
                blockedHotRooms.insert(roomID)
                continue
            }
            if let removed = removePending(itemID) {
                selected.append(removed)
            }
        }
        guard !selected.isEmpty else { return nil }
        return selected
    }

    private func enqueuePending(_ item: Pending) {
        item.previousID = pendingTailID
        if let tailID = pendingTailID, let tail = pendingByID[tailID] {
            tail.nextID = item.id
        } else {
            pendingHeadID = item.id
        }
        pendingTailID = item.id
        pendingByID[item.id] = item
        pendingCount += 1
    }

    @discardableResult
    private func removePending(_ id: UInt64) -> Pending? {
        guard let item = pendingByID.removeValue(forKey: id) else { return nil }
        if let previousID = item.previousID, let previous = pendingByID[previousID] {
            previous.nextID = item.nextID
        } else {
            pendingHeadID = item.nextID
        }
        if let nextID = item.nextID, let next = pendingByID[nextID] {
            next.previousID = item.previousID
        } else {
            pendingTailID = item.previousID
        }
        pendingCount -= 1
        sharedPendingCapacity?.release()
        item.previousID = nil
        item.nextID = nil
        return item
    }

    private func start(batch: [Pending], roomIDs: Set<RoomID>) {
        sameRoomDeferredRequests &+= UInt64(batch.count - roomIDs.count)
        let executionStartedAt = clock.now
        let sqlDeadline = batch.compactMap { $0.granted?.callDeadline }.min()
        Task {
          await V2RoomSQLDeadline.withSelectedDeadline(sqlDeadline) {
            let results: [Result<V2SendMessageOutcome, any Error>]
            let disposition: BatchDisposition
            let batchStore: any V2AtomicRoomWriteBatchStore
            do {
                batchStore = try store(for: batch)
            } catch {
                self.complete(
                    batch: batch,
                    roomIDs: roomIDs,
                    results: Array(repeating: .failure(error), count: batch.count),
                    disposition: .atomicFailed,
                    executionStartedAt: executionStartedAt
                )
                return
            }
            if batch.count == 1 {
                // 单条请求不满足原子存储的批处理契约，应直接分发，
                // 避免每次计时器刷新未装满的批次时都通过异常进行回退。
                results = await acceptIndividually(batch, store: batchStore)
                disposition = .singleton
            } else {
                let partitions = await batchStore.atomicBatchPartitions(
                    requests: batch.map(\.request)
                )
                guard partitions.count == batch.count else {
                    results = Array(
                        repeating: .failure(V2RoomWriteStoreError.corruptPersistenceState),
                        count: batch.count
                    )
                    disposition = .atomicFailed
                    self.complete(
                        batch: batch,
                        roomIDs: roomIDs,
                        results: results,
                        disposition: disposition,
                        executionStartedAt: executionStartedAt
                    )
                    return
                }
                let partitioned = await executePartitioned(
                    batch: batch,
                    partitions: partitions,
                    store: batchStore
                )
                results = partitioned.results
                disposition = partitioned.disposition
            }
            self.complete(
                batch: batch,
                roomIDs: roomIDs,
                results: results,
                disposition: disposition,
                executionStartedAt: executionStartedAt
            )
          }
        }
    }

    private func store(for batch: [Pending]) throws -> any V2AtomicRoomWriteBatchStore {
        guard batch.first?.granted != nil else { return store }
        guard let actorGrantedStoreFactory else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        var tokens: [V2RoomActivationToken] = []
        var byRoom: [RoomID: V2RoomActivationToken] = [:]
        for item in batch {
            guard let token = item.granted?.token else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            if let existing = byRoom[token.roomID] {
                guard existing == token else {
                    throw V2RoomActivationLeaseError.activationChanged
                }
            } else {
                byRoom[token.roomID] = token
                tokens.append(token)
            }
        }
        return try actorGrantedStoreFactory(tokens)
    }

    /// 为每个兼容子集保持原子存储契约。
    ///
    /// 大多数 PostgreSQL 房间日志语句每个房间只推进一个持久游标，
    /// 因此它们的存储调用采用有序的唯一房间波次。
    /// 存储可以显式声明某个分区能够按到达顺序归并重复房间、并且只持久化每个房间的最终状态；
    /// 该分区随后会在整个暂存批次上只执行一次。
    /// 这既避免热群组流量退化为每条消息一个事务，也为其他所有路由保留默认的防御性契约。
    ///
    /// 兼容分区在单个波次内串行执行，因为它们仍可能竞争共享的分片准入行。
    /// 被持久修订校验拒绝的原子尝试会整体回滚，并且只为那个兼容子集回退。
    ///
    /// - Parameters:
    ///   - batch: 当前批次中的待处理请求。
    ///   - partitions: 与每个请求对应的原子写入分区，无法合并处为 `nil`。
    /// - Returns: 分区执行结果。
    private func executePartitioned(
        batch: [Pending],
        partitions: [V2AtomicRoomWriteBatchPartition?],
        store: any V2AtomicRoomWriteBatchStore
    ) async -> PartitionedExecution {
        // 分区分类仅供参考。若同一房间得到混合提示，
        // 重复房间的分区不能越过同一获准轮次中更早的逐条命令。
        var firstIndexByRoom: [RoomID: Int] = [:]
        var mixedRooms: Set<RoomID> = []
        for (index, pending) in batch.enumerated() {
            let roomID = pending.request.command.roomID
            if let firstIndex = firstIndexByRoom[roomID] {
                if partitions[firstIndex] != partitions[index] { mixedRooms.insert(roomID) }
            } else {
                firstIndexByRoom[roomID] = index
            }
        }
        let safePartitions = batch.indices.map { index in
            mixedRooms.contains(batch[index].request.command.roomID) ? nil : partitions[index]
        }
        var results = Array<Result<V2SendMessageOutcome, any Error>?>(
            repeating: nil,
            count: batch.count
        )
        var dispositions: [BatchDisposition] = []
        var preclassifiedRequestCount = 0
        var remainingIndices = Array(batch.indices)

        // 先收集所有重复房间轮次中主动参与的分区。同一房间的请求不能跨越
        // 两条实际路径，但选取仍限制在分区内，使参考分类器出错时，
        // 能在权威存储边界回退，而不是合并不兼容的 SQL 执行图。
        var repeatedRoomPartitions: [V2AtomicRoomWriteBatchPartition] = []
        for partition in safePartitions.compactMap({ $0 }) where
            !repeatedRoomPartitions.contains(partition)
        {
            if await store.atomicBatchSupportsRepeatedRooms(in: partition) {
                repeatedRoomPartitions.append(partition)
            }
        }
        var consumedIndices: Set<Int> = []
        for partition in repeatedRoomPartitions {
            let indices = batch.indices.filter { safePartitions[$0] == partition }
            guard indices.count >= 2 else { continue }
            let execution = await executeAtomic(indices.map { batch[$0] }, store: store)
            for (index, result) in zip(indices, execution.results) {
                results[index] = result
            }
            dispositions.append(execution.disposition)
            consumedIndices.formUnion(indices)
        }
        if !consumedIndices.isEmpty {
            remainingIndices.removeAll { consumedIndices.contains($0) }
        }

        while !remainingIndices.isEmpty {
            var waveRoomIDs: Set<RoomID> = []
            var waveIndices: [Int] = []
            var deferredIndices: [Int] = []
            waveIndices.reserveCapacity(remainingIndices.count)
            deferredIndices.reserveCapacity(remainingIndices.count)
            for index in remainingIndices {
                let roomID = batch[index].request.command.roomID
                if waveRoomIDs.insert(roomID).inserted {
                    waveIndices.append(index)
                } else {
                    deferredIndices.append(index)
                }
            }
            remainingIndices = deferredIndices

            // 保留分区首次出现的顺序，不依赖 Dictionary 的遍历顺序。
            // 这样加锁和测试行为在不同进程及 Swift 版本间保持确定。
            var orderedPartitions: [V2AtomicRoomWriteBatchPartition] = []
            var indicesByPartition: [V2AtomicRoomWriteBatchPartition: [Int]] = [:]
            var individualIndices: [Int] = []
            for index in waveIndices {
                guard let partition = safePartitions[index] else {
                    individualIndices.append(index)
                    continue
                }
                if indicesByPartition[partition] == nil {
                    orderedPartitions.append(partition)
                }
                indicesByPartition[partition, default: []].append(index)
            }

            for partition in orderedPartitions {
                guard let indices = indicesByPartition[partition] else { continue }
                if indices.count == 1 {
                    individualIndices.append(indices[0])
                    continue
                }
                let execution = await executeAtomic(indices.map { batch[$0] }, store: store)
                for (index, result) in zip(indices, execution.results) {
                    results[index] = result
                }
                dispositions.append(execution.disposition)
            }

            if !individualIndices.isEmpty {
                let independentlyAccepted = await acceptIndividually(
                    individualIndices.map { batch[$0] }, store: store
                )
                for (index, result) in zip(individualIndices, independentlyAccepted) {
                    results[index] = result
                }
                preclassifiedRequestCount += individualIndices.count
            }
        }

        return .init(
            results: results.map {
                $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState)
            },
            disposition: .multiplePartitions(
                atomic: dispositions,
                preclassifiedRequestCount: preclassifiedRequestCount
            )
        )
    }

    private func executeAtomic(
        _ batch: [Pending],
        store: any V2AtomicRoomWriteBatchStore
    ) async -> AtomicExecution {
        do {
            let outcomes = try await withForegroundWriteAdmission {
                try await store.acceptAtomically(requests: batch.map(\.request))
            }
            guard outcomes.count == batch.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return .init(
                results: outcomes.map(Result.success),
                disposition: .atomicCommitted(requestCount: batch.count)
            )
        } catch let batchError as V2AtomicRoomWriteBatchError {
            // 若重试时剔除中间的单独请求，同房间后续命令可能先执行。
            // 逐条回退现在会保留每个房间的原始顺序。
            if Set(batch.map(\.request.command.roomID)).count != batch.count {
                return .init(
                    results: await acceptIndividually(batch, store: store),
                    disposition: .fallback(requestCount: batch.count, reason: batchError.reason)
                )
            }
            if let isolated = validatedIsolatedRequestIndices(
                batchError.isolatedRequestIndices,
                batchCount: batch.count
            ) {
                let isolatedSet = Set(isolated)
                let compatibleIndices = batch.indices.filter {
                    !isolatedSet.contains($0)
                }
                // 仅剩一条请求时无法以批次原子方式重试，也没有批处理收益。
                // 此退化情形继续使用既有的有界逐条回退。
                if compatibleIndices.count >= 2 {
                    let compatibleExecution = await executeAtomic(
                        compatibleIndices.map { batch[$0] }, store: store
                    )
                    let isolatedResults = await acceptIndividually(
                        isolated.map { batch[$0] }, store: store
                    )
                    var results = Array<Result<V2SendMessageOutcome, any Error>?>(
                        repeating: nil,
                        count: batch.count
                    )
                    for (index, result) in zip(
                        compatibleIndices,
                        compatibleExecution.results
                    ) {
                        results[index] = result
                    }
                    for (index, result) in zip(isolated, isolatedResults) {
                        results[index] = result
                    }
                    return .init(
                        results: results.map {
                            $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState)
                        },
                        disposition: .multiplePartitions(
                            atomic: [
                                .fallback(
                                    requestCount: batch.count,
                                    reason: batchError.reason
                                ),
                                compatibleExecution.disposition,
                            ],
                            preclassifiedRequestCount: isolated.count
                        )
                    )
                }
            }
            // 事务在提交任何内容前已回滚。仅此兼容子集逐条重试；
            // 被参考分类器排除的请求本就使用同一路径。
            return .init(
                results: await acceptIndividually(batch, store: store),
                disposition: .fallback(
                    requestCount: batch.count,
                    reason: batchError.reason
                )
            )
        } catch {
            return .init(
                results: Array(repeating: .failure(error), count: batch.count),
                disposition: .atomicFailed
            )
        }
    }

    private func validatedIsolatedRequestIndices(
        _ indices: [Int],
        batchCount: Int
    ) -> [Int]? {
        guard !indices.isEmpty, indices.count < batchCount else { return nil }
        let unique = Set(indices)
        guard unique.count == indices.count,
              unique.allSatisfy({ (0..<batchCount).contains($0) })
        else { return nil }
        return unique.sorted()
    }

    private func acceptIndividually(
        _ batch: [Pending],
        store: any V2AtomicRoomWriteBatchStore
    ) async -> [Result<V2SendMessageOutcome, any Error>] {
        var orderedRooms: [RoomID] = []
        var byRoom: [RoomID: [(Int, Pending)]] = [:]
        for (index, pending) in batch.enumerated() {
            let roomID = pending.request.command.roomID
            if byRoom[roomID] == nil { orderedRooms.append(roomID) }
            byRoom[roomID, default: []].append((index, pending))
        }
        return await withTaskGroup(
            of: [(Int, Result<V2SendMessageOutcome, any Error>)].self,
            returning: [Result<V2SendMessageOutcome, any Error>].self
        ) { group in
            for roomID in orderedRooms {
                guard let items = byRoom[roomID] else { continue }
                group.addTask {
                    var roomResults: [(Int, Result<V2SendMessageOutcome, any Error>)] = []
                    var uncertain = false
                    for (index, pending) in items {
                        if uncertain {
                            roomResults.append((index, .failure(V2RoomCallFailure.outcomeUnknown)))
                            continue
                        }
                        do {
                            let outcome = try await self.withForegroundWriteAdmission {
                                try await store.accept(
                                    command: pending.request.command,
                                    capacityProfile: pending.request.capacityProfile,
                                    identifiers: pending.request.identifiers,
                                    now: pending.request.now
                                )
                            }
                            roomResults.append((index, .success(outcome)))
                        } catch {
                            roomResults.append((index, .failure(error)))
                            uncertain = pending.granted != nil && Self.requiresRetirement(error)
                        }
                    }
                    return roomResults
                }
            }
            var results = Array<Result<V2SendMessageOutcome, any Error>?>(
                repeating: nil,
                count: batch.count
            )
            for await roomResults in group {
                for (index, result) in roomResults { results[index] = result }
            }
            return results.map { $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState) }
        }
    }

    private func withForegroundWriteAdmission<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let callerDeadline = V2RoomSQLDeadline.current
        if let callerDeadline, callerDeadline <= .now {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        guard let databaseWorkAdmission else {
            return try await operation()
        }
        switch await databaseWorkAdmission.acquire(.foregroundWrite, callerDeadline: callerDeadline) {
        case .admitted:
            do {
                if let callerDeadline, callerDeadline <= .now {
                    throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
                }
                let result = try await operation()
                await databaseWorkAdmission.release(.foregroundWrite)
                return result
            } catch {
                await databaseWorkAdmission.release(.foregroundWrite)
                throw error
            }
        case .rejected(.queueFull):
            throw V2SendMessageAdmissionBatcherError.serverBusy
        case .rejected(.timeout):
            if let callerDeadline, callerDeadline <= .now {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
            throw V2SendMessageAdmissionBatcherError.serverBusy
        case .cancelled:
            throw CancellationError()
        }
    }

    private func complete(
        batch: [Pending],
        roomIDs: Set<RoomID>,
        results: [Result<V2SendMessageOutcome, any Error>],
        disposition: BatchDisposition,
        executionStartedAt: ContinuousClock.Instant
    ) {
        precondition(inFlightBatchCount > 0)
        let resolvedResults = results.count == batch.count ? results : Array(
            repeating: Result<V2SendMessageOutcome, any Error>.failure(
                V2RoomWriteStoreError.corruptPersistenceState),
            count: batch.count
        )
        var uncertainTokens = Set(zip(batch, resolvedResults).compactMap { pending, result in
            guard let token = pending.granted?.token,
                  case .failure(let error) = result,
                  Self.requiresRetirement(error) else { return nil as V2RoomActivationToken? }
            return token
        })
        // 只有整个获准轮次都有相同的回滚证明时，才能安全地认定已回滚。
        // 较早的分区可能已经提交；混合轮次一旦结果未知，
        // 后续已排队的项目不得启动。
        for (pending, result) in zip(batch, resolvedResults) {
            guard let granted = pending.granted,
                  case .failure(let error) = result,
                  Self.isProvedRollback(error),
                  let turn = grantedTurns[granted.turnID] else { continue }
            let current = zip(batch, resolvedResults).compactMap { item, value in
                item.granted?.turnID == granted.turnID ? value : nil
            }
            let previous = turn.results.compactMap { $0 }
            if turn.remaining > current.count ||
                (previous + current).contains(where: { result in
                    guard case .failure(let error) = result else { return true }
                    return !Self.isProvedRollback(error)
                }) {
                uncertainTokens.insert(granted.token)
            }
        }
        quarantinedActivations.formUnion(uncertainTokens)
        purgeQueuedRequests(for: uncertainTokens)
        let executionMilliseconds = elapsedMilliseconds(since: executionStartedAt)
        completedBatches &+= 1
        batchExecutionMillisecondsTotal = saturatingAdd(
            batchExecutionMillisecondsTotal,
            executionMilliseconds
        )
        batchExecutionMillisecondsMax = max(
            batchExecutionMillisecondsMax,
            executionMilliseconds
        )
        inFlightBatchCount -= 1
        activeRoomIDs.subtract(roomIDs)
        shortenHighActivitySuccessorFlushIfNeeded()
        switch disposition {
        case .atomicCommitted(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchCommitted &+= 1
            atomicBatchCommittedRequests &+= UInt64(requestCount)
        case .fallback(let requestCount, let reason):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
            atomicBatchFallbackReasons[reason, default: 0] &+= 1
        case .preclassified(let requestCount):
            atomicPreclassifiedIndividualRequests &+= UInt64(requestCount)
        case .partitioned(let atomic, let preclassifiedRequestCount):
            applyAtomicDisposition(atomic)
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .multiplePartitions(let atomic, let preclassifiedRequestCount):
            for disposition in atomic { applyDisposition(disposition) }
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .atomicFailed:
            atomicBatchAttempts &+= 1
        case .singleton:
            singletonDispatches &+= 1
        }
        // 此时该 Actor 仍拥有 `roomIDs` 中的所有房间。
        // 须在请求续体恢复以及任一房间的下一批次启动前，提交已持久化的批次。
        // 这样能在提交后加速边界上保留持久化的房间序号顺序，
        // 无需让独立恢复的处理器竞速。
        if let committedMessageObserver {
            committedMessageObserver.observeCommittedMessages(
                resolvedResults.compactMap { result in
                    guard case .success(.accepted(let message)) = result else {
                        return nil
                    }
                    return .accepted(message)
                }
            )
        }
        for (pending, result) in zip(batch, resolvedResults) {
            completePending(pending, result: result)
        }
        startAvailableBatchesIfPossible()
    }

    private nonisolated static func requiresRetirement(_ error: any Error) -> Bool {
        if let failure = error as? V2RoomCallFailure {
            return failure == .outcomeUnknown
        }
        return error is V2RoomTransactionOutcomeUnknown ||
            error is V2RoomActivationLeaseError ||
            (error as? V2RoomWriteStoreError) == .corruptPersistenceState ||
            V2ActorMessagingErrorWire(domainError: error) == nil
    }

    private nonisolated static func isProvedRollback(_ error: any Error) -> Bool {
        guard let failure = error as? V2RoomCallFailure else { return false }
        switch failure {
        case .notAccepted, .rolledBack: return true
        case .outcomeUnknown: return false
        }
    }

    private func purgeQueuedRequests(for tokens: Set<V2RoomActivationToken>) {
        guard !tokens.isEmpty else { return }
        var cursor = pendingHeadID
        while let itemID = cursor, let pending = pendingByID[itemID] {
            cursor = pending.nextID
            if let token = pending.granted?.token,
               tokens.contains(token),
               let removed = removePending(itemID) {
                completePending(removed, result: .failure(V2RoomCallFailure.outcomeUnknown))
            }
        }
        if pendingCount == 0 { cancelDelayedFlush() }
    }

    private func completePending(
        _ pending: Pending,
        result: Result<V2SendMessageOutcome, any Error>
    ) {
        if let continuation = pending.continuation {
            continuation.resume(with: result)
            return
        }
        guard let granted = pending.granted,
              var turn = grantedTurns[granted.turnID],
              turn.results[granted.index] == nil else { return }
        if let remaining = trackedActivations[granted.token] {
            precondition(remaining > 0, "tracked activation completed twice")
            if remaining == 1 {
                if !retiringActivations.contains(granted.token) {
                    trackedActivations[granted.token] = 0
                } else {
                    trackedActivations.removeValue(forKey: granted.token)
                    quarantinedActivations.remove(granted.token)
                    retiringActivations.remove(granted.token)
                    sharedActivationCapacity?.release(granted.token)
                }
            } else {
                trackedActivations[granted.token] = remaining - 1
            }
        }
        turn.results[granted.index] = result
        turn.remaining -= 1
        if turn.remaining == 0 {
            grantedTurns.removeValue(forKey: granted.turnID)
            turn.continuation.resume(returning: turn.results.map {
                $0 ?? .failure(V2RoomWriteStoreError.corruptPersistenceState)
            })
        } else {
            grantedTurns[granted.turnID] = turn
        }
    }

    private enum BatchDisposition: Sendable {
        case atomicCommitted(requestCount: Int)
        case fallback(requestCount: Int, reason: V2AtomicRoomWriteBatchError.Reason)
        case preclassified(requestCount: Int)
        case partitioned(atomic: AtomicBatchDisposition, preclassifiedRequestCount: Int)
        case multiplePartitions(atomic: [BatchDisposition], preclassifiedRequestCount: Int)
        case atomicFailed
        case singleton

        func withPreclassifiedRequests(_ count: Int) -> BatchDisposition {
            guard count > 0 else { return self }
            switch self {
            case .atomicCommitted(let requestCount):
                return .partitioned(
                    atomic: .committed(requestCount: requestCount),
                    preclassifiedRequestCount: count
                )
            case .fallback(let requestCount, let reason):
                return .partitioned(
                    atomic: .fallback(requestCount: requestCount, reason: reason),
                    preclassifiedRequestCount: count
                )
            case .atomicFailed, .singleton, .preclassified, .partitioned,
                 .multiplePartitions:
                return self
            }
        }
    }

    private enum AtomicBatchDisposition: Sendable {
        case committed(requestCount: Int)
        case fallback(requestCount: Int, reason: V2AtomicRoomWriteBatchError.Reason)
    }

    private struct AtomicExecution: Sendable {
        let results: [Result<V2SendMessageOutcome, any Error>]
        let disposition: BatchDisposition
    }

    private struct PartitionedExecution: Sendable {
        let results: [Result<V2SendMessageOutcome, any Error>]
        let disposition: BatchDisposition
    }

    private func applyAtomicDisposition(_ disposition: AtomicBatchDisposition) {
        switch disposition {
        case .committed(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchCommitted &+= 1
            atomicBatchCommittedRequests &+= UInt64(requestCount)
        case .fallback(let requestCount, let reason):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
            atomicBatchFallbackReasons[reason, default: 0] &+= 1
        }
    }

    private func applyDisposition(_ disposition: BatchDisposition) {
        switch disposition {
        case .atomicCommitted(let requestCount):
            atomicBatchAttempts &+= 1
            atomicBatchCommitted &+= 1
            atomicBatchCommittedRequests &+= UInt64(requestCount)
        case .fallback(let requestCount, let reason):
            atomicBatchAttempts &+= 1
            atomicBatchFallbacks &+= 1
            atomicBatchFallbackRequests &+= UInt64(requestCount)
            atomicBatchFallbackReasons[reason, default: 0] &+= 1
        case .preclassified(let requestCount):
            atomicPreclassifiedIndividualRequests &+= UInt64(requestCount)
        case .partitioned(let atomic, let preclassifiedRequestCount):
            applyAtomicDisposition(atomic)
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .multiplePartitions(let dispositions, let preclassifiedRequestCount):
            for nested in dispositions { applyDisposition(nested) }
            atomicPreclassifiedIndividualRequests &+= UInt64(preclassifiedRequestCount)
        case .atomicFailed:
            atomicBatchAttempts &+= 1
        case .singleton:
            singletonDispatches &+= 1
        }
    }

    private func cancelPendingRequest(_ pendingID: UInt64) {
        guard let removed = removePending(pendingID) else {
            // 批次已经执行。其持久化操作保持正常的至少一次和幂等语义；
            // 出队后无法安全取消。
            return
        }
        cancelledPendingRequests &+= 1
        removed.continuation?.resume(throwing: CancellationError())
        if pendingCount == 0 {
            cancelDelayedFlush()
        }
    }

    private func recordDequeued(_ batch: [Pending]) {
        guard !batch.isEmpty else { return }
        let now = clock.now
        dequeuedRequests &+= UInt64(batch.count)
        for item in batch {
            let milliseconds = elapsedMilliseconds(from: item.enqueuedAt, to: now)
            queueWaitMillisecondsTotal = saturatingAdd(
                queueWaitMillisecondsTotal,
                milliseconds
            )
            queueWaitMillisecondsMax = max(queueWaitMillisecondsMax, milliseconds)
        }
    }

    private func elapsedMilliseconds(since instant: ContinuousClock.Instant) -> UInt64 {
        elapsedMilliseconds(from: instant, to: clock.now)
    }

    private func elapsedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> UInt64 {
        let components = start.duration(to: end).components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let wholeMilliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        guard !wholeMilliseconds.overflow else { return .max }
        let fractionalMilliseconds = UInt64(
            components.attoseconds / 1_000_000_000_000_000
        )
        return saturatingAdd(wholeMilliseconds.partialValue, fractionalMilliseconds)
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

public enum V2SendMessageAdmissionBatcherError: Error, Sendable, Equatable {
    /// 批次暂存队列或其自有的数据库准入队列已满（或有界等待已超时）。
    ///
    /// 协议会把它映射为可重试的 `SERVER_BUSY`，绝不映射为持久化失败。
    case serverBusy
}
