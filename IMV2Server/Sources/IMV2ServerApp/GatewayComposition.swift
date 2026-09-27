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
/// 装配失败先排空作者资料工作与 TLS，再排空 Actor 和已创建的辅助服务。
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
    let authorPresentations: V2AuthorPresentationRuntime?
    let authorDrainTimeout: Duration

    /// 按依赖顺序组装网关，并持有后续运行与停机所需的组件。
    ///
    /// 本方法在 `V2RoomActorApplication.start` 启动房间 Actor 节点，随后构造房间服务、
    /// 实时通知、命令处理、维护任务和 TLS 传输，并初始化撤销处理游标。
    /// TLS 端口、指标 HTTP 端口及后台 Worker 分别由 `GatewayRuntime.runServices` 中的
    /// `server.bind()`、`V2HTTPService.withRunning`、`backgroundWorkers.start()` 启动。
    /// Actor 与 Broker 创建后立即记录在局部状态中，以便任一后续抛错路径清理已启动的部分。
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
        var authorPresentations: V2AuthorPresentationRuntime?
        var constructedServer: V2TLSGatewayServer?
        do {
            guard !configuration.authorPresentationsEnabled || localMediaConfiguration != nil else {
                throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_AUTHOR_PRESENTATIONS_ENABLED")
            }
            // 1. 准备数据库拓扑、认证/限流、投影和房间归属资源，供后续装配阶段共享；
            // 此时尚未启动房间 Actor，也未绑定任何监听端口。
            let prepared = try await GatewayPreparedAssembly.build(
                configuration: configuration,
                resources: resources,
                app: app,
                logger: logger
            )
            // 2. 启动房间 Actor：有 hostIdentity 时启动房间承载节点及发现服务，
            // 否则启动仅调用远端房间的客户端节点。返回的目录和预留协调器供房间服务使用。
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
            if configuration.authorPresentationsEnabled, let localMediaConfiguration {
                // Use the configured delivery handle. With workload isolation
                // enabled, optional SQL does not use foreground connections.
                let delivery = try await GatewayAuthorPresentationAssembly.localDelivery(
                    configuration: localMediaConfiguration, controlDatabase: prepared.topology.deliveryDatabase)
                let authors = try GatewayAuthorPresentationAssembly.build(controlDatabase: prepared.topology.deliveryDatabase,
                    actors: actors, delivery: delivery)
                authorPresentations = authors
                try await prepared.frontdoor.connectionRegistry.installAuthorPresentationIngress(authors.ingress)
            }
            // 3. 用 Actor 目录装配房间创建、查询与事件服务；指标只登记为 Vapor 路由，
            // 指标 HTTP 端口要等 runServices 进入 V2HTTPService.withRunning 才会绑定。
            let roomServices = try GatewayRoomServicesAssembly.build(
                configuration: configuration,
                prepared: prepared,
                actors: actors
            )
            prepared.registerMetrics(on: app, actors: actors)
            // 4. 选择本地或 NATS 前台唤醒通道，并把兴趣订阅、在线活动回调和提交后提示
            // 接入连接注册表与事件流；这里是适配器装配，不启动客户端 TLS 监听。
            let realtime = await GatewayRealtimeAssembly.build(
                configuration: configuration,
                prepared: prepared,
                roomServices: roomServices
            )
            // 实时阶段没有可抛出操作；下一次可能失败前先登记 Broker 供 catch 关闭。
            natsGroupWakeBroker = realtime.natsGroupWakeBroker
            sharedGroupWakeInterests = realtime.sharedGroupWakeInterests
            natsLiveActivityBroker = realtime.natsLiveActivityBroker
            // 5. 装配房间恢复查询及账号房间变更服务，并把后者登记到连接注册表；
            // 账号变更跟踪由连接处理时的 startAccountRoomChanges 开始，而非在此启动监听器。
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
            // 6. 将房间、同步、社交和在线活动等命令接到统一处理器，再构造撤销、
            // 投影清理等维护 Worker；后台循环仍须等待 backgroundWorkers.start()。
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
            // 7. 创建每条连接所需的会话工厂和 TLS 服务对象。构造期间加载 TLS 配置、
            // 创建 NIO 事件循环；公网端口直到 runServices 调用 server.bind() 才绑定。
            let server = try GatewayTransportAssembly.build(
                configuration: configuration,
                prepared: prepared,
                handler: commands.handler,
                authors: authorPresentations
            )
            constructedServer = server
            // 8. 初始化两个持久化撤销游标，这是实际执行的启动期数据库操作，
            // 必须在 TLS 接受客户端连接、维护 Worker 开始轮询之前完成。
            // 新命名的副本尚无活动连接。客户端认证前先记录当前撤销水位，
            // 避免扩容时重扫只追加历史；已有游标则保留，以支持崩溃恢复。
            try await maintenance.deviceRevocationWorker.initializeForStartup()
            // 存储清理使用独立的集群全局游标，首次部署从零开始，
            // 以覆盖没有 Gateway 在线观察历史撤销的停机窗口。
            try await maintenance.revokedDeviceProjectionCleanupWorker.initializeForStartup()
            // 9. 组装跨分片转发投递及其后台任务依赖；assemble 只返回任务集合，
            // runServices 会先绑定 TLS、再启动指标 HTTP，最后调用 backgroundWorkers.start()。
            let forwardDelivery = try await GatewayForwardDeliveryAssembly.build(
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
                natsLiveActivityBroker: natsLiveActivityBroker,
                authorPresentations: authorPresentations,
                authorDrainTimeout: .milliseconds(configuration.shutdownGraceMilliseconds)
            )
        } catch {
            logger.error("IM V2 gateway composition failed; cleaning up", metadata:
                V2SafeLogMetadata.failure(error, stage: "gateway_composition"))
            await Self.drainAuthors(authorPresentations, timeout: .milliseconds(configuration.shutdownGraceMilliseconds), logger: logger)
            try? await constructedServer?.shutdown()
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

    /// 完整装配之后的运行失败由 `GatewayRuntime` 调用：先排空作者资料和 Actor，再关闭辅助服务。
    func shutdownAfterFailure(logger: Logger) async {
        await shutdownAuthorPresentations(logger: logger)
        await Self.drainActorsAfterFailure(actors, logger: logger)
        await shutdownAuxiliaryServices()
    }

    func shutdownAuthorPresentations(logger: Logger) async {
        await Self.drainAuthors(authorPresentations, timeout: authorDrainTimeout, logger: logger)
    }

    private static func drainAuthors(_ authors: V2AuthorPresentationRuntime?, timeout: Duration, logger: Logger) async {
        guard let authors else { return }
        let task = Task { await authors.close() }
        guard await v2WaitForTaskDrain([task], timeout: timeout) else {
            // A provider/SQL operation can ignore cancellation. Do not tear
            // down its database or socket event loops while it is still alive.
            logger.critical("IM V2 author presentation drain exceeded its shutdown deadline",
                metadata: V2SafeLogMetadata.drainTimeout(stage: "gateway_author_shutdown"))
            exit(EXIT_FAILURE)
        }
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
