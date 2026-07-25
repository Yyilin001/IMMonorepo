import Fluent
import Foundation
import SQLKit

/// A private, aggregate-only view of durable work waiting behind the gateway.
/// It deliberately contains no identifiers, shard labels, provider names, or
/// payload-derived fields, so it is safe to render from the loopback-only
/// Prometheus listener.
public protocol V2DurableWorkMetricsSource: Sendable {
    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot
}

public struct V2DurableWorkMetricsSnapshot: Equatable, Sendable {
    public let isAvailable: Bool
    public let readyRoomOutboxRows: Int
    public let leasedRoomOutboxRows: Int
    public let scheduledRoomOutboxRows: Int
    public let pausedRoomOutboxRows: Int
    public let readyDirectProfileUpdates: Int
    public let leasedDirectProfileUpdates: Int
    public let openFanoutPlans: Int
    public let readyFanoutDeliveries: Int
    public let leasedFanoutDeliveries: Int
    public let scheduledFanoutDeliveries: Int
    public let pausedFanoutDeliveries: Int
    public let pendingSyncRecordsAcrossDevices: Int
    public let resetPendingDevices: Int
    public let readyPushWakes: Int
    public let leasedPushWakes: Int
    public let suppressedPushWakes: Int
    /// Outstanding durable account/device revocations for the gateway node
    /// serving this private scrape. It intentionally has no node/device/user
    /// label, so the scrape cannot disclose topology or identity.
    public let pendingDeviceRevocationEvents: Int

    public init(
        isAvailable: Bool,
        readyRoomOutboxRows: Int = 0,
        leasedRoomOutboxRows: Int = 0,
        scheduledRoomOutboxRows: Int = 0,
        pausedRoomOutboxRows: Int = 0,
        readyDirectProfileUpdates: Int = 0,
        leasedDirectProfileUpdates: Int = 0,
        openFanoutPlans: Int = 0,
        readyFanoutDeliveries: Int = 0,
        leasedFanoutDeliveries: Int = 0,
        scheduledFanoutDeliveries: Int = 0,
        pausedFanoutDeliveries: Int = 0,
        pendingSyncRecordsAcrossDevices: Int = 0,
        resetPendingDevices: Int = 0,
        readyPushWakes: Int = 0,
        leasedPushWakes: Int = 0,
        suppressedPushWakes: Int = 0,
        pendingDeviceRevocationEvents: Int = 0
    ) {
        self.isAvailable = isAvailable
        self.readyRoomOutboxRows = max(0, readyRoomOutboxRows)
        self.leasedRoomOutboxRows = max(0, leasedRoomOutboxRows)
        self.scheduledRoomOutboxRows = max(0, scheduledRoomOutboxRows)
        self.pausedRoomOutboxRows = max(0, pausedRoomOutboxRows)
        self.readyDirectProfileUpdates = max(0, readyDirectProfileUpdates)
        self.leasedDirectProfileUpdates = max(0, leasedDirectProfileUpdates)
        self.openFanoutPlans = max(0, openFanoutPlans)
        self.readyFanoutDeliveries = max(0, readyFanoutDeliveries)
        self.leasedFanoutDeliveries = max(0, leasedFanoutDeliveries)
        self.scheduledFanoutDeliveries = max(0, scheduledFanoutDeliveries)
        self.pausedFanoutDeliveries = max(0, pausedFanoutDeliveries)
        self.pendingSyncRecordsAcrossDevices = max(0, pendingSyncRecordsAcrossDevices)
        self.resetPendingDevices = max(0, resetPendingDevices)
        self.readyPushWakes = max(0, readyPushWakes)
        self.leasedPushWakes = max(0, leasedPushWakes)
        self.suppressedPushWakes = max(0, suppressedPushWakes)
        self.pendingDeviceRevocationEvents = max(0, pendingDeviceRevocationEvents)
    }

    public static let unavailable = Self(isAvailable: false)
}

/// The snapshot is evaluated at scrape time rather than reconstructed from
/// worker counters. This preserves visibility across process restarts and
/// allows alerts to distinguish an idle worker from a growing durable backlog.
public struct PostgresV2DurableWorkMetricsSource: V2DurableWorkMetricsSource {
    private let database: any Database
    private let deliveryBucket: String?
    private let gatewayNodeID: String?

    /// `nil` is the runtime's all-configured-buckets view. The bucket-scoped
    /// form is retained for focused tests and partitioned deployments.
    public init(database: any Database, deliveryBucket: String? = nil, gatewayNodeID: String? = nil) {
        self.database = database
        self.deliveryBucket = deliveryBucket
        self.gatewayNodeID = gatewayNodeID
    }

    /// Exposes the fallible database boundary for focused integration tests.
    /// The metrics route must use `durableWorkMetricsSnapshot()` instead so a
    /// failed scrape remains observable without replacing the whole endpoint.
    public func loadDurableWorkMetrics() async throws -> V2DurableWorkMetricsSnapshot {
        guard let sql = database as? any SQLDatabase else {
            throw V2DurableWorkMetricsError.sqlUnavailable
        }
        // PostgreSQL cannot infer a type for a bare NULL bind in `NULL IS
        // NULL`. Bind an explicit Boolean scope flag instead, while keeping
        // the bucket bind typed by its comparison to the text column.
        let includesAllDeliveryBuckets = deliveryBucket == nil
        let scopedDeliveryBucket = deliveryBucket ?? ""
        let includesGatewayRevocationMetrics = gatewayNodeID != nil
        let scopedGatewayNodeID = gatewayNodeID ?? ""
        guard let row = try await sql.raw("""
                WITH snapshot_now AS (SELECT CURRENT_TIMESTAMP AS value)
                SELECT
                    (SELECT COUNT(*)
                     FROM im_v2.room_outbox, snapshot_now
                     WHERE state = 'pending'
                       AND (next_attempt_at IS NULL OR next_attempt_at <= snapshot_now.value)
                       AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value))
                        AS ready_room_outbox_rows,
                    (SELECT COUNT(*)
                     FROM im_v2.room_outbox, snapshot_now
                     WHERE state = 'pending' AND lease_expires_at > snapshot_now.value)
                        AS leased_room_outbox_rows,
                    (SELECT COUNT(*)
                     FROM im_v2.room_outbox, snapshot_now
                     WHERE state = 'pending' AND next_attempt_at > snapshot_now.value
                       AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value))
                        AS scheduled_room_outbox_rows,
                    (SELECT COUNT(*) FROM im_v2.room_outbox WHERE state = 'paused')
                        AS paused_room_outbox_rows,
                    (SELECT COUNT(*)
                     FROM im_v2.public_profile_update_outbox, snapshot_now
                     WHERE state = 'pending'
                        OR (state = 'claimed' AND lease_expires_at <= snapshot_now.value))
                        AS ready_direct_profile_updates,
                    (SELECT COUNT(*)
                     FROM im_v2.public_profile_update_outbox, snapshot_now
                     WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value)
                        AS leased_direct_profile_updates,
                    (SELECT COUNT(*) FROM im_v2.fanout_plans WHERE state <> 'terminal')
                        AS open_fanout_plans,
                    (SELECT COUNT(*)
                     FROM im_v2.fanout_deliveries, snapshot_now
                     WHERE (\(bind: includesAllDeliveryBuckets) OR target_shard_bucket = \(bind: scopedDeliveryBucket))
                       AND state = 'pending'
                       AND (next_attempt_at IS NULL OR next_attempt_at <= snapshot_now.value)
                       AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value))
                        AS ready_fanout_deliveries,
                    (SELECT COUNT(*)
                     FROM im_v2.fanout_deliveries, snapshot_now
                     WHERE (\(bind: includesAllDeliveryBuckets) OR target_shard_bucket = \(bind: scopedDeliveryBucket))
                       AND state = 'pending' AND lease_expires_at > snapshot_now.value)
                        AS leased_fanout_deliveries,
                    (SELECT COUNT(*)
                     FROM im_v2.fanout_deliveries, snapshot_now
                     WHERE (\(bind: includesAllDeliveryBuckets) OR target_shard_bucket = \(bind: scopedDeliveryBucket))
                       AND state = 'pending' AND next_attempt_at > snapshot_now.value
                       AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value))
                        AS scheduled_fanout_deliveries,
                    (SELECT COUNT(*)
                     FROM im_v2.fanout_deliveries
                     WHERE (\(bind: includesAllDeliveryBuckets) OR target_shard_bucket = \(bind: scopedDeliveryBucket)) AND state = 'paused')
                        AS paused_fanout_deliveries,
                    (SELECT COALESCE(SUM(GREATEST(sequence.next_sequence - 1 - cursor.acknowledged_sequence, 0)), 0)::BIGINT
                     FROM im_v2.device_sync_cursors AS cursor
                     JOIN im_v2.user_sync_sequences AS sequence ON sequence.user_id = cursor.user_id
                     WHERE cursor.state = 'ready')
                        AS pending_sync_records_across_devices,
                    (SELECT COUNT(*) FROM im_v2.device_sync_cursors WHERE state = 'reset_pending')
                        AS reset_pending_devices,
                    (SELECT COUNT(*)
                     FROM im_v2.push_wake_outbox, snapshot_now
                     WHERE state = 'pending'
                       AND (lease_expires_at IS NULL OR lease_expires_at <= snapshot_now.value))
                        AS ready_push_wakes,
                    (SELECT COUNT(*)
                     FROM im_v2.push_wake_outbox, snapshot_now
                     WHERE state = 'claimed' AND lease_expires_at > snapshot_now.value)
                        AS leased_push_wakes,
                    (SELECT COUNT(*) FROM im_v2.push_wake_outbox WHERE state = 'suppressed')
                        AS suppressed_push_wakes,
                    (SELECT CASE WHEN \(bind: includesGatewayRevocationMetrics) THEN COUNT(*) ELSE 0 END
                     FROM im_v2.device_revocation_events AS event
                     WHERE event.event_id > COALESCE((
                        SELECT cursor.last_event_id
                        FROM im_v2.gateway_worker_cursors AS cursor
                        WHERE cursor.worker_name = 'device-revocation-v1'
                          AND cursor.node_id = \(bind: scopedGatewayNodeID)
                     ), 0)) AS pending_device_revocation_events
            """).first(decoding: DurableWorkMetricsRow.self)
        else {
            throw V2DurableWorkMetricsError.emptyResult
        }
        return .init(
            isAvailable: true,
            readyRoomOutboxRows: v2MetricCount(row.readyRoomOutboxRows),
            leasedRoomOutboxRows: v2MetricCount(row.leasedRoomOutboxRows),
            scheduledRoomOutboxRows: v2MetricCount(row.scheduledRoomOutboxRows),
            pausedRoomOutboxRows: v2MetricCount(row.pausedRoomOutboxRows),
            readyDirectProfileUpdates: v2MetricCount(row.readyDirectProfileUpdates),
            leasedDirectProfileUpdates: v2MetricCount(row.leasedDirectProfileUpdates),
            openFanoutPlans: v2MetricCount(row.openFanoutPlans),
            readyFanoutDeliveries: v2MetricCount(row.readyFanoutDeliveries),
            leasedFanoutDeliveries: v2MetricCount(row.leasedFanoutDeliveries),
            scheduledFanoutDeliveries: v2MetricCount(row.scheduledFanoutDeliveries),
            pausedFanoutDeliveries: v2MetricCount(row.pausedFanoutDeliveries),
            pendingSyncRecordsAcrossDevices: v2MetricCount(row.pendingSyncRecordsAcrossDevices),
            resetPendingDevices: v2MetricCount(row.resetPendingDevices),
            readyPushWakes: v2MetricCount(row.readyPushWakes),
            leasedPushWakes: v2MetricCount(row.leasedPushWakes),
            suppressedPushWakes: v2MetricCount(row.suppressedPushWakes),
            pendingDeviceRevocationEvents: v2MetricCount(row.pendingDeviceRevocationEvents)
        )
    }

    public func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        do {
            return try await loadDurableWorkMetrics()
        } catch {
            // /metrics stays scrapeable when PostgreSQL is unavailable; the
            // availability gauge is the explicit alerting signal. Error text
            // must not escape as a metric label or response body.
            return .unavailable
        }
    }
}

public enum V2DurableWorkMetricsError: Error, Equatable, Sendable {
    case sqlUnavailable
    case emptyResult
}

public func v2RenderPrometheusDurableWorkMetrics(_ snapshot: V2DurableWorkMetricsSnapshot) -> String {
    [
        "# HELP im_v2_durable_work_metrics_available Whether the durable-work scrape completed against PostgreSQL.",
        "# TYPE im_v2_durable_work_metrics_available gauge",
        "im_v2_durable_work_metrics_available \(snapshot.isAvailable ? 1 : 0)",
        "# HELP im_v2_room_outbox_backlog Durable room outbox rows owned by this deployment.",
        "# TYPE im_v2_room_outbox_backlog gauge",
        "im_v2_room_outbox_backlog{state=\"ready\"} \(snapshot.readyRoomOutboxRows)",
        "im_v2_room_outbox_backlog{state=\"leased\"} \(snapshot.leasedRoomOutboxRows)",
        "im_v2_room_outbox_backlog{state=\"scheduled\"} \(snapshot.scheduledRoomOutboxRows)",
        "im_v2_room_outbox_backlog{state=\"paused\"} \(snapshot.pausedRoomOutboxRows)",
        "# HELP im_v2_direct_profile_update_backlog Durable direct-profile update sources awaiting or held by propagation.",
        "# TYPE im_v2_direct_profile_update_backlog gauge",
        "im_v2_direct_profile_update_backlog{state=\"ready\"} \(snapshot.readyDirectProfileUpdates)",
        "im_v2_direct_profile_update_backlog{state=\"leased\"} \(snapshot.leasedDirectProfileUpdates)",
        "# HELP im_v2_fanout_plans_open Durable fan-out plans not yet terminal.",
        "# TYPE im_v2_fanout_plans_open gauge",
        "im_v2_fanout_plans_open \(snapshot.openFanoutPlans)",
        "# HELP im_v2_fanout_delivery_backlog Durable delivery rows for this replica's configured logical bucket.",
        "# TYPE im_v2_fanout_delivery_backlog gauge",
        "im_v2_fanout_delivery_backlog{state=\"ready\"} \(snapshot.readyFanoutDeliveries)",
        "im_v2_fanout_delivery_backlog{state=\"leased\"} \(snapshot.leasedFanoutDeliveries)",
        "im_v2_fanout_delivery_backlog{state=\"scheduled\"} \(snapshot.scheduledFanoutDeliveries)",
        "im_v2_fanout_delivery_backlog{state=\"paused\"} \(snapshot.pausedFanoutDeliveries)",
        "# HELP im_v2_sync_pending_records_across_devices Aggregate unacknowledged sync records, counted once per ready device cursor.",
        "# TYPE im_v2_sync_pending_records_across_devices gauge",
        "im_v2_sync_pending_records_across_devices \(snapshot.pendingSyncRecordsAcrossDevices)",
        "# HELP im_v2_sync_reset_pending_devices Device cursors currently fenced behind a snapshot reset.",
        "# TYPE im_v2_sync_reset_pending_devices gauge",
        "im_v2_sync_reset_pending_devices \(snapshot.resetPendingDevices)",
        "# HELP im_v2_push_wake_backlog Aggregate generic Push wake work by durable state.",
        "# TYPE im_v2_push_wake_backlog gauge",
        "im_v2_push_wake_backlog{state=\"ready\"} \(snapshot.readyPushWakes)",
        "im_v2_push_wake_backlog{state=\"leased\"} \(snapshot.leasedPushWakes)",
        "im_v2_push_wake_backlog{state=\"suppressed\"} \(snapshot.suppressedPushWakes)",
        "# HELP im_v2_device_revocation_events_pending Durable device-revocation events not yet consumed by this gateway node.",
        "# TYPE im_v2_device_revocation_events_pending gauge",
        "im_v2_device_revocation_events_pending \(snapshot.pendingDeviceRevocationEvents)",
    ].joined(separator: "\n") + "\n"
}

private struct DurableWorkMetricsRow: Decodable {
    let readyRoomOutboxRows: Int64
    let leasedRoomOutboxRows: Int64
    let scheduledRoomOutboxRows: Int64
    let pausedRoomOutboxRows: Int64
    let readyDirectProfileUpdates: Int64
    let leasedDirectProfileUpdates: Int64
    let openFanoutPlans: Int64
    let readyFanoutDeliveries: Int64
    let leasedFanoutDeliveries: Int64
    let scheduledFanoutDeliveries: Int64
    let pausedFanoutDeliveries: Int64
    let pendingSyncRecordsAcrossDevices: Int64
    let resetPendingDevices: Int64
    let readyPushWakes: Int64
    let leasedPushWakes: Int64
    let suppressedPushWakes: Int64
    let pendingDeviceRevocationEvents: Int64

    enum CodingKeys: String, CodingKey {
        case readyRoomOutboxRows = "ready_room_outbox_rows"
        case leasedRoomOutboxRows = "leased_room_outbox_rows"
        case scheduledRoomOutboxRows = "scheduled_room_outbox_rows"
        case pausedRoomOutboxRows = "paused_room_outbox_rows"
        case readyDirectProfileUpdates = "ready_direct_profile_updates"
        case leasedDirectProfileUpdates = "leased_direct_profile_updates"
        case openFanoutPlans = "open_fanout_plans"
        case readyFanoutDeliveries = "ready_fanout_deliveries"
        case leasedFanoutDeliveries = "leased_fanout_deliveries"
        case scheduledFanoutDeliveries = "scheduled_fanout_deliveries"
        case pausedFanoutDeliveries = "paused_fanout_deliveries"
        case pendingSyncRecordsAcrossDevices = "pending_sync_records_across_devices"
        case resetPendingDevices = "reset_pending_devices"
        case readyPushWakes = "ready_push_wakes"
        case leasedPushWakes = "leased_push_wakes"
        case suppressedPushWakes = "suppressed_push_wakes"
        case pendingDeviceRevocationEvents = "pending_device_revocation_events"
    }
}

private func v2MetricCount(_ value: Int64) -> Int {
    guard value > 0 else { return 0 }
    return value > Int64(Int.max) ? Int.max : Int(value)
}
