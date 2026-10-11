import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Server
import IMV2ServerInfrastructure
import Logging
import IMV2ServerGateway

/// 后台工作所需的依赖集合，按投递、投影、维护三类组织。
/// `assemble` 只连接依赖；`start` 才在同一个监督器内登记可取消的任务。
struct GatewayBackgroundWorkers {
    let configuration: V2GatewayRuntimeConfiguration
    let logger: Logger
    struct Delivery {
        let forwardRuntime: V2ForwardDeliveryRuntime
        let directRoomLogEventCache: V2DirectRoomLogEventCache?
        let syncWakeCoalescer: V2SyncWakeCoalescer
        let userStateWorkers: [V2UserStateEventWorker]
        let userSyncWakeRelays: [V2UserSyncWakeRelay]
        let contentReviewWorker: V2RoutedContentReviewWorker?
        let pushWakeWorker: V2PushWakeWorker?
        let mentionPushWakeRelays: [PostgresV2MentionPushWakeRelay]
    }

    let delivery: Delivery

    struct Projection {
        let userProjectionWorkers: [PostgresV2UserProjectionWorker]
        let databaseWorkAdmission: V2DatabaseWorkAdmissionController
        let snapshotArtifactBuilders: [PostgresV2SnapshotArtifactBuilder]
        let messageProjectionStateBodyCompactionWorkers: [PostgresV2MessageProjectionStateBodyCompactionWorker]
    }

    let projection: Projection

    struct Maintenance {
        let revokedDeviceProjectionCleanupWorker: V2RevokedDeviceProjectionCleanupWorker
        let controlPlaneHousekeepingWorker: V2ControlPlaneHousekeepingWorker
        let syncLogCompactionWorkers: [PostgresV2UserSyncLogCompactionWorker]
        let roomMaintenanceWorkers: [V2RoomActorMaintenanceWorker]
        let syncHousekeepingWorkers: [V2SyncHousekeepingWorker]
        let projectionVersionGCWorkers: [PostgresV2ProjectionVersionGCWorker]
        let personalEventGCWorkers: [PostgresV2UserStateEventGCWorker]
        let messageProjectionStateGCWorkers: [PostgresV2MessageProjectionStateGCWorker]
        let forwardBackgroundDatabases: [String: any Database]
        let directRoomProfilePropagationWorker: V2DirectRoomProfilePropagationWorker
        let readReceiptPreferencePropagationWorker: V2ReadReceiptPreferencePropagationWorker
        let deviceRevocationWorker: V2DeviceRevocationWorker
        let moderationAuditRetentionWorker: V2ModerationAuditRetentionWorker
        let mediaRetentionWorker: V2MediaRetentionWorker
    }

    let maintenance: Maintenance

    /// 汇集各装配阶段的后台依赖，并建立持久唤醒 outbox 的转发器。
    /// 返回值尚无运行中的 Worker；`GatewayRuntime` 会在 HTTP 服务运行时调用 `start`。
    static func assemble(
        configuration: V2GatewayRuntimeConfiguration,
        logger: Logger,
        prepared: GatewayPreparedAssembly,
        roomServices: GatewayRoomServicesAssembly,
        realtime: GatewayActorRealtimeRuntime,
        commands: GatewayCommandAssembly,
        maintenance: GatewayMaintenanceAssembly,
        forwardDelivery: GatewayForwardDeliveryAssembly
    ) -> Self {
        let userShardWork = prepared.userShardWork
        let frontdoor = prepared.frontdoor
        let ownerMaintenance = prepared.ownerMaintenance
        let projection = prepared.projection
        return .init(
            configuration: configuration,
            logger: logger,
            delivery: .init(
                forwardRuntime: forwardDelivery.runtime,
                directRoomLogEventCache: projection.directRoomLogEventCache,
                syncWakeCoalescer: frontdoor.syncWakeCoalescer,
                userStateWorkers: projection.userStateWorkers,
                userSyncWakeRelays: realtime.userSyncWakeStores.map {
                    V2UserSyncWakeRelay(store: $0, publisher: realtime.publisher)
                },
                contentReviewWorker: commands.contentReviewWorker,
                pushWakeWorker: maintenance.pushWakeWorker,
                mentionPushWakeRelays: maintenance.mentionPushWakeRelays
            ),
            projection: .init(
                userProjectionWorkers: userShardWork.userProjectionWorkers,
                databaseWorkAdmission: frontdoor.databaseWorkAdmission,
                snapshotArtifactBuilders: userShardWork.snapshotArtifactBuilders,
                messageProjectionStateBodyCompactionWorkers: ownerMaintenance.messageProjectionStateBodyCompactionWorkers
            ),
            maintenance: .init(
                revokedDeviceProjectionCleanupWorker: maintenance.revokedDeviceProjectionCleanupWorker,
                controlPlaneHousekeepingWorker: maintenance.controlPlaneHousekeepingWorker,
                syncLogCompactionWorkers: userShardWork.syncLogCompactionWorkers,
                roomMaintenanceWorkers: maintenance.roomMaintenanceWorkers,
                syncHousekeepingWorkers: userShardWork.syncHousekeepingWorkers,
                projectionVersionGCWorkers: userShardWork.projectionVersionGCWorkers,
                personalEventGCWorkers: ownerMaintenance.personalEventGCWorkers,
                messageProjectionStateGCWorkers: ownerMaintenance.messageProjectionStateGCWorkers,
                forwardBackgroundDatabases: forwardDelivery.backgroundDatabases,
                directRoomProfilePropagationWorker: maintenance.directRoomProfilePropagationWorker,
                readReceiptPreferencePropagationWorker: maintenance.readReceiptPreferencePropagationWorker,
                deviceRevocationWorker: maintenance.deviceRevocationWorker,
                moderationAuditRetentionWorker: maintenance.moderationAuditRetentionWorker,
                mediaRetentionWorker: maintenance.mediaRetentionWorker
            )
        )
    }

    /// 启动全部后台任务，返回供停机时统一取消与排空的监督器。
    func start() throws -> GatewayWorkerSupervisor {
        let maintenanceCadence = try V2MaintenanceCadence(
            intervalMilliseconds: configuration.maintenancePollIntervalMilliseconds
        )
        let workers = GatewayWorkerSupervisor()
        startRealtimeWorkers(on: workers)
        startProjectionWorkers(on: workers)
        startDeliveryWorkers(on: workers)
        startMaintenanceWorkers(on: workers, maintenanceCadence: maintenanceCadence)
        return workers
    }
}
