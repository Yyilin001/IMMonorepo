import IMV2ServerInfrastructure
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2ActorRuntime
import IMV2ServerGateway

/// 将网关实际运行组件适配为统一运行压力指标来源。
///
/// 持有调用方注入的组件和固定连接池拓扑，每次调用时重新读取组件快照。
/// 采集不访问数据库验证持久化状态，也不启动后台轮询；跨组件的读取期间运行状态可继续变化。
public struct V2GatewayRuntimePressureMetricsSource: V2RuntimePressureMetricsSource {
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController
    private let databasePools: V2DatabasePoolTopologySnapshot
    private let syncWakeCoalescer: V2SyncWakeCoalescer
    private let shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool?
    private let roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool?
    private let directRoomLogAppendBatcher: (any V2SendMessageBatchMetricsReading)?
    private let readReceiptBatcher: (any V2ReadReceiptBatchMetricsReading)?
    private let directRoomLogAppendStageMetrics: V2DirectRoomLogAppendStageMetrics?
    private let gatewayEventLoopLagMetrics: V2EventLoopLagMetrics?
    private let directSendPolicyCache: V2DirectSendPolicyCache?
    private let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache?
    private let directRoomLogEventCache: V2DirectRoomLogEventCache?
    private let preparedGroupEventPageCache: V2PreparedGroupEventPageCache?
    private let connectionRegistry: V2DeviceConnectionRegistry?
    private let roomActors: (any V2RoomRuntimeMetricsReading)?

    /// 连接指标来源，保存依赖而不立即采样。
    ///
    /// 可选依赖默认不提供，对应指标不会被补成零值。
    ///
    /// - Parameters:
    ///   - databaseWorkAdmission: 数据库工作准入控制器。
    ///   - databasePools: 固定连接池配置拓扑；后续采集直接复用此值。
    ///   - syncWakeCoalescer: 同步可用性提示合并器。
    ///   - shardAdmissionCommandCredits: 分片命令额度池。
    ///   - roomAdmissionCommandCredits: 房间命令额度池。
    ///   - directRoomLogAppendBatcher: 私聊追加的只读批处理指标来源，可汇总多个物理归属。
    ///   - readReceiptBatcher: 已读回执批处理只读指标来源，可汇总多个物理归属。
    ///   - directRoomLogAppendStageMetrics: 私聊追加阶段耗时收集器。
    ///   - gatewayEventLoopLagMetrics: 网关事件循环延迟收集器。
    ///   - directSendPolicyCache: 私聊发送策略提示缓存。
    ///   - directRoomLogFastAppendCache: 条件式快速追加候选缓存。
    ///   - directRoomLogEventCache: 本地私聊事件缓存。
    ///   - preparedGroupEventPageCache: 共享群事件编码页缓存。
    ///   - connectionRegistry: 设备连接注册表，用于取得在线租约续期批处理指标。
    public init(
        databaseWorkAdmission: V2DatabaseWorkAdmissionController,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWakeCoalescer: V2SyncWakeCoalescer,
        shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool? = nil,
        roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool? = nil,
        directRoomLogAppendBatcher: (any V2SendMessageBatchMetricsReading)? = nil,
        readReceiptBatcher: (any V2ReadReceiptBatchMetricsReading)? = nil,
        directRoomLogAppendStageMetrics: V2DirectRoomLogAppendStageMetrics? = nil,
        gatewayEventLoopLagMetrics: V2EventLoopLagMetrics? = nil,
        directSendPolicyCache: V2DirectSendPolicyCache? = nil,
        directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCache? = nil,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCache? = nil,
        connectionRegistry: V2DeviceConnectionRegistry? = nil,
        roomActors: (any V2RoomRuntimeMetricsReading)? = nil
    ) {
        self.databaseWorkAdmission = databaseWorkAdmission
        self.databasePools = databasePools
        self.syncWakeCoalescer = syncWakeCoalescer
        self.shardAdmissionCommandCredits = shardAdmissionCommandCredits
        self.roomAdmissionCommandCredits = roomAdmissionCommandCredits
        self.directRoomLogAppendBatcher = directRoomLogAppendBatcher
        self.readReceiptBatcher = readReceiptBatcher
        self.directRoomLogAppendStageMetrics = directRoomLogAppendStageMetrics
        self.gatewayEventLoopLagMetrics = gatewayEventLoopLagMetrics
        self.directSendPolicyCache = directSendPolicyCache
        self.directRoomLogFastAppendCache = directRoomLogFastAppendCache
        self.directRoomLogEventCache = directRoomLogEventCache
        self.preparedGroupEventPageCache = preparedGroupEventPageCache
        self.connectionRegistry = connectionRegistry
        self.roomActors = roomActors
    }

    /// 采集一次基础压力与已注入组件的状态。
    ///
    /// 准入与同步提示快照通过 `async let` 并行读取，其余组件按各自同步或异步接口读取。
    /// 各读数可能来自不同时间点，适合监控趋势，不应据此推断跨组件业务事务的原子结果。
    ///
    /// - Returns: 固定拓扑和本轮读到的组件快照；未提供依赖或组件无快照时保留 `nil`。
    public func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot {
        async let databaseWork = databaseWorkAdmission.snapshot()
        async let syncWake = syncWakeCoalescer.snapshot()
        let credits = await shardAdmissionCommandCredits?.snapshot()
        let roomCredits = await roomAdmissionCommandCredits?.snapshot()
        let appendBatching = await directRoomLogAppendBatcher?.snapshot()
        let receiptBatching = await readReceiptBatcher?.snapshot()
        let appendStages = directRoomLogAppendStageMetrics?.snapshot()
        let eventLoopLag = gatewayEventLoopLagMetrics?.snapshot()
        let directSendPolicy = await directSendPolicyCache?.snapshot()
        let fastAppend = await directRoomLogFastAppendCache?.snapshot()
        let eventCache = await directRoomLogEventCache?.snapshot()
        let preparedPageCache = preparedGroupEventPageCache?.snapshot()
        let livePresenceRenewals = await connectionRegistry?.livePresenceRenewalMetrics()
        let actorMetrics = await roomActors?.roomRuntimeMetricsSnapshot()
        return await .init(
            databaseWork: databaseWork,
            databasePools: databasePools,
            syncWake: syncWake,
            shardAdmissionCommandCredits: credits,
            roomAdmissionCommandCredits: roomCredits,
            directRoomLogAppendBatching: appendBatching,
            readReceiptBatching: receiptBatching,
            directRoomLogAppendStages: appendStages,
            gatewayEventLoopLag: eventLoopLag,
            directSendPolicy: directSendPolicy,
            directRoomLogFastAppend: fastAppend,
            directRoomLogEventCache: eventCache,
            preparedGroupEventPageCache: preparedPageCache,
            livePresenceRenewals: livePresenceRenewals,
            roomActors: actorMetrics
        )
    }
}
