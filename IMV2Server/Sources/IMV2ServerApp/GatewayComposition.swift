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

/// 网关的进程组合根，负责把各装配阶段连接成可运行的服务。
///
/// `build` 会启动房间 Actor，并构造 TLS 服务与后台 Worker 的依赖；
/// 监听端口绑定和 Worker 轮询由 `GatewayRuntime.runServices` 稍后执行。
/// Actor 启动后若装配失败，此处先排空 Actor，再关闭已创建的辅助服务。
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

    /// 按依赖顺序组装网关，并持有后续运行与停机所需的组件。
    ///
    /// `GatewayPreparedAssembly` 完成前没有房间 Actor；其后创建的 Actor 与 Broker
    /// 立即记录在局部状态中，以便任一后续抛错路径都能清理已启动的部分。
    /// 若 Actor 无法在失败期限内排空，会以失败状态退出进程，避免释放仍被使用的数据库资源。
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        localMediaConfiguration: V2LocalFilesystemMediaRuntimeConfiguration?,
        resources: V2DatabaseResources,
        app: Application,
        logger: Logger
    ) async throws -> Self {
        // 构建可能在任一阶段失败；这些可选值只记录已经创建、需要回滚的资源。
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
            let actorFactory = try V2RoomServerActivationFactory(owners: prepared.roomOwners.ownerResources,
                safetyActorUserID: configuration.contentReviewSafetyActorUserID)
            let actors = try await V2RoomActorApplication.start(
                configuration: prepared.roomOwners.actorConfiguration,
                ownerRouter: V2PostgresRoomShardRouter(database: prepared.topology.database),
                roomDatabases: prepared.topology.roomShardDatabases,
                factory: prepared.roomOwners.actorConfiguration.hostIdentity == nil ? nil : actorFactory
            )
            // 从这里开始，后续任何抛错都必须先排空已启动的房间 Actor。
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
            // 实时阶段没有可抛出操作；下一次可能失败前先登记 Broker 供 catch 关闭。
            natsGroupWakeBroker = realtime.natsGroupWakeBroker
            sharedGroupWakeInterests = realtime.sharedGroupWakeInterests
            natsLiveActivityBroker = realtime.natsLiveActivityBroker
            let recoveryDirectory = try GatewayRoomRecoveryDirectory.build(
                configuration: configuration, topology: prepared.topology
            )
            let latestVisible = try V2RoomLatestVisibleCommandService(reader: roomServices.roomQueries)
            let roomRecovery = V2RoomRecoveryCommandService(
                directory: recoveryDirectory,
                states: roomServices.roomQueries,
                latestVisible: latestVisible
            )
            let accountInterests = sharedGroupWakeInterests
                ?? V2SharedGroupEventWakeInterests(underlying: V2LocalRoomChangeInterest())
            // 本地模式也需要统一的兴趣管理器；账号变更服务创建失败时仍要关闭它。
            sharedGroupWakeInterests = accountInterests
            let accountChanges = try V2AccountRoomChangeService(
                states: roomServices.roomQueries, interests: accountInterests
            )
            accountRoomChangeService = accountChanges
            await prepared.frontdoor.connectionRegistry.configureAccountRoomChanges(accountChanges)
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
                actorConfiguration: prepared.roomOwners.actorConfiguration,
                connectionRegistry: prepared.frontdoor.connectionRegistry,
                foregroundGroupEventHints: realtime.foregroundGroupEventHints,
                directRoomLogEventCache: prepared.projection.directRoomLogEventCache,
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

    /// 在连接注册表解除依赖后，按实时活动、账号变更、兴趣管理、唤醒 Broker 的顺序关闭辅助服务。
    func shutdownAuxiliaryServices() async {
        await natsLiveActivityBroker?.shutdown()
        await accountRoomChangeService?.shutdown()
        await sharedGroupWakeInterests?.shutdown()
        await natsGroupWakeBroker?.shutdown()
    }

    /// 完整装配之后的运行失败由 `GatewayRuntime` 调用：先排空 Actor，再关闭辅助服务。
    func shutdownAfterFailure(logger: Logger) async {
        await Self.drainActorsAfterFailure(actors, logger: logger)
        await shutdownAuxiliaryServices()
    }

    /// 排空失败后不继续释放下层资源；活动 Actor 仍可能持有数据库工作。
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
