import Dispatch
import Foundation
import IMV2ServerContracts
import Synchronization

/// 渲染私有 Prometheus 指标面中与连接相关的部分。
///
/// 把它与事件遥测分开，意味着一次抓取观察到的是注册表当前状态，
/// 而不是从生命周期事件重建出来的计数——后者可能在进程重启中丢失。
public func v2RenderPrometheusConnectionMetrics(_ snapshot: V2ConnectionMetricsSnapshot) -> String {
    [
        "# HELP im_v2_gateway_active_devices Process-local authenticated devices with an active gateway connection.",
        "# TYPE im_v2_gateway_active_devices gauge",
        "im_v2_gateway_active_devices \(snapshot.activeDevices)",
        "# HELP im_v2_gateway_active_connections Process-local authenticated gateway connections.",
        "# TYPE im_v2_gateway_active_connections gauge",
        "im_v2_gateway_active_connections \(snapshot.activeConnections)",
    ].joined(separator: "\n") + "\n"
}

/// 进程本地传输指标。
///
/// 网关通道更新它时不使用连接、用户、设备、房间或请求标识。
/// 峰值队列值刻意是进程生命周期的高水位线而非每通道标签，
/// 使一次抓取不会制造无界的时间序列。`Mutex` 是每个可变字段的显式同步边界，
/// 使这个进程级记录器无需 `@unchecked` 即可满足 Sendable。
public final class V2GatewayTransportMetrics: V2GatewayTransportMetricsRecorder, Sendable {
    private struct Storage: Sendable {
        var activeConnections = 0
        var peakQueuedInboundBytes = 0
        var closures: [V2GatewayConnectionClosure: UInt64] = [:]
    }

    private let storage = Mutex(Storage())
    // 前台帧路径每秒可提交数十万条本地接收方帧。
    // 使用宽松内存序的原子计数，避免指标成为此路径的全局互斥锁；
    // 这些计数器只发布观测值，不保护应用状态。
    private let foregroundFramesSubmitted = Atomic<UInt64>(0)
    private let foregroundBytesSubmitted = Atomic<UInt64>(0)
    private let foregroundRecoveryFramesQueued = Atomic<UInt64>(0)
    private let foregroundRecoveryFramesReplaced = Atomic<UInt64>(0)
    private let foregroundFramesWritten = Atomic<UInt64>(0)
    private let foregroundBytesWritten = Atomic<UInt64>(0)
    private let foregroundWriteBatches = Atomic<UInt64>(0)
    private let foregroundNonWritableDeferrals = Atomic<UInt64>(0)
    private let peakQueuedForegroundBytes = Atomic<Int>(0)
    private let foregroundGroupEventsSubmitted = Atomic<UInt64>(0)
    private let foregroundGroupEventsPublished = Atomic<UInt64>(0)
    private let foregroundGroupEventBatchesPublished = Atomic<UInt64>(0)
    private let foregroundGroupEventDuplicatesSuppressed = Atomic<UInt64>(0)
    private let foregroundGroupEventOutOfOrderArrivals = Atomic<UInt64>(0)
    private let foregroundGroupEventLateArrivals = Atomic<UInt64>(0)
    private let foregroundGroupEventBatchDegradations = Atomic<UInt64>(0)
    private let foregroundGroupInboundNotificationsDropped = Atomic<UInt64>(0)
    private let foregroundGroupCoveredWakesSuppressed = Atomic<UInt64>(0)
    private let foregroundGroupWakesDeferred = Atomic<UInt64>(0)
    private let foregroundGroupDeferredWakesDelivered = Atomic<UInt64>(0)

    public init() {}

    public func connectionOpened() {
        storage.withLock { $0.activeConnections += 1 }
    }

    public func connectionClosed(reason: V2GatewayConnectionClosure) {
        storage.withLock { storage in
            storage.activeConnections = max(0, storage.activeConnections - 1)
            storage.closures[reason] = v2SaturatingAdd(storage.closures[reason, default: 0], 1)
        }
    }

    public func connectionRejected(reason: V2GatewayConnectionClosure) {
        storage.withLock { storage in
            storage.closures[reason] = v2SaturatingAdd(storage.closures[reason, default: 0], 1)
        }
    }

    public func observeQueuedInboundBytes(_ bytes: Int) {
        storage.withLock {
            $0.peakQueuedInboundBytes = max($0.peakQueuedInboundBytes, max(0, bytes))
        }
    }

    public func foregroundFrameSubmitted(
        bytes: Int,
        recoveryQueued: Bool,
        recoveryReplaced: Bool,
        queuedBytes: Int
    ) {
        _ = foregroundFramesSubmitted.wrappingAdd(1, ordering: .relaxed)
        _ = foregroundBytesSubmitted.wrappingAdd(
            UInt64(max(0, bytes)), ordering: .relaxed
        )
        if recoveryQueued {
            _ = foregroundRecoveryFramesQueued.wrappingAdd(1, ordering: .relaxed)
        }
        if recoveryReplaced {
            _ = foregroundRecoveryFramesReplaced.wrappingAdd(1, ordering: .relaxed)
        }
        var peak = peakQueuedForegroundBytes.load(ordering: .relaxed)
        let observed = max(0, queuedBytes)
        while observed > peak {
            let exchanged = peakQueuedForegroundBytes.compareExchange(
                expected: peak,
                desired: observed,
                ordering: .relaxed
            )
            if exchanged.exchanged { break }
            peak = exchanged.original
        }
    }

    public func foregroundWriteBatch(frames: Int, bytes: Int) {
        _ = foregroundFramesWritten.wrappingAdd(
            UInt64(max(0, frames)), ordering: .relaxed
        )
        _ = foregroundBytesWritten.wrappingAdd(
            UInt64(max(0, bytes)), ordering: .relaxed
        )
        _ = foregroundWriteBatches.wrappingAdd(1, ordering: .relaxed)
    }

    public func foregroundWriteDeferredForWritability() {
        _ = foregroundNonWritableDeferrals.wrappingAdd(1, ordering: .relaxed)
    }

    public func foregroundGroupEventSubmitted(
        duplicateSuppressed: Bool,
        outOfOrder: Bool,
        lateAfterPublication: Bool,
        degradedToWake: Bool
    ) {
        _ = foregroundGroupEventsSubmitted.wrappingAdd(1, ordering: .relaxed)
        if duplicateSuppressed {
            _ = foregroundGroupEventDuplicatesSuppressed.wrappingAdd(1, ordering: .relaxed)
        }
        if outOfOrder {
            _ = foregroundGroupEventOutOfOrderArrivals.wrappingAdd(1, ordering: .relaxed)
        }
        if lateAfterPublication {
            _ = foregroundGroupEventLateArrivals.wrappingAdd(1, ordering: .relaxed)
        }
        if degradedToWake {
            _ = foregroundGroupEventBatchDegradations.wrappingAdd(1, ordering: .relaxed)
        }
    }

    public func foregroundGroupEventBatchPublished(eventCount: Int) {
        _ = foregroundGroupEventsPublished.wrappingAdd(
            UInt64(max(0, eventCount)), ordering: .relaxed
        )
        _ = foregroundGroupEventBatchesPublished.wrappingAdd(1, ordering: .relaxed)
    }

    public func foregroundGroupInboundNotificationDropped() {
        _ = foregroundGroupInboundNotificationsDropped.wrappingAdd(
            1,
            ordering: .relaxed
        )
    }

    public func foregroundGroupCoveredWakeSuppressed() {
        _ = foregroundGroupCoveredWakesSuppressed.wrappingAdd(
            1,
            ordering: .relaxed
        )
    }

    public func foregroundGroupWakeDeferred() {
        _ = foregroundGroupWakesDeferred.wrappingAdd(1, ordering: .relaxed)
    }

    public func foregroundGroupDeferredWakeDelivered() {
        _ = foregroundGroupDeferredWakesDelivered.wrappingAdd(
            1,
            ordering: .relaxed
        )
    }

    public func gatewayTransportMetricsSnapshot() -> V2GatewayTransportMetricsSnapshot {
        storage.withLock { storage in
            .init(
                activeConnections: storage.activeConnections,
                peakQueuedInboundBytes: storage.peakQueuedInboundBytes,
                foregroundFramesSubmitted:
                    foregroundFramesSubmitted.load(ordering: .relaxed),
                foregroundBytesSubmitted:
                    foregroundBytesSubmitted.load(ordering: .relaxed),
                foregroundRecoveryFramesQueued:
                    foregroundRecoveryFramesQueued.load(ordering: .relaxed),
                foregroundRecoveryFramesReplaced:
                    foregroundRecoveryFramesReplaced.load(ordering: .relaxed),
                foregroundFramesWritten:
                    foregroundFramesWritten.load(ordering: .relaxed),
                foregroundBytesWritten:
                    foregroundBytesWritten.load(ordering: .relaxed),
                foregroundWriteBatches:
                    foregroundWriteBatches.load(ordering: .relaxed),
                foregroundNonWritableDeferrals:
                    foregroundNonWritableDeferrals.load(ordering: .relaxed),
                peakQueuedForegroundBytes:
                    peakQueuedForegroundBytes.load(ordering: .relaxed),
                foregroundGroupEventsSubmitted:
                    foregroundGroupEventsSubmitted.load(ordering: .relaxed),
                foregroundGroupEventsPublished:
                    foregroundGroupEventsPublished.load(ordering: .relaxed),
                foregroundGroupEventBatchesPublished:
                    foregroundGroupEventBatchesPublished.load(ordering: .relaxed),
                foregroundGroupEventDuplicatesSuppressed:
                    foregroundGroupEventDuplicatesSuppressed.load(ordering: .relaxed),
                foregroundGroupEventOutOfOrderArrivals:
                    foregroundGroupEventOutOfOrderArrivals.load(ordering: .relaxed),
                foregroundGroupEventLateArrivals:
                    foregroundGroupEventLateArrivals.load(ordering: .relaxed),
                foregroundGroupEventBatchDegradations:
                    foregroundGroupEventBatchDegradations.load(ordering: .relaxed),
                foregroundGroupInboundNotificationsDropped:
                    foregroundGroupInboundNotificationsDropped.load(
                        ordering: .relaxed
                    ),
                foregroundGroupCoveredWakesSuppressed:
                    foregroundGroupCoveredWakesSuppressed.load(
                        ordering: .relaxed
                    ),
                foregroundGroupWakesDeferred:
                    foregroundGroupWakesDeferred.load(ordering: .relaxed),
                foregroundGroupDeferredWakesDelivered:
                    foregroundGroupDeferredWakesDelivered.load(
                        ordering: .relaxed
                    ),
                closures: storage.closures
            )
        }
    }
}

public func v2RenderPrometheusGatewayTransportMetrics(_ snapshot: V2GatewayTransportMetricsSnapshot) -> String {
    var lines = [
        "# HELP im_v2_gateway_transport_active_connections Process-local TLS gateway connections, including pre-authentication sockets.",
        "# TYPE im_v2_gateway_transport_active_connections gauge",
        "im_v2_gateway_transport_active_connections \(snapshot.activeConnections)",
        "# HELP im_v2_gateway_inbound_queue_peak_bytes Process-lifetime peak bytes queued before gateway command processing.",
        "# TYPE im_v2_gateway_inbound_queue_peak_bytes gauge",
        "im_v2_gateway_inbound_queue_peak_bytes \(snapshot.peakQueuedInboundBytes)",
        "# HELP im_v2_gateway_foreground_frames_submitted_total Best-effort foreground frames submitted to connection FIFOs.",
        "# TYPE im_v2_gateway_foreground_frames_submitted_total counter",
        "im_v2_gateway_foreground_frames_submitted_total \(snapshot.foregroundFramesSubmitted)",
        "# HELP im_v2_gateway_foreground_bytes_submitted_total Bytes submitted to foreground connection FIFOs before coalescing.",
        "# TYPE im_v2_gateway_foreground_bytes_submitted_total counter",
        "im_v2_gateway_foreground_bytes_submitted_total \(snapshot.foregroundBytesSubmitted)",
        "# HELP im_v2_gateway_foreground_recovery_frames_total Foreground queue overflows retaining a latest recovery frame.",
        "# TYPE im_v2_gateway_foreground_recovery_frames_total counter",
        "im_v2_gateway_foreground_recovery_frames_total \(snapshot.foregroundRecoveryFramesQueued)",
        "# HELP im_v2_gateway_foreground_recovery_replacements_total Newer recovery frames replacing an already retained recovery frame.",
        "# TYPE im_v2_gateway_foreground_recovery_replacements_total counter",
        "im_v2_gateway_foreground_recovery_replacements_total \(snapshot.foregroundRecoveryFramesReplaced)",
        "# HELP im_v2_gateway_foreground_frames_written_total Complete foreground protocol frames written after coalescing.",
        "# TYPE im_v2_gateway_foreground_frames_written_total counter",
        "im_v2_gateway_foreground_frames_written_total \(snapshot.foregroundFramesWritten)",
        "# HELP im_v2_gateway_foreground_bytes_written_total Foreground protocol bytes written before TLS encryption.",
        "# TYPE im_v2_gateway_foreground_bytes_written_total counter",
        "im_v2_gateway_foreground_bytes_written_total \(snapshot.foregroundBytesWritten)",
        "# HELP im_v2_gateway_foreground_write_batches_total NIO writes after coalescing foreground protocol frames.",
        "# TYPE im_v2_gateway_foreground_write_batches_total counter",
        "im_v2_gateway_foreground_write_batches_total \(snapshot.foregroundWriteBatches)",
        "# HELP im_v2_gateway_foreground_nonwritable_deferrals_total Foreground drains deferred by Channel writability backpressure.",
        "# TYPE im_v2_gateway_foreground_nonwritable_deferrals_total counter",
        "im_v2_gateway_foreground_nonwritable_deferrals_total \(snapshot.foregroundNonWritableDeferrals)",
        "# HELP im_v2_gateway_foreground_queue_peak_bytes Process-lifetime maximum bytes retained by one foreground connection FIFO.",
        "# TYPE im_v2_gateway_foreground_queue_peak_bytes gauge",
        "im_v2_gateway_foreground_queue_peak_bytes \(snapshot.peakQueuedForegroundBytes)",
        "# HELP im_v2_gateway_foreground_group_events_submitted_total Committed Hybrid group events submitted to the process-local foreground dispatcher.",
        "# TYPE im_v2_gateway_foreground_group_events_submitted_total counter",
        "im_v2_gateway_foreground_group_events_submitted_total \(snapshot.foregroundGroupEventsSubmitted)",
        "# HELP im_v2_gateway_foreground_group_events_published_total Hybrid group events published in foreground batches.",
        "# TYPE im_v2_gateway_foreground_group_events_published_total counter",
        "im_v2_gateway_foreground_group_events_published_total \(snapshot.foregroundGroupEventsPublished)",
        "# HELP im_v2_gateway_foreground_group_event_batches_total Foreground Hybrid group event batches published.",
        "# TYPE im_v2_gateway_foreground_group_event_batches_total counter",
        "im_v2_gateway_foreground_group_event_batches_total \(snapshot.foregroundGroupEventBatchesPublished)",
        "# HELP im_v2_gateway_foreground_group_event_duplicates_total Duplicate group sequence submissions suppressed in the current dispatcher window.",
        "# TYPE im_v2_gateway_foreground_group_event_duplicates_total counter",
        "im_v2_gateway_foreground_group_event_duplicates_total \(snapshot.foregroundGroupEventDuplicatesSuppressed)",
        "# HELP im_v2_gateway_foreground_group_event_out_of_order_total Group event submissions lower than an event already pending for the same room.",
        "# TYPE im_v2_gateway_foreground_group_event_out_of_order_total counter",
        "im_v2_gateway_foreground_group_event_out_of_order_total \(snapshot.foregroundGroupEventOutOfOrderArrivals)",
        "# HELP im_v2_gateway_foreground_group_event_late_total Group event submissions at or below a sequence already published for the same recent room.",
        "# TYPE im_v2_gateway_foreground_group_event_late_total counter",
        "im_v2_gateway_foreground_group_event_late_total \(snapshot.foregroundGroupEventLateArrivals)",
        "# HELP im_v2_gateway_foreground_group_event_degradations_total Full group event batches degraded to metadata-only wakes.",
        "# TYPE im_v2_gateway_foreground_group_event_degradations_total counter",
        "im_v2_gateway_foreground_group_event_degradations_total \(snapshot.foregroundGroupEventBatchDegradations)",
        "# HELP im_v2_gateway_foreground_group_inbound_notifications_dropped_total Decoded Actor group notifications evicted from the bounded socket-fanout mailbox after recovery-cache ingestion.",
        "# TYPE im_v2_gateway_foreground_group_inbound_notifications_dropped_total counter",
        "im_v2_gateway_foreground_group_inbound_notifications_dropped_total \(snapshot.foregroundGroupInboundNotificationsDropped)",
        "# HELP im_v2_gateway_foreground_group_covered_wakes_suppressed_total Durable group wakes suppressed because completed local live fan-out already covered their high watermark.",
        "# TYPE im_v2_gateway_foreground_group_covered_wakes_suppressed_total counter",
        "im_v2_gateway_foreground_group_covered_wakes_suppressed_total \(snapshot.foregroundGroupCoveredWakesSuppressed)",
        "# HELP im_v2_gateway_foreground_group_wakes_deferred_total Durable group wakes briefly deferred so an in-flight live payload can cover them.",
        "# TYPE im_v2_gateway_foreground_group_wakes_deferred_total counter",
        "im_v2_gateway_foreground_group_wakes_deferred_total \(snapshot.foregroundGroupWakesDeferred)",
        "# HELP im_v2_gateway_foreground_group_deferred_wakes_delivered_total Deferred durable group wakes released because no live payload covered their high watermark.",
        "# TYPE im_v2_gateway_foreground_group_deferred_wakes_delivered_total counter",
        "im_v2_gateway_foreground_group_deferred_wakes_delivered_total \(snapshot.foregroundGroupDeferredWakesDelivered)",
        "# HELP im_v2_gateway_connection_closures_total Gateway connection closures by closed transport reason.",
        "# TYPE im_v2_gateway_connection_closures_total counter",
    ]
    for reason in V2GatewayConnectionClosure.allCases {
        lines.append("im_v2_gateway_connection_closures_total{reason=\"\(reason.rawValue)\"} \(snapshot.closureCount(for: reason))")
    }
    return lines.joined(separator: "\n") + "\n"
}

/// 在不削弱精确指标的前提下，限制重复的命令诊断日志。
///
/// 预期内的过载响应与慢接受每秒可能出现数千次。
/// 若把每次出现都写入同步 stdout 处理器，会烧掉本应用于排空队列的 CPU，
/// 并形成正反馈循环。
/// 该限流器在每个一秒窗口内、对每个封闭的命令/结果键各自放行最初一具有界的突发量。
/// Prometheus 仍记录全部事件，因此日志只是代表性跟踪 ID 的来源，而不是不可靠的计数器。
public final class V2CommandDiagnosticLogLimiter: Sendable {
    private struct Key: Hashable, Sendable {
        let command: V2GatewayTelemetryCommand
        let outcome: V2GatewayTelemetryOutcome
        let rejection: V2GatewayTelemetryRejection?
    }

    private struct Bucket: Sendable {
        var window: UInt64
        var admitted: Int
    }

    private struct State: Sendable {
        var buckets: [Key: Bucket] = [:]
    }

    private let maximumPerSecond: Int
    private let nowNanoseconds: @Sendable () -> UInt64
    private let state = Mutex(State())

    public init(maximumPerSecond: Int) {
        precondition(maximumPerSecond > 0)
        self.maximumPerSecond = maximumPerSecond
        nowNanoseconds = { DispatchTime.now().uptimeNanoseconds }
    }

    init(
        maximumPerSecond: Int,
        nowNanoseconds: @escaping @Sendable () -> UInt64
    ) {
        precondition(maximumPerSecond > 0)
        self.maximumPerSecond = maximumPerSecond
        self.nowNanoseconds = nowNanoseconds
    }

    public func admit(
        command: V2GatewayTelemetryCommand,
        outcome: V2GatewayTelemetryOutcome,
        rejection: V2GatewayTelemetryRejection?
    ) -> Bool {
        let window = nowNanoseconds() / 1_000_000_000
        let key = Key(command: command, outcome: outcome, rejection: rejection)
        return state.withLock { state in
            var bucket = state.buckets[key] ?? .init(window: window, admitted: 0)
            if bucket.window != window {
                bucket = .init(window: window, admitted: 0)
            }
            guard bucket.admitted < maximumPerSecond else {
                state.buckets[key] = bucket
                return false
            }
            bucket.admitted += 1
            state.buckets[key] = bucket
            return true
        }
    }
}

/// 把同一个经过隐私审查的事件发送到多个接收端。
///
/// 这使生产结构化日志与指标聚合保持同步，
/// 同时不让任一接收端接触到请求载荷或标识符。
public struct V2CompositeTelemetrySink: V2TelemetrySink {
    private let sinks: [any V2TelemetrySink]

    public init(_ sinks: [any V2TelemetrySink]) {
        self.sinks = sinks
    }

    public func record(_ event: V2TelemetryEvent) async {
        for sink in sinks {
            await sink.record(event)
        }
    }
}

/// 有限基数的 Prometheus 文本导出器，也是所有网关命令共享的有限基数指标累加器。
///
/// 它刻意只消费既定的遥测事件词汇：关联 ID 会被丢弃，
/// 且没有任何用户、房间、设备、令牌、载荷、URL 或异常文本能成为指标标签。
///
/// 命令遥测是极热路径。此前使用 actor 会让每条命令都挂起并在单一执行器上排队，
/// 即便下方的变更只是几次整数加法。改用简短的 `Mutex` 临界区既保留精确计数，
/// 又避免了那次调度跳转。渲染时先取一份值快照，再在锁外格式化，
/// 因此构建 Prometheus 文本文档时不会阻塞命令接受。
public final class V2PrometheusTelemetrySink: V2TelemetrySink, Sendable {
    private struct GatewayKey: Hashable, Sendable {
        let command: V2GatewayTelemetryCommand
        let outcome: V2GatewayTelemetryOutcome
        let rejection: V2GatewayTelemetryRejection?
    }

    private struct MessageFailureKey: Hashable, Sendable {
        let command: V2MessageSendFailureCommand
        let disposition: V2MessageSendFailureDisposition
        let reason: V2MessageSendFailureReason
    }

    private struct CounterAndDuration: Sendable {
        var count: UInt64 = 0
        var elapsedMilliseconds: UInt64 = 0

        mutating func add(elapsedMilliseconds: UInt64) {
            count = v2SaturatingAdd(count, 1)
            self.elapsedMilliseconds = v2SaturatingAdd(self.elapsedMilliseconds, elapsedMilliseconds)
        }
    }

    private struct Storage: Sendable {
        var gateway: [GatewayKey: CounterAndDuration] = [:]
        var messageFailures: [MessageFailureKey: UInt64] = [:]

    }

    private let storage = Mutex(Storage())

    public init() {}

    public func record(_ event: V2TelemetryEvent) async {
        storage.withLock { storage in
            switch event {
            case let .messageSendInternalFailure(command, disposition, reason):
                let key = MessageFailureKey(command: command, disposition: disposition, reason: reason)
                storage.messageFailures[key] = v2SaturatingAdd(storage.messageFailures[key, default: 0], 1)
            case let .gatewayCommand(_, command, outcome, rejection, elapsedMilliseconds):
                let key = GatewayKey(command: command, outcome: outcome, rejection: rejection)
                var aggregate = storage.gateway[key, default: .init()]
                aggregate.add(elapsedMilliseconds: elapsedMilliseconds)
                storage.gateway[key] = aggregate


            }
        }
    }

    /// 产出一份稳定的 Prometheus 0.0.4 文本文档，供私有指标监听器使用。
    ///
    /// 调用方不得把它暴露在公开媒体边缘或实时网关监听器上。
    ///
    /// - Returns: 渲染后的 Prometheus 文本。
    public func renderPrometheus() async -> String {
        let storage = storage.withLock { $0 }
        var lines: [String] = [
            "# HELP im_v2_gateway_commands_total Gateway commands by closed result vocabulary.",
            "# TYPE im_v2_gateway_commands_total counter",
        ]
        lines.append("# HELP im_v2_gateway_message_operation_internal_failures_total Internal room-call failures before wire error mapping; bounded enum labels only.")
        lines.append("# TYPE im_v2_gateway_message_operation_internal_failures_total counter")
        // Export zeros too: a pre-phase scrape supplies a real baseline for
        // failures first observed during the phase, rather than a sparse guess.
        for command in V2MessageSendFailureCommand.allCases {
            for disposition in V2MessageSendFailureDisposition.allCases {
                for reason in V2MessageSendFailureReason.allCases {
                    let key = MessageFailureKey(command: command, disposition: disposition, reason: reason)
                    lines.append("im_v2_gateway_message_operation_internal_failures_total{command=\"\(command.rawValue)\",disposition=\"\(disposition.rawValue)\",reason=\"\(reason.rawValue)\"} \(storage.messageFailures[key, default: 0])")
                }
            }
        }
        for key in storage.gateway.keys.sorted(by: v2GatewayMetricOrder) {
            let aggregate = storage.gateway[key]!
            let rejection = key.rejection?.rawValue ?? "none"
            let labels = "command=\"\(key.command.rawValue)\",outcome=\"\(key.outcome.rawValue)\",rejection=\"\(rejection)\""
            lines.append("im_v2_gateway_commands_total{\(labels)} \(aggregate.count)")
            lines.append("im_v2_gateway_command_duration_milliseconds_sum{\(labels)} \(aggregate.elapsedMilliseconds)")
            lines.append("im_v2_gateway_command_duration_milliseconds_count{\(labels)} \(aggregate.count)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func v2GatewayMetricOrder(_ lhs: GatewayKey, _ rhs: GatewayKey) -> Bool {
        (lhs.command.rawValue, lhs.outcome.rawValue, lhs.rejection?.rawValue ?? "none")
            < (rhs.command.rawValue, rhs.outcome.rawValue, rhs.rejection?.rawValue ?? "none")
    }
}

private func v2SaturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
}
