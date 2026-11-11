import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure

extension GatewayBackgroundWorkers {
    func startProjectionWorkers(on workers: GatewayWorkerSupervisor) {
        let configuration = self.configuration
        let logger = self.logger
        let userProjectionWorkers = projection.userProjectionWorkers
        let databaseWorkAdmission = projection.databaseWorkAdmission
        let messageWritesAreBusy = projection.messageWritesAreBusy
        let snapshotArtifactBuilders = projection.snapshotArtifactBuilders
        let messageProjectionStateBodyCompactionWorkers = projection.messageProjectionStateBodyCompactionWorkers
        let userStateWorkers = delivery.userStateWorkers

        // 使用 `SKIP LOCKED` 领取检查点，可让每个物理存储运行多个有界 worker，
        // 同时保持单个用户的严格顺序。快照发布的工件构建更重且有独立栅栏，
        // 因此每个存储只保留一个循环。
        _ = userProjectionWorkers.flatMap { worker in
            (0 ..< configuration.userProjectionConcurrency).map { workerIndex in
                workers.start {
                    var cadence = V2BoundedBusyDrainCadence(
                        minimumIdleIntervalMilliseconds:
                            configuration.workerPollIntervalMilliseconds,
                        maximumConsecutiveBusyPasses: configuration
                            .userProjectionMaximumConsecutiveBusyPasses,
                        maximumConsecutiveBusyDurationMilliseconds: configuration
                            .userProjectionBusyDrainBudgetMilliseconds
                    )
                    while !Task.isCancelled {
                        // 消息发送使用独立物理调度器，旧准入队列不能反映其压力。
                        // 繁忙时额外 worker 让出容量，保底 worker 仍限速推进持久投影。
                        let messagePressure = await messageWritesAreBusy()
                        let sharedPressure = configuration.databaseWorkAdmissionEnabled
                            ? await databaseWorkAdmission.snapshot().queued > 0 : false
                        if messagePressure || sharedPressure {
                            do {
                                try await v2Sleep(for: .milliseconds(max(25,
                                    configuration.workerPollIntervalMilliseconds)))
                            } catch { break }
                            if workerIndex > 0 { continue }
                        }
                        let passStartedAt = ContinuousClock.now
                        var didWork = false
                        do {
                            didWork = try await worker.runOnce().claimed
                        } catch is CancellationError {
                            break
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "user_snapshot_projection", error: error)
                        }
                        let passDuration = passStartedAt.duration(to: .now)
                        switch cadence.decisionAfterPass(
                            didWork: didWork,
                            passDuration: passDuration
                        ) {
                        case .continueImmediately:
                            continue
                        case .yield:
                            await Task.yield()
                        case .sleep(let duration):
                            do {
                                try await v2Sleep(for: duration)
                            } catch {
                                break
                            }
                        }
                    }
                }
            }
        }
        _ = snapshotArtifactBuilders.map { builder in
            workers.start {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        didWork = try await builder.runOnce().claimed
                    } catch is CancellationError {
                        break
                    } catch {
                        V2ServiceLogging.logWorkerFailure(logger, worker: "snapshot_artifact_build", error: error)
                    }
                    do {
                        try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch {
                        break
                    }
                }
            }
        }
        // 历史数据转换与延迟敏感的用户投影隔离。
        // 有积压时持续处理批次；空闲分片退避为低成本的有界轮询。
        _ =
            messageProjectionStateBodyCompactionWorkers.map { worker in
                workers.start {
                    var cadence = V2AdaptiveWorkerCadence(
                        minimumIntervalMilliseconds:
                            configuration.workerPollIntervalMilliseconds
                    )
                    while !Task.isCancelled {
                        var didWork = false
                        do {
                            let report = try await worker.runOnce(
                                limit: cadence.claimLimit(
                                    configuredLimit: configuration.workerBatchSize
                                )
                            )
                            didWork = report.didWork
                        } catch is CancellationError {
                            break
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "message_state_body_compaction", error: error)
                        }
                        do {
                            try await Task.sleep(
                                for: cadence.delayAfterPass(didWork: didWork)
                            )
                        } catch {
                            break
                        }
                    }
                }
            }
        _ = userStateWorkers.map { worker in
            workers.start {
                var cadence = V2AdaptiveWorkerCadence(
                    minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
                )
                while !Task.isCancelled {
                    var didWork = false
                    do {
                        didWork = try await worker.runOnce(limit: min(1024, cadence.claimLimit(
                            configuredLimit: configuration.workerBatchSize
                        ))) > 0
                    } catch is CancellationError {
                        break
                    } catch {
                        V2ServiceLogging.logWorkerFailure(logger, worker: "personal_state_delivery", error: error)
                    }
                    do {
                        try await v2Sleep(for: cadence.delayAfterPass(didWork: didWork))
                    } catch { break }
                }
            }
        }
    }
}
