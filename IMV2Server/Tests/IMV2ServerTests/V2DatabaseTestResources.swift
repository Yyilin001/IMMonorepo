import IMV2Server
import Logging
import NIOPosix

/// Explicit resources for PostgreSQL tests that do not start an HTTP server.
func makeV2DatabaseTestResources(eventLoopThreads: Int = 1) -> V2DatabaseResources {
    V2DatabaseResources(
        eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: eventLoopThreads),
        logger: Logger(label: "imv2.database.tests"),
        ownsEventLoopGroup: true,
        threadPoolThreads: 1
    )
}
