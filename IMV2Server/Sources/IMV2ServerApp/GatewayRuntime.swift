import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ServerHTTP
import Logging
import IMV2ServerGateway
import IMV2ActorApplication
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
        let (configuration, resourceConfiguration) = try loadConfigurations()
        logger.notice("IM V2 startup stage started", metadata: ["stage": "infrastructure"])
        let infrastructure = try await startInfrastructure(configuration: configuration, logger: logger)
        logger.notice("IM V2 startup stage completed", metadata: ["stage": "infrastructure"])
        // 只登记已完整组装的组件，供外层失败路径清理。
        var startedComposition: GatewayComposition?
        // 记录当前阶段，供失败日志和向进程入口抛出的错误定位。
        var stage = "gateway_composition"
        do {
            logger.notice("IM V2 startup stage started", metadata: ["stage": "composition"])
            let composition = try await GatewayComposition.build(
                configuration: configuration,
                resourceConfiguration: resourceConfiguration,
                resources: infrastructure.databases,
                app: infrastructure.application,
                logger: logger
            )
            logger.notice("IM V2 startup stage completed", metadata: ["stage": "composition"])
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
            if case V2RoomActorApplicationError.incompleteShutdown = error {
                logger.critical("IM V2 room actor startup drain incomplete; retaining shared resources",
                    metadata: V2SafeLogMetadata.failure(error, stage: "gateway_actor_startup_drain"))
                exit(EXIT_FAILURE)
            }
            // 失败时仍按上层组件到基础设施的顺序尽力清理，再保留阶段信息上抛。
            let stagedError = V2StagedOperationalError(stage: stage, error: error)
            logger.error("IM V2 gateway lifecycle failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(stagedError, stage: stage))
            if let startedComposition { await startedComposition.shutdownAfterFailure(logger: logger) }
            await infrastructure.shutdownAfterFailure()
            throw stagedError
        }
    }

    /// 从同一进程环境读取网关与可选本地媒体配置。
    /// 配置解析失败时标记为 `gateway_configuration`，此时尚未创建运行时资源。
    private static func loadConfigurations() throws -> (
        V2GatewayRuntimeConfiguration, V2ResourceRuntimeConfiguration?
    ) {
        let environment = ProcessRuntimeEnvironment()
        do {
            return (
                try V2GatewayRuntimeConfiguration(environment: environment),
                try V2ResourceRuntimeConfiguration(environment: environment)
            )
        } catch {
            throw V2StagedOperationalError(stage: "gateway_configuration", error: error)
        }
    }

    /// 创建 HTTP 应用、数据库资源和事件循环，并标记启动失败阶段。
    /// `GatewayInfrastructure.start` 负责清理自身创建过程中未完成的资源。
    private static func startInfrastructure(
        configuration: V2GatewayRuntimeConfiguration, logger: Logger
    ) async throws -> GatewayInfrastructure {
        do {
            return try await GatewayInfrastructure.start(configuration: configuration, logger: logger)
        } catch {
            throw V2StagedOperationalError(stage: "gateway_infrastructure_start", error: error)
        }
    }

    /// 绑定公网 TLS 监听，再在指标 HTTP 服务的运行作用域内启动后台任务。
    ///
    /// 停机时先排空上层任务，再关闭 TLS 与房间 Actor；只有这些资源退出后，
    /// `run` 才会释放基础设施。绑定失败和 HTTP 运行失败分别保留自己的阶段标识。
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
                    do {
                        await shutdown.wait()
                        logger.notice("IM V2 shutdown signal received")

                        let connectionDrainError = await drainConnections(
                            server: server,
                            timeout: .milliseconds(configuration.shutdownGraceMilliseconds),
                            logger: logger
                        )
                        let listenerShutdownError = await stopAcceptingAndDrainWorkers(
                            composition: composition,
                            workers: workers,
                            configuration: configuration,
                            logger: logger
                        )
                        await composition.shutdownAuthorPresentations(logger: logger)
                        await shutdownPresenceAndAuxiliaryServices(composition: composition, logger: logger)
                        try await shutdownTLS(server: server, logger: logger)
                        serverIsShutdown = true
                        try await stopRoomActors(composition: composition, logger: logger)
                        if let connectionDrainError {
                            throw V2StagedOperationalError(
                                stage: "gateway_connection_shutdown", error: connectionDrainError
                            )
                        }
                        if let listenerShutdownError {
                            // 停止接纳新连接失败时，也要先完成后续排空与清理再上抛。
                            throw V2StagedOperationalError(
                                stage: "gateway_listener_shutdown", error: listenerShutdownError
                            )
                        }
                    } catch {
                        // HTTP 或后续停机失败时，仍保留 worker 对事件循环的依赖直到其退出。
                        workers.cancelAll()
                        await composition.directRoomLogEventCache?.finish()
                        guard await workers.drain(
                            timeout: .milliseconds(configuration.shutdownGraceMilliseconds)
                        ) else {
                            logger.critical("IM V2 service-task drain exceeded its shutdown deadline",
                                metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_worker_shutdown"))
                            exit(EXIT_FAILURE)
                        }
                        throw error
                    }
                }
            } catch {
                throw V2StagedOperationalError(stage: "gateway_http_runtime", error: error)
            }
        } catch {
            if !serverIsShutdown {
                _ = await drainConnections(
                    server: server,
                    timeout: .milliseconds(configuration.shutdownGraceMilliseconds),
                    logger: logger
                )
            }
            await composition.shutdownAuthorPresentations(logger: logger)
            if !serverIsShutdown { try await shutdownTLS(server: server, logger: logger) }
            throw error
        }
    }

    private static func shutdownTLS(server: V2TLSGatewayServer, logger: Logger) async throws {
        logger.notice("IM V2 shutdown stage started", metadata: ["stage": "tls_resources"])
        try await server.shutdown()
        logger.notice("IM V2 shutdown stage completed", metadata: ["stage": "tls_resources"])
    }

    private static func drainConnections(
        server: V2TLSGatewayServer,
        timeout: Duration,
        logger: Logger
    ) async -> (any Error)? {
        do {
            try await server.closeConnectionsAndDrain(timeout: timeout)
            return nil
        } catch V2TLSGatewayServerError.drainTimedOut {
            logger.critical("IM V2 connection drain exceeded its shutdown deadline",
                metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_connection_shutdown"))
            exit(EXIT_FAILURE)
        } catch {
            return error
        }
    }

    /// 连接已排空后，取消后台任务并在期限内等待任务退出。
    ///
    /// 监听关闭错误暂存到排空完成后再报告；若任务未能排空，则立即退出进程，
    /// 避免在仍有任务使用数据库时释放连接池和事件循环。
    ///
    /// - Returns: 停止接纳新连接时的错误；成功则为 `nil`。
    private static func stopAcceptingAndDrainWorkers(
        composition: GatewayComposition,
        workers: GatewayWorkerSupervisor,
        configuration: V2GatewayRuntimeConfiguration,
        logger: Logger
    ) async -> (any Error)? {
        // 再次关闭监听是幂等的，也保留首次关闭错误以便最终报告。
        var listenerShutdownError: (any Error)?
        do { try await composition.server.stopAccepting() }
        catch { listenerShutdownError = error }
        logger.notice("IM V2 public listener closed")

        workers.cancelAll()
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

    /// 在后台任务排空后断开在线状态管理，并关闭相关 broker 等辅助服务。
    /// 这些组件必须先于 TLS 服务和底层基础设施退出。
    private static func shutdownPresenceAndAuxiliaryServices(
        composition: GatewayComposition, logger: Logger
    ) async {
        await composition.shutdownAuxiliaryServices(logger: logger)
        logger.notice("IM V2 broker and presence shutdown finished")
    }

    /// 在 TLS 服务关闭后，按 Actor 配置的期限等待房间 Actor 停止。
    /// 超时直接失败退出；停止过程抛出的错误交由上层执行失败清理。
    private static func stopRoomActors(composition: GatewayComposition, logger: Logger) async throws {
        logger.notice("IM V2 shutdown stage started", metadata: ["stage": "room_actors"])
        guard try await composition.actors.stop(
            deadline: .now + composition.actorConfiguration.runtime.drainTimeout.duration
        ) else {
            logger.critical("IM V2 room actors still own work after shutdown deadline",
                metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_actor_shutdown"))
            exit(EXIT_FAILURE)
        }
        logger.notice("IM V2 shutdown stage completed", metadata: ["stage": "room_actors"])
        await composition.shutdownDatabaseLoans(logger: logger)
        logger.notice("IM V2 TLS event loops and room actors shut down")
    }
}

/// 将当前进程的环境变量提供给各项网关配置解析器。
struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}
