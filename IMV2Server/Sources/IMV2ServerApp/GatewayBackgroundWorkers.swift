import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Server
import Logging

/// 只包含后台工作所需的依赖。任务由同一个监督器登记、取消和排空。
struct GatewayBackgroundWorkers {
    let configuration: V2GatewayRuntimeConfiguration
    let logger: Logger
    struct Delivery {
        let forwardRuntime: V2ForwardDeliveryRuntime
        let directAuthorizationCoordinator: V2DirectAuthorizationCoordinator
        let foregroundGroupEventHints: V2ForegroundGroupEventHintDispatcher
        let directRoomLogEventCache: V2DirectRoomLogEventCache?
        let syncWakeCoalescer: V2SyncWakeCoalescer
        let userStateWorkers: [V2UserStateEventWorker]
        let groupEventWakeRelay: V2GroupEventWakeRelay
        let contentReviewWorker: V2RoutedContentReviewWorker?
        let pushWakeWorker: V2PushWakeWorker?
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
        let maintenanceGroupAudienceStore: PostgresV2GroupAudienceImportStore
        let roomCreation: V2ActorRoomCreationCoordinator
        let callTimeout: V2ActorMilliseconds
        let mediaRetentionWorker: V2MediaRetentionWorker
    }

    let maintenance: Maintenance

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
