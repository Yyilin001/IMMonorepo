import IMV2ServerApplication
import IMV2ServerContracts
import Vapor
import HTTPTypes

/// 注册唯一的 HTTP 指标出口。
///
/// 运行时配置会把承载它的 Vapor 应用绑定到回环地址，绝不监听公网端口。
public enum V2VaporMetricsRoutes {
    /// 在给定应用上注册 `/metrics` 路由。
    ///
    /// 响应固定为 Prometheus 文本格式并禁止缓存；遥测之外的各项指标只有在对应来源
    /// 被注入时才会追加，未注入的指标不会出现在输出中。
    ///
    /// - Parameters:
    ///   - app: 承载路由的 Vapor 应用。
    ///   - telemetry: 基础遥测渲染器。
    ///   - connectionMetrics: 连接指标来源，可选。
    ///   - transportMetrics: 网关传输指标来源，可选。
    ///   - durableWorkMetrics: 持久化工作指标来源，可选。
    ///   - runtimePressureMetrics: 运行时压力指标来源，可选。
    public static func register(
        on app: Application,
        telemetry: V2PrometheusTelemetrySink,
        connectionMetrics: (any V2ConnectionMetricsSource)? = nil,
        transportMetrics: (any V2GatewayTransportMetricsSource)? = nil,
        durableWorkMetrics: (any V2DurableWorkMetricsSource)? = nil,
        runtimePressureMetrics: (any V2RuntimePressureMetricsSource)? = nil,
        actorRealtimeMetrics: (any V2ActorRealtimeMetricsSource)? = nil,
        recoverySchedulingMetrics: (@Sendable () -> V2RecoverySchedulingSnapshot)? = nil,
        roomHeadDeliveryMetrics: (@Sendable () -> String)? = nil
    ) {
        // This diagnostic path avoids the full scrape's cross-actor waits.
        // Its source copies fixed-cardinality completed observations only.
        if let recoverySchedulingMetrics {
            app.get("metrics", "recovery-scheduling") { _ -> Response in
                var response = Response(status: .ok)
                response.headers[.contentType] = "text/plain; version=0.0.4; charset=utf-8"
                response.headers[.cacheControl] = "no-store, no-cache"
                response.body = .init(string: v2RenderPrometheusRecoverySchedulingMetrics(recoverySchedulingMetrics())
                    + (roomHeadDeliveryMetrics?() ?? ""))
                return response
            }
        }
        app.get("metrics") { _ async -> Response in
            var response = Response(status: .ok)
            response.headers[.contentType] = "text/plain; version=0.0.4; charset=utf-8"
            response.headers[.cacheControl] = "no-store, no-cache"
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
            if let actorRealtimeMetrics {
                document += v2RenderPrometheusActorRealtimeMetrics(await actorRealtimeMetrics.actorRealtimeMetricsSnapshot())
            }
            document += roomHeadDeliveryMetrics?() ?? ""
            response.body = .init(string: document)
            return response
        }
    }
}
