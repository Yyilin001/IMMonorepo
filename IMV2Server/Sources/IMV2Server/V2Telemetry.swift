import Foundation
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
    private let closures: [V2GatewayConnectionClosure: UInt64]

    public init(
        activeConnections: Int,
        peakQueuedInboundBytes: Int,
        closures: [V2GatewayConnectionClosure: UInt64] = [:]
    ) {
        self.activeConnections = max(0, activeConnections)
        self.peakQueuedInboundBytes = max(0, peakQueuedInboundBytes)
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

    public func gatewayTransportMetricsSnapshot() -> V2GatewayTransportMetricsSnapshot {
        storage.withLock { storage in
            .init(
                activeConnections: storage.activeConnections,
                peakQueuedInboundBytes: storage.peakQueuedInboundBytes,
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
        "# HELP im_v2_gateway_connection_closures_total Gateway connection closures by closed transport reason.",
        "# TYPE im_v2_gateway_connection_closures_total counter",
    ]
    for reason in V2GatewayConnectionClosure.allCases {
        lines.append("im_v2_gateway_connection_closures_total{reason=\"\(reason.rawValue)\"} \(snapshot.closureCount(for: reason))")
    }
    return lines.joined(separator: "\n") + "\n"
}

public enum V2GatewayTelemetryCommand: String, CaseIterable, Equatable, Sendable {
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
    case groupEventSubscribe = "group_event_subscribe"
    case groupEventUnsubscribe = "group_event_unsubscribe"
    case unsupported = "unsupported"
}

public enum V2GatewayTelemetryOutcome: String, CaseIterable, Equatable, Sendable {
    case accepted
    case rejected
    case failed
}

/// Error codes are intentionally a closed, protocol-level vocabulary. The
/// server must not use exception descriptions as telemetry dimensions.
public enum V2GatewayTelemetryRejection: String, CaseIterable, Equatable, Sendable {
    case invalidArgument = "INVALID_ARGUMENT"
    case forbidden = "FORBIDDEN"
    case notFound = "NOT_FOUND"
    case groupCreationFrozen = "GROUP_CREATION_FROZEN"
    case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    case revisionConflict = "REVISION_CONFLICT"
    case rateLimited = "RATE_LIMITED"
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

public struct V2NoopTelemetrySink: V2TelemetrySink {
    public init() {}
    public func record(_: V2TelemetryEvent) async {}
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

/// A deterministic test probe and a minimal adapter for an operations layer
/// that periodically consumes aggregate events. It never stores raw payloads.
public actor V2InMemoryTelemetrySink: V2TelemetrySink {
    private var recordedEvents: [V2TelemetryEvent] = []

    public init() {}

    public func record(_ event: V2TelemetryEvent) {
        recordedEvents.append(event)
    }

    public func events() -> [V2TelemetryEvent] {
        recordedEvents
    }
}

/// A finite-cardinality Prometheus text exporter. It deliberately consumes
/// only the established telemetry event vocabulary: correlation IDs are
/// discarded, and no user, room, device, token, payload, URL, or exception
/// text can become a metric label.
public actor V2PrometheusTelemetrySink: V2TelemetrySink {
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

    private var gateway: [GatewayKey: CounterAndDuration] = [:]
    private var fanoutRuns = CounterAndDuration()
    private var fanoutRelayRuns = CounterAndDuration()
    private var fanoutDeliveryRuns = CounterAndDuration()
    private var fanoutFailures: [V2FanoutTelemetryStage: UInt64] = [:]
    private var fanoutOutboxClaimed: UInt64 = 0
    private var fanoutOutboxPublished: UInt64 = 0
    private var fanoutOutboxReleased: UInt64 = 0
    private var fanoutOutboxPaused: UInt64 = 0
    private var fanoutDeliveriesClaimed: UInt64 = 0
    private var fanoutDeliveriesCommitted: UInt64 = 0
    private var fanoutDeliveriesStale: UInt64 = 0
    private var fanoutDeliveriesStaleRoute: UInt64 = 0
    private var fanoutDeliveriesReleased: UInt64 = 0
    private var fanoutDeliveriesPaused: UInt64 = 0

    public init() {}

    public func record(_ event: V2TelemetryEvent) {
        switch event {
        case let .gatewayCommand(_, command, outcome, rejection, elapsedMilliseconds):
            let key = GatewayKey(command: command, outcome: outcome, rejection: rejection)
            var aggregate = gateway[key, default: .init()]
            aggregate.add(elapsedMilliseconds: elapsedMilliseconds)
            gateway[key] = aggregate

        case let .fanoutProgress(_, claimedOutboxRows, publishedOutboxRows, releasedOutboxRows, pausedOutboxRows, claimedDeliveries, committedDeliveries, staleDeliveries, staleRouteDeliveries, releasedDeliveries, pausedDeliveries, relayElapsedMilliseconds, deliveryElapsedMilliseconds, elapsedMilliseconds):
            fanoutRuns.add(elapsedMilliseconds: elapsedMilliseconds)
            fanoutRelayRuns.add(elapsedMilliseconds: relayElapsedMilliseconds)
            fanoutDeliveryRuns.add(elapsedMilliseconds: deliveryElapsedMilliseconds)
            fanoutOutboxClaimed = v2SaturatingAdd(fanoutOutboxClaimed, v2NonNegative(claimedOutboxRows))
            fanoutOutboxPublished = v2SaturatingAdd(fanoutOutboxPublished, v2NonNegative(publishedOutboxRows))
            fanoutOutboxReleased = v2SaturatingAdd(fanoutOutboxReleased, v2NonNegative(releasedOutboxRows))
            fanoutOutboxPaused = v2SaturatingAdd(fanoutOutboxPaused, v2NonNegative(pausedOutboxRows))
            fanoutDeliveriesClaimed = v2SaturatingAdd(fanoutDeliveriesClaimed, v2NonNegative(claimedDeliveries))
            fanoutDeliveriesCommitted = v2SaturatingAdd(fanoutDeliveriesCommitted, v2NonNegative(committedDeliveries))
            fanoutDeliveriesStale = v2SaturatingAdd(fanoutDeliveriesStale, v2NonNegative(staleDeliveries))
            fanoutDeliveriesStaleRoute = v2SaturatingAdd(fanoutDeliveriesStaleRoute, v2NonNegative(staleRouteDeliveries))
            fanoutDeliveriesReleased = v2SaturatingAdd(fanoutDeliveriesReleased, v2NonNegative(releasedDeliveries))
            fanoutDeliveriesPaused = v2SaturatingAdd(fanoutDeliveriesPaused, v2NonNegative(pausedDeliveries))

        case let .fanoutFailure(_, stage, _):
            fanoutFailures[stage] = v2SaturatingAdd(fanoutFailures[stage, default: 0], 1)
        }
    }

    /// Produces a stable Prometheus 0.0.4 text document suitable for a
    /// private metrics listener. Callers must not expose it on the public
    /// media edge or realtime gateway listener.
    public func renderPrometheus() -> String {
        var lines: [String] = [
            "# HELP im_v2_gateway_commands_total Gateway commands by closed result vocabulary.",
            "# TYPE im_v2_gateway_commands_total counter",
        ]
        for key in gateway.keys.sorted(by: v2GatewayMetricOrder) {
            let aggregate = gateway[key]!
            let rejection = key.rejection?.rawValue ?? "none"
            let labels = "command=\"\(key.command.rawValue)\",outcome=\"\(key.outcome.rawValue)\",rejection=\"\(rejection)\""
            lines.append("im_v2_gateway_commands_total{\(labels)} \(aggregate.count)")
            lines.append("im_v2_gateway_command_duration_milliseconds_sum{\(labels)} \(aggregate.elapsedMilliseconds)")
            lines.append("im_v2_gateway_command_duration_milliseconds_count{\(labels)} \(aggregate.count)")
        }

        lines += [
            "# HELP im_v2_fanout_runs_total Durable fan-out pipeline runs.",
            "# TYPE im_v2_fanout_runs_total counter",
            "im_v2_fanout_runs_total \(fanoutRuns.count)",
            "im_v2_fanout_run_duration_milliseconds_sum \(fanoutRuns.elapsedMilliseconds)",
            "im_v2_fanout_run_duration_milliseconds_count \(fanoutRuns.count)",
            "# HELP im_v2_fanout_relay_duration_milliseconds Aggregate outbox relay phase duration.",
            "# TYPE im_v2_fanout_relay_duration_milliseconds summary",
            "im_v2_fanout_relay_duration_milliseconds_sum \(fanoutRelayRuns.elapsedMilliseconds)",
            "im_v2_fanout_relay_duration_milliseconds_count \(fanoutRelayRuns.count)",
            "# HELP im_v2_fanout_delivery_duration_milliseconds Aggregate delivery phase duration.",
            "# TYPE im_v2_fanout_delivery_duration_milliseconds summary",
            "im_v2_fanout_delivery_duration_milliseconds_sum \(fanoutDeliveryRuns.elapsedMilliseconds)",
            "im_v2_fanout_delivery_duration_milliseconds_count \(fanoutDeliveryRuns.count)",
            "# HELP im_v2_fanout_outbox_rows_total Aggregate durable outbox progression.",
            "# TYPE im_v2_fanout_outbox_rows_total counter",
            "im_v2_fanout_outbox_rows_total{state=\"claimed\"} \(fanoutOutboxClaimed)",
            "im_v2_fanout_outbox_rows_total{state=\"published\"} \(fanoutOutboxPublished)",
            "im_v2_fanout_outbox_rows_total{state=\"released\"} \(fanoutOutboxReleased)",
            "im_v2_fanout_outbox_rows_total{state=\"paused\"} \(fanoutOutboxPaused)",
            "# HELP im_v2_fanout_deliveries_total Aggregate delivery progression.",
            "# TYPE im_v2_fanout_deliveries_total counter",
            "im_v2_fanout_deliveries_total{state=\"claimed\"} \(fanoutDeliveriesClaimed)",
            "im_v2_fanout_deliveries_total{state=\"committed\"} \(fanoutDeliveriesCommitted)",
            "im_v2_fanout_deliveries_total{state=\"stale\"} \(fanoutDeliveriesStale)",
            "im_v2_fanout_deliveries_total{state=\"stale_route\"} \(fanoutDeliveriesStaleRoute)",
            "im_v2_fanout_deliveries_total{state=\"released\"} \(fanoutDeliveriesReleased)",
            "im_v2_fanout_deliveries_total{state=\"paused\"} \(fanoutDeliveriesPaused)",
            "# HELP im_v2_fanout_failures_total Fan-out failures by closed stage vocabulary.",
            "# TYPE im_v2_fanout_failures_total counter",
        ]
        for stage in V2FanoutTelemetryStage.allCases {
            lines.append("im_v2_fanout_failures_total{stage=\"\(stage.rawValue)\"} \(fanoutFailures[stage, default: 0])")
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
    case .groupEventSubscribe: .groupEventSubscribe
    case .groupEventUnsubscribe: .groupEventUnsubscribe
    default: .unsupported
    }
}

func v2ElapsedMilliseconds(since startedAt: Date, now: Date) -> UInt64 {
    UInt64(max(0, (now.timeIntervalSince(startedAt) * 1_000).rounded(.down)))
}
