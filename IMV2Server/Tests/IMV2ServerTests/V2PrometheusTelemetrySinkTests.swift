import Foundation
@testable import IMV2Server
import Testing

@Suite("V2 Prometheus telemetry exporter")
struct V2PrometheusTelemetrySinkTests {
    @Test("exporter aggregates only closed labels and never renders trace IDs")
    func aggregatesPrivacySafeMetrics() async throws {
        let sink = V2PrometheusTelemetrySink()
        let trace = UUID(uuidString: "00000000-0000-0000-0000-000000000777")!
        await sink.record(.gatewayCommand(
            traceID: trace,
            command: .sendMessage,
            outcome: .rejected,
            rejection: .rateLimited,
            elapsedMilliseconds: 12
        ))
        await sink.record(.fanoutProgress(
            traceID: trace,
            claimedOutboxRows: 2,
            publishedOutboxRows: 1,
            releasedOutboxRows: -1,
            pausedOutboxRows: 2,
            claimedDeliveries: 4,
            committedDeliveries: 3,
            staleDeliveries: 1,
            staleRouteDeliveries: 1,
            releasedDeliveries: 2,
            pausedDeliveries: 3,
            elapsedMilliseconds: 8
        ))
        await sink.record(.fanoutFailure(traceID: trace, stage: .delivery, elapsedMilliseconds: 1))

        let metrics = await sink.renderPrometheus()

        #expect(metrics.contains("im_v2_gateway_commands_total{command=\"send_message\",outcome=\"rejected\",rejection=\"RATE_LIMITED\"} 1"))
        #expect(metrics.contains("im_v2_gateway_command_duration_milliseconds_sum{command=\"send_message\",outcome=\"rejected\",rejection=\"RATE_LIMITED\"} 12"))
        #expect(metrics.contains("im_v2_fanout_outbox_rows_total{state=\"claimed\"} 2"))
        #expect(metrics.contains("im_v2_fanout_outbox_rows_total{state=\"released\"} 0"))
        #expect(metrics.contains("im_v2_fanout_outbox_rows_total{state=\"paused\"} 2"))
        #expect(metrics.contains("im_v2_fanout_deliveries_total{state=\"stale_route\"} 1"))
        #expect(metrics.contains("im_v2_fanout_deliveries_total{state=\"paused\"} 3"))
        #expect(metrics.contains("im_v2_fanout_failures_total{stage=\"delivery\"} 1"))
        #expect(!metrics.contains(trace.uuidString))
        #expect(!metrics.contains("room_id"))
        #expect(!metrics.contains("user_id"))
    }

    @Test("transport metrics retain only aggregate queue pressure and closed closure reasons")
    func rendersTransportMetrics() async {
        let metrics = V2GatewayTransportMetrics()
        metrics.connectionOpened()
        metrics.connectionOpened()
        metrics.observeQueuedInboundBytes(1_024)
        metrics.observeQueuedInboundBytes(-1)
        metrics.connectionClosed(reason: .idleTimeout)

        let snapshot = metrics.gatewayTransportMetricsSnapshot()
        #expect(snapshot.activeConnections == 1)
        #expect(snapshot.peakQueuedInboundBytes == 1_024)
        #expect(snapshot.closureCount(for: .idleTimeout) == 1)
        #expect(snapshot.closureCount(for: .frameLimitViolation) == 0)
        #expect(snapshot.closureCount(for: .requestFailure) == 0)

        let rendered = v2RenderPrometheusGatewayTransportMetrics(snapshot)
        #expect(rendered.contains("im_v2_gateway_transport_active_connections 1"))
        #expect(rendered.contains("im_v2_gateway_inbound_queue_peak_bytes 1024"))
        #expect(rendered.contains("im_v2_gateway_connection_closures_total{reason=\"idle_timeout\"} 1"))
        #expect(!rendered.contains("user_id"))
        #expect(!rendered.contains("device_id"))
    }

    @Test("durable-work metrics use fixed aggregate labels and advertise a failed scrape")
    func rendersDurableWorkMetrics() {
        let snapshot = V2DurableWorkMetricsSnapshot(
            isAvailable: false,
            readyRoomOutboxRows: -1,
            leasedRoomOutboxRows: 2,
            scheduledRoomOutboxRows: 3,
            pausedRoomOutboxRows: 4,
            openFanoutPlans: 5,
            readyFanoutDeliveries: 6,
            leasedFanoutDeliveries: 7,
            scheduledFanoutDeliveries: 8,
            pausedFanoutDeliveries: 9,
            pendingSyncRecordsAcrossDevices: 10,
            resetPendingDevices: 11,
            readyPushWakes: 12,
            leasedPushWakes: 13,
            suppressedPushWakes: 14
        )

        let rendered = v2RenderPrometheusDurableWorkMetrics(snapshot)

        #expect(rendered.contains("im_v2_durable_work_metrics_available 0"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"ready\"} 0"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"leased\"} 2"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"scheduled\"} 3"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"paused\"} 4"))
        #expect(rendered.contains("im_v2_fanout_plans_open 5"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"ready\"} 6"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"leased\"} 7"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"scheduled\"} 8"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"paused\"} 9"))
        #expect(rendered.contains("im_v2_sync_pending_records_across_devices 10"))
        #expect(rendered.contains("im_v2_sync_reset_pending_devices 11"))
        #expect(rendered.contains("im_v2_push_wake_backlog{state=\"ready\"} 12"))
        #expect(rendered.contains("im_v2_push_wake_backlog{state=\"leased\"} 13"))
        #expect(rendered.contains("im_v2_push_wake_backlog{state=\"suppressed\"} 14"))
        #expect(!rendered.contains("room_id"))
        #expect(!rendered.contains("user_id"))
        #expect(!rendered.contains("bucket="))
    }
}
