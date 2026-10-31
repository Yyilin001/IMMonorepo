import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Server
import IMV2ServerInfrastructure

/// 构造定时维护、撤销清理和可选推送处理器，不启动轮询。
/// 两个撤销 Worker 的启动游标由组合根在监听器绑定前初始化。
struct GatewayMaintenanceAssembly {
    let profileSecurityInvalidationWorker: V2ProfileSecurityInvalidationWorker
    let readReceiptPreferencePropagationWorker: V2ReadReceiptPreferencePropagationWorker
    let deviceRevocationWorker: V2DeviceRevocationWorker
    let revokedDeviceProjectionCleanupWorker: V2RevokedDeviceProjectionCleanupWorker
    let moderationAuditRetentionWorker: V2ModerationAuditRetentionWorker
    let mediaRetentionWorker: V2MediaRetentionWorker
    let roomMaintenanceWorkers: [V2RoomActorMaintenanceWorker]
    let controlPlaneHousekeepingWorker: V2ControlPlaneHousekeepingWorker
    let pushWakeWorker: V2PushWakeWorker?
    let mentionPushWakeRelays: [PostgresV2MentionPushWakeRelay]

    /// 将维护库与房间归属库的处理器接到同一组后台依赖中。
    /// 构造 APNS 凭据或媒体保留策略失败时，错误交由组合根回滚。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        prepared: GatewayPreparedAssembly,
        roomServices: GatewayRoomServicesAssembly,
        actors: V2RoomActorApplication
    ) throws -> Self {
        let topology = prepared.topology
        let maintenanceDatabase = topology.maintenanceDatabase
        let maintenanceUserShardStorage = topology.maintenanceUserShardStorage
        let maintenanceUserShardProjectionDelivery = prepared.projection.maintenanceUserShardProjectionDelivery
        let liveSyncNotifier = prepared.frontdoor.liveSyncNotifier
        let maintenanceUserShardRouter = prepared.projection.maintenanceUserShardRouter
        let coLocatedControlBuckets = prepared.coLocatedControlBuckets
        let roomOwnerMaintenanceDatabases = prepared.ownerMaintenance.roomOwnerMaintenanceDatabases
        let actorDirectory = actors.directory
        let callTimeout = roomServices.callTimeout
        let connectionRegistry = prepared.frontdoor.connectionRegistry
        let profileSecurityInvalidationWorker = V2ProfileSecurityInvalidationWorker(
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
        let pushEnabled: Bool
        let roomRouter = V2PostgresRoomShardRouter(database: maintenanceDatabase)
        let preferenceOwners = try Dictionary(uniqueKeysWithValues: configuration.roomShardStorage.map { storage in
            guard let database = topology.databaseForRole(for: .maintenance, url: storage.databaseURL) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return (storage.shardID, database)
        })
        switch configuration.push {
        case .disabled:
            pushEnabled = false
            pushWakeWorker = nil
        case .apns(let pushConfiguration):
            pushEnabled = true
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
                store: PostgresV2PushWakeStore(
                    database: maintenanceDatabase,
                    conversationMuted: { roomID, userID, now in
                        let route = try await roomRouter.route(for: RoomID(roomID.uuidString))
                        guard let owner = preferenceOwners[route.shardID],
                              let sql = owner as? any SQLDatabase else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        return try await sql.raw("""
                            SELECT EXISTS (SELECT 1 FROM im_v2.user_room_preferences
                                WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID)
                                  AND mute_until > \(bind: now)) AS muted
                            """).first(decoding: GatewayPushMuteRow.self)?.muted == true
                    }
                ),
                provider: provider
            )
        }
        return .init(
            profileSecurityInvalidationWorker: profileSecurityInvalidationWorker,
            readReceiptPreferencePropagationWorker: readReceiptPreferencePropagationWorker,
            deviceRevocationWorker: deviceRevocationWorker,
            revokedDeviceProjectionCleanupWorker: revokedDeviceProjectionCleanupWorker,
            moderationAuditRetentionWorker: moderationAuditRetentionWorker,
            mediaRetentionWorker: mediaRetentionWorker,
            roomMaintenanceWorkers: roomMaintenanceWorkers,
            controlPlaneHousekeepingWorker: controlPlaneHousekeepingWorker,
            pushWakeWorker: pushWakeWorker,
            mentionPushWakeRelays: roomOwnerMaintenanceDatabases.map {
                PostgresV2MentionPushWakeRelay(owner: $0, control: maintenanceDatabase, enabled: pushEnabled)
            }
        )
    }
}

private struct GatewayPushMuteRow: Decodable { let muted: Bool }
