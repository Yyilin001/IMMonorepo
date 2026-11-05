import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import Logging
import IMV2Server
import IMV2ServerInfrastructure

extension GatewayBackgroundWorkers {
    func startDeliveryWorkers(on workers: GatewayWorkerSupervisor) {
        let configuration = self.configuration
        let logger = self.logger
        let contentReviewWorker = delivery.contentReviewWorker
        let pushWakeWorker = delivery.pushWakeWorker
        for worker in delivery.roomDispatchWorkers {
            _ = workers.start {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds)
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await worker.runOnce(limit: cadence.claimLimit(configuredLimit: configuration.workerBatchSize))
                        didWork = report.claimedPages > 0
                        if report.failedPages > 0 {
                            logger.warning("room_dispatch_page_retry", metadata: ["count": .stringConvertible(report.failedPages)])
                        }
                    } catch is CancellationError { break }
                    catch { V2ServiceLogging.logWorkerFailure(logger, worker: "room_dispatch", error: error) }
                    do { try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork)) }
                    catch { break }
                }
            }
        }
        for relay in delivery.userSyncWakeRelays {
            _ = workers.start {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.groupEventWakePollIntervalMilliseconds)
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        let report = try await relay.runOnce(limit: cadence.claimLimit(configuredLimit: configuration.workerBatchSize))
                        didWork = report.claimed > 0
                    } catch is CancellationError { break }
                    catch { V2ServiceLogging.logWorkerFailure(logger, worker: "user_sync_wake_relay", error: error) }
                    do { try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork)) }
                    catch { break }
                }
            }
        }

        // 审核工作独立于个人状态投递和维护任务。
        // 缓慢的外部/OCR 适配器不得增加已接受消息的接收端交付延迟，
        // 也不得拖延媒体保留处理。
        _ = workers.start {
            guard let contentReviewWorker else { return }
            var cadence = V2AdaptiveWorkerCadence(
                minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
            )
            while !Task.isCancelled {
                var didWork = false
                do {
                    let report = try await contentReviewWorker.runOnce(
                        limitPerOwner: configuration.workerBatchSize
                    )
                    didWork = report.claimedCount > 0 || report.resolvedCount > 0 ||
                        report.redactedCount > 0 || report.releasedCount > 0
                } catch is CancellationError {
                    break
                } catch {
                    // 此日志行不包含消息正文、标识符或服务提供方响应。
                    V2ServiceLogging.logWorkerFailure(logger, worker: "content_review_worker", error: error)
                }
                do {
                    try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
        // Unconfigured alerts retain responsibility for a bounded lifetime.
        // Sweep each user store independently without touching room Actors.
        for worker in delivery.accountNotificationWorkers {
            _ = workers.start {
                while !Task.isCancelled {
                    var expired = 0
                    do {
                        expired = try await worker.runOnce(limit: 128).expired
                        if expired > 0 { logger.info("account_notification_expired", metadata: ["count": .stringConvertible(expired)]) }
                    } catch is CancellationError { break }
                    catch { V2ServiceLogging.logWorkerFailure(logger, worker: "account_notification_retention", error: error) }
                    do { try await v2Sleep(for: .milliseconds(expired == 128 ? 10 : 30_000)) }
                    catch { break }
                }
            }
        }
        // Push 自行承担外部网络延迟和重试策略，不得串行阻塞撤销、
        // 传播或数据库维护任务。
        _ = workers.start {
            guard let pushWakeWorker else { return }
            var cadence = V2AdaptiveWorkerCadence(
                minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
            )
            while !Task.isCancelled {
                var didWork = false
                do {
                    let report = try await pushWakeWorker.runOnce(limit: configuration.workerBatchSize)
                    didWork = report.admittedCount > 0 || report.sentCount > 0 || report.releasedCount > 0
                } catch is CancellationError {
                    break
                } catch {
                    // 服务提供方和端点详情不得写入日志。
                    V2ServiceLogging.logWorkerFailure(logger, worker: "push_wake_worker", error: error)
                }
                do {
                    try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }
}
