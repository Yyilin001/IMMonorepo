import Foundation
import IMV2Server

extension GatewayBackgroundWorkers {
    func startRealtimeWorkers(on workers: GatewayWorkerSupervisor) {
        let configuration = self.configuration
        let logger = self.logger
        let forwardRuntime = delivery.forwardRuntime
        let directAuthorizationCoordinator = delivery.directAuthorizationCoordinator
        let foregroundGroupEventHints = delivery.foregroundGroupEventHints
        let directRoomLogEventCache = delivery.directRoomLogEventCache
        let syncWakeCoalescer = delivery.syncWakeCoalescer

        _ = workers.start { await forwardRuntime.run() }
        _ = workers.start {
            while !Task.isCancelled {
                do {
                    let report = try await directAuthorizationCoordinator.recover(limit: 8, now: Date())
                    if report.deferred > 0 {
                        logger.warning("IM V2 authorization recovery deferred owner work", metadata: ["count": "\(report.deferred)"])
                    }
                } catch is CancellationError { break }
                catch { V2ServiceLogging.logWorkerFailure(logger, worker: "authorization_recovery", error: error) }
                do { try await v2Sleep(for: .milliseconds(configuration.workerPollIntervalMilliseconds)) }
                catch { break }
            }
        }

        // 前台元数据发布由命令处理器之外的组件负责。
        // 可选 Broker 或套接字卡顿不会延长已提交消息的响应路径。
        _ = workers.start {
            await foregroundGroupEventHints.run()
        }
        _ = workers.start {
            if let directRoomLogEventCache {
                await directRoomLogEventCache.run()
            }
        }
        _ = workers.start {
            if configuration.syncWakeCoalescingEnabled {
                await syncWakeCoalescer.run()
            }
        }
    }
}
