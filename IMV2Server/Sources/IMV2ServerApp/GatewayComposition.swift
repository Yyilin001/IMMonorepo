import Foundation
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import IMV2Server
import IMV2ActorApplication
import Vapor

/// 进程组合根：按依赖顺序装配网关，启动房间 Actor，但不启动监听器或后台轮询。
/// Actor 启动后的任一步骤失败，均在此边界按原顺序清理 Actor 与 Broker。
struct GatewayComposition {
    let server: V2TLSGatewayServer
    let actors: V2RoomActorApplication
    let actorConfiguration: V2RoomActorApplicationConfiguration
    let connectionRegistry: V2DeviceConnectionRegistry
    let foregroundGroupEventHints: V2ForegroundGroupEventHintDispatcher
    let directRoomLogEventCache: V2DirectRoomLogEventCache?
    let backgroundWorkers: GatewayBackgroundWorkers
    let natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
    let sharedGroupWakeInterests: V2SharedGroupEventWakeInterests?
    let accountRoomChangeService: V2AccountRoomChangeService?
    let natsLiveActivityBroker: V2NATSLiveActivityBroker?

    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        localMediaConfiguration: V2LocalFilesystemMediaRuntimeConfiguration?,
        resources: V2DatabaseResources,
        app: Application,
        logger: Logger
    ) async throws -> Self {
        var natsGroupWakeBroker: V2NATSGroupEventWakeBroker?
        var sharedGroupWakeInterests: V2SharedGroupEventWakeInterests?
        var accountRoomChangeService: V2AccountRoomChangeService?
        var natsLiveActivityBroker: V2NATSLiveActivityBroker?
        var roomActorApplication: V2RoomActorApplication?
        do {
            let prepared = try await GatewayPreparedAssembly.build(
                configuration: configuration,
                resources: resources,
                app: app,
                logger: logger
            )
            let topology = prepared.topology
            let frontdoor = prepared.frontdoor
            let projection = prepared.projection
            let roomOwners = prepared.roomOwners
            let actorConfiguration = roomOwners.actorConfiguration
            let actorFactory = try V2RoomServerActivationFactory(owners: roomOwners.ownerResources,
                safetyActorUserID: configuration.contentReviewSafetyActorUserID)
            let actors = try await V2RoomActorApplication.start(configuration: actorConfiguration,
                ownerRouter: V2PostgresRoomShardRouter(database: topology.database),
                roomDatabases: topology.roomShardDatabases,
                factory: actorConfiguration.hostIdentity == nil ? nil : actorFactory)
            roomActorApplication = actors
            let roomServices = try GatewayRoomServicesAssembly.build(
                configuration: configuration,
                prepared: prepared,
                actors: actors
            )
            prepared.registerMetrics(on: app, actors: actors)
            let realtime = await GatewayRealtimeAssembly.build(
                configuration: configuration,
                prepared: prepared,
                roomServices: roomServices
            )
            natsGroupWakeBroker = realtime.natsGroupWakeBroker
            sharedGroupWakeInterests = realtime.sharedGroupWakeInterests
            natsLiveActivityBroker = realtime.natsLiveActivityBroker
            let foregroundGroupEventHints = realtime.foregroundGroupEventHints
            let recoveryDirectory = try GatewayRoomRecoveryDirectory.build(
                configuration: configuration, topology: topology
            )
            let recoveryStates = roomServices.roomQueries
            let latestVisible = try V2RoomLatestVisibleCommandService(reader: roomServices.roomQueries)
            let roomRecovery = V2RoomRecoveryCommandService(directory: recoveryDirectory, states: recoveryStates, latestVisible: latestVisible)
            let accountInterests = sharedGroupWakeInterests
                ?? V2SharedGroupEventWakeInterests(underlying: V2LocalRoomChangeInterest())
            sharedGroupWakeInterests = accountInterests
            let accountChanges = try V2AccountRoomChangeService(states: recoveryStates, interests: accountInterests)
            accountRoomChangeService = accountChanges
            await frontdoor.connectionRegistry.configureAccountRoomChanges(accountChanges)
            let commands = try await GatewayCommandAssembly.build(
                configuration: configuration,
                prepared: prepared,
                roomServices: roomServices,
                realtime: realtime,
                roomRecovery: roomRecovery,
                actors: actors
            )
            let maintenance = try GatewayMaintenanceAssembly.build(
                configuration: configuration,
                prepared: prepared,
                roomServices: roomServices,
                actors: actors
            )
            let server = try GatewayTransportAssembly.build(
                configuration: configuration,
                prepared: prepared,
                handler: commands.handler
            )
            // 新命名的副本尚无活动连接。客户端认证前先记录当前撤销水位，
            // 避免扩容时重扫只追加历史；已有游标则保留，以支持崩溃恢复。
            try await maintenance.deviceRevocationWorker.initializeForStartup()
            // 存储清理使用独立的集群全局游标，首次部署从零开始，
            // 以覆盖没有 Gateway 在线观察历史撤销的停机窗口。
            try await maintenance.revokedDeviceProjectionCleanupWorker.initializeForStartup()
            let forwardDelivery = try GatewayForwardDeliveryAssembly.build(
                configuration: configuration,
                localMediaConfiguration: localMediaConfiguration,
                prepared: prepared,
                roomServices: roomServices,
                logger: logger
            )
            let backgroundWorkers = GatewayBackgroundWorkers.assemble(
                configuration: configuration,
                logger: logger,
                prepared: prepared,
                roomServices: roomServices,
                realtime: realtime,
                commands: commands,
                maintenance: maintenance,
                forwardDelivery: forwardDelivery
            )
            return .init(
                server: server,
                actors: actors,
                actorConfiguration: actorConfiguration,
                connectionRegistry: frontdoor.connectionRegistry,
                foregroundGroupEventHints: foregroundGroupEventHints,
                directRoomLogEventCache: projection.directRoomLogEventCache,
                backgroundWorkers: backgroundWorkers,
                natsGroupWakeBroker: natsGroupWakeBroker,
                sharedGroupWakeInterests: sharedGroupWakeInterests,
                accountRoomChangeService: accountRoomChangeService,
                natsLiveActivityBroker: natsLiveActivityBroker
            )
        } catch {
            logger.error("IM V2 gateway composition failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(error, stage: "gateway_composition"))
            if let roomActorApplication {
                await Self.drainActorsAfterFailure(roomActorApplication, logger: logger)
            }
            await natsLiveActivityBroker?.shutdown()
            await accountRoomChangeService?.shutdown()
            await sharedGroupWakeInterests?.shutdown()
            await natsGroupWakeBroker?.shutdown()
            throw error
        }
    }

    func shutdownAuxiliaryServices() async {
        await natsLiveActivityBroker?.shutdown()
        await accountRoomChangeService?.shutdown()
        await sharedGroupWakeInterests?.shutdown()
        await natsGroupWakeBroker?.shutdown()
    }

    func shutdownAfterFailure(logger: Logger) async {
        await Self.drainActorsAfterFailure(actors, logger: logger)
        await shutdownAuxiliaryServices()
    }

    private static func drainActorsAfterFailure(
        _ actors: V2RoomActorApplication, logger: Logger
    ) async {
        do {
            guard try await actors.stop(deadline: .now + .seconds(60)) else {
                logger.critical("IM V2 room actor failure drain exceeded its deadline",
                    metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_actor_failure_drain"))
                exit(EXIT_FAILURE)
            }
        } catch {
            logger.critical("IM V2 room actor failure drain failed", metadata:
                V2SafeLogMetadata.failure(error, stage: "gateway_actor_failure_drain"))
            exit(EXIT_FAILURE)
        }
    }
}
