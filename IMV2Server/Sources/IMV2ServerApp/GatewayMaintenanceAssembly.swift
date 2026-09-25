import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Server

/// 构造定时维护与持久工作处理器；启动前初始化仍由组合根按原顺序调用。
struct GatewayMaintenanceAssembly {
    let directRoomProfilePropagationWorker: V2DirectRoomProfilePropagationWorker
    let readReceiptPreferencePropagationWorker: V2ReadReceiptPreferencePropagationWorker
    let deviceRevocationWorker: V2DeviceRevocationWorker
    let revokedDeviceProjectionCleanupWorker: V2RevokedDeviceProjectionCleanupWorker
    let moderationAuditRetentionWorker: V2ModerationAuditRetentionWorker
    let mediaRetentionWorker: V2MediaRetentionWorker
    let roomMaintenanceWorkers: [V2RoomActorMaintenanceWorker]
    let controlPlaneHousekeepingWorker: V2ControlPlaneHousekeepingWorker
    let pushWakeWorker: V2PushWakeWorker?

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        topology: GatewayDatabaseTopology,
        projectionDelivery: V2PostgresUserShardProjectionDelivery,
        liveSyncNotifier: any V2LiveSyncNotifier,
        maintenanceUserShardRouter: V2PostgresUserShardRouter,
        coLocatedControlBuckets: Set<String>,
        roomOwnerMaintenanceDatabases: [any Database],
        actorDirectory: V2RoomDirectory,
        callTimeout: V2ActorMilliseconds,
        connectionRegistry: V2DeviceConnectionRegistry
    ) throws -> Self {
        let maintenanceDatabase = topology.maintenanceDatabase
        let maintenanceUserShardStorage = topology.maintenanceUserShardStorage
        let maintenanceUserShardProjectionDelivery = projectionDelivery
        let directRoomProfilePropagationWorker = V2DirectRoomProfilePropagationWorker(
            database: maintenanceDatabase,
            projectionDelivery: maintenanceUserShardProjectionDelivery,
            liveNotifier: liveSyncNotifier
        )
        let readReceiptPreferencePropagationWorker = V2ReadReceiptPreferencePropagationWorker(
            database: maintenanceDatabase
        )
        let deviceRevocationWorker = V2DeviceRevocationWorker(
            store: V2PostgresDeviceRevocationEventStore(database: maintenanceDatabase),
            registry: connectionRegistry,
            nodeID: configuration.gatewayNodeID
        )
        let revokedDeviceProjectionCleanupWorker = V2RevokedDeviceProjectionCleanupWorker(
            store: V2PostgresDeviceRevocationEventStore.projectionCleanup(
                database: maintenanceDatabase
            ),
            cleaner: V2RoutedRevokedDeviceProjectionCleaner(
                routeFence: maintenanceUserShardRouter,
                registry: maintenanceUserShardStorage,
                coLocatedControlBuckets: coLocatedControlBuckets
            )
        )
        let moderationAuditRetentionWorker = V2ModerationAuditRetentionWorker(
            store: V2OwnerModerationAuditRetentionStore(owners: roomOwnerMaintenanceDatabases.map {
                PostgresV2ModerationAuditRetentionStore(database: $0)
            })
        )
        let mediaRetentionWorker = try V2MediaRetentionWorker(
            store: PostgresV2MediaRetentionStore(database: maintenanceDatabase),
            withdrawnRetention: TimeInterval(configuration.mediaWithdrawnRetentionSeconds)
        )
        // 房间日志保留：permanent 计入全部回执，window 只计入窗口内回执；
        // 缺少回执的当前成员始终保护历史，裁剪下界告知返回客户端历史不完整。
        let roomMaintenanceWorkers = roomOwnerMaintenanceDatabases.map { owner in
            V2RoomActorMaintenanceWorker(scanner: PostgresV2RoomMaintenanceScanner(database: owner),
                invoker: V2RoomRefMaintenanceInvoker(directory: actorDirectory), callTimeout: callTimeout.duration)
        }
        let controlPlaneHousekeepingWorker = V2ControlPlaneHousekeepingWorker(
            store: PostgresV2ControlPlaneHousekeepingStore(database: maintenanceDatabase),
            idempotencyRetention: TimeInterval(configuration.idempotencyRetentionSeconds)
        )
        let pushWakeWorker: V2PushWakeWorker?
        switch configuration.push {
        case .disabled:
            pushWakeWorker = nil
        case .apns(let pushConfiguration):
            let authorizer = try V2APNSJWTAuthorizer(
                teamID: pushConfiguration.teamID,
                keyID: pushConfiguration.keyID,
                privateKeyRawBase64: pushConfiguration.privateKeyRawBase64
            )
            let provider = try V2APNSPushWakeProvider(
                endpointStore: PostgresV2PushDeviceEndpointStore(
                    database: maintenanceDatabase,
                    envelopeKey: pushConfiguration.endpointEnvelopeKey
                ),
                httpClient: V2URLSessionPushHTTPClient(),
                authorizer: authorizer,
                topic: pushConfiguration.topic
            )
            pushWakeWorker = .init(
                store: PostgresV2PushWakeStore(database: maintenanceDatabase),
                provider: provider
            )
        }
        return .init(
            directRoomProfilePropagationWorker: directRoomProfilePropagationWorker,
            readReceiptPreferencePropagationWorker: readReceiptPreferencePropagationWorker,
            deviceRevocationWorker: deviceRevocationWorker,
            revokedDeviceProjectionCleanupWorker: revokedDeviceProjectionCleanupWorker,
            moderationAuditRetentionWorker: moderationAuditRetentionWorker,
            mediaRetentionWorker: mediaRetentionWorker,
            roomMaintenanceWorkers: roomMaintenanceWorkers,
            controlPlaneHousekeepingWorker: controlPlaneHousekeepingWorker,
            pushWakeWorker: pushWakeWorker
        )
    }
}
