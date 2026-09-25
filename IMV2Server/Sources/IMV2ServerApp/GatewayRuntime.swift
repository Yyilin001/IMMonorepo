import Foundation
import IMV2Server
import IMV2ServerHTTP
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum GatewayRuntime {
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
        let infrastructure: GatewayInfrastructure
        do {
            infrastructure = try await GatewayInfrastructure.start(
                configuration: configuration, logger: logger
            )
        } catch {
            throw V2StagedOperationalError(stage: "gateway_infrastructure_start", error: error)
        }
        let app = infrastructure.application
        var startedComposition: GatewayComposition?
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
            var serverIsShutdown = false
            do {
                stage = "gateway_tls_bind"
                try await server.bind()
                logger.notice("IM V2 TLS gateway bound", metadata: ["host": "\(configuration.tls.host)", "port": "\(configuration.tls.port)"])
                stage = "gateway_http_runtime"
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
            stage = "gateway_infrastructure_shutdown"
            try await infrastructure.shutdown(logger: logger)
        } catch {
            logger.error("IM V2 gateway lifecycle failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(error, stage: stage))
            if let startedComposition { await startedComposition.shutdownAfterFailure(logger: logger) }
            await infrastructure.shutdownAfterFailure()
            throw V2StagedOperationalError(stage: stage, error: error)
        }
    }
}

struct ProcessRuntimeEnvironment: V2RuntimeEnvironment {
    func value(for key: String) -> String? { ProcessInfo.processInfo.environment[key] }
}
