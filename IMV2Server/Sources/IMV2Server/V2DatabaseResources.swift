import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Logging
import NIOCore
import NIOPosix
import Synchronization

/// 持有 Fluent 驱动及其使用的线程池。
///
/// 调用方决定此对象是否也持有 EventLoopGroup。
/// 借用的组在 `shutdown()` 后仍保持运行，使共享它的 HTTP 服务端
/// 能先完成排空，再由调用方关闭该组。
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

    /// 返回下一个 EventLoop 上的一个句柄，供短期配置工作使用。
    /// 长期存活的存储应改用 `V2EventLoopDatabasePool`。
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

    /// 先关闭数据库驱动，再关闭线程池及自身持有的 EventLoopGroup。
    /// 使用数据库的请求与工作器排空后再调用。
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
