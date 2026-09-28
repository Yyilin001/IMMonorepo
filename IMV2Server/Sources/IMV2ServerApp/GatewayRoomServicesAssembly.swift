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
        let groupEventLog = V2RoomRefGroupEventLogClient(rooms: roomQueries,
            directRoomLogEventCache: projection.directRoomLogEventCache)
        let forwardPort = V2RoomRefForwardPort(directory: actorDirectory)
        let forwardSources = topology.roomShardDatabases.mapValues {
            V2ActorForwardSourceEndpoint(receipts: .init(database: $0), jobs: .init(database: $0))
        }
        let importRouting = V2ResourceForwardImportRouting(sources: topology.roomShardDatabases)
        // 资源跨房间复制与跨归属方转发都通过 Actor 命令和持久作业完成。
        let forwardMessages = try V2ActorForwardingCoordinator(router: projection.roomShardRouter,
            physicalStoreKeyByShard: roomOwners.physicalStoreKeyByShard,
            pair: .init(coordinator: actors.reservations, executorsByShard: roomOwners.forwardPairs),
            crossOwner: V2ActorCrossOwnerForwardService(sources: forwardSources,
                sourceCommand: { try await forwardPort.execute($0, deadline: $1) },
                deadline: { .now + callTimeout.duration }),
            requiresImport: { actor, operation, source, target, route in
                try await importRouting.requiresImport(actor: actor, operation: operation,
                    source: source, target: target, route: route)
            },
            deadline: { .now + callTimeout.duration })
        return .init(
            callTimeout: callTimeout,
            roomQueries: roomQueries,
            roomActorServices: roomActorServices,
            groupEventLog: groupEventLog,
            forwardPort: forwardPort,
            forwardMessages: forwardMessages
        )
    }
}
