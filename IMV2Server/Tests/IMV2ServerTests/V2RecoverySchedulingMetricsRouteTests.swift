import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerHTTP
import HTTPTypes
import Testing
import Vapor
import VaporTesting

struct V2RecoverySchedulingMetricsRouteTests {
    @Test("recovery scheduling scrape avoids unrelated actor snapshots")
    func independentSchedulingScrape() async throws {
        let app = try await Application(.testing)
        defer { Task { try? await app.shutdown() } }
        let connections = SchedulingConnectionMetricsProbe()
        var value = V2RecoverySchedulingSnapshot()
        value.scans[.desired] = 128
        value.readyRejections[.permissionExpired] = 3
        let snapshot = value
        V2VaporMetricsRoutes.register(on: app, telemetry: V2PrometheusTelemetrySink(),
            connectionMetrics: connections, recoverySchedulingMetrics: { snapshot })
        try await app.testing { client in
            let response = try await client.send(.get, to: "metrics/recovery-scheduling")
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-store, no-cache")
            #expect(response.headers[.contentType]?.contains("text/plain") == true)
            let body = try await response.body.string() ?? ""
            #expect(body.contains("im_v2_gateway_recovery_scheduling_scan_entries_total{source=\"desired\"} 128\n"))
            #expect(body.contains("im_v2_gateway_recovery_ready_rejections_total{reason=\"permission_expired\"} 3\n"))
            #expect(body.contains("im_v2_gateway_recovery_ready_rejections_total{reason=\"generation_invalid\"} 0\n"))
            #expect(body.split(separator: "\n").filter { $0.hasPrefix("im_v2_gateway_recovery_ready_rejections_total{") }.count == V2RecoveryReadyRejectionReason.allCases.count)
            #expect(!body.contains("im_v2_gateway_active_connections"))
            #expect(await connections.calls == 0)
        }
    }
}

private actor SchedulingConnectionMetricsProbe: V2ConnectionMetricsSource {
    private(set) var calls = 0
    func connectionMetricsSnapshot() -> V2ConnectionMetricsSnapshot {
        calls += 1
        return .init(activeDevices: 0, activeConnections: 0)
    }
}
