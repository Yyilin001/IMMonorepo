import Foundation
import IMV2Core

/// Stable, process-local partitioning for message admission.
///
/// Every room is routed to exactly one lane for the lifetime of this value,
/// so commands for that room retain the existing FIFO and no-overtake
/// guarantees. Independent rooms can progress on separate actor executors.
/// Database concurrency is split across lanes. Pending requests instead use
/// one process-wide limiter, so skewed room hashes can borrow idle capacity
/// without silently increasing PostgreSQL pressure or retained request memory.
public final class V2ShardedSendMessageAdmissionBatcher: V2SendMessageAdmission, Sendable {
    private let lanes: [V2SendMessageAdmissionBatcher]

    nonisolated public let managesForegroundWriteAdmission: Bool
    nonisolated public let publishesCommittedGroupEvents: Bool

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

    public func accept(
        _ request: consuming V2RoomWriteRequest
    ) async throws -> V2SendMessageOutcome {
        let ownedRequest = consume request
        return try await lanes[Self.laneIndex(
            for: ownedRequest.command.roomID,
            laneCount: lanes.count
        )].accept(ownedRequest)
    }

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

    /// FNV-1a is deterministic across launches, unlike Swift's randomized
    /// `Hashable` seed. Stable routing is required for reproducible load tests
    /// and ensures one room cannot move between lanes during a process run.
    static func laneIndex(for roomID: RoomID, laneCount: Int) -> Int {
        precondition(laneCount > 0)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in roomID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(laneCount))
    }

    private static func portion(total: Int, index: Int, count: Int) -> Int {
        (total / count) + (index < total % count ? 1 : 0)
    }

    private static func ceilingDivide(_ value: Int, by divisor: Int) -> Int {
        (value + divisor - 1) / divisor
    }

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

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let sum = partial.addingReportingOverflow(value)
            return sum.overflow ? .max : sum.partialValue
        }
    }
}
