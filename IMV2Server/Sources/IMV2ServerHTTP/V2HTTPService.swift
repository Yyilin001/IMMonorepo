import Configuration
import Foundation
import Logging
import ServiceLifecycle
import Vapor

/// Owns the HTTP task scope. Database and worker resources belong to the caller
/// and outlive this scope, including streamed response completion.
public enum V2HTTPService {
    public enum Failure: Error, Sendable { case unexpectedServerExit }

    /// A process signal or listener failure asks the role to drain its work.
    public actor ShutdownRequest {
        private var requested = false
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        fileprivate var stoppingHTTP = false

        public func wait() async {
            guard !requested else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if requested || Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }

        fileprivate func request() {
            requested = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        private func cancelWaiter(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume()
        }

        fileprivate func beginHTTPShutdown() { stoppingHTTP = true }
    }

    /// Listener addresses have already passed the role's runtime validation.
    /// Generic HOSTNAME/PORT or CLI options must not override that boundary.
    public static func makeApplication(host: String, port: Int) async throws -> Application {
        try await Application(.production,
            configuration: .init(address: .hostname(host, port: port)),
            configReader: ConfigReader(provider: InMemoryProvider(values: [:])))
    }

    /// Keeps the role operation on its caller's task. In particular, the NIO TLS
    /// server's mutable lifecycle owner is not sent into an unrelated task.
    /// The optional signal wait must return when cancelled. This scope never
    /// installs an additional process signal handler.
    public static func withRunning(
        _ application: Application,
        logger: Logger,
        gracefulShutdownDuration: Duration = .seconds(30),
        waitForShutdown: (@Sendable () async -> Void)? = nil,
        operation: (ShutdownRequest) async throws -> Void
    ) async throws {
        // A failed boot hook cannot publish a listening address.
        try await application.boot()
        var configuration = ServiceGroupConfiguration(
            services: [.init(service: application, serviceName: "IM V2 HTTP")],
            logger: logger
        )
        configuration.maximumGracefulShutdownDuration = gracefulShutdownDuration
        configuration.maximumCancellationDuration = gracefulShutdownDuration
        let services = ServiceGroup(configuration: configuration)
        let stop = ShutdownRequest()

        try await withThrowingTaskGroup(of: Void.self) { signalTasks in
            if let waitForShutdown {
                signalTasks.addTask {
                    await waitForShutdown()
                    await stop.request()
                }
            }
            defer { signalTasks.cancelAll() }
            try await withThrowingTaskGroup(of: Void.self) { serverTasks in
                serverTasks.addTask {
                    do {
                        try await services.run()
                        if !(await stop.stoppingHTTP) { throw Failure.unexpectedServerExit }
                    } catch {
                        await stop.request()
                        throw error
                    }
                }
                serverTasks.addTask {
                    _ = try await application.server.listeningAddress
                }
                var listening = false
                do {
                    // Observe either readiness or service failure. A server
                    // that exits before binding must not leave this task parked
                    // solely on listeningAddress.
                    guard try await serverTasks.next() != nil else {
                        throw Failure.unexpectedServerExit
                    }
                    listening = true
                    try Task.checkCancellation()
                    try await operation(stop)
                    await stop.beginHTTPShutdown()
                    await services.triggerGracefulShutdown()
                    try await serverTasks.waitForAll()
                } catch {
                    await stop.request()
                    if listening {
                        // Let accepted requests and response streams drain while
                        // the caller still owns their database and file resources.
                        await stop.beginHTTPShutdown()
                        await services.triggerGracefulShutdown()
                    } else {
                        serverTasks.cancelAll()
                    }
                    try? await serverTasks.waitForAll()
                    throw error
                }
            }
        }
    }
}
