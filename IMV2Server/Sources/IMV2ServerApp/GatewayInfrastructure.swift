import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ServerHTTP
import Logging
import Vapor

/// 按创建顺序持有网关的基础设施，按依赖顺序释放。
/// 只有请求、后台任务和房间 Actor 都已排空后才能调用 `shutdown`。
struct GatewayInfrastructure {
    let application: Application
    let databases: V2DatabaseWorkloadResources

    static func start(configuration: V2GatewayRuntimeConfiguration, logger: Logger) async throws -> Self {
        try configuration.requirePersistentMessageWritePool()
        let databases = V2DatabaseWorkloadResources(
            controlEventLoopThreads: configuration.databaseNonMessagePoolEventLoopThreads,
            messageEventLoopThreads: configuration.databasePolicy.eventLoopThreads,
            logger: logger)
        do {
            let application = try await V2HTTPService.makeApplication(
                host: configuration.metrics.host, port: configuration.metrics.port
            )
            V2RedactedHTTPMiddlewareConfiguration.install(on: application)
            return .init(application: application, databases: databases)
        } catch {
            try? await databases.shutdown()
            throw error
        }
    }

    func shutdown(logger: Logger) async throws {
        try await application.shutdown()
        logger.notice("IM V2 Vapor application shut down")
        try await databases.shutdown()
    }

    func shutdownAfterFailure() async {
        try? await application.shutdown()
        try? await databases.shutdown()
    }
}
