import Foundation
import IMV2Core

/// 消息准入的稳定进程内分片。
///
/// 每个房间在本值存活期间只会落入固定的一条通道，因此该房间的命令仍保持既有的
/// 先进先出与不可超越语义；相互独立的房间则可以在不同 actor 执行器上并行推进。
/// 数据库并发被拆分到各通道，而待处理请求改用进程级统一限流器，
/// 使哈希偏斜的房间可以借用空闲容量，又不会悄悄抬高 PostgreSQL 压力或驻留内存。
public final class V2ShardedSendMessageAdmissionBatcher: V2SendMessageAdmission, Sendable {
    private let lanes: [V2SendMessageAdmissionBatcher]

    /// 是否接管前台写入准入。
    nonisolated public let managesForegroundWriteAdmission: Bool
    /// 是否发布已提交的群事件。
    nonisolated public let publishesCommittedGroupEvents: Bool

    /// 构造分片准入器。
    ///
    /// 各通道的在途批量额度按商与余数精确分配；自适应策略中的最小窗口请求数按通道数向上取整，
    /// 但至少为 2，保证单通道仍能观察到足够样本。进程级待处理上限由共享容量统一持有，
    /// 通道内保留同值仅用于配置校验与诊断。
    ///
    /// - Parameters:
    ///   - store: 执行原子批量写入的存储。
    ///   - configuration: 基础批量接入配置。
    ///   - laneCount: 通道数量，需大于 1 且不超过在途批量与待处理请求上限。
    ///   - databaseWorkAdmission: 可选的数据库工作准入控制器。
    ///   - committedMessageObserver: 可选的已提交消息观察者。
    public init(
        store: any V2AtomicRoomWriteBatchStore,
        configuration: V2SendMessageAdmissionBatcher.Configuration,
        laneCount: Int,
        databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
        committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil
    ) {
        precondition(laneCount > 1)
        precondition(laneCount <= configuration.maximumInFlightBatches)
        precondition(laneCount <= configuration.maximumPendingRequests)

        managesForegroundWriteAdmission = databaseWorkAdmission != nil
        publishesCommittedGroupEvents = committedMessageObserver != nil
        let sharedPendingCapacity = V2SharedSendMessagePendingCapacity(
            maximum: configuration.maximumPendingRequests
        )
        lanes = (0 ..< laneCount).map { laneIndex in
            let inFlight = Self.portion(
                total: configuration.maximumInFlightBatches,
                index: laneIndex,
                count: laneCount
            )
            let adaptivePolicy = configuration.adaptiveDelayPolicy.map { policy in
                V2SendMessageAdmissionBatcher.Configuration.AdaptiveDelayPolicy(
                    highActivityMaximumDelay: policy.highActivityMaximumDelay,
                    minimumRequestsInWindow: max(
                        2,
                        Self.ceilingDivide(policy.minimumRequestsInWindow, by: laneCount)
                    ),
                    observationWindow: policy.observationWindow
                )
            }
            return V2SendMessageAdmissionBatcher(
                store: store,
                configuration: .init(
                    maximumBatchSize: configuration.maximumBatchSize,
                    maximumDelay: configuration.maximumDelay,
                    adaptiveDelayPolicy: adaptivePolicy,
                    maximumInFlightBatches: inFlight,
                    // The shared capacity below owns the process-wide bound.
                    // Retain the same value here for configuration invariants
                    // and diagnostics; a lane no longer gets a hard slice.
                    maximumPendingRequests: configuration.maximumPendingRequests
                ),
                databaseWorkAdmission: databaseWorkAdmission,
                sharedPendingCapacity: sharedPendingCapacity,
                committedMessageObserver: committedMessageObserver
            )
        }
    }

    /// 接受一条房间写入请求。
    ///
    /// 请求按房间标识的稳定哈希进入固定通道，从而保持该房间的命令顺序。
    ///
    /// - Parameter request: 待接受的写入请求，函数会消费该值。
    /// - Returns: 写入结果。
    /// - Throws: 准入拒绝、取消或存储失败时抛出。
    public func accept(
        _ request: consuming V2RoomWriteRequest
    ) async throws -> V2SendMessageOutcome {
        let ownedRequest = consume request
        return try await lanes[Self.laneIndex(
            for: ownedRequest.command.roomID,
            laneCount: lanes.count
        )].accept(ownedRequest)
    }

    /// 汇总各通道的运行快照。
    ///
    /// 计数类指标在求和时饱和到 `UInt64.max`，最大值类指标取各通道最大值，
    /// 布尔类指标取任一通道为真，避免长跑进程因溢出产生错误读数。
    ///
    /// - Returns: 聚合后的准入快照。
    public func snapshot() async -> V2SendMessageAdmissionBatcher.Snapshot {
        let laneSnapshots = await withTaskGroup(
            of: V2SendMessageAdmissionBatcher.Snapshot.self,
            returning: [V2SendMessageAdmissionBatcher.Snapshot].self
        ) { group in
            for lane in lanes {
                group.addTask { await lane.snapshot() }
            }
            var snapshots: [V2SendMessageAdmissionBatcher.Snapshot] = []
            snapshots.reserveCapacity(lanes.count)
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }
        return Self.aggregate(laneSnapshots)
    }

    /// 计算房间所属通道下标。
    ///
    /// 这里使用 FNV-1a 而非 Swift 随机化的 `Hashable` 种子，以获得跨启动的确定性：
    /// 稳定路由是压测可复现的前提，也保证同一房间在进程运行期间不会在通道间迁移。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - laneCount: 通道数量，需大于零。
    /// - Returns: 通道下标。
    static func laneIndex(for roomID: RoomID, laneCount: Int) -> Int {
        precondition(laneCount > 0)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in roomID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(laneCount))
    }

    /// 按商与余数把一个总量精确分配到第 `index` 份。
    ///
    /// - Parameters:
    ///   - total: 待分配总量。
    ///   - index: 当前份下标。
    ///   - count: 总份数。
    /// - Returns: 该份应得的数量；各份之和等于 `total`。
    private static func portion(total: Int, index: Int, count: Int) -> Int {
        (total / count) + (index < total % count ? 1 : 0)
    }

    /// 计算向上取整的整数除法。
    ///
    /// - Parameters:
    ///   - value: 被除数。
    ///   - divisor: 除数。
    /// - Returns: 向上取整的结果。
    private static func ceilingDivide(_ value: Int, by divisor: Int) -> Int {
        // Inputs are positive. Adding the divisor first can overflow even
        // though both the threshold and its per-lane result are representable.
        (value / divisor) + (value % divisor == 0 ? 0 : 1)
    }

    /// 聚合各通道快照。
    ///
    /// - Parameter snapshots: 各通道快照。
    /// - Returns: 聚合后的快照。
    private static func aggregate(
        _ snapshots: [V2SendMessageAdmissionBatcher.Snapshot]
    ) -> V2SendMessageAdmissionBatcher.Snapshot {
        .init(
            pendingRequests: snapshots.reduce(0) { $0 + $1.pendingRequests },
            inFlightBatches: snapshots.reduce(0) { $0 + $1.inFlightBatches },
            activeRooms: snapshots.reduce(0) { $0 + $1.activeRooms },
            laneCount: snapshots.count,
            busiestLanePendingRequests: snapshots.map(\.pendingRequests).max() ?? 0,
            busiestLaneInFlightBatches: snapshots.map(\.inFlightBatches).max() ?? 0,
            dequeuedRequests: saturatingSum(snapshots.map(\.dequeuedRequests)),
            queueWaitMillisecondsTotal: saturatingSum(
                snapshots.map(\.queueWaitMillisecondsTotal)
            ),
            queueWaitMillisecondsMax: snapshots.map(\.queueWaitMillisecondsMax).max() ?? 0,
            completedBatches: saturatingSum(snapshots.map(\.completedBatches)),
            batchExecutionMillisecondsTotal: saturatingSum(
                snapshots.map(\.batchExecutionMillisecondsTotal)
            ),
            batchExecutionMillisecondsMax:
                snapshots.map(\.batchExecutionMillisecondsMax).max() ?? 0,
            stagingQueueFullRejections: saturatingSum(
                snapshots.map(\.stagingQueueFullRejections)
            ),
            cancelledPendingRequests: saturatingSum(
                snapshots.map(\.cancelledPendingRequests)
            ),
            baseDelayFlushes: saturatingSum(snapshots.map(\.baseDelayFlushes)),
            highActivityDelayFlushes: saturatingSum(
                snapshots.map(\.highActivityDelayFlushes)
            ),
            highActivityDelayScheduled: snapshots.contains {
                $0.highActivityDelayScheduled
            },
            atomicBatchAttempts: saturatingSum(snapshots.map(\.atomicBatchAttempts)),
            atomicBatchCommitted: saturatingSum(snapshots.map(\.atomicBatchCommitted)),
            atomicBatchFallbacks: saturatingSum(snapshots.map(\.atomicBatchFallbacks)),
            atomicBatchCommittedRequests: saturatingSum(
                snapshots.map(\.atomicBatchCommittedRequests)
            ),
            atomicBatchFallbackRequests: saturatingSum(
                snapshots.map(\.atomicBatchFallbackRequests)
            ),
            atomicBatchFallbackReasons: Dictionary(uniqueKeysWithValues:
                V2AtomicRoomWriteBatchError.Reason.allCases.map { reason in
                    (reason, saturatingSum(snapshots.map {
                        $0.atomicBatchFallbackReasons[reason, default: 0]
                    }))
                }
            ),
            sameRoomDeferredRequests: saturatingSum(
                snapshots.map(\.sameRoomDeferredRequests)
            ),
            atomicPreclassifiedIndividualRequests: saturatingSum(
                snapshots.map(\.atomicPreclassifiedIndividualRequests)
            ),
            singletonDispatches: saturatingSum(snapshots.map(\.singletonDispatches))
        )
    }

    /// 以饱和方式求和，溢出时返回 `UInt64.max`。
    ///
    /// - Parameter values: 待求和的计数。
    /// - Returns: 求和结果。
    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let sum = partial.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }
}
