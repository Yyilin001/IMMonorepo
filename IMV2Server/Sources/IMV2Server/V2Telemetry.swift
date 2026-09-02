import Foundation
import Dispatch
import Synchronization

/// A deliberately small observability boundary. Its fields are enumerated or
/// aggregate values only: callers must not attach room IDs, user IDs, message
/// content, opaque tokens, URLs, or arbitrary error strings as metric labels.
public protocol V2TelemetrySink: Sendable {
    func record(_ event: V2TelemetryEvent) async
}

/// A privacy-safe, point-in-time view of gateway connection state. It is
/// intentionally limited to process-local aggregate counts: neither device
/// identifiers nor user identifiers may cross this boundary.
public protocol V2ConnectionMetricsSource: Sendable {
    func connectionMetricsSnapshot() async -> V2ConnectionMetricsSnapshot
}

public struct V2ConnectionMetricsSnapshot: Equatable, Sendable {
    public let activeDevices: Int
    public let activeConnections: Int

    public init(activeDevices: Int, activeConnections: Int) {
        self.activeDevices = max(0, activeDevices)
        self.activeConnections = max(0, activeConnections)
    }
}

/// Renders the connection-specific part of the private Prometheus surface.
/// Keeping it separate from event telemetry means a scrape observes the
/// current registry state instead of a counter reconstructed from lifecycle
/// events that could be lost across a process restart.
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

/// Closed reasons for a gateway socket leaving service. These are intentionally
/// transport facts rather than error strings, so they remain safe metric
/// labels and cannot expose command payload or identity data.
public enum V2GatewayConnectionClosure: String, CaseIterable, Equatable, Sendable {
    case peerDisconnected = "peer_disconnected"
    case connectionLimit = "connection_limit"
    case authenticationTimeout = "authentication_timeout"
    case idleTimeout = "idle_timeout"
    case inboundQueueLimit = "inbound_queue_limit"
    case frameLimitViolation = "frame_limit_violation"
    case requestFailure = "request_failure"
    case deviceRevoked = "device_revoked"
}

public struct V2GatewayTransportMetricsSnapshot: Equatable, Sendable {
    public let activeConnections: Int
    public let peakQueuedInboundBytes: Int
    public let foregroundFramesSubmitted: UInt64
    public let foregroundBytesSubmitted: UInt64
    public let foregroundRecoveryFramesQueued: UInt64
    public let foregroundRecoveryFramesReplaced: UInt64
    public let foregroundFramesWritten: UInt64
    public let foregroundBytesWritten: UInt64
    public let foregroundWriteBatches: UInt64
    public let foregroundNonWritableDeferrals: UInt64
    public let peakQueuedForegroundBytes: Int
    public let foregroundGroupEventsSubmitted: UInt64
    public let foregroundGroupEventsPublished: UInt64
    public let foregroundGroupEventBatchesPublished: UInt64
    public let foregroundGroupEventDuplicatesSuppressed: UInt64
    public let foregroundGroupEventOutOfOrderArrivals: UInt64
    public let foregroundGroupEventLateArrivals: UInt64
    public let foregroundGroupEventBatchDegradations: UInt64
    public let foregroundGroupInboundNotificationsDropped: UInt64
    public let foregroundGroupCoveredWakesSuppressed: UInt64
    public let foregroundGroupWakesDeferred: UInt64
    public let foregroundGroupDeferredWakesDelivered: UInt64
    private let closures: [V2GatewayConnectionClosure: UInt64]

    public init(
        activeConnections: Int,
        peakQueuedInboundBytes: Int,
        foregroundFramesSubmitted: UInt64 = 0,
        foregroundBytesSubmitted: UInt64 = 0,
        foregroundRecoveryFramesQueued: UInt64 = 0,
        foregroundRecoveryFramesReplaced: UInt64 = 0,
        foregroundFramesWritten: UInt64 = 0,
        foregroundBytesWritten: UInt64 = 0,
        foregroundWriteBatches: UInt64 = 0,
        foregroundNonWritableDeferrals: UInt64 = 0,
        peakQueuedForegroundBytes: Int = 0,
        foregroundGroupEventsSubmitted: UInt64 = 0,
        foregroundGroupEventsPublished: UInt64 = 0,
        foregroundGroupEventBatchesPublished: UInt64 = 0,
        foregroundGroupEventDuplicatesSuppressed: UInt64 = 0,
        foregroundGroupEventOutOfOrderArrivals: UInt64 = 0,
        foregroundGroupEventLateArrivals: UInt64 = 0,
        foregroundGroupEventBatchDegradations: UInt64 = 0,
        foregroundGroupInboundNotificationsDropped: UInt64 = 0,
        foregroundGroupCoveredWakesSuppressed: UInt64 = 0,
        foregroundGroupWakesDeferred: UInt64 = 0,
        foregroundGroupDeferredWakesDelivered: UInt64 = 0,
        closures: [V2GatewayConnectionClosure: UInt64] = [:]
    ) {
        self.activeConnections = max(0, activeConnections)
        self.peakQueuedInboundBytes = max(0, peakQueuedInboundBytes)
        self.foregroundFramesSubmitted = foregroundFramesSubmitted
        self.foregroundBytesSubmitted = foregroundBytesSubmitted
        self.foregroundRecoveryFramesQueued = foregroundRecoveryFramesQueued
        self.foregroundRecoveryFramesReplaced = foregroundRecoveryFramesReplaced
        self.foregroundFramesWritten = foregroundFramesWritten
        self.foregroundBytesWritten = foregroundBytesWritten
        self.foregroundWriteBatches = foregroundWriteBatches
        self.foregroundNonWritableDeferrals = foregroundNonWritableDeferrals
        self.peakQueuedForegroundBytes = max(0, peakQueuedForegroundBytes)
        self.foregroundGroupEventsSubmitted = foregroundGroupEventsSubmitted
        self.foregroundGroupEventsPublished = foregroundGroupEventsPublished
        self.foregroundGroupEventBatchesPublished = foregroundGroupEventBatchesPublished
        self.foregroundGroupEventDuplicatesSuppressed =
            foregroundGroupEventDuplicatesSuppressed
        self.foregroundGroupEventOutOfOrderArrivals =
            foregroundGroupEventOutOfOrderArrivals
        self.foregroundGroupEventLateArrivals = foregroundGroupEventLateArrivals
        self.foregroundGroupEventBatchDegradations =
            foregroundGroupEventBatchDegradations
        self.foregroundGroupInboundNotificationsDropped =
            foregroundGroupInboundNotificationsDropped
        self.foregroundGroupCoveredWakesSuppressed =
            foregroundGroupCoveredWakesSuppressed
        self.foregroundGroupWakesDeferred = foregroundGroupWakesDeferred
        self.foregroundGroupDeferredWakesDelivered =
            foregroundGroupDeferredWakesDelivered
        self.closures = closures
    }

    public func closureCount(for reason: V2GatewayConnectionClosure) -> UInt64 {
        closures[reason, default: 0]
    }
}

public protocol V2GatewayTransportMetricsSource: Sendable {
    func gatewayTransportMetricsSnapshot() async -> V2GatewayTransportMetricsSnapshot
}

/// Write-side transport instrumentation boundary. The reader-only source is
/// what the metrics listener accepts; gateway handlers additionally need this
/// closed mutation vocabulary.
public protocol V2GatewayTransportMetricsRecorder: V2GatewayTransportMetricsSource {
    func connectionOpened()
    func connectionClosed(reason: V2GatewayConnectionClosure)
    /// Records a socket rejected before the channel handler owns an active
    /// connection gauge slot.
    func connectionRejected(reason: V2GatewayConnectionClosure)
    func observeQueuedInboundBytes(_ bytes: Int)
    func foregroundFrameSubmitted(
        bytes: Int,
        recoveryQueued: Bool,
        recoveryReplaced: Bool,
        queuedBytes: Int
    )
    func foregroundWriteBatch(frames: Int, bytes: Int)
    func foregroundWriteDeferredForWritability()
    func foregroundGroupEventSubmitted(
        duplicateSuppressed: Bool,
        outOfOrder: Bool,
        lateAfterPublication: Bool,
        degradedToWake: Bool
    )
    func foregroundGroupEventBatchPublished(eventCount: Int)
    func foregroundGroupInboundNotificationDropped()
    func foregroundGroupCoveredWakeSuppressed()
    func foregroundGroupWakeDeferred()
    func foregroundGroupDeferredWakeDelivered()
}

extension V2GatewayTransportMetricsRecorder {
    public func foregroundFrameSubmitted(
        bytes _: Int,
        recoveryQueued _: Bool,
        recoveryReplaced _: Bool,
        queuedBytes _: Int
    ) {}
    public func foregroundWriteBatch(frames _: Int, bytes _: Int) {}
    public func foregroundWriteDeferredForWritability() {}
    public func foregroundGroupEventSubmitted(
        duplicateSuppressed _: Bool,
        outOfOrder _: Bool,
        lateAfterPublication _: Bool,
        degradedToWake _: Bool
    ) {}
    public func foregroundGroupEventBatchPublished(eventCount _: Int) {}
    public func foregroundGroupInboundNotificationDropped() {}
    public func foregroundGroupCoveredWakeSuppressed() {}
    public func foregroundGroupWakeDeferred() {}
    public func foregroundGroupDeferredWakeDelivered() {}
}

/// Process-local transport metrics. Gateway channels update it without using
/// connection, user, device, room or request identifiers. The peak queue value
/// is deliberately a process lifetime high-water mark, not a per-channel
/// label, so a scrape cannot create unbounded time series. `Mutex` is the
/// explicit synchronization boundary for every mutable field, allowing this
/// process-wide recorder to be Sendable without an unchecked conformance.
public final class V2GatewayTransportMetrics: V2GatewayTransportMetricsRecorder, Sendable {
    private struct Storage: Sendable {
        var activeConnections = 0
        var peakQueuedInboundBytes = 0
        var closures: [V2GatewayConnectionClosure: UInt64] = [:]
    }

    private let storage = Mutex(Storage())
    // The foreground fanout path can submit hundreds of thousands of local
    // recipient frames per second. Relaxed atomics keep metrics from becoming
    // a global mutex on that path; these counters publish observations only
    // and protect no application state.
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
        "# HELP im_v2_gateway_foreground_group_inbound_notifications_dropped_total Decoded NATS group notifications evicted from the bounded socket-fanout mailbox after recovery-cache ingestion.",
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

public enum V2GatewayTelemetryCommand: String, CaseIterable, Hashable, Sendable {
    case sendMessage = "send_message"
    case changeRoomMembership = "change_room_membership"
    case withdrawMessage = "withdraw_message"
    case changeMessageReaction = "change_message_reaction"
    case editMessage = "edit_message"
    case recordReadReceipt = "record_read_receipt"
    case openDirectRoom = "open_direct_room"
    case setStrangerMessagePermission = "set_stranger_message_permission"
    case setUserAddPermission = "set_user_add_permission"
    case changeRelationship = "change_relationship"
    case changeUserBlock = "change_user_block"
    case moderateMemberRemoval = "moderate_member_removal"
    case syncPull = "sync_pull"
    case syncAck = "sync_ack"
    case syncSnapshot = "sync_snapshot"
    case snapshotPagePull = "snapshot_page_pull"
    case snapshotAck = "snapshot_ack"
    case listRoomMembers = "list_room_members"
    case groupEventPull = "group_event_pull"
    case groupEventSubscribe = "group_event_subscribe"
    case groupEventUnsubscribe = "group_event_unsubscribe"
    case unsupported = "unsupported"
}

public enum V2GatewayTelemetryOutcome: String, CaseIterable, Hashable, Sendable {
    case accepted
    case rejected
    case failed
}

/// Error codes are intentionally a closed, protocol-level vocabulary. The
/// server must not use exception descriptions as telemetry dimensions.
public enum V2GatewayTelemetryRejection: String, CaseIterable, Hashable, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case forbidden = "FORBIDDEN"
    case notFound = "NOT_FOUND"
    case groupCreationFrozen = "GROUP_CREATION_FROZEN"
    case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    case revisionConflict = "REVISION_CONFLICT"
    case rateLimited = "RATE_LIMITED"
    case serverBusy = "SERVER_BUSY"
    case unavailable = "UNAVAILABLE"
    case syncTokenInvalid = "SYNC_TOKEN_INVALID"
    case syncReceiptInvalid = "SYNC_RECEIPT_INVALID"
    case resetRequired = "RESET_REQUIRED"
    case upgradeRequired = "UPGRADE_REQUIRED"

    init?(protocolCode: String) {
        self.init(rawValue: protocolCode)
    }
}

public enum V2TelemetryEvent: Equatable, Sendable {
    /// The trace ID correlates a single gateway command without identifying a
    /// user, device, room, message, token or protocol payload.
    case gatewayCommand(
        traceID: UUID,
        command: V2GatewayTelemetryCommand,
        outcome: V2GatewayTelemetryOutcome,
        rejection: V2GatewayTelemetryRejection?,
        elapsedMilliseconds: UInt64
    )
    /// Aggregate durable-work progression. Counts are deliberately not keyed
    /// by room, source event, target user or shard to avoid high cardinality.
    case fanoutProgress(
        traceID: UUID,
        claimedOutboxRows: Int,
        publishedOutboxRows: Int,
        releasedOutboxRows: Int,
        pausedOutboxRows: Int,
        claimedDeliveries: Int,
        committedDeliveries: Int,
        staleDeliveries: Int,
        staleRouteDeliveries: Int,
        releasedDeliveries: Int,
        pausedDeliveries: Int,
        relayElapsedMilliseconds: UInt64,
        deliveryElapsedMilliseconds: UInt64,
        elapsedMilliseconds: UInt64
    )
    case fanoutFailure(traceID: UUID, stage: V2FanoutTelemetryStage, elapsedMilliseconds: UInt64)
}

public enum V2FanoutTelemetryStage: String, CaseIterable, Equatable, Sendable {
    case relay
    case delivery
    case pipeline
}

/// Bounds repeated command diagnostics without weakening exact metrics.
///
/// Expected overload responses and slow accepts can arrive thousands of times
/// per second. Writing every occurrence to a synchronous stdout handler burns
/// the CPU needed to drain the queue and creates a positive feedback loop.
/// This limiter admits the first bounded burst independently for every closed
/// command/result key in each one-second window. Prometheus still records all
/// events, so the log remains a source of representative trace IDs rather than
/// an unreliable counter.
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

/// Sends the same privacy-reviewed event to several sinks. This keeps the
/// production structured log and the metrics aggregate in lockstep without
/// giving either sink access to request payloads or identifiers.
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

/// A finite-cardinality Prometheus text exporter. It deliberately consumes
/// only the established telemetry event vocabulary: correlation IDs are
/// discarded, and no user, room, device, token, payload, URL, or exception
/// text can become a metric label.
/// A finite-cardinality metrics accumulator shared by every gateway command.
///
/// Command telemetry is a very hot path. An actor made every command suspend
/// and enqueue on one executor even though the mutation below is only a few
/// integer additions. A short `Mutex` critical section preserves exact
/// counters while avoiding that scheduler hop. Rendering first takes a value
/// snapshot and formats outside the lock, so a scrape cannot stall command
/// acceptance while it builds the Prometheus text document.
public final class V2PrometheusTelemetrySink: V2TelemetrySink, Sendable {
    private struct GatewayKey: Hashable, Sendable {
        let command: V2GatewayTelemetryCommand
        let outcome: V2GatewayTelemetryOutcome
        let rejection: V2GatewayTelemetryRejection?
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
        var fanoutRuns = CounterAndDuration()
        var fanoutRelayRuns = CounterAndDuration()
        var fanoutDeliveryRuns = CounterAndDuration()
        var fanoutFailures: [V2FanoutTelemetryStage: UInt64] = [:]
        var fanoutOutboxClaimed: UInt64 = 0
        var fanoutOutboxPublished: UInt64 = 0
        var fanoutOutboxReleased: UInt64 = 0
        var fanoutOutboxPaused: UInt64 = 0
        var fanoutDeliveriesClaimed: UInt64 = 0
        var fanoutDeliveriesCommitted: UInt64 = 0
        var fanoutDeliveriesStale: UInt64 = 0
        var fanoutDeliveriesStaleRoute: UInt64 = 0
        var fanoutDeliveriesReleased: UInt64 = 0
        var fanoutDeliveriesPaused: UInt64 = 0
    }

    private let storage = Mutex(Storage())

    public init() {}

    public func record(_ event: V2TelemetryEvent) async {
        storage.withLock { storage in
            switch event {
            case let .gatewayCommand(_, command, outcome, rejection, elapsedMilliseconds):
                let key = GatewayKey(command: command, outcome: outcome, rejection: rejection)
                var aggregate = storage.gateway[key, default: .init()]
                aggregate.add(elapsedMilliseconds: elapsedMilliseconds)
                storage.gateway[key] = aggregate

            case let .fanoutProgress(_, claimedOutboxRows, publishedOutboxRows, releasedOutboxRows, pausedOutboxRows, claimedDeliveries, committedDeliveries, staleDeliveries, staleRouteDeliveries, releasedDeliveries, pausedDeliveries, relayElapsedMilliseconds, deliveryElapsedMilliseconds, elapsedMilliseconds):
                storage.fanoutRuns.add(elapsedMilliseconds: elapsedMilliseconds)
                storage.fanoutRelayRuns.add(elapsedMilliseconds: relayElapsedMilliseconds)
                storage.fanoutDeliveryRuns.add(elapsedMilliseconds: deliveryElapsedMilliseconds)
                storage.fanoutOutboxClaimed = v2SaturatingAdd(storage.fanoutOutboxClaimed, v2NonNegative(claimedOutboxRows))
                storage.fanoutOutboxPublished = v2SaturatingAdd(storage.fanoutOutboxPublished, v2NonNegative(publishedOutboxRows))
                storage.fanoutOutboxReleased = v2SaturatingAdd(storage.fanoutOutboxReleased, v2NonNegative(releasedOutboxRows))
                storage.fanoutOutboxPaused = v2SaturatingAdd(storage.fanoutOutboxPaused, v2NonNegative(pausedOutboxRows))
                storage.fanoutDeliveriesClaimed = v2SaturatingAdd(storage.fanoutDeliveriesClaimed, v2NonNegative(claimedDeliveries))
                storage.fanoutDeliveriesCommitted = v2SaturatingAdd(storage.fanoutDeliveriesCommitted, v2NonNegative(committedDeliveries))
                storage.fanoutDeliveriesStale = v2SaturatingAdd(storage.fanoutDeliveriesStale, v2NonNegative(staleDeliveries))
                storage.fanoutDeliveriesStaleRoute = v2SaturatingAdd(storage.fanoutDeliveriesStaleRoute, v2NonNegative(staleRouteDeliveries))
                storage.fanoutDeliveriesReleased = v2SaturatingAdd(storage.fanoutDeliveriesReleased, v2NonNegative(releasedDeliveries))
                storage.fanoutDeliveriesPaused = v2SaturatingAdd(storage.fanoutDeliveriesPaused, v2NonNegative(pausedDeliveries))

            case let .fanoutFailure(_, stage, _):
                storage.fanoutFailures[stage] = v2SaturatingAdd(
                    storage.fanoutFailures[stage, default: 0],
                    1
                )
            }
        }
    }

    /// Produces a stable Prometheus 0.0.4 text document suitable for a
    /// private metrics listener. Callers must not expose it on the public
    /// media edge or realtime gateway listener.
    public func renderPrometheus() async -> String {
        let storage = storage.withLock { $0 }
        var lines: [String] = [
            "# HELP im_v2_gateway_commands_total Gateway commands by closed result vocabulary.",
            "# TYPE im_v2_gateway_commands_total counter",
        ]
        for key in storage.gateway.keys.sorted(by: v2GatewayMetricOrder) {
            let aggregate = storage.gateway[key]!
            let rejection = key.rejection?.rawValue ?? "none"
            let labels = "command=\"\(key.command.rawValue)\",outcome=\"\(key.outcome.rawValue)\",rejection=\"\(rejection)\""
            lines.append("im_v2_gateway_commands_total{\(labels)} \(aggregate.count)")
            lines.append("im_v2_gateway_command_duration_milliseconds_sum{\(labels)} \(aggregate.elapsedMilliseconds)")
            lines.append("im_v2_gateway_command_duration_milliseconds_count{\(labels)} \(aggregate.count)")
        }

        lines += [
            "# HELP im_v2_fanout_runs_total Durable fan-out pipeline runs.",
            "# TYPE im_v2_fanout_runs_total counter",
            "im_v2_fanout_runs_total \(storage.fanoutRuns.count)",
            "im_v2_fanout_run_duration_milliseconds_sum \(storage.fanoutRuns.elapsedMilliseconds)",
            "im_v2_fanout_run_duration_milliseconds_count \(storage.fanoutRuns.count)",
            "# HELP im_v2_fanout_relay_duration_milliseconds Aggregate outbox relay phase duration.",
            "# TYPE im_v2_fanout_relay_duration_milliseconds summary",
            "im_v2_fanout_relay_duration_milliseconds_sum \(storage.fanoutRelayRuns.elapsedMilliseconds)",
            "im_v2_fanout_relay_duration_milliseconds_count \(storage.fanoutRelayRuns.count)",
            "# HELP im_v2_fanout_delivery_duration_milliseconds Aggregate delivery phase duration.",
            "# TYPE im_v2_fanout_delivery_duration_milliseconds summary",
            "im_v2_fanout_delivery_duration_milliseconds_sum \(storage.fanoutDeliveryRuns.elapsedMilliseconds)",
            "im_v2_fanout_delivery_duration_milliseconds_count \(storage.fanoutDeliveryRuns.count)",
            "# HELP im_v2_fanout_outbox_rows_total Aggregate durable outbox progression.",
            "# TYPE im_v2_fanout_outbox_rows_total counter",
            "im_v2_fanout_outbox_rows_total{state=\"claimed\"} \(storage.fanoutOutboxClaimed)",
            "im_v2_fanout_outbox_rows_total{state=\"published\"} \(storage.fanoutOutboxPublished)",
            "im_v2_fanout_outbox_rows_total{state=\"released\"} \(storage.fanoutOutboxReleased)",
            "im_v2_fanout_outbox_rows_total{state=\"paused\"} \(storage.fanoutOutboxPaused)",
            "# HELP im_v2_fanout_deliveries_total Aggregate delivery progression.",
            "# TYPE im_v2_fanout_deliveries_total counter",
            "im_v2_fanout_deliveries_total{state=\"claimed\"} \(storage.fanoutDeliveriesClaimed)",
            "im_v2_fanout_deliveries_total{state=\"committed\"} \(storage.fanoutDeliveriesCommitted)",
            "im_v2_fanout_deliveries_total{state=\"stale\"} \(storage.fanoutDeliveriesStale)",
            "im_v2_fanout_deliveries_total{state=\"stale_route\"} \(storage.fanoutDeliveriesStaleRoute)",
            "im_v2_fanout_deliveries_total{state=\"released\"} \(storage.fanoutDeliveriesReleased)",
            "im_v2_fanout_deliveries_total{state=\"paused\"} \(storage.fanoutDeliveriesPaused)",
            "# HELP im_v2_fanout_failures_total Fan-out failures by closed stage vocabulary.",
            "# TYPE im_v2_fanout_failures_total counter",
        ]
        for stage in V2FanoutTelemetryStage.allCases {
            lines.append("im_v2_fanout_failures_total{stage=\"\(stage.rawValue)\"} \(storage.fanoutFailures[stage, default: 0])")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func v2GatewayMetricOrder(_ lhs: GatewayKey, _ rhs: GatewayKey) -> Bool {
        (lhs.command.rawValue, lhs.outcome.rawValue, lhs.rejection?.rawValue ?? "none")
            < (rhs.command.rawValue, rhs.outcome.rawValue, rhs.rejection?.rawValue ?? "none")
    }
}

private func v2NonNegative(_ value: Int) -> UInt64 {
    value > 0 ? UInt64(value) : 0
}

private func v2SaturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
}

func v2TelemetryCommand(for envelope: IMV2Envelope) -> V2GatewayTelemetryCommand {
    switch envelope.body {
    case .sendMessage: .sendMessage
    case .changeRoomMembership: .changeRoomMembership
    case .withdrawMessage: .withdrawMessage
    case .changeMessageReaction: .changeMessageReaction
    case .editMessage: .editMessage
    case .recordReadReceipt: .recordReadReceipt
    case .openDirectRoom: .openDirectRoom
    case .setStrangerMessagePermission: .setStrangerMessagePermission
    case .setUserAddPermission: .setUserAddPermission
    case .changeRelationship: .changeRelationship
    case .changeUserBlock: .changeUserBlock
    case .moderateMemberRemoval: .moderateMemberRemoval
    case .syncPull: .syncPull
    case .syncAck: .syncAck
    case .syncSnapshot: .syncSnapshot
    case .snapshotPagePull: .snapshotPagePull
    case .snapshotAck: .snapshotAck
    case .listRoomMembers: .listRoomMembers
    case .groupEventPull: .groupEventPull
    case .groupEventSubscribe: .groupEventSubscribe
    case .groupEventUnsubscribe: .groupEventUnsubscribe
    default: .unsupported
    }
}

func v2ElapsedMilliseconds(since startedAt: Date, now: Date) -> UInt64 {
    UInt64(max(0, (now.timeIntervalSince(startedAt) * 1_000).rounded(.down)))
}
