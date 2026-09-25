import Configuration
import Foundation
import Logging
import ServiceLifecycle
import Vapor

/// 持有 HTTP 任务作用域。数据库与工作器资源归调用方所有，
/// 存续期长于此作用域，包括流式响应结束之后。
public enum V2HTTPService {
    public enum Failure: Error, Sendable { case unexpectedServerExit }

    /// 进程信号或监听器故障会要求该角色排空工作。
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

    /// 监听地址已通过该角色的运行时校验。
    /// 通用 HOSTNAME/PORT 环境变量或 CLI 选项不能覆盖这一边界。
    public static func makeApplication(host: String, port: Int) async throws -> Application {
        try await Application(.production,
            configuration: .init(address: .hostname(host, port: port)),
            configReader: ConfigReader(provider: InMemoryProvider(values: [:])))
    }

    /// 让该角色的操作留在调用方任务中。尤其不会把 NIO TLS 服务端的
    /// 可变生命周期所有者传入无关任务。可选的信号等待必须在取消时返回；
    /// 此作用域不会额外安装进程信号处理器。
    public static func withRunning(
        _ application: Application,
        logger: Logger,
        gracefulShutdownDuration: Duration = .seconds(30),
        waitForShutdown: (@Sendable () async -> Void)? = nil,
        operation: (ShutdownRequest) async throws -> Void
    ) async throws {
        // 启动钩子失败时不能发布监听地址。
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
                    // 同时观察就绪和服务故障。服务端若在绑定前退出，
                    // 不能让此任务只因等待 listeningAddress 而一直挂起。
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
                        // 趁调用方仍持有数据库和文件资源时，
                        // 排空已接受的请求与响应流。
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
