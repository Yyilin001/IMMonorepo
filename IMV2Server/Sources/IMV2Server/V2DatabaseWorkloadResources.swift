import IMV2ServerInfrastructure
import Logging
import NIOPosix
import Synchronization

/// Owns distinct driver containers and EventLoopGroups for message writes,
/// foreground authentication/control, and background work.
public final class V2DatabaseWorkloadResources: Sendable {
    public let control: V2DatabaseResources
    public let messageWrite: V2DatabaseResources?
    public let foreground: V2DatabaseResources?
    private let shutdownTask = Mutex<Task<Void, any Error>?>(nil)

    /// A nil message count preserves the explicitly configured shared-pool mode.
    public init(controlEventLoopThreads: Int, messageEventLoopThreads: Int?, logger: Logger) {
        precondition(controlEventLoopThreads > 0)
        if let count = messageEventLoopThreads { precondition(count > 0) }
        control = V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(
            numberOfThreads: controlEventLoopThreads), logger: logger, ownsEventLoopGroup: true)
        messageWrite = messageEventLoopThreads.map { count in
            V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: count),
                logger: logger, ownsEventLoopGroup: true)
        }
        foreground = messageEventLoopThreads.map { _ in
            V2DatabaseResources(eventLoopGroup: MultiThreadedEventLoopGroup(numberOfThreads: controlEventLoopThreads),
                logger: logger, ownsEventLoopGroup: true)
        }
    }

    public func resources(for role: V2PostgresWorkloadPoolBudget.Role) -> V2DatabaseResources {
        switch role {
        case .messageWrite: messageWrite ?? control
        case .foreground: foreground ?? control
        default: control
        }
    }

    /// Call after all actors and workers have drained. Each container closes its
    /// pools before its own group; failures do not skip the remaining containers.
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
        var firstError: (any Error)?
        if let messageWrite {
            do { try await messageWrite.shutdown() } catch { firstError = error }
        }
        if let foreground {
            do { try await foreground.shutdown() } catch { if firstError == nil { firstError = error } }
        }
        do { try await control.shutdown() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }
}
