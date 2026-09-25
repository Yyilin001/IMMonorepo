import IMV2Server
import IMV2ServerHTTP
import Logging
import NIOPosix
import Vapor

/// 按创建顺序持有网关的基础设施，按依赖顺序释放。
/// 只有请求、后台任务和房间 Actor 都已排空后才能调用 `shutdown`。
struct GatewayInfrastructure {
    let application: Application
    let databases: V2DatabaseResources
    let eventLoops: MultiThreadedEventLoopGroup

    static func start(configuration: V2GatewayRuntimeConfiguration, logger: Logger) async throws -> Self {
        let eventLoops = MultiThreadedEventLoopGroup(
            numberOfThreads: configuration.databasePolicy.eventLoopThreads
        )
        let databases = V2DatabaseResources(eventLoopGroup: eventLoops, logger: logger)
        do {
            let application = try await V2HTTPService.makeApplication(
                host: configuration.metrics.host, port: configuration.metrics.port
            )
            V2RedactedHTTPMiddlewareConfiguration.install(on: application)
            return .init(application: application, databases: databases, eventLoops: eventLoops)
        } catch {
            try? await databases.shutdown()
            try? await eventLoops.shutdownGracefully()
            throw error
        }
    }

    func shutdown(logger: Logger) async throws {
        try await application.shutdown()
        logger.notice("IM V2 Vapor application shut down")
        try await databases.shutdown()
        try await eventLoops.shutdownGracefully()
    }

    func shutdownAfterFailure() async {
        try? await application.shutdown()
        try? await databases.shutdown()
        try? await eventLoops.shutdownGracefully()
    }
}
