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
}

public protocol V2RuntimePressureMetricsSource: Sendable {
    func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot
}

public struct V2GatewayRuntimePressureMetricsSource: V2RuntimePressureMetricsSource {
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController
    private let databasePools: V2DatabasePoolTopologySnapshot
    private let syncWakeCoalescer: V2SyncWakeCoalescer

    public init(
        databaseWorkAdmission: V2DatabaseWorkAdmissionController,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWakeCoalescer: V2SyncWakeCoalescer
    ) {
        self.databaseWorkAdmission = databaseWorkAdmission
        self.databasePools = databasePools
        self.syncWakeCoalescer = syncWakeCoalescer
    }

    public func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot {
        async let databaseWork = databaseWorkAdmission.snapshot()
        async let syncWake = syncWakeCoalescer.snapshot()
        return await .init(
            databaseWork: databaseWork,
            databasePools: databasePools,
            syncWake: syncWake
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
    return lines.joined(separator: "\n") + "\n"
}
