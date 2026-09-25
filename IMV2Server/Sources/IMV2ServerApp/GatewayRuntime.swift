import Foundation
import IMV2Server
import IMV2ServerHTTP
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 编排网关进程从配置解析到停机清理的完整生命周期。
///
/// 依次创建数据库与 HTTP 基础设施、组装 TLS 网关和后台服务，
/// 收到终止信号后先排空工作，再释放依赖它们的连接池与事件循环。
enum GatewayRuntime {
    /// 启动并运行网关，直到收到终止信号或发生启动、运行、停机错误。
    ///
    /// 错误会附带故障阶段交给进程入口记录；若工作排空超时，
    /// 则直接以失败状态退出，避免释放仍被使用的底层资源。
    ///
    /// - Parameter logger: 网关生命周期及其子组件共用的日志记录器。
    /// - Throws: 带故障阶段的 `V2StagedOperationalError`。
    static func run(logger: Logger) async throws {
        V2ProcessTerminationSignal.install()
        let configuration: V2GatewayRuntimeConfiguration
        let localMediaConfiguration: V2LocalFilesystemMediaRuntimeConfiguration?
        do {
            configuration = try V2GatewayRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
            localMediaConfiguration = try V2LocalFilesystemMediaRuntimeConfiguration(environment: ProcessRuntimeEnvironment())
        } catch {
            throw V2StagedOperationalError(stage: "gateway_configuration", error: error)
        }
        // 基础设施先于网关组装创建；组装失败时仍需由此处负责释放。
        let infrastructure: GatewayInfrastructure
        do {
            infrastructure = try await GatewayInfrastructure.start(
                configuration: configuration, logger: logger
            )
        } catch {
            throw V2StagedOperationalError(stage: "gateway_infrastructure_start", error: error)
        }
        let app = infrastructure.application
        // 只登记已完整组装的组件，供外层失败路径清理。
        var startedComposition: GatewayComposition?
        // 记录当前阶段，供失败日志和向进程入口抛出的错误定位。
        var stage = "gateway_composition"
        do {
            let composition = try await GatewayComposition.build(
                configuration: configuration,
                localMediaConfiguration: localMediaConfiguration,
                resources: infrastructure.databases,
                app: app,
                logger: logger
            )
            startedComposition = composition
            let server = composition.server
            let actors = composition.actors
            let actorConfiguration = composition.actorConfiguration
            let connectionRegistry = composition.connectionRegistry
            let foregroundGroupEventHints = composition.foregroundGroupEventHints
            let directRoomLogEventCache = composition.directRoomLogEventCache
            // 内层失败路径可能已经关闭 TLS 服务；避免再次关闭。
            var serverIsShutdown = false
            do {
                stage = "gateway_tls_bind"
                try await server.bind()
                logger.notice("IM V2 TLS gateway bound", metadata: ["host": "\(configuration.tls.host)", "port": "\(configuration.tls.port)"])
                stage = "gateway_http_runtime"
                // 指标 HTTP 服务运行期间启动后台任务，并等待进程终止信号。
                try await V2HTTPService.withRunning(app, logger: logger,
                    gracefulShutdownDuration: .milliseconds(configuration.shutdownGraceMilliseconds),
                    waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
                    logger.notice("IM V2 metrics listener bound", metadata: ["host": "\(configuration.metrics.host)", "port": "\(configuration.metrics.port)"])
                    let workers = try composition.backgroundWorkers.start()
                    await shutdown.wait()
                    logger.notice("IM V2 shutdown signal received")
                    // 取消后台工作前，先停止接纳新连接。
                    // 现有通道在有界协作式排空期间保持存活，
                    // 随后由下方的完整服务器停机流程关闭。
                    var listenerShutdownError: (any Error)?
                    do { try await server.stopAccepting() }
                    catch { listenerShutdownError = error }
                    logger.notice("IM V2 public listener closed")
                    workers.cancelAll()
                    foregroundGroupEventHints.finish()
                    await directRoomLogEventCache?.finish()
                    let drained = await workers.drain(
                        timeout: .milliseconds(configuration.shutdownGraceMilliseconds)
                    )
                    guard drained else {
                        // 活动 worker 可能仍持有事务；即使超过期限，
                        // 也不能从它下方释放连接池或 EventLoop。
                        logger.critical("IM V2 service-task drain exceeded its shutdown deadline",
                            metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_worker_shutdown"))
                        exit(EXIT_FAILURE)
                    }
                    logger.notice("IM V2 service-task drain finished", metadata: ["drained": "\(drained)"])
                    // 工作排空后，再断开在线状态和辅助服务，最后关闭 TLS 与房间 Actor。
                    await connectionRegistry.finishLivePresenceRenewals()
                    await connectionRegistry.detachForegroundGroupInterestManager()
                    await connectionRegistry.detachLiveActivityBroker()
                    await composition.shutdownAuxiliaryServices()
                    logger.notice("IM V2 broker and presence shutdown finished")
                    try await server.shutdown()
                    serverIsShutdown = true
                    guard try await actors.stop(deadline: .now + actorConfiguration.runtime.drainTimeout.duration) else {
                        logger.critical("IM V2 room actors still own work after shutdown deadline",
                            metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_actor_shutdown"))
                        exit(EXIT_FAILURE)
                    }
                    logger.notice("IM V2 TLS event loops and room actors shut down")
                    if let listenerShutdownError {
                        throw V2StagedOperationalError(
                            stage: "gateway_listener_shutdown", error: listenerShutdownError
                        )
                    }
                }
            } catch {
                if !serverIsShutdown { try? await server.shutdown() }
                throw error
            }
            // 所有上层服务退出后，才能释放 HTTP 应用、数据库和事件循环。
            stage = "gateway_infrastructure_shutdown"
            try await infrastructure.shutdown(logger: logger)
        } catch {
            // 失败时仍按上层组件到基础设施的顺序尽力清理，再保留阶段信息上抛。
            logger.error("IM V2 gateway lifecycle failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(error, stage: stage))
            if let startedComposition { await startedComposition.shutdownAfterFailure(logger: logger) }
            await infrastructure.shutdownAfterFailure()
            throw V2StagedOperationalError(stage: stage, error: error)
        }
    }
}

/// 将当前进程的环境变量提供给各项网关配置解析器。
struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}
