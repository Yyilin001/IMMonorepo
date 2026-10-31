import IMV2ServerApplication
import IMV2ServerContracts
import Vapor
import HTTPTypes

/// 注册内部 HTTP 指标出口。
///
/// 运行时配置会把承载它的 Vapor 应用绑定到回环地址，绝不监听公网端口。
public enum V2VaporMetricsRoutes {
    /// Optional-author pressure is separate from the full cross-actor scrape.
    /// Only fixed metric names and aggregate counts leave the runtime.
    public static func registerAuthorPresentations(on app: Application, runtime: V2AuthorPresentationRuntime,
        roomReads: @escaping @Sendable () -> V2ProfilePresentationReadDiagnostics.Snapshot = { .init() }) {
        app.get("metrics", "authors") { _ async -> Response in
            let dispatcher = await runtime.dispatcher.statistics()
            let ingress = runtime.ingress.statistics()
            let gauges: [(String, Int)] = [
                ("connections", dispatcher.connections), ("visible_interests", dispatcher.visibleInterests),
                ("pending_keys", dispatcher.pendingKeys), ("pending_bytes", dispatcher.pendingBytes),
                ("reading_batches", dispatcher.reading), ("writing_frames", dispatcher.writing),
                ("output_bytes", dispatcher.outputBytes), ("hint_bytes", dispatcher.hintBytes),
                ("ingress_pending", ingress.pendingOffers), ("ingress_keys", ingress.retainedKeys)]
            let counters: [(String, Int)] = [
                ("rejected_offers", dispatcher.rejectedOffers), ("expired_jobs", dispatcher.expiredJobs),
                ("suppressed_reads", dispatcher.suppressedReads), ("delivered_frames", dispatcher.deliveredFrames),
                ("ingress_rejected", ingress.rejected), ("ingress_expired", ingress.expired),
                ("change_read_failures", await runtime.profileChangeFailures())]
            var document = ""
            for (name, count) in gauges {
                document += "# TYPE im_v2_author_\(name) gauge\nim_v2_author_\(name) \(count)\n"
            }
            for (name, count) in counters {
                document += "# TYPE im_v2_author_\(name)_total counter\nim_v2_author_\(name)_total \(count)\n"
            }
            let reads = runtime.readDiagnostics().merging(roomReads())
            for stage in V2ProfilePresentationReadDiagnostics.Stage.allCases {
                let value = reads.stages[stage]
                let prefix = "im_v2_author_read_\(stage.rawValue)"
                for (suffix, number) in [("calls", value?.calls ?? 0), ("failures", value?.failures ?? 0)] {
                    document += "# TYPE \(prefix)_\(suffix)_total counter\n\(prefix)_\(suffix)_total \(number)\n"
                }
                document += "# TYPE \(prefix)_milliseconds_total counter\n\(prefix)_milliseconds_total \(value?.totalMilliseconds ?? 0)\n"
                document += "# TYPE \(prefix)_milliseconds_max_lifetime gauge\n\(prefix)_milliseconds_max_lifetime \(value?.maximumMilliseconds ?? 0)\n"
            }
            for outcome in V2ProfilePresentationReadDiagnostics.Outcome.allCases {
                let name = "im_v2_author_read_\(outcome.rawValue)_total"
                document += "# TYPE \(name) counter\n\(name) \(reads.outcomes[outcome, default: 0])\n"
            }
            var response = Response(status: .ok)
            response.headers[.contentType] = "text/plain; version=0.0.4; charset=utf-8"
            response.headers[.cacheControl] = "no-store, no-cache"
            response.body = .init(string: document)
            return response
        }
    }

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
