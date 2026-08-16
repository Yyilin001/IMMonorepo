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
            relayElapsedMilliseconds: 3,
            deliveryElapsedMilliseconds: 5,
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
        #expect(metrics.contains("im_v2_fanout_relay_duration_milliseconds_sum 3"))
        #expect(metrics.contains("im_v2_fanout_delivery_duration_milliseconds_sum 5"))
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
        metrics.connectionRejected(reason: .connectionLimit)

        let snapshot = metrics.gatewayTransportMetricsSnapshot()
        #expect(snapshot.activeConnections == 1)
        #expect(snapshot.peakQueuedInboundBytes == 1_024)
        #expect(snapshot.closureCount(for: .idleTimeout) == 1)
        #expect(snapshot.closureCount(for: .connectionLimit) == 1)
        #expect(snapshot.closureCount(for: .frameLimitViolation) == 0)
        #expect(snapshot.closureCount(for: .requestFailure) == 0)

        let rendered = v2RenderPrometheusGatewayTransportMetrics(snapshot)
        #expect(rendered.contains("im_v2_gateway_transport_active_connections 1"))
        #expect(rendered.contains("im_v2_gateway_inbound_queue_peak_bytes 1024"))
        #expect(rendered.contains("im_v2_gateway_connection_closures_total{reason=\"idle_timeout\"} 1"))
        #expect(!rendered.contains("user_id"))
        #expect(!rendered.contains("device_id"))
    }

    @Test("transport metrics remain exact under concurrent gateway callbacks")
    func serializesConcurrentTransportMetricUpdates() async {
        let metrics = V2GatewayTransportMetrics()
        let workers = 12
        let iterations = 400

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    for value in 0..<iterations {
                        metrics.connectionOpened()
                        metrics.observeQueuedInboundBytes(value)
                        metrics.connectionClosed(reason: .requestFailure)
                    }
                }
            }
        }

        let snapshot = metrics.gatewayTransportMetricsSnapshot()
        #expect(snapshot.activeConnections == 0)
        #expect(snapshot.peakQueuedInboundBytes == iterations - 1)
        #expect(snapshot.closureCount(for: .requestFailure) == UInt64(workers * iterations))
    }

    @Test("durable-work metrics use fixed aggregate labels and advertise a failed scrape")
    func rendersDurableWorkMetrics() {
        let snapshot = V2DurableWorkMetricsSnapshot(
            isAvailable: false,
            servedFromLastKnownGood: true,
            lastSuccessfulRefreshAgeSeconds: 77,
            readyRoomOutboxRows: -1,
            leasedRoomOutboxRows: 2,
            scheduledRoomOutboxRows: 3,
            pausedRoomOutboxRows: 4,
            readyDirectProfileUpdates: 15,
            leasedDirectProfileUpdates: 16,
            readyReadReceiptPreferencePropagations: 29,
            leasedReadReceiptPreferencePropagations: 30,
            scheduledReadReceiptPreferencePropagations: 31,
            pausedReadReceiptPreferencePropagations: 32,
            openFanoutPlans: 5,
            readyFanoutDeliveries: 6,
            leasedFanoutDeliveries: 7,
            scheduledFanoutDeliveries: 8,
            pausedFanoutDeliveries: 9,
            terminalFanoutCompletionUnits: 10,
            oldestTerminalFanoutCompletionAgeSeconds: 11,
            readyContentReviews: 17,
            leasedContentReviews: 18,
            scheduledContentReviews: 19,
            pausedContentReviews: 20,
            readyMediaScans: 21,
            leasedMediaScans: 22,
            scheduledMediaScans: 23,
            pausedMediaScans: 24,
            readyMediaPurges: 25,
            leasedMediaPurges: 26,
            scheduledMediaPurges: 27,
            pausedMediaPurges: 28,
            userSyncLogEstimatedRows: 34,
            userSyncLogRelationBytes: 35,
            readyUserProjections: 36,
            scheduledUserProjections: 37,
            pausedUserProjections: 38,
            maximumUserProjectionLag: 39,
            buildingSnapshotArtifacts: 40,
            failedSnapshotArtifacts: 41,
            oldestBuildingSnapshotAgeSeconds: 42,
            projectionVersionGCBacklogEstimatedRows: 43,
            uncompactedProjectedRecords: 44,
            pendingSyncRecordsAcrossDevices: 10,
            resetPendingDevices: 11,
            readyPushWakes: 12,
            leasedPushWakes: 13,
            suppressedPushWakes: 14
        )

        let rendered = v2RenderPrometheusDurableWorkMetrics(snapshot)

        #expect(rendered.contains("im_v2_durable_work_metrics_available 0"))
        #expect(rendered.contains("im_v2_durable_work_metrics_last_known_good 1"))
        #expect(rendered.contains("im_v2_durable_work_metrics_last_success_age_seconds 77"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"ready\"} 0"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"leased\"} 2"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"scheduled\"} 3"))
        #expect(rendered.contains("im_v2_room_outbox_backlog{state=\"paused\"} 4"))
        #expect(rendered.contains("im_v2_direct_profile_update_backlog{state=\"ready\"} 15"))
        #expect(rendered.contains("im_v2_direct_profile_update_backlog{state=\"leased\"} 16"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"ready\"} 29"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"leased\"} 30"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"scheduled\"} 31"))
        #expect(rendered.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"paused\"} 32"))
        #expect(rendered.contains("im_v2_fanout_plans_open 5"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"ready\"} 6"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"leased\"} 7"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"scheduled\"} 8"))
        #expect(rendered.contains("im_v2_fanout_delivery_backlog{state=\"paused\"} 9"))
        #expect(rendered.contains("im_v2_fanout_completion_release_backlog 10"))
        #expect(rendered.contains("im_v2_fanout_completion_release_oldest_age_seconds 11"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"ready\"} 17"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"leased\"} 18"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"scheduled\"} 19"))
        #expect(rendered.contains("im_v2_content_review_backlog{state=\"paused\"} 20"))
        #expect(rendered.contains("im_v2_media_scan_backlog{state=\"ready\"} 21"))
        #expect(rendered.contains("im_v2_media_scan_backlog{state=\"paused\"} 24"))
        #expect(rendered.contains("im_v2_media_purge_backlog{state=\"ready\"} 25"))
        #expect(rendered.contains("im_v2_media_purge_backlog{state=\"paused\"} 28"))
        #expect(rendered.contains("im_v2_user_sync_log_estimated_rows 34"))
        #expect(rendered.contains("im_v2_user_sync_log_relation_bytes 35"))
        #expect(rendered.contains("im_v2_user_projection_effects_estimated_rows 0"))
        #expect(rendered.contains("im_v2_user_projection_effects_relation_bytes 0"))
        #expect(rendered.contains("im_v2_user_projection_backlog{state=\"paused\"} 38"))
        #expect(rendered.contains("im_v2_user_projection_maximum_lag_records 39"))
        #expect(rendered.contains("im_v2_snapshot_artifacts{state=\"building\"} 40"))
        #expect(rendered.contains("im_v2_snapshot_oldest_building_age_seconds 42"))
        #expect(rendered.contains("im_v2_projection_version_gc_backlog_estimated_rows 43"))
        #expect(rendered.contains("im_v2_sync_uncompacted_projected_records 44"))
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
