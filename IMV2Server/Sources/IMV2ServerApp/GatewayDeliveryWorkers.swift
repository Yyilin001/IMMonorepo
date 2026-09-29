import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure

extension GatewayBackgroundWorkers {
    func startDeliveryWorkers(on workers: GatewayWorkerSupervisor) {
        let configuration = self.configuration
        let logger = self.logger
        let groupEventWakeRelay = delivery.groupEventWakeRelay
        let contentReviewWorker = delivery.contentReviewWorker
        let pushWakeWorker = delivery.pushWakeWorker

        // 房间事件载荷已由低延迟前台调度器发送。持久唤醒是合并后的修复提示：
        // 先给独立的 Gateway 发布者时间交付载荷，
        // 再向所有活动客户端公布后续水位。
        _ = workers.start {
            var cadence = V2AdaptiveWorkerCadence(
                minimumIntervalMilliseconds:
                    configuration.groupEventWakePollIntervalMilliseconds
            )
            while !Task.isCancelled {
                var didWork = false
                do {
                    let report = try await groupEventWakeRelay.runOnce(
                        limit: cadence.claimLimit(
                            configuredLimit: configuration.workerBatchSize
                        )
                    )
                    didWork = report.claimed > 0 || report.published > 0
                        || report.retryScheduled > 0
                } catch is CancellationError {
                    break
                } catch {
                    V2ServiceLogging.logWorkerFailure(logger, worker: "group_event_wake_relay", error: error)
                }
                do {
                    try await Task.sleep(
                        for: cadence.delayAfterPass(didWork: didWork)
                    )
                } catch is CancellationError {
                    break
                } catch {
                    break
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
