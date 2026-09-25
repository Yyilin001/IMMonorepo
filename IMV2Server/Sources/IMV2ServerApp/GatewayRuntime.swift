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
        let (configuration, localMediaConfiguration) = try loadConfigurations()
        let infrastructure = try await startInfrastructure(configuration: configuration, logger: logger)
        // 只登记已完整组装的组件，供外层失败路径清理。
        var startedComposition: GatewayComposition?
        // 记录当前阶段，供失败日志和向进程入口抛出的错误定位。
        var stage = "gateway_composition"
        do {
            let composition = try await GatewayComposition.build(
                configuration: configuration,
                localMediaConfiguration: localMediaConfiguration,
                resources: infrastructure.databases,
                app: infrastructure.application,
                logger: logger
            )
            startedComposition = composition
            stage = "gateway_http_runtime"
            try await runServices(
                configuration: configuration,
                infrastructure: infrastructure,
                composition: composition,
                logger: logger
            )
            // 所有上层服务退出后，才能释放 HTTP 应用、数据库和事件循环。
            stage = "gateway_infrastructure_shutdown"
            try await infrastructure.shutdown(logger: logger)
        } catch {
            // 失败时仍按上层组件到基础设施的顺序尽力清理，再保留阶段信息上抛。
            let stagedError = V2StagedOperationalError(stage: stage, error: error)
            logger.error("IM V2 gateway lifecycle failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(stagedError, stage: stage))
            if let startedComposition { await startedComposition.shutdownAfterFailure(logger: logger) }
            await infrastructure.shutdownAfterFailure()
            throw stagedError
        }
    }

    private static func loadConfigurations() throws -> (
        V2GatewayRuntimeConfiguration, V2LocalFilesystemMediaRuntimeConfiguration?
    ) {
        let environment = ProcessRuntimeEnvironment()
        do {
            return (
                try V2GatewayRuntimeConfiguration(environment: environment),
                try V2LocalFilesystemMediaRuntimeConfiguration(environment: environment)
            )
        } catch {
            throw V2StagedOperationalError(stage: "gateway_configuration", error: error)
        }
    }

    private static func startInfrastructure(
        configuration: V2GatewayRuntimeConfiguration, logger: Logger
    ) async throws -> GatewayInfrastructure {
        do {
            return try await GatewayInfrastructure.start(configuration: configuration, logger: logger)
        } catch {
            throw V2StagedOperationalError(stage: "gateway_infrastructure_start", error: error)
        }
    }

    private static func runServices(
        configuration: V2GatewayRuntimeConfiguration,
        infrastructure: GatewayInfrastructure,
        composition: GatewayComposition,
        logger: Logger
    ) async throws {
        let server = composition.server
        // TLS 服务关闭后若后续停机失败，不能再次关闭它。
        var serverIsShutdown = false
        do {
            do { try await server.bind() }
            catch { throw V2StagedOperationalError(stage: "gateway_tls_bind", error: error) }
            logger.notice("IM V2 TLS gateway bound", metadata: ["host": "\(configuration.tls.host)", "port": "\(configuration.tls.port)"])

            do {
                try await V2HTTPService.withRunning(infrastructure.application, logger: logger,
                    gracefulShutdownDuration: .milliseconds(configuration.shutdownGraceMilliseconds),
                    waitForShutdown: V2ProcessTerminationSignal.wait) { shutdown in
                    logger.notice("IM V2 metrics listener bound", metadata: ["host": "\(configuration.metrics.host)", "port": "\(configuration.metrics.port)"])
                    let workers = try composition.backgroundWorkers.start()
                    await shutdown.wait()
                    logger.notice("IM V2 shutdown signal received")

                    let listenerShutdownError = await stopAcceptingAndDrainWorkers(
                        composition: composition,
                        workers: workers,
                        configuration: configuration,
                        logger: logger
                    )
                    await shutdownPresenceAndAuxiliaryServices(composition: composition, logger: logger)
                    try await server.shutdown()
                    serverIsShutdown = true
                    try await stopRoomActors(composition: composition, logger: logger)
                    if let listenerShutdownError {
                        throw V2StagedOperationalError(
                            stage: "gateway_listener_shutdown", error: listenerShutdownError
                        )
                    }
                }
            } catch {
                throw V2StagedOperationalError(stage: "gateway_http_runtime", error: error)
            }
        } catch {
            if !serverIsShutdown { try? await server.shutdown() }
            throw error
        }
    }

    private static func stopAcceptingAndDrainWorkers(
        composition: GatewayComposition,
        workers: GatewayWorkerSupervisor,
        configuration: V2GatewayRuntimeConfiguration,
        logger: Logger
    ) async -> (any Error)? {
        // 先停止接纳新连接；现有通道在工作排空期间继续存活。
        var listenerShutdownError: (any Error)?
        do { try await composition.server.stopAccepting() }
        catch { listenerShutdownError = error }
        logger.notice("IM V2 public listener closed")

        workers.cancelAll()
        composition.foregroundGroupEventHints.finish()
        await composition.directRoomLogEventCache?.finish()
        let drained = await workers.drain(
            timeout: .milliseconds(configuration.shutdownGraceMilliseconds)
        )
        guard drained else {
            // 活动 worker 可能仍持有事务，不能释放其下层的连接池或 EventLoop。
            logger.critical("IM V2 service-task drain exceeded its shutdown deadline",
                metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_worker_shutdown"))
            exit(EXIT_FAILURE)
        }
        logger.notice("IM V2 service-task drain finished", metadata: ["drained": "\(drained)"])
        return listenerShutdownError
    }

    private static func shutdownPresenceAndAuxiliaryServices(
        composition: GatewayComposition, logger: Logger
    ) async {
        let connectionRegistry = composition.connectionRegistry
        await connectionRegistry.finishLivePresenceRenewals()
        await connectionRegistry.detachForegroundGroupInterestManager()
        await connectionRegistry.detachLiveActivityBroker()
        await composition.shutdownAuxiliaryServices()
        logger.notice("IM V2 broker and presence shutdown finished")
    }

    private static func stopRoomActors(composition: GatewayComposition, logger: Logger) async throws {
        guard try await composition.actors.stop(
            deadline: .now + composition.actorConfiguration.runtime.drainTimeout.duration
        ) else {
            logger.critical("IM V2 room actors still own work after shutdown deadline",
                metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_actor_shutdown"))
            exit(EXIT_FAILURE)
        }
        logger.notice("IM V2 TLS event loops and room actors shut down")
    }
}

/// 将当前进程的环境变量提供给各项网关配置解析器。
struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}
