import Foundation
@testable import IMV2Server
@testable import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 Vapor metrics routes")
struct V2VaporMetricsRoutesTests {
    @Test("metrics route exposes only aggregate Prometheus text with no-store semantics")
    func rendersAggregateMetrics() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        await telemetry.record(.gatewayCommand(
            traceID: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            command: .sendMessage,
            outcome: .accepted,
            rejection: nil,
            elapsedMilliseconds: 12
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry)

        try await app.testing().test(.GET, "metrics") { response async throws in
            #expect(response.status == .ok)
            let contentType = try #require(response.headers.first(name: .contentType))
            #expect(contentType.contains("text/plain"))
            #expect(contentType.contains("version=0.0.4"))
            #expect(contentType.contains("charset=utf-8"))
            #expect(response.headers.first(name: .cacheControl) == "no-store, no-cache")
            let body = response.body.string
            #expect(body.contains("im_v2_gateway_commands_total{command=\"send_message\",outcome=\"accepted\",rejection=\"none\"} 1"))
            #expect(!body.contains("00000000-0000-0000-0000-000000000901"))
        }
    }

    @Test("metrics route includes only aggregate live connection gauges when configured")
    func rendersConnectionGauges() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let connectionMetrics = ConnectionMetricsProbe(snapshot: .init(activeDevices: 2, activeConnections: 3))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, connectionMetrics: connectionMetrics)

        try await app.testing().test(.GET, "metrics") { response async throws in
            #expect(response.status == .ok)
            let body = response.body.string
            #expect(body.contains("im_v2_gateway_active_devices 2"))
            #expect(body.contains("im_v2_gateway_active_connections 3"))
            #expect(!body.contains("user_id"))
            #expect(!body.contains("device_id"))
        }
    }

    @Test("metrics route includes aggregate transport gauges when configured")
    func rendersTransportGauges() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let transportMetrics = TransportMetricsProbe(snapshot: .init(
            activeConnections: 4,
            peakQueuedInboundBytes: 512,
            closures: [.idleTimeout: 2]
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, transportMetrics: transportMetrics)

        try await app.testing().test(.GET, "metrics") { response async throws in
            let body = response.body.string
            #expect(body.contains("im_v2_gateway_transport_active_connections 4"))
            #expect(body.contains("im_v2_gateway_inbound_queue_peak_bytes 512"))
            #expect(body.contains("im_v2_gateway_connection_closures_total{reason=\"idle_timeout\"} 2"))
        }
    }

    @Test("metrics route includes durable-work aggregates without accepting a shard label")
    func rendersDurableWorkGauges() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let telemetry = V2PrometheusTelemetrySink()
        let durableWorkMetrics = DurableWorkMetricsProbe(snapshot: .init(
            isAvailable: true,
            readyRoomOutboxRows: 2,
            leasedRoomOutboxRows: 1,
            scheduledRoomOutboxRows: 6,
            pausedRoomOutboxRows: 7,
            readyDirectProfileUpdates: 15,
            leasedDirectProfileUpdates: 16,
            readyReadReceiptPreferencePropagations: 30,
            leasedReadReceiptPreferencePropagations: 31,
            scheduledReadReceiptPreferencePropagations: 32,
            pausedReadReceiptPreferencePropagations: 33,
            openFanoutPlans: 3,
            readyFanoutDeliveries: 4,
            leasedFanoutDeliveries: 5,
            scheduledFanoutDeliveries: 8,
            pausedFanoutDeliveries: 9,
            readyContentReviews: 18,
            leasedContentReviews: 19,
            scheduledContentReviews: 20,
            pausedContentReviews: 21,
            readyMediaScans: 22,
            leasedMediaScans: 23,
            scheduledMediaScans: 24,
            pausedMediaScans: 25,
            readyMediaPurges: 26,
            leasedMediaPurges: 27,
            scheduledMediaPurges: 28,
            pausedMediaPurges: 29,
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
            suppressedPushWakes: 14,
            pendingDeviceRevocationEvents: 17,
            pendingRevokedDeviceProjectionCleanupEvents: 18
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, durableWorkMetrics: durableWorkMetrics)

        try await app.testing().test(.GET, "metrics") { response async throws in
            let body = response.body.string
            #expect(body.contains("im_v2_durable_work_metrics_available 1"))
            #expect(body.contains("im_v2_room_outbox_backlog{state=\"ready\"} 2"))
            #expect(body.contains("im_v2_room_outbox_backlog{state=\"scheduled\"} 6"))
            #expect(body.contains("im_v2_room_outbox_backlog{state=\"paused\"} 7"))
            #expect(body.contains("im_v2_direct_profile_update_backlog{state=\"ready\"} 15"))
            #expect(body.contains("im_v2_direct_profile_update_backlog{state=\"leased\"} 16"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"ready\"} 30"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"leased\"} 31"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"scheduled\"} 32"))
            #expect(body.contains("im_v2_read_receipt_preference_propagation_backlog{state=\"paused\"} 33"))
            #expect(body.contains("im_v2_user_sync_log_estimated_rows 34"))
            #expect(body.contains("im_v2_user_sync_log_relation_bytes 35"))
            #expect(body.contains("im_v2_user_projection_backlog{state=\"paused\"} 38"))
            #expect(body.contains("im_v2_user_projection_maximum_lag_records 39"))
            #expect(body.contains("im_v2_snapshot_artifacts{state=\"failed\"} 41"))
            #expect(body.contains("im_v2_projection_version_gc_backlog_estimated_rows 43"))
            #expect(body.contains("im_v2_sync_uncompacted_projected_records 44"))
            #expect(body.contains("im_v2_fanout_delivery_backlog{state=\"leased\"} 5"))
            #expect(body.contains("im_v2_fanout_delivery_backlog{state=\"scheduled\"} 8"))
            #expect(body.contains("im_v2_fanout_delivery_backlog{state=\"paused\"} 9"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"ready\"} 18"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"leased\"} 19"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"scheduled\"} 20"))
            #expect(body.contains("im_v2_content_review_backlog{state=\"paused\"} 21"))
            #expect(body.contains("im_v2_media_scan_backlog{state=\"scheduled\"} 24"))
            #expect(body.contains("im_v2_media_scan_backlog{state=\"paused\"} 25"))
            #expect(body.contains("im_v2_media_purge_backlog{state=\"scheduled\"} 28"))
            #expect(body.contains("im_v2_media_purge_backlog{state=\"paused\"} 29"))
            #expect(body.contains("im_v2_sync_pending_records_across_devices 10"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"ready\"} 12"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"leased\"} 13"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"suppressed\"} 14"))
            #expect(body.contains("im_v2_device_revocation_events_pending 17"))
            #expect(body.contains("im_v2_revoked_device_projection_cleanup_events_pending 18"))
            #expect(!body.contains("im_v2_device_revocation_events_pending{"))
            #expect(!body.contains("target_shard_bucket"))
        }
    }
}

private struct ConnectionMetricsProbe: V2ConnectionMetricsSource {
    let snapshot: V2ConnectionMetricsSnapshot

    func connectionMetricsSnapshot() async -> V2ConnectionMetricsSnapshot { snapshot }
}

private struct TransportMetricsProbe: V2GatewayTransportMetricsSource {
    let snapshot: V2GatewayTransportMetricsSnapshot

    func gatewayTransportMetricsSnapshot() async -> V2GatewayTransportMetricsSnapshot { snapshot }
}

private struct DurableWorkMetricsProbe: V2DurableWorkMetricsSource {
    let snapshot: V2DurableWorkMetricsSnapshot

    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot { snapshot }
}
