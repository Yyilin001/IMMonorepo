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
            openFanoutPlans: 3,
            readyFanoutDeliveries: 4,
            leasedFanoutDeliveries: 5,
            scheduledFanoutDeliveries: 8,
            pausedFanoutDeliveries: 9,
            pendingSyncRecordsAcrossDevices: 10,
            resetPendingDevices: 11,
            readyPushWakes: 12,
            leasedPushWakes: 13,
            suppressedPushWakes: 14
        ))
        V2VaporMetricsRoutes.register(on: app, telemetry: telemetry, durableWorkMetrics: durableWorkMetrics)

        try await app.testing().test(.GET, "metrics") { response async throws in
            let body = response.body.string
            #expect(body.contains("im_v2_durable_work_metrics_available 1"))
            #expect(body.contains("im_v2_room_outbox_backlog{state=\"ready\"} 2"))
            #expect(body.contains("im_v2_room_outbox_backlog{state=\"scheduled\"} 6"))
            #expect(body.contains("im_v2_room_outbox_backlog{state=\"paused\"} 7"))
            #expect(body.contains("im_v2_fanout_delivery_backlog{state=\"leased\"} 5"))
            #expect(body.contains("im_v2_fanout_delivery_backlog{state=\"scheduled\"} 8"))
            #expect(body.contains("im_v2_fanout_delivery_backlog{state=\"paused\"} 9"))
            #expect(body.contains("im_v2_sync_pending_records_across_devices 10"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"ready\"} 12"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"leased\"} 13"))
            #expect(body.contains("im_v2_push_wake_backlog{state=\"suppressed\"} 14"))
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
