import Foundation
import IMV2ServerContracts
import IMV2ActorContracts

/// 将运行压力快照转换为 Prometheus 文本指标。
///
/// 始终输出连接池、四类数据库准入和同步提示指标；仅在可选快照存在时输出对应扩展组。
/// 数值按快照原样输出，不重新采样、重置或修正计数。直方图输出累积桶、`+Inf`、总和及样本数；
/// 固定阶段与事件循环耗时另外输出最大观测值。时间指标以名称所示的毫秒为单位。
///
/// 标签仅使用固定用途、类别、阶段和结果枚举，不引入用户、房间、请求或缓存键等动态身份。
/// 此函数只生成文本，HTTP 内容类型、访问控制和响应缓存策略由调用方负责。
///
/// - Parameter snapshot: 已采集的基础指标与可选扩展指标。
/// - Returns: 带 `HELP`、`TYPE` 声明的指标文本，各行以换行符分隔且末尾保留一个换行符。
public func v2RenderPrometheusRuntimePressureMetrics(
    _ snapshot: V2RuntimePressureMetricsSnapshot
) -> String {
    var lines = [
        "# HELP im_v2_database_pool_event_loop_handles Configured Fluent handles spanning the application EventLoops by fixed pool class.",
        "# TYPE im_v2_database_pool_event_loop_handles gauge",
    ]
    if let actors = snapshot.roomActors {
        lines.append(contentsOf: v2RoomActorMetricLines(actors))
    }
    if let recovery = snapshot.roomRecoveryBatches {
        lines += v2RoomRecoveryBatchMetricLines(recovery)
    }
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
    // These fixed purposes partition interactiveRead; they never add capacity.
    for (name, type, help) in [
        ("in_flight", "gauge", "Interactive database permits by trusted purpose; shares the original class capacity."),
        ("queued", "gauge", "Interactive queued work by trusted purpose; sum stays within the original class queue."),
        ("admissions_total", "counter", "Actual interactive permit grants by trusted purpose."),
        ("rejections_total", "counter", "Interactive work rejected before borrowing by purpose and fixed reason."),
        ("cancellations_total", "counter", "Interactive queued cancellations by trusted purpose."),
        ("queue_wait_milliseconds", "histogram", "Completed interactive queue waits including grants, cancellation and timeout; milliseconds.")
    ] {
        lines.append("# HELP im_v2_database_work_interactive_read_\(name) \(help)")
        lines.append("# TYPE im_v2_database_work_interactive_read_\(name) \(type)")
    }
    for purpose in V2InteractiveReadAdmissionPurpose.allCases {
        let value = snapshot.databaseWork.interactiveReadPurposes[purpose] ?? .empty
        let labels = "purpose=\"\(purpose.rawValue)\""
        let prefix = "im_v2_database_work_interactive_read_"
        lines.append("\(prefix)in_flight{\(labels)} \(value.inFlight)")
        lines.append("\(prefix)queued{\(labels)} \(value.queued)")
        lines.append("\(prefix)admissions_total{\(labels)} \(value.admittedRequests)")
        lines.append("\(prefix)cancellations_total{\(labels)} \(value.cancelledRequests)")
        lines.append("\(prefix)rejections_total{\(labels),reason=\"queue_full\"} \(value.queueFullRejections)")
        lines.append("\(prefix)rejections_total{\(labels),reason=\"timeout\"} \(value.timeoutRejections)")
        let wait = value.queueWait
        for bucket in V2DatabaseWorkAdmissionWaitBucket.allCases {
            lines.append("\(prefix)queue_wait_milliseconds_bucket{\(labels),le=\"\(bucket.rawValue)\"} \(wait.count(atOrBelow: bucket))")
        }
        lines.append("\(prefix)queue_wait_milliseconds_bucket{\(labels),le=\"+Inf\"} \(wait.samples)")
        lines.append("\(prefix)queue_wait_milliseconds_sum{\(labels)} \(wait.sumMilliseconds)")
        lines.append("\(prefix)queue_wait_milliseconds_count{\(labels)} \(wait.samples)")
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
    if let send = snapshot.gatewayMessageSend {
        let gauges: [(String, Int)] = [
            ("in_flight_requests", send.inFlightRequests),
            ("reserved_bytes", send.reservedBytes),
            ("peak_in_flight_requests_lifetime", send.peakInFlightRequests),
            ("peak_reserved_bytes_lifetime", send.peakReservedBytes),
        ]
        for (name, value) in gauges {
            lines.append("# TYPE im_v2_gateway_message_send_\(name) gauge")
            lines.append("im_v2_gateway_message_send_\(name) \(value)")
        }
        lines.append("# TYPE im_v2_gateway_message_send_rejected_total counter")
        for reason in V2GatewayMessageSendRejectionReason.allCases {
            lines.append("im_v2_gateway_message_send_rejected_total{reason=\"\(reason.rawValue)\"} \(send.rejections[reason, default: 0])")
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
    if let recovery = snapshot.registryRecovery {
        lines.append(contentsOf: v2RenderPrometheusRecoverySchedulingMetrics(recovery.schedulingTelemetry)
            .split(separator: "\n").map(String.init))
        let positions = recovery.positionLedger
        lines += [
            "# HELP im_v2_gateway_recovery_positions_occupied Authoritative recovery admission positions: queued plus authorization_returns plus selected_handoff plus outbound. Mutually exclusive positions; prepared queued proofs are included in queued. Independent from overlapping scope and root-task gauges.",
            "# TYPE im_v2_gateway_recovery_positions_occupied gauge",
            "im_v2_gateway_recovery_positions_occupied \(positions.occupied)",
            "# HELP im_v2_gateway_recovery_positions_capacity Recovery admission position limit.",
            "# TYPE im_v2_gateway_recovery_positions_capacity gauge",
            "im_v2_gateway_recovery_positions_capacity \(positions.capacity)",
            "# HELP im_v2_gateway_recovery_positions Recovery admission positions by fixed mutually exclusive stage.",
            "# TYPE im_v2_gateway_recovery_positions gauge",
            "# HELP im_v2_gateway_recovery_position_oldest_milliseconds Oldest currently retained position using original demand enqueue, attempt reservation, selected dispatch or outbound ticket start time.",
            "# TYPE im_v2_gateway_recovery_position_oldest_milliseconds gauge",
            "im_v2_gateway_recovery_position_oldest_milliseconds{stage=\"all\"} \(positions.oldestMilliseconds)"
        ]
        for stage in V2RecoveryPositionStage.allCases {
            let value = positions.stages[stage] ?? .init()
            let labels = "{stage=\"\(stage.rawValue)\"}"
            lines.append("im_v2_gateway_recovery_positions\(labels) \(value.count)")
            lines.append("im_v2_gateway_recovery_position_oldest_milliseconds\(labels) \(value.oldestMilliseconds)")
        }
        lines += [
            "# HELP im_v2_gateway_retired_recovery_writer_work Retired recovery writer ownership by fixed stage and unit: retained_streams occupies the connection Directory operation budget until actual drain; actual_drains counts at most 16 owned drain worker tasks processing a subset of retained streams. Different units and overlapping ownership must not be added together.",
            "# TYPE im_v2_gateway_retired_recovery_writer_work gauge",
            "# HELP im_v2_gateway_retired_recovery_writer_oldest_milliseconds Oldest retained stream or actual drain worker using its own original monotonic retirement or drain start time.",
            "# TYPE im_v2_gateway_retired_recovery_writer_oldest_milliseconds gauge"
        ]
        for stage in V2RetiredRecoveryWriterStage.allCases {
            let value = recovery.retiredRecoveryWriterStages[stage] ?? .init()
            let labels = "{stage=\"\(stage.rawValue)\",unit=\"\(stage.unit)\"}"
            lines.append("im_v2_gateway_retired_recovery_writer_work\(labels) \(value.count)")
            lines.append("im_v2_gateway_retired_recovery_writer_oldest_milliseconds\(labels) \(value.oldestMilliseconds)")
        }
        lines += [
            "# HELP im_v2_gateway_recovery_attempts Recovery ownership by fixed stage and unit: interest_activation, query_root and control are independently bounded root tasks; authorization_query counts actual provider query attempts within query roots until provider return. Query roots include result settlement. The query subset overlaps roots; these are not scope counts or physical database sessions.",
            "# TYPE im_v2_gateway_recovery_attempts gauge",
            "# HELP im_v2_gateway_recovery_attempt_oldest_milliseconds Oldest currently owned recovery root or provider query attempt using its own original monotonic start time.",
            "# TYPE im_v2_gateway_recovery_attempt_oldest_milliseconds gauge"
        ]
        for stage in V2RecoveryAttemptStage.allCases {
            let value = recovery.recoveryAttemptStages[stage] ?? .init()
            let labels = "{stage=\"\(stage.rawValue)\",unit=\"\(stage.unit)\"}"
            lines.append("im_v2_gateway_recovery_attempts\(labels) \(value.count)")
            lines.append("im_v2_gateway_recovery_attempt_oldest_milliseconds\(labels) \(value.oldestMilliseconds)")
        }
        lines += [
            "# HELP im_v2_gateway_presence_observation_work Presence observation owner work by fixed stage and unit: actual_queries are locally submitted query batches until provider return; result_positions retain exact batch/request keys after query ownership transfers to output; queued keys, active query keys and retained result positions share the 1024 position budget; owned_jobs also include result preparation and mailbox offers; tickets include per-target output responsibility until actual settlement; retired_tickets is the generation-retired subset. Overlapping gauges, never connection counts or physical database sessions.",
            "# TYPE im_v2_gateway_presence_observation_work gauge",
            "# HELP im_v2_gateway_presence_observation_oldest_milliseconds Oldest currently owned presence stage work using original monotonic enqueue, query or result-retention time; settlement and retired stages preserve the result ticket time.",
            "# TYPE im_v2_gateway_presence_observation_oldest_milliseconds gauge"
        ]
        for stage in V2PresenceObservationStage.allCases {
            let value = recovery.presenceObservationStages[stage] ?? .init()
            let labels = "{stage=\"\(stage.rawValue)\",unit=\"\(stage.unit)\"}"
            lines.append("im_v2_gateway_presence_observation_work\(labels) \(value.count)")
            lines.append("im_v2_gateway_presence_observation_oldest_milliseconds\(labels) \(value.oldestMilliseconds)")
        }
        lines += [
            "# HELP im_v2_gateway_registry_recovery_scopes Current Registry scope stages; actual and actual_scopes alias the same root-owned scopes and must not be added together; outbound_retention holds scope tickets after mailbox handoff until actual output settlement; root tasks and provider queries have separate recovery_attempts gauges; authorization_returns counts exact actual-owned result return positions within the same queued-plus-reserved 1024 bound; inline_retention is the separate existing ingress-consumer handoff lane; overlapping gauges, not client cursor progress.",
            "# TYPE im_v2_gateway_registry_recovery_scopes gauge",
            "# HELP im_v2_gateway_registry_recovery_oldest_milliseconds Oldest current scope demand or actual job by fixed kind/stage.",
            "# TYPE im_v2_gateway_registry_recovery_oldest_milliseconds gauge",
            "# HELP im_v2_gateway_registry_recovery_demands Current pending demands by fixed reason; not successful permission checks.",
            "# TYPE im_v2_gateway_registry_recovery_demands gauge",
            "# HELP im_v2_gateway_registry_recovery_actual_reasons Root-owned Registry scopes by original demand reason until result requeue or mailbox handoff; outbound tickets, root tasks and provider queries are counted separately.",
            "# TYPE im_v2_gateway_registry_recovery_actual_reasons gauge",
            "# HELP im_v2_gateway_registry_recovery_duplicate_retained_total Same-generation confirmed retained requirements skipped without new work.",
            "# TYPE im_v2_gateway_registry_recovery_duplicate_retained_total counter"
        ]
        for kind in V2RegistryRecoveryScopeKind.allCases {
            for stage in V2RegistryRecoveryStage.allCases {
                let value = recovery.stages[kind]?[stage] ?? .init()
                let labels = "{kind=\"\(kind.rawValue)\",stage=\"\(stage.rawValue)\"}"
                lines.append("im_v2_gateway_registry_recovery_scopes\(labels) \(value.count)")
                lines.append("im_v2_gateway_registry_recovery_oldest_milliseconds\(labels) \(value.oldestMilliseconds)")
            }
            for reason in V2RegistryRecoveryReason.allCases {
                lines.append("im_v2_gateway_registry_recovery_demands{kind=\"\(kind.rawValue)\",reason=\"\(reason.rawValue)\"} \(recovery.reasons[kind]?[reason] ?? 0)")
                lines.append("im_v2_gateway_registry_recovery_actual_reasons{kind=\"\(kind.rawValue)\",reason=\"\(reason.rawValue)\"} \(recovery.actualReasons[kind]?[reason] ?? 0)")
            }
            lines.append("im_v2_gateway_registry_recovery_duplicate_retained_total{kind=\"\(kind.rawValue)\"} \(recovery.duplicateRetained[kind] ?? 0)")
        }
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
    if let loans = snapshot.databaseLoans {
        lines.append(contentsOf: [
            "# HELP im_v2_database_loan_in_flight Granted loans until actual database future settlement, including driver borrow wait; not actual connection utilization.",
            "# TYPE im_v2_database_loan_in_flight gauge",
            "# HELP im_v2_database_loan_queued Requests awaiting a physical loan grant.",
            "# TYPE im_v2_database_loan_queued gauge",
            "# HELP im_v2_database_loan_granted_total Physical loan grants.",
            "# TYPE im_v2_database_loan_granted_total counter",
            "# HELP im_v2_database_loan_rejected_total Physical loan requests rejected before grant.",
            "# TYPE im_v2_database_loan_rejected_total counter",
        ])
        for (label, value) in [("ordinary", loans.ordinary), ("activation", loans.activation), ("sync", loans.sync), ("renewal", loans.renewal)] {
            lines.append(contentsOf: [
                "im_v2_database_loan_in_flight{class=\"\(label)\"} \(value.inFlight)",
                "im_v2_database_loan_queued{class=\"\(label)\"} \(value.queued)",
                "im_v2_database_loan_granted_total{class=\"\(label)\"} \(value.granted)",
                "im_v2_database_loan_rejected_total{class=\"\(label)\"} \(value.rejected)",
            ])
        }
    }
    if let observations = snapshot.databaseLoans?.observations {
        let prefix = "im_v2_database_loan_observation"
        for (suffix, type, help) in [
            ("active", "gauge", "Currently observed loans in a nonterminal stage; not all database work."),
            ("oldest_ms", "gauge", "Oldest currently observed stage age in milliseconds; zero means no active observation for this stage."),
            ("stage_duration_sum", "counter", "Milliseconds of completed observed stage intervals; not SQL statement counts or message latency."),
            ("stage_duration_count", "counter", "Completed observed stage intervals."),
            ("stage_duration_max", "gauge", "Lifetime maximum completed observed stage interval in milliseconds."),
            ("held_duration_sum", "counter", "Milliseconds from loan grant until actual future settlement, including driver wait and transaction finalization."),
            ("held_duration_count", "counter", "Granted observed loans whose actual database future settled."),
            ("held_duration_max", "gauge", "Lifetime maximum grant-to-actual-settlement duration in milliseconds."),
            ("sql_duration_sum", "counter", "Milliseconds of completed actual SQL futures by fixed phase; concurrent futures may overlap, so this cannot be added to held wall-clock duration."),
            ("sql_duration_count", "counter", "Completed actual SQL futures by fixed phase, including failures."),
            ("sql_duration_max", "gauge", "Lifetime maximum completed actual SQL-future duration in milliseconds.")
        ] {
            lines.append("# HELP \(prefix)_\(suffix) \(help)")
            lines.append("# TYPE \(prefix)_\(suffix) \(type)")
        }
        for source in V2DatabaseLoanObservationMetricSource.allCases {
            let value = observations[source, default: .init()]
            let sourceLabel = "source=\"\(source.rawValue)\""
            for stage in V2DatabaseLoanObservationMetricStage.allCases where stage != .settled {
                let item = value.stages[stage, default: .init()]
                let labels = "\(sourceLabel),stage=\"\(stage.rawValue)\""
                lines.append(contentsOf: [
                    "\(prefix)_active{\(labels)} \(item.active)",
                    "\(prefix)_oldest_ms{\(labels)} \(item.oldestMilliseconds)",
                    "\(prefix)_stage_duration_sum{\(labels)} \(item.totalMilliseconds)",
                    "\(prefix)_stage_duration_count{\(labels)} \(item.count)",
                    "\(prefix)_stage_duration_max{\(labels)} \(item.maxMilliseconds)"
                ])
            }
            for phase in V2DatabaseLoanObservationMetricSQLPhase.allCases {
                let item = value.sqlPhases[phase, default: .init()]
                let labels = "\(sourceLabel),phase=\"\(phase.rawValue)\""
                lines.append(contentsOf: [
                    "\(prefix)_sql_duration_sum{\(labels)} \(item.totalMilliseconds)",
                    "\(prefix)_sql_duration_count{\(labels)} \(item.count)",
                    "\(prefix)_sql_duration_max{\(labels)} \(item.maxMilliseconds)"
                ])
            }
            lines.append(contentsOf: [
                "\(prefix)_held_duration_sum{\(sourceLabel)} \(value.actualHeldTotalMilliseconds)",
                "\(prefix)_held_duration_count{\(sourceLabel)} \(value.actualHeldCount)",
                "\(prefix)_held_duration_max{\(sourceLabel)} \(value.actualHeldMaxMilliseconds)"
            ])
        }
    }
    for (prefix, optionalOwner) in [
        ("im_v2_send_operation_owner_", snapshot.sendOperationOwnerBatching)
    ] {
        guard let owner = optionalOwner else { continue }
        let gauges: [(String, Int, String)] = [
            ("retained_items", owner.retainedItems, "Commands retained across queued and executing physical-owner work."),
            ("retained_bytes", owner.retainedBytes, "Encoded command payload bytes retained across queued and executing owner work."),
            ("queued_turns", owner.queuedTurns, "Room requests waiting for this physical-owner stage's cohort selection."),
            ("waiting_policy_turns", owner.waitingPolicyTurns, "Room turns retaining original inputs until cold policy preparation settles."),
            ("in_flight_batches", owner.inFlightBatches, "Actual stage cohorts awaiting admission or executor settlement, not database transactions."),
            ("largest_batch", owner.largestBatch, "Largest command count in one physical-owner coordinator cohort."),
            ("largest_room_count", owner.largestRoomCount, "Largest distinct room count in one physical-owner coordinator cohort.")
        ]
        for (suffix, value, help) in gauges {
            let name = "\(prefix)\(suffix)"
            lines.append(contentsOf: ["# HELP \(name) \(help)", "# TYPE \(name) gauge", "\(name) \(value)"])
        }
        if let stages = owner.stages {
            let name = "\(prefix)batch_roots"
            lines.append(contentsOf: [
                "# HELP \(name) Retained physical-owner roots partitioned by lifecycle stage. Quota turn includes actual execution and cleanup, not SQL transaction counts; standby borrowing remains within existing root and payload budgets.",
                "# TYPE \(name) gauge"
            ])
            for stage in V2SendOperationOwnerBatchStage.allCases {
                lines.append("\(name){stage=\"\(stage.rawValue)\"} \(stages[stage, default: 0])")
            }
        }
        let counters: [(String, UInt64, String)] = [
            ("batches_started_total", owner.batchesStarted, "Physical-owner stage cohorts started, including admission attempts; not room turns or commits."),
            ("batches_completed_total", owner.batchesCompleted, "Stage cohorts whose actual executor or admission rejection has settled; not successful commits."),
            ("commands_submitted_total", owner.commandsSubmitted, "Commands selected into actual stage cohorts; not durable acceptances or client acknowledgements.")
        ]
        for (suffix, value, help) in counters {
            let name = "\(prefix)\(suffix)"
            lines.append(contentsOf: ["# HELP \(name) \(help)", "# TYPE \(name) counter", "\(name) \(value)"])
        }
    }
    if let operations = snapshot.sendOperationBatching {
        lines.append("# HELP im_v2_policy_memory_events_total Bounded policy state lookup and object/fact retention events.")
        lines.append("# TYPE im_v2_policy_memory_events_total counter")
        for event in V2PolicyMemoryEvent.allCases {
            lines.append("im_v2_policy_memory_events_total{event=\"\(event.rawValue)\"} \(operations.policyMemoryEvents[event, default: 0])")
        }
        lines.append(contentsOf: [
            "# HELP im_v2_send_operation_sql_continuation_settled_not_resumed Observed settled SQL results whose continuation has not resumed; does not cover all SQL or actor tasks.",
            "# TYPE im_v2_send_operation_sql_continuation_settled_not_resumed gauge",
            "# HELP im_v2_send_operation_sql_continuation_resumed_not_dispatched Observed resumed continuations awaiting a recorded adjacent dispatch or sequence end; does not cover all SQL or actor tasks.",
            "# TYPE im_v2_send_operation_sql_continuation_resumed_not_dispatched gauge",
            "# HELP im_v2_send_operation_sql_continuation_no_next_dispatch_total Observations ended without a recorded successor dispatch due to sequence end, failure or closure; unobserved SQL, COMMIT or ROLLBACK may still run.",
            "# TYPE im_v2_send_operation_sql_continuation_no_next_dispatch_total counter",
            "# HELP im_v2_send_operation_sql_continuation_duration_milliseconds_sum Independent observed SQL continuation segments, with the second ending only at a recorded adjacent dispatch; overlap transaction stages and are not proof of COMMIT or socket delivery.",
            "# TYPE im_v2_send_operation_sql_continuation_duration_milliseconds_sum counter",
            "# TYPE im_v2_send_operation_sql_continuation_duration_milliseconds_count counter",
            "# HELP im_v2_send_operation_sql_continuation_duration_milliseconds_max Lifetime maximum of each completed SQL continuation segment.",
            "# TYPE im_v2_send_operation_sql_continuation_duration_milliseconds_max gauge",
        ])
        for source in V2RoomSQLContinuationSource.allCases {
            let item = operations.sqlContinuations[source, default: .init()]
            let label = "{source=\"\(source.rawValue)\"}"
            lines.append("im_v2_send_operation_sql_continuation_settled_not_resumed\(label) \(item.settledNotResumed)")
            lines.append("im_v2_send_operation_sql_continuation_resumed_not_dispatched\(label) \(item.resumedNotDispatched)")
            lines.append("im_v2_send_operation_sql_continuation_no_next_dispatch_total\(label) \(item.noNextDispatch)")
            let parts: [(String, UInt64, Double, Double)] = [
                ("settled_to_resumed", item.settledToResumedCount,
                 item.settledToResumedTotalMilliseconds, item.settledToResumedMaxMilliseconds),
                ("resumed_to_dispatch", item.resumedToDispatchCount,
                 item.resumedToDispatchTotalMilliseconds, item.resumedToDispatchMaxMilliseconds),
            ]
            for (part, count, sum, maximum) in parts {
                let labels = "{source=\"\(source.rawValue)\",part=\"\(part)\"}"
                lines.append("im_v2_send_operation_sql_continuation_duration_milliseconds_sum\(labels) \(sum)")
                lines.append("im_v2_send_operation_sql_continuation_duration_milliseconds_count\(labels) \(count)")
                lines.append("im_v2_send_operation_sql_continuation_duration_milliseconds_max\(labels) \(maximum)")
            }
        }
        lines.append(contentsOf: [
            "# HELP im_v2_send_operation_admission_handoff_duration_milliseconds_sum Admission handoff segments before COMMIT dispatch; overlap body/admission and transaction finalization, never add to stage latency.",
            "# TYPE im_v2_send_operation_admission_handoff_duration_milliseconds_sum counter",
            "# TYPE im_v2_send_operation_admission_handoff_duration_milliseconds_count counter",
            "# HELP im_v2_send_operation_admission_handoff_duration_milliseconds_max Lifetime maximum admission handoff segment before COMMIT dispatch.",
            "# TYPE im_v2_send_operation_admission_handoff_duration_milliseconds_max gauge",
        ])
        for path in V2SendOperationAdmissionPath.allCases {
            let item = operations.ownerAdmissionHandoffs[path, default: .init()]
            let parts: [(String, Double, Double)] = [
                ("result_ready_to_validated", item.resultReadyToValidatedMillisecondsTotal,
                 item.resultReadyToValidatedMillisecondsMax),
                ("validated_to_commit_dispatch", item.validatedToCommitDispatchMillisecondsTotal,
                 item.validatedToCommitDispatchMillisecondsMax),
            ]
            for (part, sum, maximum) in parts {
                let labels = "{path=\"\(path.rawValue)\",part=\"\(part)\"}"
                lines.append("im_v2_send_operation_admission_handoff_duration_milliseconds_sum\(labels) \(sum)")
                lines.append("im_v2_send_operation_admission_handoff_duration_milliseconds_count\(labels) \(item.count)")
                lines.append("im_v2_send_operation_admission_handoff_duration_milliseconds_max\(labels) \(maximum)")
            }
        }
    }
    if let operations = snapshot.sendOperationBatching {
        lines.append(contentsOf: [
            "# HELP im_v2_send_operation_batches_in_flight Durable operation turns admitted or waiting for database admission.",
            "# TYPE im_v2_send_operation_batches_in_flight gauge",
            "im_v2_send_operation_batches_in_flight \(operations.inFlightBatches)",
            "# HELP im_v2_send_operation_batches_total Durable sendOperation turn outcomes; independent of legacy append metrics.",
            "# TYPE im_v2_send_operation_batches_total counter",
            "im_v2_send_operation_batches_total{outcome=\"attempted\"} \(operations.attemptedBatches)",
            "im_v2_send_operation_batches_total{outcome=\"committed\"} \(operations.committedBatches)",
            "im_v2_send_operation_batches_total{outcome=\"rolled_back\"} \(operations.rolledBackBatches)",
            "im_v2_send_operation_batches_total{outcome=\"unknown\"} \(operations.outcomeUnknownBatches)",
            "# HELP im_v2_send_operation_commands_total Durable commands submitted and completed in committed turns, including replays and business rejections.",
            "# TYPE im_v2_send_operation_commands_total counter",
            "im_v2_send_operation_commands_total{outcome=\"submitted\"} \(operations.submittedCommands)",
            "im_v2_send_operation_commands_total{outcome=\"committed\"} \(operations.committedCommands)",
            "# HELP im_v2_send_operation_singleton_batches_total Durable turns containing exactly one command.",
            "# TYPE im_v2_send_operation_singleton_batches_total counter",
            "im_v2_send_operation_singleton_batches_total \(operations.singletonBatches)",
            "# HELP im_v2_send_operation_largest_batch Largest durable turn submitted by this process.",
            "# TYPE im_v2_send_operation_largest_batch gauge",
            "im_v2_send_operation_largest_batch \(operations.largestBatch)",
            "# HELP im_v2_send_operation_execution_milliseconds_sum Durable turn time including database admission, authorization and commit.",
            "# TYPE im_v2_send_operation_execution_milliseconds_sum counter",
            "im_v2_send_operation_execution_milliseconds_sum \(operations.executionMillisecondsTotal)",
            "# HELP im_v2_send_operation_execution_milliseconds_max Longest durable turn observed by this process.",
            "# TYPE im_v2_send_operation_execution_milliseconds_max gauge",
            "im_v2_send_operation_execution_milliseconds_max \(operations.executionMillisecondsMax)",
        ])
    }
    if let operations = snapshot.sendOperationBatching {
        let counters: [(String, UInt64, String)] = [
            ("cohort_attempts_total", operations.ownerCohortAttempts, "Actual Store setwise transaction attempts, including isolation subcohorts; not coordinator batches."),
            ("cohort_handles_total", operations.ownerCohortHandles, "Handles included across actual setwise attempts; isolation may retry a handle."),
            ("cohort_commands_total", operations.ownerCohortCommands, "Commands included across actual setwise attempts; not unique submissions or throughput."),
            ("cohort_commits_total", operations.ownerCohortCommits, "Confirmed Store setwise transaction commits."),
            ("cohort_accepted_commands_total", operations.ownerCohortAcceptedCommands, "Newly accepted commands in confirmed setwise commits."),
            ("cohort_replayed_commands_total", operations.ownerCohortReplayedCommands, "Permanent receipt replays returned by confirmed setwise commits."),
            ("cohort_isolations_total", operations.ownerCohortIsolations, "Proven rollback isolation decisions; not scalar fallback command counts.")
        ]
        for (suffix, value, help) in counters {
            let name = "im_v2_send_operation_store_\(suffix)"
            lines.append(contentsOf: ["# HELP \(name) \(help)", "# TYPE \(name) counter", "\(name) \(value)"])
        }
        lines.append(contentsOf: [
            "# HELP im_v2_send_operation_store_scalar_fallback_handles_total Handles taking their scalar execution, counted once at that boundary by fixed reason.",
            "# TYPE im_v2_send_operation_store_scalar_fallback_handles_total counter",
            "# HELP im_v2_send_operation_store_scalar_fallback_commands_total Commands taking scalar execution; not repeated for binary isolation depth.",
            "# TYPE im_v2_send_operation_store_scalar_fallback_commands_total counter"
        ])
        for reason in V2SendOperationOwnerScalarFallbackReason.allCases {
            let value = operations.ownerScalarFallbacks[reason, default: .init()]
            lines.append("im_v2_send_operation_store_scalar_fallback_handles_total{reason=\"\(reason.rawValue)\"} \(value.handles)")
            lines.append("im_v2_send_operation_store_scalar_fallback_commands_total{reason=\"\(reason.rawValue)\"} \(value.commands)")
        }
    }
    if let operations = snapshot.sendOperationBatching {
        lines.append(contentsOf: [
            "# HELP im_v2_send_operation_stage_in_flight Actual durable send operations still executing in each fixed stage.",
            "# TYPE im_v2_send_operation_stage_in_flight gauge",
            "# HELP im_v2_send_operation_stage_started_total Actual operations started in each fixed stage.",
            "# TYPE im_v2_send_operation_stage_started_total counter",
            "# HELP im_v2_send_operation_stage_completed_total Actual operations completed in each fixed stage.",
            "# TYPE im_v2_send_operation_stage_completed_total counter",
            "# HELP im_v2_send_operation_stage_duration_milliseconds_sum Monotonic elapsed milliseconds of completed stage operations.",
            "# TYPE im_v2_send_operation_stage_duration_milliseconds_sum counter",
            "# HELP im_v2_send_operation_stage_duration_milliseconds_max Longest completed stage operation in milliseconds.",
            "# TYPE im_v2_send_operation_stage_duration_milliseconds_max gauge",
        ])
        for stage in V2SendOperationStage.allCases {
            let item = operations.stages[stage, default: .init()]
            let started = item.count.addingReportingOverflow(UInt64(max(0, item.inFlight)))
            let startedCount = started.overflow ? UInt64.max : started.partialValue
            let label = "{stage=\"\(stage.rawValue)\"}"
            lines.append("im_v2_send_operation_stage_in_flight\(label) \(item.inFlight)")
            lines.append("im_v2_send_operation_stage_started_total\(label) \(startedCount)")
            lines.append("im_v2_send_operation_stage_completed_total\(label) \(item.count)")
            lines.append("im_v2_send_operation_stage_duration_milliseconds_sum\(label) \(item.totalMilliseconds)")
            lines.append("im_v2_send_operation_stage_duration_milliseconds_max\(label) \(item.maxMilliseconds)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}
