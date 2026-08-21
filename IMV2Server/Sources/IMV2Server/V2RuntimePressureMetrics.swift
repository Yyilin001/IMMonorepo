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
    /// Best-effort local direct-event cache facts. No room, user or event ID
    /// is exposed as a metric label.
    public let directRoomLogEventCache: V2DirectRoomLogEventCache.Snapshot?

    public init(
        databaseWork: V2DatabaseWorkAdmissionSnapshot,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWake: V2SyncWakeCoalescerSnapshot,
        shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool.Snapshot? = nil,
        roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool.Snapshot? = nil,
        directRoomLogAppendBatching: V2SendMessageAdmissionBatcher.Snapshot? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCache.Snapshot? = nil
    ) {
        self.databaseWork = databaseWork
        self.databasePools = databasePools
        self.syncWake = syncWake
        self.shardAdmissionCommandCredits = shardAdmissionCommandCredits
        self.roomAdmissionCommandCredits = roomAdmissionCommandCredits
        self.directRoomLogAppendBatching = directRoomLogAppendBatching
        self.directRoomLogEventCache = directRoomLogEventCache
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
    private let directRoomLogAppendBatcher: V2SendMessageAdmissionBatcher?
    private let directRoomLogEventCache: V2DirectRoomLogEventCache?

    public init(
        databaseWorkAdmission: V2DatabaseWorkAdmissionController,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWakeCoalescer: V2SyncWakeCoalescer,
        shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool? = nil,
        roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool? = nil,
        directRoomLogAppendBatcher: V2SendMessageAdmissionBatcher? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCache? = nil
    ) {
        self.databaseWorkAdmission = databaseWorkAdmission
        self.databasePools = databasePools
        self.syncWakeCoalescer = syncWakeCoalescer
        self.shardAdmissionCommandCredits = shardAdmissionCommandCredits
        self.roomAdmissionCommandCredits = roomAdmissionCommandCredits
        self.directRoomLogAppendBatcher = directRoomLogAppendBatcher
        self.directRoomLogEventCache = directRoomLogEventCache
    }

    public func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot {
        async let databaseWork = databaseWorkAdmission.snapshot()
        async let syncWake = syncWakeCoalescer.snapshot()
        let credits = await shardAdmissionCommandCredits?.snapshot()
        let roomCredits = await roomAdmissionCommandCredits?.snapshot()
        let appendBatching = await directRoomLogAppendBatcher?.snapshot()
        let eventCache = await directRoomLogEventCache?.snapshot()
        return await .init(
            databaseWork: databaseWork,
            databasePools: databasePools,
            syncWake: syncWake,
            shardAdmissionCommandCredits: credits,
            roomAdmissionCommandCredits: roomCredits,
            directRoomLogAppendBatching: appendBatching,
            directRoomLogEventCache: eventCache
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
            "# HELP im_v2_direct_room_log_append_batch_pending_requests Process-local direct append requests waiting for an atomic batch.",
            "# TYPE im_v2_direct_room_log_append_batch_pending_requests gauge",
            "im_v2_direct_room_log_append_batch_pending_requests \(batching.pendingRequests)",
            "# HELP im_v2_direct_room_log_append_batch_in_flight Batches currently holding one foreground database admission.",
            "# TYPE im_v2_direct_room_log_append_batch_in_flight gauge",
            "im_v2_direct_room_log_append_batch_in_flight \(batching.inFlightBatches)",
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
            "# HELP im_v2_direct_room_log_append_batch_rejections_total Requests rejected because the bounded staging queue is full.",
            "# TYPE im_v2_direct_room_log_append_batch_rejections_total counter",
            "im_v2_direct_room_log_append_batch_rejections_total{reason=\"queue_full\"} \(batching.stagingQueueFullRejections)",
            "# HELP im_v2_direct_room_log_append_batch_cancellations_total Staged requests removed before durable acceptance because their caller was cancelled.",
            "# TYPE im_v2_direct_room_log_append_batch_cancellations_total counter",
            "im_v2_direct_room_log_append_batch_cancellations_total \(batching.cancelledPendingRequests)",
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
        ])
    }
    return lines.joined(separator: "\n") + "\n"
}
