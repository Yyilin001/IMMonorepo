import Foundation

public enum V2DatabasePoolMetricClass: String, CaseIterable, Sendable {
    case shared
    case foreground
    case sync
    case delivery
    case projection
    case maintenance
}

public struct V2DatabasePoolMetric: Equatable, Sendable {
    public let poolClass: V2DatabasePoolMetricClass
    public let eventLoopHandles: Int
    public let connectionCeiling: Int

    public init(
        poolClass: V2DatabasePoolMetricClass,
        eventLoopHandles: Int,
        connectionCeiling: Int
    ) {
        precondition(eventLoopHandles > 0)
        precondition(connectionCeiling > 0)
        self.poolClass = poolClass
        self.eventLoopHandles = eventLoopHandles
        self.connectionCeiling = connectionCeiling
    }
}

public struct V2DatabasePoolTopologySnapshot: Equatable, Sendable {
    public let pools: [V2DatabasePoolMetric]

    public init(pools: [V2DatabasePoolMetric]) {
        precondition(!pools.isEmpty)
        precondition(Set(pools.map(\.poolClass)).count == pools.count)
        self.pools = pools.sorted { $0.poolClass.rawValue < $1.poolClass.rawValue }
    }
}

public struct V2RuntimePressureMetricsSnapshot: Equatable, Sendable {
    public let databaseWork: V2DatabaseWorkAdmissionSnapshot
    public let databasePools: V2DatabasePoolTopologySnapshot
    public let syncWake: V2SyncWakeCoalescerSnapshot
    /// Present only when direct room-log command credit batching is enabled.
    /// This is deliberately aggregate-only: shard IDs, room IDs and leases
    /// must never become Prometheus labels.
    public let shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool.Snapshot?
    /// Aggregate room-command credits. This intentionally has no room or
    /// lease labels; it exists to verify that the semantic-preserving room
    /// admission optimization is reserving bounded durable batches.
    public let roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool.Snapshot?
    /// Present only when ordered direct-room append batching is enabled. It
    /// exposes process-local queue and timer facts, never room/user/request
    /// identifiers, so an adaptive rollout can be verified without a SQL
    /// inference or high-cardinality labels.
    public let directRoomLogAppendBatching: V2SendMessageAdmissionBatcher.Snapshot?
    /// Aggregate group read-cursor micro-batch facts. These counters contain
    /// no room, user or operation identifiers and are sufficient to verify
    /// that production traffic, rather than only a synthetic load shape, is
    /// sharing transactions.
    public let readReceiptBatching: V2ReadReceiptBatcher.Snapshot?
    /// Fixed-stage latency histograms for the authoritative shard-only direct
    /// append transaction. Stage names are an enum, never dynamic SQL or
    /// relation identifiers.
    public let directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot?
    /// Scheduler delay observed on the TLS child-channel EventLoop group.
    public let gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot?
    /// Aggregate LRU facts for the policy hint cache. This proves whether a
    /// deployment is operating at capacity without exposing cache keys.
    public let directSendPolicy: V2DirectSendPolicyCache.Snapshot?
    /// Aggregate results from the conditional one-statement direct append.
    /// It intentionally contains no room, user, operation, or policy labels.
    public let directRoomLogFastAppend: V2DirectRoomLogFastAppendCache.Snapshot?
    /// Best-effort local direct-event cache facts. No room, user or event ID
    /// is exposed as a metric label.
    public let directRoomLogEventCache: V2DirectRoomLogEventCache.Snapshot?
    /// Shared encoded group-page occupancy and lookup outcomes. The cache key
    /// is deliberately not exposed, so room and event identifiers never
    /// become metrics labels.
    public let preparedGroupEventPageCache: V2PreparedGroupEventPageCache.Snapshot?
    /// Aggregate heartbeat renewal batching facts. Connection and user IDs are
    /// intentionally absent to keep this operational metric low-cardinality.
    public let livePresenceRenewals: V2LivePresenceRenewalBatcher.Snapshot?

    public init(
        databaseWork: V2DatabaseWorkAdmissionSnapshot,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWake: V2SyncWakeCoalescerSnapshot,
        shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool.Snapshot? = nil,
        roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool.Snapshot? = nil,
        directRoomLogAppendBatching: V2SendMessageAdmissionBatcher.Snapshot? = nil,
        readReceiptBatching: V2ReadReceiptBatcher.Snapshot? = nil,
        directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot? = nil,
        gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot? = nil,
        directSendPolicy: V2DirectSendPolicyCache.Snapshot? = nil,
        directRoomLogFastAppend: V2DirectRoomLogFastAppendCache.Snapshot? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCache.Snapshot? = nil,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCache.Snapshot? = nil,
        livePresenceRenewals: V2LivePresenceRenewalBatcher.Snapshot? = nil
    ) {
        self.databaseWork = databaseWork
        self.databasePools = databasePools
        self.syncWake = syncWake
        self.shardAdmissionCommandCredits = shardAdmissionCommandCredits
        self.roomAdmissionCommandCredits = roomAdmissionCommandCredits
        self.directRoomLogAppendBatching = directRoomLogAppendBatching
        self.readReceiptBatching = readReceiptBatching
        self.directRoomLogAppendStages = directRoomLogAppendStages
        self.gatewayEventLoopLag = gatewayEventLoopLag
        self.directSendPolicy = directSendPolicy
        self.directRoomLogFastAppend = directRoomLogFastAppend
        self.directRoomLogEventCache = directRoomLogEventCache
        self.preparedGroupEventPageCache = preparedGroupEventPageCache
        self.livePresenceRenewals = livePresenceRenewals
    }
}

public protocol V2RuntimePressureMetricsSource: Sendable {
    func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot
}

public struct V2GatewayRuntimePressureMetricsSource: V2RuntimePressureMetricsSource {
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController
    private let databasePools: V2DatabasePoolTopologySnapshot
    private let syncWakeCoalescer: V2SyncWakeCoalescer
    private let shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool?
    private let roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool?
    private let directRoomLogAppendBatcher: (any V2SendMessageAdmission)?
    private let readReceiptBatcher: V2ReadReceiptBatcher?
    private let directRoomLogAppendStageMetrics: V2DirectRoomLogAppendStageMetrics?
    private let gatewayEventLoopLagMetrics: V2EventLoopLagMetrics?
    private let directSendPolicyCache: V2DirectSendPolicyCache?
    private let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache?
    private let directRoomLogEventCache: V2DirectRoomLogEventCache?
    private let preparedGroupEventPageCache: V2PreparedGroupEventPageCache?
    private let connectionRegistry: V2DeviceConnectionRegistry?

    public init(
        databaseWorkAdmission: V2DatabaseWorkAdmissionController,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWakeCoalescer: V2SyncWakeCoalescer,
        shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool? = nil,
        roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool? = nil,
        directRoomLogAppendBatcher: (any V2SendMessageAdmission)? = nil,
        readReceiptBatcher: V2ReadReceiptBatcher? = nil,
        directRoomLogAppendStageMetrics: V2DirectRoomLogAppendStageMetrics? = nil,
        gatewayEventLoopLagMetrics: V2EventLoopLagMetrics? = nil,
        directSendPolicyCache: V2DirectSendPolicyCache? = nil,
        directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCache? = nil,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCache? = nil,
        connectionRegistry: V2DeviceConnectionRegistry? = nil
    ) {
        self.databaseWorkAdmission = databaseWorkAdmission
        self.databasePools = databasePools
        self.syncWakeCoalescer = syncWakeCoalescer
        self.shardAdmissionCommandCredits = shardAdmissionCommandCredits
        self.roomAdmissionCommandCredits = roomAdmissionCommandCredits
        self.directRoomLogAppendBatcher = directRoomLogAppendBatcher
        self.readReceiptBatcher = readReceiptBatcher
        self.directRoomLogAppendStageMetrics = directRoomLogAppendStageMetrics
        self.gatewayEventLoopLagMetrics = gatewayEventLoopLagMetrics
        self.directSendPolicyCache = directSendPolicyCache
        self.directRoomLogFastAppendCache = directRoomLogFastAppendCache
        self.directRoomLogEventCache = directRoomLogEventCache
        self.preparedGroupEventPageCache = preparedGroupEventPageCache
        self.connectionRegistry = connectionRegistry
    }

    public func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot {
        async let databaseWork = databaseWorkAdmission.snapshot()
        async let syncWake = syncWakeCoalescer.snapshot()
        let credits = await shardAdmissionCommandCredits?.snapshot()
        let roomCredits = await roomAdmissionCommandCredits?.snapshot()
        let appendBatching = await directRoomLogAppendBatcher?.snapshot()
        let receiptBatching = await readReceiptBatcher?.snapshot()
        let appendStages = directRoomLogAppendStageMetrics?.snapshot()
        let eventLoopLag = gatewayEventLoopLagMetrics?.snapshot()
        let directSendPolicy = await directSendPolicyCache?.snapshot()
        let fastAppend = await directRoomLogFastAppendCache?.snapshot()
        let eventCache = await directRoomLogEventCache?.snapshot()
        let preparedPageCache = preparedGroupEventPageCache?.snapshot()
        let livePresenceRenewals = await connectionRegistry?.livePresenceRenewalMetrics()
        return await .init(
            databaseWork: databaseWork,
            databasePools: databasePools,
            syncWake: syncWake,
            shardAdmissionCommandCredits: credits,
            roomAdmissionCommandCredits: roomCredits,
            directRoomLogAppendBatching: appendBatching,
            readReceiptBatching: receiptBatching,
            directRoomLogAppendStages: appendStages,
            gatewayEventLoopLag: eventLoopLag,
            directSendPolicy: directSendPolicy,
            directRoomLogFastAppend: fastAppend,
            directRoomLogEventCache: eventCache,
            preparedGroupEventPageCache: preparedPageCache,
            livePresenceRenewals: livePresenceRenewals
        )
    }
}

public func v2RenderPrometheusRuntimePressureMetrics(
    _ snapshot: V2RuntimePressureMetricsSnapshot
) -> String {
    var lines = [
        "# HELP im_v2_database_pool_event_loop_handles Configured Fluent handles spanning the application EventLoops by fixed pool class.",
        "# TYPE im_v2_database_pool_event_loop_handles gauge",
    ]
    for pool in snapshot.databasePools.pools {
        lines.append(
            "im_v2_database_pool_event_loop_handles{pool=\"\(pool.poolClass.rawValue)\"} \(pool.eventLoopHandles)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_pool_connection_ceiling Configured maximum PostgreSQL connections across all EventLoops by fixed pool class.",
        "# TYPE im_v2_database_pool_connection_ceiling gauge",
    ])
    for pool in snapshot.databasePools.pools {
        lines.append(
            "im_v2_database_pool_connection_ceiling{pool=\"\(pool.poolClass.rawValue)\"} \(pool.connectionCeiling)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_in_flight Process-local admitted database work by reserved class.",
        "# TYPE im_v2_database_work_in_flight gauge",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_in_flight{class=\"\(workClass.rawValue)\"} \(value.inFlight)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_queued Process-local short admission queue by reserved class.",
        "# TYPE im_v2_database_work_queued gauge",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_queued{class=\"\(workClass.rawValue)\"} \(value.queued)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_admissions_total Requests admitted immediately or from a bounded queue.",
        "# TYPE im_v2_database_work_admissions_total counter",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_admissions_total{class=\"\(workClass.rawValue)\"} \(value.admittedRequests)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_rejections_total Requests rejected before the Fluent database pool wait.",
        "# TYPE im_v2_database_work_rejections_total counter",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_rejections_total{class=\"\(workClass.rawValue)\",reason=\"queue_full\"} \(value.queueFullRejections)"
        )
        lines.append(
            "im_v2_database_work_rejections_total{class=\"\(workClass.rawValue)\",reason=\"timeout\"} \(value.timeoutRejections)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_cancellations_total Queued requests removed because their owning task was cancelled.",
        "# TYPE im_v2_database_work_cancellations_total counter",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_cancellations_total{class=\"\(workClass.rawValue)\"} \(value.cancelledRequests)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_queue_wait_milliseconds Time requests spent waiting in the process-local database admission queue by reserved class.",
        "# TYPE im_v2_database_work_queue_wait_milliseconds histogram",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let wait = snapshot.databaseWork.value(for: workClass).queueWait
        for bucket in V2DatabaseWorkAdmissionWaitBucket.allCases {
            lines.append(
                "im_v2_database_work_queue_wait_milliseconds_bucket{class=\"\(workClass.rawValue)\",le=\"\(bucket.rawValue)\"} \(wait.count(atOrBelow: bucket))"
            )
        }
        lines.append(
            "im_v2_database_work_queue_wait_milliseconds_bucket{class=\"\(workClass.rawValue)\",le=\"+Inf\"} \(wait.samples)"
        )
        lines.append(
            "im_v2_database_work_queue_wait_milliseconds_sum{class=\"\(workClass.rawValue)\"} \(wait.sumMilliseconds)"
        )
        lines.append(
            "im_v2_database_work_queue_wait_milliseconds_count{class=\"\(workClass.rawValue)\"} \(wait.samples)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_sync_wake_pending_users Users waiting for the next coalescer flush.",
        "# TYPE im_v2_sync_wake_pending_users gauge",
        "im_v2_sync_wake_pending_users \(snapshot.syncWake.pendingUsers)",
        "# HELP im_v2_sync_wake_in_flight_users Users currently being delivered by the coalescer flush.",
        "# TYPE im_v2_sync_wake_in_flight_users gauge",
        "im_v2_sync_wake_in_flight_users \(snapshot.syncWake.inFlightUsers)",
        "# HELP im_v2_sync_wake_coalesced_total Redundant per-user availability hints collapsed in-process.",
        "# TYPE im_v2_sync_wake_coalesced_total counter",
        "im_v2_sync_wake_coalesced_total \(snapshot.syncWake.coalescedNotifications)",
        "# HELP im_v2_sync_wake_delivered_total Best-effort Sync availability hints completed by the downstream notifier.",
        "# TYPE im_v2_sync_wake_delivered_total counter",
        "im_v2_sync_wake_delivered_total \(snapshot.syncWake.deliveredNotifications)",
        "# HELP im_v2_sync_wake_dropped_total Best-effort hints dropped at the bounded pending-user ceiling or shutdown.",
        "# TYPE im_v2_sync_wake_dropped_total counter",
        "im_v2_sync_wake_dropped_total \(snapshot.syncWake.droppedNotifications)",
    ])
    if let credits = snapshot.shardAdmissionCommandCredits {
        lines.append(contentsOf: [
            "# HELP im_v2_shard_admission_command_credits Process-local, already durable-charged command-window credits for direct room-event-log sends.",
            "# TYPE im_v2_shard_admission_command_credits gauge",
            "im_v2_shard_admission_command_credits{state=\"available\"} \(credits.activeCredits)",
            "im_v2_shard_admission_command_credits{state=\"in_flight\"} \(credits.inFlightCredits)",
            "# HELP im_v2_shard_admission_command_credit_reservations_total Durable batch reservations of direct room-event-log command credits.",
            "# TYPE im_v2_shard_admission_command_credit_reservations_total counter",
            "im_v2_shard_admission_command_credit_reservations_total \(credits.batchReservations)",
            "# HELP im_v2_shard_admission_command_credits_reserved_total Command-window credits durably charged in PostgreSQL batches.",
            "# TYPE im_v2_shard_admission_command_credits_reserved_total counter",
            "im_v2_shard_admission_command_credits_reserved_total \(credits.databaseCreditsReserved)",
            "# HELP im_v2_shard_admission_command_credits_committed_total Credits consumed by committed message transactions.",
            "# TYPE im_v2_shard_admission_command_credits_committed_total counter",
            "im_v2_shard_admission_command_credits_committed_total \(credits.committedCredits)",
            "# HELP im_v2_shard_admission_command_credit_rejections_total Requests rejected because the durable command window is full.",
            "# TYPE im_v2_shard_admission_command_credit_rejections_total counter",
            "im_v2_shard_admission_command_credit_rejections_total \(credits.capacityRejections)",
        ])
    }
    if let credits = snapshot.roomAdmissionCommandCredits {
        lines.append(contentsOf: [
            "# HELP im_v2_room_admission_command_credits Process-local, already durable-charged per-room command-window credits for direct room-event-log sends.",
            "# TYPE im_v2_room_admission_command_credits gauge",
            "im_v2_room_admission_command_credits{state=\"available\"} \(credits.activeCredits)",
            "im_v2_room_admission_command_credits{state=\"in_flight\"} \(credits.inFlightCredits)",
            "# HELP im_v2_room_admission_command_credit_hot_rooms Locally promoted hot rooms eligible for precharged per-room command credits.",
            "# TYPE im_v2_room_admission_command_credit_hot_rooms gauge",
            "im_v2_room_admission_command_credit_hot_rooms \(credits.promotedHotRooms)",
            "# HELP im_v2_room_admission_command_credit_reservations_total Durable per-room command-credit batch reservations.",
            "# TYPE im_v2_room_admission_command_credit_reservations_total counter",
            "im_v2_room_admission_command_credit_reservations_total \(credits.batchReservations)",
            "# HELP im_v2_room_admission_command_credits_reserved_total Per-room command-window credits durably charged in PostgreSQL batches.",
            "# TYPE im_v2_room_admission_command_credits_reserved_total counter",
            "im_v2_room_admission_command_credits_reserved_total \(credits.databaseCreditsReserved)",
            "# HELP im_v2_room_admission_command_credits_committed_total Per-room credits consumed by committed message transactions.",
            "# TYPE im_v2_room_admission_command_credits_committed_total counter",
            "im_v2_room_admission_command_credits_committed_total \(credits.committedCredits)",
            "# HELP im_v2_room_admission_command_credit_rejections_total Requests rejected because a per-room durable command window is full.",
            "# TYPE im_v2_room_admission_command_credit_rejections_total counter",
            "im_v2_room_admission_command_credit_rejections_total \(credits.capacityRejections)",
        ])
    }
    if let batching = snapshot.directRoomLogAppendBatching {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_append_batch_lanes Independent room-keyed append scheduling lanes.",
            "# TYPE im_v2_direct_room_log_append_batch_lanes gauge",
            "im_v2_direct_room_log_append_batch_lanes \(batching.laneCount)",
            "# HELP im_v2_direct_room_log_append_batch_pending_requests Process-local direct append requests waiting for an atomic batch.",
            "# TYPE im_v2_direct_room_log_append_batch_pending_requests gauge",
            "im_v2_direct_room_log_append_batch_pending_requests \(batching.pendingRequests)",
            "# HELP im_v2_direct_room_log_append_batch_busiest_lane_pending_requests Pending append requests in the busiest room-keyed lane.",
            "# TYPE im_v2_direct_room_log_append_batch_busiest_lane_pending_requests gauge",
            "im_v2_direct_room_log_append_batch_busiest_lane_pending_requests \(batching.busiestLanePendingRequests)",
            "# HELP im_v2_direct_room_log_append_batch_in_flight Batches currently holding one foreground database admission.",
            "# TYPE im_v2_direct_room_log_append_batch_in_flight gauge",
            "im_v2_direct_room_log_append_batch_in_flight \(batching.inFlightBatches)",
            "# HELP im_v2_direct_room_log_append_batch_busiest_lane_in_flight Batches executing in the busiest room-keyed lane.",
            "# TYPE im_v2_direct_room_log_append_batch_busiest_lane_in_flight gauge",
            "im_v2_direct_room_log_append_batch_busiest_lane_in_flight \(batching.busiestLaneInFlightBatches)",
            "# HELP im_v2_direct_room_log_append_batch_dequeued_requests_total Requests removed from staging for durable execution.",
            "# TYPE im_v2_direct_room_log_append_batch_dequeued_requests_total counter",
            "im_v2_direct_room_log_append_batch_dequeued_requests_total \(batching.dequeuedRequests)",
            "# HELP im_v2_direct_room_log_append_batch_queue_wait_milliseconds_total Cumulative request time in append staging.",
            "# TYPE im_v2_direct_room_log_append_batch_queue_wait_milliseconds_total counter",
            "im_v2_direct_room_log_append_batch_queue_wait_milliseconds_total \(batching.queueWaitMillisecondsTotal)",
            "# HELP im_v2_direct_room_log_append_batch_queue_wait_milliseconds_max Maximum request time observed in append staging since process start.",
            "# TYPE im_v2_direct_room_log_append_batch_queue_wait_milliseconds_max gauge",
            "im_v2_direct_room_log_append_batch_queue_wait_milliseconds_max \(batching.queueWaitMillisecondsMax)",
            "# HELP im_v2_direct_room_log_append_batch_completed_total Durable append batches completed.",
            "# TYPE im_v2_direct_room_log_append_batch_completed_total counter",
            "im_v2_direct_room_log_append_batch_completed_total \(batching.completedBatches)",
            "# HELP im_v2_direct_room_log_append_batch_execution_milliseconds_total Cumulative time from batch dispatch through durable completion.",
            "# TYPE im_v2_direct_room_log_append_batch_execution_milliseconds_total counter",
            "im_v2_direct_room_log_append_batch_execution_milliseconds_total \(batching.batchExecutionMillisecondsTotal)",
            "# HELP im_v2_direct_room_log_append_batch_execution_milliseconds_max Maximum batch execution time observed since process start.",
            "# TYPE im_v2_direct_room_log_append_batch_execution_milliseconds_max gauge",
            "im_v2_direct_room_log_append_batch_execution_milliseconds_max \(batching.batchExecutionMillisecondsMax)",
            "# HELP im_v2_direct_room_log_append_batch_active_rooms Rooms currently serialized by an in-flight batch.",
            "# TYPE im_v2_direct_room_log_append_batch_active_rooms gauge",
            "im_v2_direct_room_log_append_batch_active_rooms \(batching.activeRooms)",
            "# HELP im_v2_direct_room_log_append_batch_delayed_flushes_total Delayed append batch timers that actually fired by bounded delay mode.",
            "# TYPE im_v2_direct_room_log_append_batch_delayed_flushes_total counter",
            "im_v2_direct_room_log_append_batch_delayed_flushes_total{mode=\"base\"} \(batching.baseDelayFlushes)",
            "im_v2_direct_room_log_append_batch_delayed_flushes_total{mode=\"high_activity\"} \(batching.highActivityDelayFlushes)",
            "# HELP im_v2_direct_room_log_append_atomic_batches_total Atomic direct append execution outcomes by bounded batch mode.",
            "# TYPE im_v2_direct_room_log_append_atomic_batches_total counter",
            "im_v2_direct_room_log_append_atomic_batches_total{outcome=\"attempted\"} \(batching.atomicBatchAttempts)",
            "im_v2_direct_room_log_append_atomic_batches_total{outcome=\"committed\"} \(batching.atomicBatchCommitted)",
            "im_v2_direct_room_log_append_atomic_batches_total{outcome=\"shape_fallback\"} \(batching.atomicBatchFallbacks)",
            "# HELP im_v2_direct_room_log_append_atomic_requests_total Requests by atomic direct append execution outcome.",
            "# TYPE im_v2_direct_room_log_append_atomic_requests_total counter",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"committed\"} \(batching.atomicBatchCommittedRequests)",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"shape_fallback\"} \(batching.atomicBatchFallbackRequests)",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"preclassified_individual\"} \(batching.atomicPreclassifiedIndividualRequests)",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"singleton_dispatch\"} \(batching.singletonDispatches)",
            "# HELP im_v2_direct_room_log_append_atomic_fallback_reasons_total Atomic subsets rolled back before commit by bounded store reason.",
            "# TYPE im_v2_direct_room_log_append_atomic_fallback_reasons_total counter",
        ])
        for reason in V2AtomicRoomWriteBatchError.Reason.allCases {
            lines.append(
                "im_v2_direct_room_log_append_atomic_fallback_reasons_total{reason=\"\(reason.rawValue)\"} \(batching.atomicBatchFallbackReasons[reason, default: 0])"
            )
        }
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_append_same_room_deferred_requests_total Later same-room commands serialized into subsequent unique-room waves.",
            "# TYPE im_v2_direct_room_log_append_same_room_deferred_requests_total counter",
            "im_v2_direct_room_log_append_same_room_deferred_requests_total \(batching.sameRoomDeferredRequests)",
            "# HELP im_v2_direct_room_log_append_batch_rejections_total Requests rejected because the bounded staging queue is full.",
            "# TYPE im_v2_direct_room_log_append_batch_rejections_total counter",
            "im_v2_direct_room_log_append_batch_rejections_total{reason=\"queue_full\"} \(batching.stagingQueueFullRejections)",
            "# HELP im_v2_direct_room_log_append_batch_cancellations_total Staged requests removed before durable acceptance because their caller was cancelled.",
            "# TYPE im_v2_direct_room_log_append_batch_cancellations_total counter",
            "im_v2_direct_room_log_append_batch_cancellations_total \(batching.cancelledPendingRequests)",
        ])
    }
    if let batching = snapshot.readReceiptBatching {
        lines.append(contentsOf: [
            "# HELP im_v2_read_receipt_batch_pending_requests Read-receipt operations waiting for a durable batch.",
            "# TYPE im_v2_read_receipt_batch_pending_requests gauge",
            "im_v2_read_receipt_batch_pending_requests \(batching.pendingRequests)",
            "# HELP im_v2_read_receipt_batch_in_flight Durable read-receipt batches currently executing.",
            "# TYPE im_v2_read_receipt_batch_in_flight gauge",
            "im_v2_read_receipt_batch_in_flight \(batching.inFlightBatches)",
            "# HELP im_v2_read_receipt_batches_completed_total Durable read-receipt batches completed.",
            "# TYPE im_v2_read_receipt_batches_completed_total counter",
            "im_v2_read_receipt_batches_completed_total \(batching.completedBatches)",
            "# HELP im_v2_read_receipt_requests_completed_total Read-receipt operations completed through the batch path.",
            "# TYPE im_v2_read_receipt_requests_completed_total counter",
            "im_v2_read_receipt_requests_completed_total \(batching.completedRequests)",
            "# HELP im_v2_read_receipt_batch_maximum_observed_size Largest read-receipt transaction batch observed since process start.",
            "# TYPE im_v2_read_receipt_batch_maximum_observed_size gauge",
            "im_v2_read_receipt_batch_maximum_observed_size \(batching.maximumObservedBatchSize)",
            "# HELP im_v2_read_receipt_batch_rejections_total Read-receipt operations rejected by the bounded staging queue.",
            "# TYPE im_v2_read_receipt_batch_rejections_total counter",
            "im_v2_read_receipt_batch_rejections_total{reason=\"queue_full\"} \(batching.queueFullRejections)",
            "# HELP im_v2_read_receipt_batch_cancellations_total Pending read-receipt operations removed before durable dispatch.",
            "# TYPE im_v2_read_receipt_batch_cancellations_total counter",
            "im_v2_read_receipt_batch_cancellations_total \(batching.cancelledPendingRequests)",
        ])
    }
    if let stages = snapshot.directRoomLogAppendStages {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_append_stage_milliseconds Fixed-stage latency inside the authoritative direct append path.",
            "# TYPE im_v2_direct_room_log_append_stage_milliseconds histogram",
        ])
        for stage in V2DirectRoomLogAppendStage.allCases {
            let latency = stages.value(for: stage)
            for bucket in V2RuntimeLatencyBucket.allCases {
                lines.append(
                    "im_v2_direct_room_log_append_stage_milliseconds_bucket{stage=\"\(stage.rawValue)\",le=\"\(bucket.rawValue)\"} \(latency.count(atOrBelow: bucket))"
                )
            }
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_bucket{stage=\"\(stage.rawValue)\",le=\"+Inf\"} \(latency.samples)"
            )
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_sum{stage=\"\(stage.rawValue)\"} \(latency.sumMilliseconds)"
            )
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_count{stage=\"\(stage.rawValue)\"} \(latency.samples)"
            )
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_max{stage=\"\(stage.rawValue)\"} \(latency.maximumMilliseconds)"
            )
        }
    }
    if let lag = snapshot.gatewayEventLoopLag {
        lines.append(contentsOf: [
            "# HELP im_v2_gateway_event_loop_lag_milliseconds Delay of a low-frequency task scheduled on TLS child-channel EventLoops.",
            "# TYPE im_v2_gateway_event_loop_lag_milliseconds histogram",
        ])
        for bucket in V2RuntimeLatencyBucket.allCases {
            lines.append(
                "im_v2_gateway_event_loop_lag_milliseconds_bucket{le=\"\(bucket.rawValue)\"} \(lag.count(atOrBelow: bucket))"
            )
        }
        lines.append(contentsOf: [
            "im_v2_gateway_event_loop_lag_milliseconds_bucket{le=\"+Inf\"} \(lag.samples)",
            "im_v2_gateway_event_loop_lag_milliseconds_sum \(lag.sumMilliseconds)",
            "im_v2_gateway_event_loop_lag_milliseconds_count \(lag.samples)",
            "im_v2_gateway_event_loop_lag_milliseconds_max \(lag.maximumMilliseconds)",
        ])
    }
    if let policy = snapshot.directSendPolicy {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_send_policy_cache_entries Process-local durable-fenced direct policy snapshots.",
            "# TYPE im_v2_direct_send_policy_cache_entries gauge",
            "im_v2_direct_send_policy_cache_entries \(policy.entries)",
            "# HELP im_v2_direct_send_policy_cache_lookups_total Direct policy cache lookup outcomes.",
            "# TYPE im_v2_direct_send_policy_cache_lookups_total counter",
            "im_v2_direct_send_policy_cache_lookups_total{outcome=\"hit\"} \(policy.hits)",
            "im_v2_direct_send_policy_cache_lookups_total{outcome=\"miss\"} \(policy.misses)",
            "# HELP im_v2_direct_send_policy_cache_insertions_total New direct policy cache keys inserted.",
            "# TYPE im_v2_direct_send_policy_cache_insertions_total counter",
            "im_v2_direct_send_policy_cache_insertions_total \(policy.insertions)",
            "# HELP im_v2_direct_send_policy_cache_removals_total Direct policy cache removals by bounded reason.",
            "# TYPE im_v2_direct_send_policy_cache_removals_total counter",
            "im_v2_direct_send_policy_cache_removals_total{reason=\"capacity\"} \(policy.evictions)",
            "im_v2_direct_send_policy_cache_removals_total{reason=\"expired\"} \(policy.expirations)",
        ])
    }
    if let fastAppend = snapshot.directRoomLogFastAppend {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_fast_append_entries Bounded process-local snapshots eligible for a conditional direct append.",
            "# TYPE im_v2_direct_room_log_fast_append_entries gauge",
            "im_v2_direct_room_log_fast_append_entries \(fastAppend.entries)",
            "# HELP im_v2_direct_room_log_fast_append_lookups_total Candidate cache lookup outcomes.",
            "# TYPE im_v2_direct_room_log_fast_append_lookups_total counter",
            "im_v2_direct_room_log_fast_append_lookups_total{outcome=\"hit\"} \(fastAppend.lookupHits)",
            "im_v2_direct_room_log_fast_append_lookups_total{outcome=\"miss\"} \(fastAppend.lookupMisses)",
            "# HELP im_v2_direct_room_log_fast_append_requests_total Conditional append request outcomes.",
            "# TYPE im_v2_direct_room_log_fast_append_requests_total counter",
            "im_v2_direct_room_log_fast_append_requests_total{outcome=\"attempted\"} \(fastAppend.attemptedAppends)",
            "im_v2_direct_room_log_fast_append_requests_total{outcome=\"committed\"} \(fastAppend.committedAppends)",
            "im_v2_direct_room_log_fast_append_requests_total{outcome=\"fallback\"} \(fastAppend.fallbackAppends)",
            "# HELP im_v2_direct_room_log_fast_append_insertions_total New conditional append cache keys inserted.",
            "# TYPE im_v2_direct_room_log_fast_append_insertions_total counter",
            "im_v2_direct_room_log_fast_append_insertions_total \(fastAppend.insertions)",
            "# HELP im_v2_direct_room_log_fast_append_removals_total Conditional append cache removals by bounded reason.",
            "# TYPE im_v2_direct_room_log_fast_append_removals_total counter",
            "im_v2_direct_room_log_fast_append_removals_total{reason=\"capacity\"} \(fastAppend.evictions)",
            "im_v2_direct_room_log_fast_append_removals_total{reason=\"expired\"} \(fastAppend.expirations)",
        ])
    }
    if let eventCache = snapshot.directRoomLogEventCache {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_event_cache_entries Bounded process-local plain direct event cache occupancy.",
            "# TYPE im_v2_direct_room_log_event_cache_entries gauge",
            "im_v2_direct_room_log_event_cache_entries \(eventCache.cachedEvents)",
            "# HELP im_v2_direct_room_log_event_cache_rooms Bounded process-local direct event cache room count.",
            "# TYPE im_v2_direct_room_log_event_cache_rooms gauge",
            "im_v2_direct_room_log_event_cache_rooms \(eventCache.cachedRooms)",
            "# HELP im_v2_direct_room_log_event_cache_bytes Approximate payload bytes retained by the local direct event cache.",
            "# TYPE im_v2_direct_room_log_event_cache_bytes gauge",
            "im_v2_direct_room_log_event_cache_bytes \(eventCache.cachedBytes)",
            "# HELP im_v2_direct_room_log_event_cache_lookups_total Local direct event cache lookup outcomes.",
            "# TYPE im_v2_direct_room_log_event_cache_lookups_total counter",
            "im_v2_direct_room_log_event_cache_lookups_total{outcome=\"hit\"} \(eventCache.hits)",
            "im_v2_direct_room_log_event_cache_lookups_total{outcome=\"miss\"} \(eventCache.misses)",
            "# HELP im_v2_direct_room_log_event_cache_bypassed_events_total Committed events that do not satisfy the plain direct cache contract.",
            "# TYPE im_v2_direct_room_log_event_cache_bypassed_events_total counter",
            "im_v2_direct_room_log_event_cache_bypassed_events_total \(eventCache.bypassedIneligibleEvents)",
            "# HELP im_v2_direct_room_log_event_cache_pending_writes Committed messages waiting for best-effort cache materialization.",
            "# TYPE im_v2_direct_room_log_event_cache_pending_writes gauge",
            "im_v2_direct_room_log_event_cache_pending_writes \(eventCache.pendingWrites)",
            "# HELP im_v2_direct_room_log_event_cache_dropped_writes_total Cache accelerators dropped at the bounded post-commit mailbox.",
            "# TYPE im_v2_direct_room_log_event_cache_dropped_writes_total counter",
            "im_v2_direct_room_log_event_cache_dropped_writes_total \(eventCache.droppedWrites)",
        ])
    }
    if let prepared = snapshot.preparedGroupEventPageCache {
        lines.append(contentsOf: [
            "# HELP im_v2_prepared_group_event_page_cache_entries Bounded shared encoded group-event page entries.",
            "# TYPE im_v2_prepared_group_event_page_cache_entries gauge",
            "im_v2_prepared_group_event_page_cache_entries \(prepared.entries)",
            "# HELP im_v2_prepared_group_event_page_cache_bytes Encoded payload bytes retained by the shared group-event page cache.",
            "# TYPE im_v2_prepared_group_event_page_cache_bytes gauge",
            "im_v2_prepared_group_event_page_cache_bytes \(prepared.bytes)",
            "# HELP im_v2_prepared_group_event_page_cache_lookups_total Shared encoded group-event page lookup outcomes.",
            "# TYPE im_v2_prepared_group_event_page_cache_lookups_total counter",
            "im_v2_prepared_group_event_page_cache_lookups_total{outcome=\"hit\"} \(prepared.hits)",
            "im_v2_prepared_group_event_page_cache_lookups_total{outcome=\"miss\"} \(prepared.misses)",
            "# HELP im_v2_prepared_group_event_page_cache_evictions_total Shared encoded group-event page removals caused by capacity bounds.",
            "# TYPE im_v2_prepared_group_event_page_cache_evictions_total counter",
            "im_v2_prepared_group_event_page_cache_evictions_total \(prepared.evictions)",
        ])
    }
    if let renewals = snapshot.livePresenceRenewals {
        lines.append(contentsOf: [
            "# HELP im_v2_live_presence_renewal_pending_connections Heartbeat lease renewals waiting in the bounded coalescing window.",
            "# TYPE im_v2_live_presence_renewal_pending_connections gauge",
            "im_v2_live_presence_renewal_pending_connections \(renewals.pendingConnections)",
            "# HELP im_v2_live_presence_renewal_requests_total Heartbeat lease renewal requests submitted to the batcher.",
            "# TYPE im_v2_live_presence_renewal_requests_total counter",
            "im_v2_live_presence_renewal_requests_total \(renewals.submittedRequests)",
            "# HELP im_v2_live_presence_renewal_batches_total Database renewal batch outcomes.",
            "# TYPE im_v2_live_presence_renewal_batches_total counter",
            "im_v2_live_presence_renewal_batches_total{outcome=\"executed\"} \(renewals.executedBatches)",
            "im_v2_live_presence_renewal_batches_total{outcome=\"failed\"} \(renewals.failedBatches)",
            "# HELP im_v2_live_presence_renewal_largest_batch Largest heartbeat renewal batch observed by this process.",
            "# TYPE im_v2_live_presence_renewal_largest_batch gauge",
            "im_v2_live_presence_renewal_largest_batch \(renewals.largestBatch)",
        ])
    }
    return lines.joined(separator: "\n") + "\n"
}
