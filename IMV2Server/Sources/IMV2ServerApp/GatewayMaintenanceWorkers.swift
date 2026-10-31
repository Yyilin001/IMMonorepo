import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure

extension GatewayBackgroundWorkers {
    func startMaintenanceWorkers(on workers: GatewayWorkerSupervisor, maintenanceCadence: V2MaintenanceCadence) {
        let configuration = self.configuration
        let logger = self.logger
        let revokedDeviceProjectionCleanupWorker = maintenance.revokedDeviceProjectionCleanupWorker
        let controlPlaneHousekeepingWorker = maintenance.controlPlaneHousekeepingWorker
        let syncLogCompactionWorkers = maintenance.syncLogCompactionWorkers
        let roomMaintenanceWorkers = maintenance.roomMaintenanceWorkers
        let syncHousekeepingWorkers = maintenance.syncHousekeepingWorkers
        let projectionVersionGCWorkers = maintenance.projectionVersionGCWorkers
        let personalEventGCWorkers = maintenance.personalEventGCWorkers
        let messageProjectionStateGCWorkers = maintenance.messageProjectionStateGCWorkers
        let forwardBackgroundDatabases = maintenance.forwardBackgroundDatabases
        let profileSecurityInvalidationWorker = maintenance.profileSecurityInvalidationWorker
        let readReceiptPreferencePropagationWorker = maintenance.readReceiptPreferencePropagationWorker
        let deviceRevocationWorker = maintenance.deviceRevocationWorker
        let moderationAuditRetentionWorker = maintenance.moderationAuditRetentionWorker
        let mediaRetentionWorker = maintenance.mediaRetentionWorker

        // 投影清理可能跨越远端分片边界，因此使用独立的重试节奏，
        // 避免单个不可用分片拖延活动连接撤销或无关的控制面工作。
        _ = workers.start {
            var cadence = V2AdaptiveWorkerCadence(
                minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
            )
            while !Task.isCancelled {
                var didWork = false
                do {
                    didWork = try await revokedDeviceProjectionCleanupWorker.runOnce(
                        limit: configuration.workerBatchSize
                    ) > 0
                } catch is CancellationError {
                    break
                } catch {
                    V2ServiceLogging.logWorkerFailure(logger, worker: "revoked_device_projection_cleanup", error: error)
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
        // 这些表随消息吞吐量而非操作员活动增长。其追赶能力独立于
        // 分钟级保留期扫描，同时在每笔数据库事务后限制执行器与
        // 维护连接池的占用。
        _ = workers.start {
            var cadence = V2BoundedBusyDrainCadence(
                minimumIdleIntervalMilliseconds:
                    configuration.backlogMaintenanceIdlePollIntervalMilliseconds,
                maximumConsecutiveBusyPasses:
                    configuration.backlogMaintenanceMaximumConsecutiveBusyPasses,
                maximumConsecutiveBusyDurationMilliseconds:
                    configuration.backlogMaintenanceBusyDrainBudgetMilliseconds
            )
            while !Task.isCancelled {
                let passStartedAt = ContinuousClock.now
                var didWork = false
                do {
                    didWork = try await controlPlaneHousekeepingWorker.runOnce(
                        limit: configuration.workerBatchSize
                    ).didWork
                } catch is CancellationError {
                    break
                } catch {
                    V2ServiceLogging.logWorkerFailure(logger, worker: "control_plane_housekeeping", error: error)
                }
                switch cadence.decisionAfterPass(
                    didWork: didWork,
                    passDuration: passStartedAt.duration(to: .now)
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
        _ = workers.start { [syncLogCompactionWorkers] in
            var cadence = V2BoundedBusyDrainCadence(
                minimumIdleIntervalMilliseconds:
                    configuration.backlogMaintenanceIdlePollIntervalMilliseconds,
                maximumConsecutiveBusyPasses:
                    configuration.backlogMaintenanceMaximumConsecutiveBusyPasses,
                maximumConsecutiveBusyDurationMilliseconds:
                    configuration.backlogMaintenanceBusyDrainBudgetMilliseconds
            )
            while !Task.isCancelled {
                let passStartedAt = ContinuousClock.now
                var didWork = false
                for worker in syncLogCompactionWorkers {
                    do {
                        let report = try await worker.runOnce(
                            userLimit: min(8, configuration.workerBatchSize),
                            rowLimit: configuration.workerBatchSize
                        )
                        didWork = didWork || report.didWork
                    } catch is CancellationError {
                        return
                    } catch {
                        V2ServiceLogging.logWorkerFailure(logger, worker: "user_sync_log_compaction", error: error)
                    }
                }
                switch cadence.decisionAfterPass(
                    didWork: didWork,
                    passDuration: passStartedAt.duration(to: .now)
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
        _ = workers.start { [roomMaintenanceWorkers, syncHousekeepingWorkers,
            projectionVersionGCWorkers, personalEventGCWorkers,
            messageProjectionStateGCWorkers, forwardBackgroundDatabases] in
            var nextMaintenanceAt: ContinuousClock.Instant?
            var cadence = V2AdaptiveWorkerCadence(
                minimumIntervalMilliseconds: configuration.workerPollIntervalMilliseconds
            )
            while !Task.isCancelled {
                var didWork = false
                do {
                    // 资料安全失效沿已有私聊关系持久投递；普通修改由作者通道处理。
                    // 工作预算按接收者计算，避免联系人众多的账号
                    // 将一次维护周期变成无界循环。
                    let report = try await profileSecurityInvalidationWorker.runOnce(
                        limit: configuration.workerBatchSize
                    )
                    didWork = report.claimedUpdateCount > 0 || report.projectedRecipientCount > 0 ||
                        report.completedUpdateCount > 0
                } catch is CancellationError {
                    break
                } catch {
                    V2ServiceLogging.logWorkerFailure(logger, worker: "profile_security_invalidation", error: error)
                }
                do {
                    let report = try await readReceiptPreferencePropagationWorker.runOnce(
                        limit: configuration.workerBatchSize
                    )
                    didWork = didWork || report.claimedOperationCount > 0 ||
                        report.projectedRoomCount > 0 || report.completedOperationCount > 0 ||
                        report.releasedOperationCount > 0 || report.pausedOperationCount > 0
                } catch is CancellationError {
                    break
                } catch {
                    V2ServiceLogging.logWorkerFailure(logger, worker: "read_receipt_preference_propagation", error: error)
                }
                do {
                    didWork = try await deviceRevocationWorker.runOnce(limit: configuration.workerBatchSize) > 0 || didWork
                } catch is CancellationError {
                    break
                } catch {
                    V2ServiceLogging.logWorkerFailure(logger, worker: "device_revocation_worker", error: error)
                }
                let maintenanceNow = ContinuousClock.now
                if maintenanceCadence.isDue(now: maintenanceNow, nextScheduledAt: nextMaintenanceAt) {
                    do {
                        _ = try await moderationAuditRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                    } catch is CancellationError {
                        break
                    } catch {
                        V2ServiceLogging.logWorkerFailure(logger, worker: "moderation_audit_retention_worker", error: error)
                    }
                    do {
                        _ = try await mediaRetentionWorker.runOnce(limit: configuration.workerBatchSize)
                    } catch is CancellationError {
                        break
                    } catch {
                        V2ServiceLogging.logWorkerFailure(logger, worker: "media_retention_worker", error: error)
                    }
                    for worker in roomMaintenanceWorkers {
                        do {
                            _ = try await worker.runRetention(limit: configuration.workerBatchSize,
                                mode: configuration.roomLogRetentionMode,
                                window: configuration.roomLogRetentionWindowSeconds)
                            _ = try await worker.runBookkeeping(limit: configuration.workerBatchSize,
                                retention: 7 * 86_400,
                                idempotencyRetention: TimeInterval(configuration.idempotencyRetentionSeconds),
                                rowLimitPerRoom: configuration.workerBatchSize)
                        } catch is CancellationError {
                            return
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "room_log_retention_worker", error: error)
                        }
                    }
                    for worker in syncHousekeepingWorkers {
                        do {
                            _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            return
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "sync_capability_housekeeping", error: error)
                        }
                    }
                    for worker in projectionVersionGCWorkers {
                        do {
                            _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            return
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "snapshot_projection_history_cleanup", error: error)
                        }
                    }
                    for worker in personalEventGCWorkers {
                        do {
                            _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            return
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "completed_personal_event_cleanup", error: error)
                        }
                    }
                    for worker in messageProjectionStateGCWorkers {
                        do {
                            _ = try await worker.runOnce(limit: configuration.workerBatchSize)
                        } catch is CancellationError {
                            return
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "shared_message_state_cleanup", error: error)
                        }
                    }
                    for database in forwardBackgroundDatabases.values {
                        do {
                            _ = try await PostgresV2ForwardExportCompactor(database: database).runOnce(
                                limit: min(1_024, max(1, configuration.workerBatchSize)))
                        } catch is CancellationError {
                            return
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "terminal_forward_export_compaction", error: error)
                        }
                        do {
                            _ = try await PostgresV2ForwardInboxCompactor(database: database).runOnce(
                                limit: min(1_024, max(1, configuration.workerBatchSize)))
                        } catch is CancellationError {
                            return
                        } catch {
                            V2ServiceLogging.logWorkerFailure(logger, worker: "terminal_forward_inbox_compaction", error: error)
                        }
                    }
                    nextMaintenanceAt = maintenanceCadence.nextScheduledAt(after: maintenanceNow)
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
