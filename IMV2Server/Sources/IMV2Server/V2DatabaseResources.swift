import FluentKit
import Logging
import NIOCore
import NIOPosix
import Synchronization

/// Owns Fluent drivers and the thread pool used by them.
///
/// The caller chooses whether this object also owns the EventLoopGroup. A
/// borrowed group remains alive after `shutdown()` so an HTTP server sharing it
/// can finish its own drain before the caller closes the group.
public final class V2DatabaseResources: Sendable {
    public let databases: Databases
    public let logger: Logger
    public let eventLoopGroup: any EventLoopGroup

    let threadPool: NIOThreadPool
    private let ownsEventLoopGroup: Bool
    private let shutdownTask = Mutex<Task<Void, any Error>?>(nil)

    public init(
        eventLoopGroup: any EventLoopGroup,
        logger: Logger,
        ownsEventLoopGroup: Bool = false,
        threadPoolThreads: Int = 2
    ) {
        precondition(threadPoolThreads > 0)
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.ownsEventLoopGroup = ownsEventLoopGroup
        let threadPool = NIOThreadPool(numberOfThreads: threadPoolThreads)
        threadPool.start()
        self.threadPool = threadPool
        databases = Databases(threadPool: threadPool, on: eventLoopGroup)
    }

    /// Returns one handle on the next EventLoop, for short-lived setup work.
    /// Long-lived stores should use `V2EventLoopDatabasePool` instead.
    public func database(_ identifier: DatabaseID? = nil) -> any Database {
        guard let database = databases.database(
            identifier,
            logger: logger,
            on: eventLoopGroup.next()
        ) else {
            preconditionFailure("Database resources have shut down")
        }
        return database
    }

    /// Close database drivers before the thread pool and any owned EventLoopGroup.
    /// Call after requests and workers that use a database have drained.
    public func shutdown() async throws {
        let task = shutdownTask.withLock { current in
            if let current { return current }
            let task = Task { try await self.performShutdown() }
            current = task
            return task
        }
        try await task.value
    }

    private func performShutdown() async throws {
        await databases.shutdownAsync()
        let threadPoolError: (any Error)?
        do {
            try await threadPool.shutdownGracefully()
            threadPoolError = nil
        } catch {
            threadPoolError = error
        }
        if ownsEventLoopGroup {
            try await eventLoopGroup.shutdownGracefully()
        }
        if let threadPoolError { throw threadPoolError }
    }
}
