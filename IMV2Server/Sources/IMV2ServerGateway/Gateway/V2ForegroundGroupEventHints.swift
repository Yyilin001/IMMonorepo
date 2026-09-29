import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization

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
