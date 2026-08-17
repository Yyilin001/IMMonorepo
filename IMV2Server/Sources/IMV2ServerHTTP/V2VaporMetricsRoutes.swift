import IMV2Server
import Vapor

/// Registers the only HTTP metrics surface. Runtime configuration binds the
/// containing Vapor application to loopback, never to a public listener.
public enum V2VaporMetricsRoutes {
    public static func register(
        on app: Application,
        telemetry: V2PrometheusTelemetrySink,
        connectionMetrics: (any V2ConnectionMetricsSource)? = nil,
        transportMetrics: (any V2GatewayTransportMetricsSource)? = nil,
        durableWorkMetrics: (any V2DurableWorkMetricsSource)? = nil,
        runtimePressureMetrics: (any V2RuntimePressureMetricsSource)? = nil
    ) {
        app.get("metrics") { _ async -> Response in
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(
                name: .contentType,
                value: "text/plain; version=0.0.4; charset=utf-8"
            )
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store, no-cache")
            var document = await telemetry.renderPrometheus()
            if let connectionMetrics {
                document += v2RenderPrometheusConnectionMetrics(await connectionMetrics.connectionMetricsSnapshot())
            }
            if let transportMetrics {
                document += v2RenderPrometheusGatewayTransportMetrics(await transportMetrics.gatewayTransportMetricsSnapshot())
            }
            if let durableWorkMetrics {
                document += v2RenderPrometheusDurableWorkMetrics(await durableWorkMetrics.durableWorkMetricsSnapshot())
            }
            if let runtimePressureMetrics {
                document += v2RenderPrometheusRuntimePressureMetrics(
                    await runtimePressureMetrics.runtimePressureMetricsSnapshot()
                )
            }
            response.body = .init(string: document)
            return response
        }
    }
}
