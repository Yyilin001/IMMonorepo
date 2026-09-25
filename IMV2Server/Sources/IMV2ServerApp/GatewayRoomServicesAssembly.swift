import Foundation
import IMV2ActorApplication
import IMV2ActorContracts
import IMV2Server

/// Actor 已启动后，为房间创建、查询、事件读取和消息转发构造调用入口。
/// 所有房间调用使用同一 Actor 目录和配置的调用期限。
struct GatewayRoomServicesAssembly {
    let callTimeout: V2ActorMilliseconds
    let roomQueries: V2RoomRefQueryClient
    let roomActorServices: V2GatewayRoomActorServices
    let roomCreation: V2ActorRoomCreationCoordinator
    let roomCreationServices: V2GatewayRoomCreationServices
    let maintenanceGroupAudienceStore: PostgresV2GroupAudienceImportStore
    let groupEventLog: V2RoomRefGroupEventLogClient
    let forwardPort: V2RoomRefForwardPort
    let forwardMessages: V2ActorForwardingCoordinator

    /// 连接控制库中的房间路由与各物理归属方的执行器，不启动新任务。
    /// 若创建协调器或转发协调器配置无效，错误交由组合根排空已启动的 Actor。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        prepared: GatewayPreparedAssembly,
        actors: V2RoomActorApplication
    ) throws -> Self {
        let topology = prepared.topology
        let frontdoor = prepared.frontdoor
        let projection = prepared.projection
        let roomOwners = prepared.roomOwners
        let actorDirectory = actors.directory
        let callTimeout = roomOwners.actorConfiguration.runtime.callTimeout
        let roomQueries = V2RoomRefQueryClient(directory: actorDirectory, callTimeout: callTimeout.duration)
        let roomActorServices = V2GatewayRoomActorServices(directory: actorDirectory, callTimeout: callTimeout,
            readReceiptControlStore: PostgresV2ReadReceiptStore(database: topology.database,
                projectionDelivery: projection.userShardProjectionDelivery), databaseWorkAdmission: frontdoor.databaseWorkAdmission,
            directRoomLogEventCache: projection.directRoomLogEventCache)
        // 创建命令只能交给请求指定分片的归属方；超时或未知分片在进入执行器前拒绝。
        let fixedBootstraps = roomOwners.bootstraps
        let bootstrapPort = V2ActorCreationBootstrapPort(execute: { request, deadline in
            guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let shard: String
            switch request {
            case .direct(let value): shard = value.roomShardID
            case .group(let value): shard = value.intent.roomShardID
            case .stagedGroup(let value): shard = value.intent.roomShardID
            }
            guard let owner = fixedBootstraps[shard] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            return try await owner.execute(request)
        }, stage: { intent, page, deadline in
            guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            guard let owner = fixedBootstraps[intent.roomShardID] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
            try await owner.stage(intent: intent, page: page)
        })
        let roomCreation = V2ActorRoomCreationCoordinator(controlDatabase: topology.database,
            directRoutes: V2PostgresRoomShardRouter(database: topology.database),
            directSelector: configuration.directRoomShardRouter,
            groupSelector: try .init(rawValue: configuration.groupRoomShardIDs.joined(separator: ",")),
            bootstrap: bootstrapPort, capacityProfile: configuration.capacityProfile)
        let roomCreationServices = V2GatewayRoomCreationServices(coordinator: roomCreation,
            directPreferences: V2ControlDirectMessagePreferenceClient(store:
                PostgresV2DirectMessagingStore(database: topology.database, projectionDelivery: projection.userShardProjectionDelivery,
                    authorizationCoordinator: prepared.authorization)), callTimeout: callTimeout)
        let maintenanceGroupAudienceStore = PostgresV2GroupAudienceImportStore(database: topology.maintenanceDatabase)
        let groupEventLog = V2RoomRefGroupEventLogClient(rooms: roomQueries,
            directRoomLogEventCache: projection.directRoomLogEventCache)
        let forwardPort = V2RoomRefForwardPort(directory: actorDirectory)
        let forwardSources = topology.roomShardDatabases.mapValues {
            V2ActorForwardSourceEndpoint(receipts: .init(database: $0), jobs: .init(database: $0))
        }
        // 同址转发使用共享写入资源；跨归属方转发通过 Actor 命令和持久作业完成。
        let forwardMessages = try V2ActorForwardingCoordinator(router: projection.roomShardRouter,
            physicalStoreKeyByShard: roomOwners.physicalStoreKeyByShard,
            pair: .init(coordinator: actors.reservations, executorsByShard: roomOwners.forwardPairs),
            crossOwner: V2ActorCrossOwnerForwardService(sources: forwardSources,
                sourceCommand: { try await forwardPort.execute($0, deadline: $1) },
                deadline: { .now + callTimeout.duration }),
            deadline: { .now + callTimeout.duration })
        return .init(
            callTimeout: callTimeout,
            roomQueries: roomQueries,
            roomActorServices: roomActorServices,
            roomCreation: roomCreation,
            roomCreationServices: roomCreationServices,
            maintenanceGroupAudienceStore: maintenanceGroupAudienceStore,
            groupEventLog: groupEventLog,
            forwardPort: forwardPort,
            forwardMessages: forwardMessages
        )
    }
}
