import Foundation
import IMV2Core
import Synchronization

/// 混合群组房间事件提交后产生的纯元数据工作项。
///
/// 其载荷刻意不包含事件内容与接收者身份。
public struct V2GroupEventWake: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64

    public init(roomID: RoomID, highWatermark: UInt64) {
        self.roomID = roomID
        self.highWatermark = highWatermark
    }
}

public struct V2GroupEventWakeLease: Equatable, Sendable {
    public let wake: V2GroupEventWake
    public let revision: UInt64
    public let claimToken: UUID
    public let attempt: Int

    public init(wake: V2GroupEventWake, revision: UInt64, claimToken: UUID, attempt: Int) {
        self.wake = wake
        self.revision = revision
        self.claimToken = claimToken
        self.attempt = attempt
    }
}

public protocol V2GroupEventWakeStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2GroupEventWakeLease]
    /// 在发布进行期间，更新的某个事件可能已替换掉被认领的修订。
    ///
    /// 存储必须保留这条更新的水位线，而不是删除已合并的那一行。
    ///
    /// - Parameter lease: 已完成发布的租约。
    func markPublished(_ lease: V2GroupEventWakeLease) async throws
    func scheduleRetry(_ lease: V2GroupEventWakeLease, nextAttemptAt: Date) async throws
}

public protocol V2GroupEventWakePublishing: Sendable {
    func publish(_ wake: V2GroupEventWake) async throws
}

/// 群消息源事务提交后发出的尽力而为提示。
///
/// 与 `V2GroupEventWakePublishing` 不同，该契约没有发件箱、重试或投递义务。
/// 它唯一的目的是缩短一个已打开详情页拉取授权房间日志之前的等待时间。
public protocol V2ForegroundGroupEventHintPublishing: Sendable {
    func publishForegroundHint(_ hint: V2GroupEventWake) async
    func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async
    func publishForegroundGroupEvents(_ events: [V2DirectRoomLiveEvent]) async
}

/// 面向能够在不挂起的情况下完成前台私聊事件发布的发布方的可选进程本地加速。
///
/// 遵循者只能执行有界的内存路由并入队工作；
/// broker I/O 与 actor 跳转仍由 ``V2ForegroundGroupEventHintPublishing`` 承担。
///
/// 返回 `false` 表示请投递器保留其常规异步发布路径。
/// 这使多网关/NATS 部署与测试嵌入在语义上保持一致，
/// 同时让本地 SwiftNIO 网关无需为每条已接受的私聊消息新建一个短生命周期子任务。
protocol V2ImmediateForegroundDirectEventPublishing: Sendable {
    func publishForegroundDirectEventImmediately(_ event: V2DirectRoomLiveEvent) -> Bool
    func publishForegroundGroupEventsImmediately(_ events: [V2DirectRoomLiveEvent]) -> Bool
}

extension V2ImmediateForegroundDirectEventPublishing {
    func publishForegroundGroupEventsImmediately(
        _: [V2DirectRoomLiveEvent]
    ) -> Bool { false }
}

/// Gateway 接受路径使用的不挂起提交后边界。
///
/// 实现只能执行有界的进程本地入队工作。
/// 任何 broker、套接字、序列化或重试工作都归该边界之后由运行时拥有的消费者负责。
public protocol V2ForegroundGroupEventHintSubmitting: Sendable {
    func submitForegroundHint(_ hint: V2GroupEventWake)
    func submitForegroundDirectEvent(_ event: V2DirectRoomLiveEvent)
    func submitForegroundDirectMessage(_ message: V2AcceptedMessage)
    func submitForegroundDirectMessage(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID?
    )
}

/// 把消息准入提交边界桥接到 Gateway 可选的混合群组前台加速器。
///
/// 准入通道在仍持有已完成批次中每个房间的执行权时调用该值。
/// 按房间序号对已接受结果排序，从而在任何 ACK 处理器恢复、
/// 或下一个同房间数据库批次开始之前，为投递器提供每个房间一条单调流。
/// 缓存与套接字工作保持有界、进程本地且尽力而为；
/// PostgreSQL 房间日志行仍然是唯一的恢复权威。
public final class V2CommittedHybridGroupEventObserver:
    V2CommittedMessageBatchObserving,
    Sendable
{
    private struct State: Sendable {
        var sink: (any V2ForegroundGroupEventHintSubmitting)?
    }

    private let directRoomLogEventCache: V2DirectRoomLogEventCache?
    private let state = Mutex(State())

    public init(directRoomLogEventCache: V2DirectRoomLogEventCache?) {
        self.directRoomLogEventCache = directRoomLogEventCache
    }

    /// 运行时装配会在打开公开监听器之前安装接收端。
    ///
    /// 之后再替换会把某房间的实时流拆分到多个投递器上，因此配置刻意只允许一次。
    ///
    /// - Parameter sink: 要安装的前台群事件提示接收端。
    public func install(
        sink: any V2ForegroundGroupEventHintSubmitting
    ) {
        state.withLock { state in
            precondition(state.sink == nil, "committed group event sink already installed")
            state.sink = sink
        }
    }

    public func observeCommittedRoomSequence(roomID: RoomID, roomSequence: UInt64) {
        state.withLock { $0.sink }?.submitForegroundHint(.init(roomID: roomID, highWatermark: roomSequence))
    }

    public func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome]) {
        guard !outcomes.isEmpty else { return }
        let sink = state.withLock { $0.sink }
        var events: [V2DirectRoomLiveEvent] = []
        events.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            guard case .accepted(let message) = outcome else { continue }
            // Direct drafts preserve the exact two-person audience; group drafts
            // retain the existing large-group eligibility boundary.
            if let event = V2DirectRoomLiveEventDraft(message)?.materialized()
                ?? V2GroupRoomLiveEventDraft(message)?.materialized() {
                events.append(event)
            } else {
                sink?.submitForegroundHint(.init(roomID: message.roomID, highWatermark: message.roomSequence))
            }
        }
        guard !events.isEmpty else { return }
        events.sort {
            if $0.roomID == $1.roomID {
                return $0.roomSequence < $1.roomSequence
            }
            return $0.roomID.rawValue < $1.roomID.rawValue
        }
        for event in events {
            directRoomLogEventCache?.enqueueCommittedPlainDirectEvent(event)
            sink?.submitForegroundDirectEvent(event)
        }
    }
}

/// 运行时拥有的前台提示信箱。
///
/// 它按房间合并水位线，并刻意在 broker I/O 开始之前就从 `publishForegroundHint` 返回，
/// 使发送方的接受响应不受可选的 NATS 连接或缓慢的本地套接字写入影响。
public final class V2ForegroundGroupEventHintDispatcher:
    V2ForegroundGroupEventHintSubmitting,
    Sendable
{
    private let publisher: any V2ForegroundGroupEventHintPublishing
    private let immediateDirectEventPublisher: (any V2ImmediateForegroundDirectEventPublishing)?
    private let maximumPendingRooms: Int
    /// 前台实时发送只是允许丢失的加速器，
    /// 但单个串行发布方绝不能成为无关房间的吞吐上限。
    ///
    /// 适度的上限既保护网关执行器与套接字缓冲区，
    /// 又在相邻两次信箱排空之间保留批次边界。
    private let maximumConcurrentPublications: Int
    private let maximumGroupEventsPerBatch: Int
    /// 一个热房间可能在前台合并窗口内收到数个数据库提交批次。
    ///
    /// 把这个有界积压与更小的协议帧批量上限区分开，
    /// 使一次无害的提交突发不会丢弃本可连续的实时流。
    private let maximumPendingGroupEventsPerRoom: Int
    private let groupBatchDelay: Duration
    private let groupBatchExtensionDelay: Duration
    private let groupBatchExtensionMinimumEvents: Int
    private let metrics: (any V2GatewayTransportMetricsRecorder)?
    private let signal: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private struct Pending: Sendable {
        var wake: V2GroupEventWake
        var directEvent: V2DirectRoomLiveEvent?
        var groupEvents: [V2DirectRoomLiveEvent]
        var groupEventSequences: Set<UInt64>
        var requiresOrderingSort: Bool
        var degradedToWake: Bool

        mutating func appendGroupEvent(
            _ event: V2DirectRoomLiveEvent,
            outOfOrder: Bool
        ) {
            groupEvents.append(event)
            groupEventSequences.insert(event.roomSequence)
            requiresOrderingSort = requiresOrderingSort || outOfOrder
            wake = .init(
                roomID: event.roomID,
                highWatermark: max(wake.highWatermark, event.roomSequence)
            )
        }
    }

    private struct Publication: Sendable {
        let wake: V2GroupEventWake
        let directEvent: V2DirectRoomLiveEvent?
        let groupEvents: [V2DirectRoomLiveEvent]
    }

    private struct State: Sendable {
        var pending: [RoomID: Pending] = [:]
        /// 用于检测「更高序号已离开本投递器之后才到达的事件」的有界诊断水位线。
        ///
        /// 这些值只是可观测性提示，绝不授权任何投递。
        var recentlyPublishedHighWatermarks: [RoomID: UInt64] = [:]
        var finished = false
    }

    private struct GroupSubmissionResult: Sendable {
        let accepted: Bool
        let duplicate: Bool
        let outOfOrder: Bool
        let late: Bool
        let degraded: Bool
    }
    private let state = Mutex(State())

    public init(
        publisher: any V2ForegroundGroupEventHintPublishing,
        maximumPendingRooms: Int = 256,
        maximumConcurrentPublications: Int = 8,
        maximumGroupEventsPerBatch: Int = 64,
        maximumPendingGroupEventsPerRoom: Int = 1_024,
        groupBatchDelay: Duration = .milliseconds(10),
        groupBatchExtensionDelay: Duration = .milliseconds(10),
        groupBatchExtensionMinimumEvents: Int = 8,
        metrics: (any V2GatewayTransportMetricsRecorder)? = nil
    ) {
        precondition(
            maximumPendingRooms > 0 && maximumConcurrentPublications > 0
                && maximumGroupEventsPerBatch > 0 && groupBatchDelay >= .zero
                && maximumPendingGroupEventsPerRoom >= maximumGroupEventsPerBatch
                && groupBatchExtensionDelay >= .zero
                && groupBatchExtensionMinimumEvents > 0
                && groupBatchExtensionMinimumEvents <= maximumGroupEventsPerBatch
        )
        self.publisher = publisher
        immediateDirectEventPublisher = publisher as? any V2ImmediateForegroundDirectEventPublishing
        self.maximumPendingRooms = maximumPendingRooms
        self.maximumConcurrentPublications = maximumConcurrentPublications
        self.maximumGroupEventsPerBatch = maximumGroupEventsPerBatch
        self.maximumPendingGroupEventsPerRoom = maximumPendingGroupEventsPerRoom
        self.groupBatchDelay = groupBatchDelay
        self.groupBatchExtensionDelay = groupBatchExtensionDelay
        self.groupBatchExtensionMinimumEvents = groupBatchExtensionMinimumEvents
        self.metrics = metrics
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = stream.stream
        signalContinuation = stream.continuation
    }

    public func submitForegroundHint(_ hint: V2GroupEventWake) {
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            if let existing = state.pending[hint.roomID],
               existing.wake.highWatermark >= hint.highWatermark {
                return false
            }
            if state.pending[hint.roomID] == nil,
               state.pending.count >= maximumPendingRooms,
               let bufferedRoom = state.pending.keys.first {
                // 提示允许丢失，持久化游标拉取才是恢复路径。
                // 保留数量有界的最新房间集合。
                state.pending.removeValue(forKey: bufferedRoom)
            }
            state.pending[hint.roomID] = .init(
                wake: hint,
                directEvent: nil,
                groupEvents: [],
                groupEventSequences: [],
                requiresOrderingSort: false,
                degradedToWake: false
            )
            return true
        }
        if accepted { signalContinuation.yield() }
    }

    public func submitForegroundDirectMessage(_ message: V2AcceptedMessage) {
        submitForegroundDirectMessage(message, excludingConnectionID: nil)
    }

    public func submitForegroundDirectMessage(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID?
    ) {
        guard let event = V2DirectRoomLiveEventDraft(
            message,
            excludingConnectionID: excludingConnectionID
        )?.materialized() else { return }
        submitForegroundDirectEvent(event)
    }

    public func submitForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) {
        if event.groupMembershipRevision != nil {
            submitGroupEvents([event])
            return
        }
        // 生产环境的单 Gateway 发布器只负责准备不可变帧，
        // 并向各连接有界邮箱追加。先完成这些操作，再接触共享回退邮箱，
        // 避免每条已接受的私聊消息都触发一次全局锁、AsyncStream 信号和执行器跳转。
        if immediateDirectEventPublisher?.publishForegroundDirectEventImmediately(event) == true {
            return
        }
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            if let existing = state.pending[event.roomID],
               existing.wake.highWatermark >= event.roomSequence {
                return false
            }
            if state.pending[event.roomID] == nil,
               state.pending.count >= maximumPendingRooms,
               let bufferedRoom = state.pending.keys.first {
                state.pending.removeValue(forKey: bufferedRoom)
            }
            state.pending[event.roomID] = .init(
                wake: .init(
                    roomID: event.roomID,
                    highWatermark: event.roomSequence
                ),
                directEvent: event,
                groupEvents: [],
                groupEventSequences: [],
                requiresOrderingSort: false,
                degradedToWake: false
            )
            return true
        }
        if accepted { signalContinuation.yield() }
    }

    private func submitGroupEvents(_ events: [V2DirectRoomLiveEvent]) {
        let results = state.withLock { state in
            events.map { appendGroupEvent($0, state: &state) }
        }
        var acceptedAny = false
        for result in results {
            metrics?.foregroundGroupEventSubmitted(
                duplicateSuppressed: result.duplicate,
                outOfOrder: result.outOfOrder,
                lateAfterPublication: result.late,
                degradedToWake: result.degraded
            )
            acceptedAny = acceptedAny || result.accepted
        }
        if acceptedAny { signalContinuation.yield() }
    }

    private func appendGroupEvent(
        _ event: V2DirectRoomLiveEvent,
        state: inout State
    ) -> GroupSubmissionResult {
        guard !state.finished else {
            return .init(
                accepted: false, duplicate: false, outOfOrder: false,
                late: false, degraded: false
            )
        }
        if state.pending[event.roomID] == nil,
           state.pending.count >= maximumPendingRooms,
           let bufferedRoom = state.pending.keys.first {
            state.pending.removeValue(forKey: bufferedRoom)
        }
        if state.pending[event.roomID]?.degradedToWake == true {
            state.pending[event.roomID]!.wake = .init(
                roomID: event.roomID,
                highWatermark: max(
                    state.pending[event.roomID]!.wake.highWatermark,
                    event.roomSequence
                )
            )
            return .init(
                accepted: true, duplicate: false, outOfOrder: false,
                late: false, degraded: false
            )
        }
        let canAppendToExisting = state.pending[event.roomID].map {
            $0.directEvent == nil
                && $0.groupEvents.last?.groupMembershipRevision
                    == event.groupMembershipRevision
        } ?? false
        if !canAppendToExisting {
            state.pending[event.roomID] = .init(
                wake: .init(
                    roomID: event.roomID,
                    highWatermark: event.roomSequence
                ),
                directEvent: nil,
                groupEvents: [],
                groupEventSequences: [],
                requiresOrderingSort: false,
                degradedToWake: false
            )
        }
        let lastSequence = state.pending[event.roomID]!.groupEvents.last?
            .roomSequence
        let outOfOrder = lastSequence.map { event.roomSequence < $0 } ?? false
        let duplicate = state.pending[event.roomID]!.groupEventSequences
            .contains(event.roomSequence)
        let late = state.recentlyPublishedHighWatermarks[event.roomID].map {
            event.roomSequence <= $0
        } ?? false
        guard !duplicate else {
            return .init(
                accepted: false, duplicate: true, outOfOrder: outOfOrder,
                late: late, degraded: false
            )
        }
        if state.pending[event.roomID]!.groupEvents.count
            >= maximumPendingGroupEventsPerRoom {
            // 进程内加速器保持有界。只有房间的积压超过整个多帧容量时才降级；
            // 普通突发流量会在排空时拆成有序帧。
            state.pending[event.roomID] = .init(
                wake: .init(
                    roomID: event.roomID,
                    highWatermark: event.roomSequence
                ),
                directEvent: nil,
                groupEvents: [],
                groupEventSequences: [],
                requiresOrderingSort: false,
                degradedToWake: true
            )
            return .init(
                accepted: true, duplicate: false, outOfOrder: outOfOrder,
                late: late, degraded: true
            )
        }
        // 原地修改字典持有的 Array。若先复制取出该值，
        // 每条事件都会触发 Array 写时复制，使热房间的开销呈平方增长。
        state.pending[event.roomID]!.appendGroupEvent(
            event,
            outOfOrder: outOfOrder
        )
        return .init(
            accepted: true, duplicate: false, outOfOrder: outOfOrder,
            late: late, degraded: false
        )
    }

    /// 由生命周期归网关运行时所有的单个任务调用。
    ///
    /// 没有任何持久状态依赖该循环，因此关闭时可以安全丢弃待处理提示；
    /// 游标与个人同步的恢复路径会修复可见性。
    public func run() async {
        for await _ in signal {
            if Task.isCancelled { return }
            if groupBatchDelay > .zero {
                try? await v2Sleep(for: groupBatchDelay)
            }
            // 安静房间保持基础延迟。事件已累积到一定数量的房间
            // 恰好获得一次有界延长，减少逐接收方 TLS 刷新，且不会无限等待。
            let shouldExtendGroupBatch = state.withLock { state in
                groupBatchExtensionDelay > .zero
                    && state.pending.values.contains {
                        $0.groupEvents.count >= groupBatchExtensionMinimumEvents
                            && $0.groupEvents.count < maximumGroupEventsPerBatch
                    }
            }
            if shouldExtendGroupBatch {
                try? await v2Sleep(for: groupBatchExtensionDelay)
            }
            let batch = state.withLock { state in
                let batch = Array(state.pending.values)
                state.pending.removeAll(keepingCapacity: true)
                return batch
            }

            // 后续房间事件只会在本次排空完成后进入下一轮排空。
            // 同一轮内各房间相互独立：客户端仍要求游标精确连续；
            // 遇到重复、缺口或丢失的提示时回退到持久化日志。
            var lowerBound = 0
            while lowerBound < batch.count {
                if Task.isCancelled { return }
                let upperBound = min(
                    lowerBound + maximumConcurrentPublications, batch.count
                )
                let slice = batch[lowerBound..<upperBound]
                let publicationSink = publisher
                let immediateSink = immediateDirectEventPublisher
                var fallbacks: [Publication] = []
                fallbacks.reserveCapacity(slice.count)
                for item in slice {
                    let event = item.directEvent
                    if !item.groupEvents.isEmpty {
                        let ordered = item.requiresOrderingSort
                            ? item.groupEvents.sorted {
                                $0.roomSequence < $1.roomSequence
                            }
                            : item.groupEvents
                        if publishGroupEventsImmediately(
                            ordered,
                            sink: immediateSink
                        ) {
                            continue
                        }
                        fallbacks.append(.init(
                            wake: item.wake,
                            directEvent: nil,
                            groupEvents: ordered
                        ))
                        continue
                    }
                    if let event,
                       immediateSink?.publishForegroundDirectEventImmediately(event) == true {
                        continue
                    }
                    fallbacks.append(.init(
                        wake: item.wake,
                        directEvent: event,
                        groupEvents: []
                    ))
                }
                guard !fallbacks.isEmpty else {
                    lowerBound = upperBound
                    continue
                }
                await withTaskGroup(of: Void.self) { group in
                    for publication in fallbacks {
                        group.addTask {
                            guard !Task.isCancelled else { return }
                            if !publication.groupEvents.isEmpty {
                                for batch in self.groupEventBatches(
                                    publication.groupEvents
                                ) {
                                    await publicationSink.publishForegroundGroupEvents(batch)
                                    self.recordPublishedGroupBatch(batch)
                                }
                            } else if let event = publication.directEvent {
                                await publicationSink.publishForegroundDirectEvent(event)
                            } else {
                                await publicationSink.publishForegroundHint(publication.wake)
                            }
                        }
                    }
                }
                lowerBound = upperBound
            }
        }
    }

    public func finish() {
        let shouldFinish = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            state.pending.removeAll(keepingCapacity: false)
            return true
        }
        if shouldFinish { signalContinuation.finish() }
    }

    func pendingRoomCount() -> Int { state.withLock { $0.pending.count } }

    private func publishGroupEventsImmediately(
        _ events: [V2DirectRoomLiveEvent],
        sink: (any V2ImmediateForegroundDirectEventPublishing)?
    ) -> Bool {
        guard let sink else { return false }
        for batch in groupEventBatches(events) {
            guard sink.publishForegroundGroupEventsImmediately(batch) else {
                // 常规异步发布路径会重新发布整个有序序列。
                // 前台事件具备幂等性，因此可安全修复部分传输生命周期未命中。
                return false
            }
            recordPublishedGroupBatch(batch)
        }
        return true
    }

    private func groupEventBatches(
        _ events: [V2DirectRoomLiveEvent]
    ) -> [[V2DirectRoomLiveEvent]] {
        guard events.count > maximumGroupEventsPerBatch else { return [events] }
        var batches: [[V2DirectRoomLiveEvent]] = []
        batches.reserveCapacity(
            (events.count + maximumGroupEventsPerBatch - 1)
                / maximumGroupEventsPerBatch
        )
        var lowerBound = 0
        while lowerBound < events.count {
            let upperBound = min(
                lowerBound + maximumGroupEventsPerBatch,
                events.count
            )
            batches.append(Array(events[lowerBound..<upperBound]))
            lowerBound = upperBound
        }
        return batches
    }

    private func recordPublishedGroupBatch(_ events: [V2DirectRoomLiveEvent]) {
        guard let last = events.last else { return }
        state.withLock { state in
            if state.recentlyPublishedHighWatermarks[last.roomID] == nil,
               state.recentlyPublishedHighWatermarks.count >= maximumPendingRooms,
               let evictedRoom = state.recentlyPublishedHighWatermarks.keys.first {
                state.recentlyPublishedHighWatermarks.removeValue(forKey: evictedRoom)
            }
            state.recentlyPublishedHighWatermarks[last.roomID] = max(
                state.recentlyPublishedHighWatermarks[last.roomID] ?? 0,
                last.roomSequence
            )
        }
        metrics?.foregroundGroupEventBatchPublished(eventCount: events.count)
    }
}

public struct V2GroupEventWakeRelayReport: Equatable, Sendable {
    public let claimed: Int
    public let published: Int
    public let retryScheduled: Int

    public init(claimed: Int, published: Int, retryScheduled: Int) {
        self.claimed = claimed
        self.published = published
        self.retryScheduled = retryScheduled
    }
}

/// 从持久合并表到非权威路由机制的有界桥接。
///
/// 发布失败绝不会回滚房间事件或扇出；它只会把前台可见性推迟到一次重试或游标拉取之后。
public struct V2GroupEventWakeRelay: Sendable {
    private let store: any V2GroupEventWakeStore
    private let publisher: any V2GroupEventWakePublishing
    private let leaseDuration: TimeInterval
    private let retryMaximumDelay: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        store: any V2GroupEventWakeStore,
        publisher: any V2GroupEventWakePublishing,
        leaseDuration: TimeInterval = 15,
        retryMaximumDelay: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(leaseDuration > 0 && retryMaximumDelay > 0)
        self.store = store
        self.publisher = publisher
        self.leaseDuration = leaseDuration
        self.retryMaximumDelay = retryMaximumDelay
        self.now = now
    }

    public func runOnce(limit: Int) async throws -> V2GroupEventWakeRelayReport {
        precondition(limit > 0)
        let leases = try await store.claimPending(now: now(), leaseDuration: leaseDuration, limit: limit)
        var published = 0
        var retryScheduled = 0
        for lease in leases {
            do {
                try Task.checkCancellation()
                try await publisher.publish(lease.wake)
                try await store.markPublished(lease)
                published += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard lease.attempt > 0 else {
                    throw V2GroupEventWakeStoreError.corruptPersistenceState
                }
                let exponent = min(lease.attempt - 1, 5)
                let delay = min(retryMaximumDelay, pow(2, Double(exponent)))
                guard let nextAttemptAt = v2PostgresFutureTimestamp(now: now(), interval: delay) else {
                    throw V2GroupEventWakeStoreError.corruptPersistenceState
                }
                try await store.scheduleRetry(lease, nextAttemptAt: nextAttemptAt)
                retryScheduled += 1
            }
        }
        return .init(claimed: leases.count, published: published, retryScheduled: retryScheduled)
    }
}

/// 本地群事件唤醒发布器。
///
/// 单节点开发部署可以直接路由到本地注册表。
/// 多网关部署会用 NATS 适配器替换该发布器；
/// 两者都保持相同的纯元数据唤醒契约。
public struct V2LocalGroupEventWakePublisher:
    V2GroupEventWakePublishing,
    V2ForegroundGroupEventHintPublishing,
    V2ImmediateForegroundDirectEventPublishing
{
    private let registry: V2DeviceConnectionRegistry

    public init(registry: V2DeviceConnectionRegistry) { self.registry = registry }

    public func publish(_ wake: V2GroupEventWake) async throws {
        await registry.notifyForegroundGroupAvailable(roomID: wake.roomID, highWatermark: wake.highWatermark)
    }

    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        await registry.notifyForegroundGroupAvailable(roomID: hint.roomID, highWatermark: hint.highWatermark)
    }

    public func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        await registry.notifyForegroundDirectEvent(event)
    }

    public func publishForegroundGroupEvents(_ events: [V2DirectRoomLiveEvent]) async {
        await registry.notifyForegroundGroupEvents(events)
    }

    func publishForegroundDirectEventImmediately(_ event: V2DirectRoomLiveEvent) -> Bool {
        registry.submitForegroundDirectEvent(event)
    }

    func publishForegroundGroupEventsImmediately(
        _ events: [V2DirectRoomLiveEvent]
    ) -> Bool {
        registry.submitForegroundGroupEvents(events)
    }
}
