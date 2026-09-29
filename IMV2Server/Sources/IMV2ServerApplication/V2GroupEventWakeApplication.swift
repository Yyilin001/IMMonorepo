import Foundation
import IMV2Core
import IMV2ServerContracts
import Synchronization

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

    private let directRoomLogEventCache: (any V2CommittedRoomLogObserving)?
    private let state = Mutex(State())

    public init(directRoomLogEventCache: (any V2CommittedRoomLogObserving)?) {
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
