import Foundation
import IMV2ActorRuntime

/// 数据库连接池的固定指标分类，原始字符串用作 Prometheus 的 `pool` 标签。
///
/// 表示部署配置中的连接池用途，不是每次请求的准入类别，也不包含动态数据库或分片标识。
public enum V2DatabasePoolMetricClass: String, CaseIterable, Sendable {
    /// 多类工作共用的连接池。
    case shared
    /// 个人事件跨库提交期间持有路由围栏的专用连接池。
    case userStateRoute = "user_state_route"
    /// 私聊权限范围持锁至 owner 提交的专用连接池。
    case directSendControl = "direct_send_control"
    case directAuthorizationResolution = "direct_authorization_resolution"
    /// 前台消息写入、控制写入和交互读取使用的连接池。
    case foreground
    /// 同步工作使用的连接池。
    case sync
    /// 持久化后台投递使用的连接池。
    case delivery
    /// 派生状态投影使用的连接池。
    case projection
    /// 清理等维护工作使用的连接池。
    case maintenance
}

/// 一个固定用途连接池的配置规模，不表示当前活动连接数。
public struct V2DatabasePoolMetric: Equatable, Sendable {
    /// 该连接池的固定用途分类。
    public let poolClass: V2DatabasePoolMetricClass
    /// 跨应用事件循环配置的 Fluent 句柄数量。
    public let eventLoopHandles: Int
    /// 该类连接池跨所有事件循环的 PostgreSQL 连接数配置上限。
    public let connectionCeiling: Int

    /// 保存连接池配置指标，不查询实际连接池或数据库。
    ///
    /// - Parameters:
    ///   - poolClass: 连接池用途。
    ///   - eventLoopHandles: 配置的事件循环句柄总数，必须大于零。
    ///   - connectionCeiling: 配置的连接总上限，必须大于零。
    /// - Precondition: 两个数量均为正数；无效值触发前置条件失败。
    public init(
        poolClass: V2DatabasePoolMetricClass,
        eventLoopHandles: Int,
        connectionCeiling: Int
    ) {
        precondition(eventLoopHandles > 0)
        precondition(connectionCeiling > 0)
        self.poolClass = poolClass
        self.eventLoopHandles = eventLoopHandles
        self.connectionCeiling = connectionCeiling
    }
}

/// 按固定用途去重并排序的连接池配置快照。
///
/// 每种用途最多一项；多实例或多分片的数据应先按约定汇总，再构造此快照。
public struct V2DatabasePoolTopologySnapshot: Equatable, Sendable {
    /// 按用途原始字符串升序排列的非空连接池列表，保证指标输出顺序稳定。
    public let pools: [V2DatabasePoolMetric]

    /// 校验用途唯一性并规范连接池列表顺序。
    ///
    /// - Parameter pools: 至少一个连接池配置，每个用途只能出现一次。
    /// - Precondition: 列表非空且不存在重复用途；不满足时触发前置条件失败。
    public init(pools: [V2DatabasePoolMetric]) {
        precondition(!pools.isEmpty)
        precondition(Set(pools.map(\.poolClass)).count == pools.count)
        self.pools = pools.sorted { $0.poolClass.rawValue < $1.poolClass.rawValue }
    }
}

/// 聚合网关进程内的数据库压力、通知合并、批处理和缓存指标。
///
/// 必填部分描述基础工作压力，可选部分承载已接入组件的观测结果。
/// 可选值为 `nil` 表示未提供该组观测，导出时整组省略，不能解释为所有计数均为零。
/// 各组件独立采样，此值不提供跨 actor 或跨数据库的同一时刻事务快照。
public struct V2RuntimePressureMetricsSnapshot: Equatable, Sendable {
    /// 数据库工作准入的在途数、队列长度和累计结果。
    public let databaseWork: V2DatabaseWorkAdmissionSnapshot
    /// 采集器提供的连接池配置拓扑，不是实时连接使用率。
    public let databasePools: V2DatabasePoolTopologySnapshot
    /// 同步可用性提示的合并、投递和丢弃统计。
    public let syncWake: V2SyncWakeCoalescerSnapshot
    /// 分片命令额度池的聚合统计；不携带分片、房间或租约标识作为指标标签。
    public let shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool.Snapshot?
    /// 按房间预留命令额度的聚合统计，用于观察批量预留效果，不暴露房间或租约标识。
    public let roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool.Snapshot?
    /// 私聊日志追加的本地排队、执行及批处理结果，使用固定模式和原因分类。
    public let directRoomLogAppendBatching: V2SendMessageAdmissionBatcher.Snapshot?
    /// 已读游标微批处理的排队与事务统计，不包含用户、房间或操作标识。
    public let readReceiptBatching: V2ReadReceiptBatcher.Snapshot?
    /// 私聊权威追加事务的固定阶段耗时分布，阶段名来自枚举而非动态 SQL。
    public let directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot?
    /// TLS 子通道事件循环上低频探测任务观察到的调度延迟，不等同于请求耗时。
    public let gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot?
    /// 私聊发送策略提示缓存的占用、命中、淘汰与过期统计，不暴露缓存键。
    public let directSendPolicy: V2DirectSendPolicyCache.Snapshot?
    /// 条件式单语句追加的候选缓存及提交、回退统计，不携带业务身份标签。
    public let directRoomLogFastAppend: V2DirectRoomLogFastAppendCache.Snapshot?
    /// 尽力维护的本地私聊事件缓存统计，包含占用、查询和提交后写入状态。
    public let directRoomLogEventCache: V2DirectRoomLogEventCache.Snapshot?
    /// 共享群事件编码页缓存的条目数、字节数和查询结果，不导出缓存键。
    public let preparedGroupEventPageCache: V2PreparedGroupEventPageCache.Snapshot?
    /// 心跳租约续期的合并与数据库批处理统计，不使用连接或用户标识作为标签。
    public let livePresenceRenewals: V2LivePresenceRenewalBatcher.Snapshot?
    /// Local Actor host and directory pressure; caller-only nodes omit host fields.
    public let roomActors: V2RoomRuntimeMetricsSnapshot?

    /// 从各组件的观测构造聚合值，不执行采集、不清零计数，也不校验组件间的一致性。
    ///
    /// - Parameters:
    ///   - databaseWork: 数据库准入观测。
    ///   - databasePools: 连接池配置拓扑。
    ///   - syncWake: 同步提示合并器观测。
    ///   - shardAdmissionCommandCredits: 分片命令额度池的聚合统计；不携带分片、房间或租约标识作为指标标签。 默认 `nil`，表示未提供。
    ///   - roomAdmissionCommandCredits: 按房间预留命令额度的聚合统计，用于观察批量预留效果，不暴露房间或租约标识。 默认 `nil`，表示未提供。
    ///   - directRoomLogAppendBatching: 私聊日志追加的本地排队、执行及批处理结果，使用固定模式和原因分类。 默认 `nil`，表示未提供。
    ///   - readReceiptBatching: 已读游标微批处理的排队与事务统计，不包含用户、房间或操作标识。 默认 `nil`，表示未提供。
    ///   - directRoomLogAppendStages: 私聊权威追加事务的固定阶段耗时分布，阶段名来自枚举而非动态 SQL。 默认 `nil`，表示未提供。
    ///   - gatewayEventLoopLag: TLS 子通道事件循环上低频探测任务观察到的调度延迟，不等同于请求耗时。 默认 `nil`，表示未提供。
    ///   - directSendPolicy: 私聊发送策略提示缓存的占用、命中、淘汰与过期统计，不暴露缓存键。 默认 `nil`，表示未提供。
    ///   - directRoomLogFastAppend: 条件式单语句追加的候选缓存及提交、回退统计，不携带业务身份标签。 默认 `nil`，表示未提供。
    ///   - directRoomLogEventCache: 尽力维护的本地私聊事件缓存统计，包含占用、查询和提交后写入状态。 默认 `nil`，表示未提供。
    ///   - preparedGroupEventPageCache: 共享群事件编码页缓存的条目数、字节数和查询结果，不导出缓存键。 默认 `nil`，表示未提供。
    ///   - livePresenceRenewals: 心跳租约续期的合并与数据库批处理统计，不使用连接或用户标识作为标签。 默认 `nil`，表示未提供。
    public init(
        databaseWork: V2DatabaseWorkAdmissionSnapshot,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWake: V2SyncWakeCoalescerSnapshot,
        shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPool.Snapshot? = nil,
        roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPool.Snapshot? = nil,
        directRoomLogAppendBatching: V2SendMessageAdmissionBatcher.Snapshot? = nil,
        readReceiptBatching: V2ReadReceiptBatcher.Snapshot? = nil,
        directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot? = nil,
        gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot? = nil,
        directSendPolicy: V2DirectSendPolicyCache.Snapshot? = nil,
        directRoomLogFastAppend: V2DirectRoomLogFastAppendCache.Snapshot? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCache.Snapshot? = nil,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCache.Snapshot? = nil,
        livePresenceRenewals: V2LivePresenceRenewalBatcher.Snapshot? = nil,
        roomActors: V2RoomRuntimeMetricsSnapshot? = nil
    ) {
        self.databaseWork = databaseWork
        self.databasePools = databasePools
        self.syncWake = syncWake
        self.shardAdmissionCommandCredits = shardAdmissionCommandCredits
        self.roomAdmissionCommandCredits = roomAdmissionCommandCredits
        self.directRoomLogAppendBatching = directRoomLogAppendBatching
        self.readReceiptBatching = readReceiptBatching
        self.directRoomLogAppendStages = directRoomLogAppendStages
        self.gatewayEventLoopLag = gatewayEventLoopLag
        self.directSendPolicy = directSendPolicy
        self.directRoomLogFastAppend = directRoomLogFastAppend
        self.directRoomLogEventCache = directRoomLogEventCache
        self.preparedGroupEventPageCache = preparedGroupEventPageCache
        self.livePresenceRenewals = livePresenceRenewals
        self.roomActors = roomActors
    }
}

/// 为运维指标接口提供可跨并发域调用的运行压力采集边界。
///
/// 实现负责从运行时组件读取观测；协议本身不承诺跨组件原子性或取消时的完成时限。
public protocol V2RuntimePressureMetricsSource: Sendable {
    /// 读取一份运行压力聚合快照。
    ///
    /// - Returns: 基础压力指标及当前可用的组件观测；未接入的可选组件以 `nil` 表示。
    func runtimePressureMetricsSnapshot() async -> V2RuntimePressureMetricsSnapshot
}

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

/// 将运行压力快照转换为 Prometheus 文本指标。
///
/// 始终输出连接池、四类数据库准入和同步提示指标；仅在可选快照存在时输出对应扩展组。
/// 数值按快照原样输出，不重新采样、重置或修正计数。直方图输出累积桶、`+Inf`、总和及样本数；
/// 固定阶段与事件循环耗时另外输出最大观测值。时间指标以名称所示的毫秒为单位。
///
/// 标签仅使用固定用途、类别、阶段和结果枚举，不引入用户、房间、请求或缓存键等动态身份。
/// 此函数只生成文本，HTTP 内容类型、访问控制和响应缓存策略由调用方负责。
///
/// - Parameter snapshot: 已采集的基础指标与可选扩展指标。
/// - Returns: 带 `HELP`、`TYPE` 声明的指标文本，各行以换行符分隔且末尾保留一个换行符。
public func v2RenderPrometheusRuntimePressureMetrics(
    _ snapshot: V2RuntimePressureMetricsSnapshot
) -> String {
    var lines = [
        "# HELP im_v2_database_pool_event_loop_handles Configured Fluent handles spanning the application EventLoops by fixed pool class.",
        "# TYPE im_v2_database_pool_event_loop_handles gauge",
    ]
    if let actors = snapshot.roomActors {
        lines.append(contentsOf: v2RoomActorMetricLines(actors))
    }
    for pool in snapshot.databasePools.pools {
        lines.append(
            "im_v2_database_pool_event_loop_handles{pool=\"\(pool.poolClass.rawValue)\"} \(pool.eventLoopHandles)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_pool_connection_ceiling Configured maximum PostgreSQL connections across all EventLoops by fixed pool class.",
        "# TYPE im_v2_database_pool_connection_ceiling gauge",
    ])
    for pool in snapshot.databasePools.pools {
        lines.append(
            "im_v2_database_pool_connection_ceiling{pool=\"\(pool.poolClass.rawValue)\"} \(pool.connectionCeiling)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_in_flight Process-local admitted database work by reserved class.",
        "# TYPE im_v2_database_work_in_flight gauge",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_in_flight{class=\"\(workClass.rawValue)\"} \(value.inFlight)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_queued Process-local short admission queue by reserved class.",
        "# TYPE im_v2_database_work_queued gauge",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_queued{class=\"\(workClass.rawValue)\"} \(value.queued)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_admissions_total Requests admitted immediately or from a bounded queue.",
        "# TYPE im_v2_database_work_admissions_total counter",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_admissions_total{class=\"\(workClass.rawValue)\"} \(value.admittedRequests)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_rejections_total Requests rejected before the Fluent database pool wait.",
        "# TYPE im_v2_database_work_rejections_total counter",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_rejections_total{class=\"\(workClass.rawValue)\",reason=\"queue_full\"} \(value.queueFullRejections)"
        )
        lines.append(
            "im_v2_database_work_rejections_total{class=\"\(workClass.rawValue)\",reason=\"timeout\"} \(value.timeoutRejections)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_cancellations_total Queued requests removed because their owning task was cancelled.",
        "# TYPE im_v2_database_work_cancellations_total counter",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let value = snapshot.databaseWork.value(for: workClass)
        lines.append(
            "im_v2_database_work_cancellations_total{class=\"\(workClass.rawValue)\"} \(value.cancelledRequests)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_database_work_queue_wait_milliseconds Time requests spent waiting in the process-local database admission queue by reserved class.",
        "# TYPE im_v2_database_work_queue_wait_milliseconds histogram",
    ])
    for workClass in V2DatabaseWorkClass.allCases {
        let wait = snapshot.databaseWork.value(for: workClass).queueWait
        for bucket in V2DatabaseWorkAdmissionWaitBucket.allCases {
            lines.append(
                "im_v2_database_work_queue_wait_milliseconds_bucket{class=\"\(workClass.rawValue)\",le=\"\(bucket.rawValue)\"} \(wait.count(atOrBelow: bucket))"
            )
        }
        lines.append(
            "im_v2_database_work_queue_wait_milliseconds_bucket{class=\"\(workClass.rawValue)\",le=\"+Inf\"} \(wait.samples)"
        )
        lines.append(
            "im_v2_database_work_queue_wait_milliseconds_sum{class=\"\(workClass.rawValue)\"} \(wait.sumMilliseconds)"
        )
        lines.append(
            "im_v2_database_work_queue_wait_milliseconds_count{class=\"\(workClass.rawValue)\"} \(wait.samples)"
        )
    }
    lines.append(contentsOf: [
        "# HELP im_v2_sync_wake_pending_users Users waiting for the next coalescer flush.",
        "# TYPE im_v2_sync_wake_pending_users gauge",
        "im_v2_sync_wake_pending_users \(snapshot.syncWake.pendingUsers)",
        "# HELP im_v2_sync_wake_in_flight_users Users currently being delivered by the coalescer flush.",
        "# TYPE im_v2_sync_wake_in_flight_users gauge",
        "im_v2_sync_wake_in_flight_users \(snapshot.syncWake.inFlightUsers)",
        "# HELP im_v2_sync_wake_coalesced_total Redundant per-user availability hints collapsed in-process.",
        "# TYPE im_v2_sync_wake_coalesced_total counter",
        "im_v2_sync_wake_coalesced_total \(snapshot.syncWake.coalescedNotifications)",
        "# HELP im_v2_sync_wake_delivered_total Best-effort Sync availability hints completed by the downstream notifier.",
        "# TYPE im_v2_sync_wake_delivered_total counter",
        "im_v2_sync_wake_delivered_total \(snapshot.syncWake.deliveredNotifications)",
        "# HELP im_v2_sync_wake_dropped_total Best-effort hints dropped at the bounded pending-user ceiling or shutdown.",
        "# TYPE im_v2_sync_wake_dropped_total counter",
        "im_v2_sync_wake_dropped_total \(snapshot.syncWake.droppedNotifications)",
    ])
    if let credits = snapshot.shardAdmissionCommandCredits {
        lines.append(contentsOf: [
            "# HELP im_v2_shard_admission_command_credits Process-local, already durable-charged command-window credits for direct room-event-log sends.",
            "# TYPE im_v2_shard_admission_command_credits gauge",
            "im_v2_shard_admission_command_credits{state=\"available\"} \(credits.activeCredits)",
            "im_v2_shard_admission_command_credits{state=\"in_flight\"} \(credits.inFlightCredits)",
            "# HELP im_v2_shard_admission_command_credit_reservations_total Durable batch reservations of direct room-event-log command credits.",
            "# TYPE im_v2_shard_admission_command_credit_reservations_total counter",
            "im_v2_shard_admission_command_credit_reservations_total \(credits.batchReservations)",
            "# HELP im_v2_shard_admission_command_credits_reserved_total Command-window credits durably charged in PostgreSQL batches.",
            "# TYPE im_v2_shard_admission_command_credits_reserved_total counter",
            "im_v2_shard_admission_command_credits_reserved_total \(credits.databaseCreditsReserved)",
            "# HELP im_v2_shard_admission_command_credits_committed_total Credits consumed by committed message transactions.",
            "# TYPE im_v2_shard_admission_command_credits_committed_total counter",
            "im_v2_shard_admission_command_credits_committed_total \(credits.committedCredits)",
            "# HELP im_v2_shard_admission_command_credit_rejections_total Requests rejected because the durable command window is full.",
            "# TYPE im_v2_shard_admission_command_credit_rejections_total counter",
            "im_v2_shard_admission_command_credit_rejections_total \(credits.capacityRejections)",
        ])
    }
    if let credits = snapshot.roomAdmissionCommandCredits {
        lines.append(contentsOf: [
            "# HELP im_v2_room_admission_command_credits Process-local, already durable-charged per-room command-window credits for direct room-event-log sends.",
            "# TYPE im_v2_room_admission_command_credits gauge",
            "im_v2_room_admission_command_credits{state=\"available\"} \(credits.activeCredits)",
            "im_v2_room_admission_command_credits{state=\"in_flight\"} \(credits.inFlightCredits)",
            "# HELP im_v2_room_admission_command_credit_hot_rooms Locally promoted hot rooms eligible for precharged per-room command credits.",
            "# TYPE im_v2_room_admission_command_credit_hot_rooms gauge",
            "im_v2_room_admission_command_credit_hot_rooms \(credits.promotedHotRooms)",
            "# HELP im_v2_room_admission_command_credit_reservations_total Durable per-room command-credit batch reservations.",
            "# TYPE im_v2_room_admission_command_credit_reservations_total counter",
            "im_v2_room_admission_command_credit_reservations_total \(credits.batchReservations)",
            "# HELP im_v2_room_admission_command_credits_reserved_total Per-room command-window credits durably charged in PostgreSQL batches.",
            "# TYPE im_v2_room_admission_command_credits_reserved_total counter",
            "im_v2_room_admission_command_credits_reserved_total \(credits.databaseCreditsReserved)",
            "# HELP im_v2_room_admission_command_credits_committed_total Per-room credits consumed by committed message transactions.",
            "# TYPE im_v2_room_admission_command_credits_committed_total counter",
            "im_v2_room_admission_command_credits_committed_total \(credits.committedCredits)",
            "# HELP im_v2_room_admission_command_credit_rejections_total Requests rejected because a per-room durable command window is full.",
            "# TYPE im_v2_room_admission_command_credit_rejections_total counter",
            "im_v2_room_admission_command_credit_rejections_total \(credits.capacityRejections)",
        ])
    }
    if let batching = snapshot.directRoomLogAppendBatching {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_append_batch_lanes Independent room-keyed append scheduling lanes.",
            "# TYPE im_v2_direct_room_log_append_batch_lanes gauge",
            "im_v2_direct_room_log_append_batch_lanes \(batching.laneCount)",
            "# HELP im_v2_direct_room_log_append_batch_pending_requests Process-local direct append requests waiting for an atomic batch.",
            "# TYPE im_v2_direct_room_log_append_batch_pending_requests gauge",
            "im_v2_direct_room_log_append_batch_pending_requests \(batching.pendingRequests)",
            "# HELP im_v2_direct_room_log_append_batch_busiest_lane_pending_requests Pending append requests in the busiest room-keyed lane.",
            "# TYPE im_v2_direct_room_log_append_batch_busiest_lane_pending_requests gauge",
            "im_v2_direct_room_log_append_batch_busiest_lane_pending_requests \(batching.busiestLanePendingRequests)",
            "# HELP im_v2_direct_room_log_append_batch_in_flight Batches currently holding one foreground database admission.",
            "# TYPE im_v2_direct_room_log_append_batch_in_flight gauge",
            "im_v2_direct_room_log_append_batch_in_flight \(batching.inFlightBatches)",
            "# HELP im_v2_direct_room_log_append_batch_busiest_lane_in_flight Batches executing in the busiest room-keyed lane.",
            "# TYPE im_v2_direct_room_log_append_batch_busiest_lane_in_flight gauge",
            "im_v2_direct_room_log_append_batch_busiest_lane_in_flight \(batching.busiestLaneInFlightBatches)",
            "# HELP im_v2_direct_room_log_append_batch_dequeued_requests_total Requests removed from staging for durable execution.",
            "# TYPE im_v2_direct_room_log_append_batch_dequeued_requests_total counter",
            "im_v2_direct_room_log_append_batch_dequeued_requests_total \(batching.dequeuedRequests)",
            "# HELP im_v2_direct_room_log_append_batch_queue_wait_milliseconds_total Cumulative request time in append staging.",
            "# TYPE im_v2_direct_room_log_append_batch_queue_wait_milliseconds_total counter",
            "im_v2_direct_room_log_append_batch_queue_wait_milliseconds_total \(batching.queueWaitMillisecondsTotal)",
            "# HELP im_v2_direct_room_log_append_batch_queue_wait_milliseconds_max Maximum request time observed in append staging since process start.",
            "# TYPE im_v2_direct_room_log_append_batch_queue_wait_milliseconds_max gauge",
            "im_v2_direct_room_log_append_batch_queue_wait_milliseconds_max \(batching.queueWaitMillisecondsMax)",
            "# HELP im_v2_direct_room_log_append_batch_completed_total Durable append batches completed.",
            "# TYPE im_v2_direct_room_log_append_batch_completed_total counter",
            "im_v2_direct_room_log_append_batch_completed_total \(batching.completedBatches)",
            "# HELP im_v2_direct_room_log_append_batch_execution_milliseconds_total Cumulative time from batch dispatch through durable completion.",
            "# TYPE im_v2_direct_room_log_append_batch_execution_milliseconds_total counter",
            "im_v2_direct_room_log_append_batch_execution_milliseconds_total \(batching.batchExecutionMillisecondsTotal)",
            "# HELP im_v2_direct_room_log_append_batch_execution_milliseconds_max Maximum batch execution time observed since process start.",
            "# TYPE im_v2_direct_room_log_append_batch_execution_milliseconds_max gauge",
            "im_v2_direct_room_log_append_batch_execution_milliseconds_max \(batching.batchExecutionMillisecondsMax)",
            "# HELP im_v2_direct_room_log_append_batch_active_rooms Rooms currently serialized by an in-flight batch.",
            "# TYPE im_v2_direct_room_log_append_batch_active_rooms gauge",
            "im_v2_direct_room_log_append_batch_active_rooms \(batching.activeRooms)",
            "# HELP im_v2_direct_room_log_append_batch_delayed_flushes_total Delayed append batch timers that actually fired by bounded delay mode.",
            "# TYPE im_v2_direct_room_log_append_batch_delayed_flushes_total counter",
            "im_v2_direct_room_log_append_batch_delayed_flushes_total{mode=\"base\"} \(batching.baseDelayFlushes)",
            "im_v2_direct_room_log_append_batch_delayed_flushes_total{mode=\"high_activity\"} \(batching.highActivityDelayFlushes)",
            "# HELP im_v2_direct_room_log_append_atomic_batches_total Atomic direct append execution outcomes by bounded batch mode.",
            "# TYPE im_v2_direct_room_log_append_atomic_batches_total counter",
            "im_v2_direct_room_log_append_atomic_batches_total{outcome=\"attempted\"} \(batching.atomicBatchAttempts)",
            "im_v2_direct_room_log_append_atomic_batches_total{outcome=\"committed\"} \(batching.atomicBatchCommitted)",
            "im_v2_direct_room_log_append_atomic_batches_total{outcome=\"shape_fallback\"} \(batching.atomicBatchFallbacks)",
            "# HELP im_v2_direct_room_log_append_atomic_requests_total Requests by atomic direct append execution outcome.",
            "# TYPE im_v2_direct_room_log_append_atomic_requests_total counter",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"committed\"} \(batching.atomicBatchCommittedRequests)",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"shape_fallback\"} \(batching.atomicBatchFallbackRequests)",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"preclassified_individual\"} \(batching.atomicPreclassifiedIndividualRequests)",
            "im_v2_direct_room_log_append_atomic_requests_total{outcome=\"singleton_dispatch\"} \(batching.singletonDispatches)",
            "# HELP im_v2_direct_room_log_append_atomic_fallback_reasons_total Atomic subsets rolled back before commit by bounded store reason.",
            "# TYPE im_v2_direct_room_log_append_atomic_fallback_reasons_total counter",
        ])
        for reason in V2AtomicRoomWriteBatchError.Reason.allCases {
            lines.append(
                "im_v2_direct_room_log_append_atomic_fallback_reasons_total{reason=\"\(reason.rawValue)\"} \(batching.atomicBatchFallbackReasons[reason, default: 0])"
            )
        }
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_append_same_room_deferred_requests_total Later same-room commands serialized into subsequent unique-room waves.",
            "# TYPE im_v2_direct_room_log_append_same_room_deferred_requests_total counter",
            "im_v2_direct_room_log_append_same_room_deferred_requests_total \(batching.sameRoomDeferredRequests)",
            "# HELP im_v2_direct_room_log_append_batch_rejections_total Requests rejected because the bounded staging queue is full.",
            "# TYPE im_v2_direct_room_log_append_batch_rejections_total counter",
            "im_v2_direct_room_log_append_batch_rejections_total{reason=\"queue_full\"} \(batching.stagingQueueFullRejections)",
            "# HELP im_v2_direct_room_log_append_batch_cancellations_total Staged requests removed before durable acceptance because their caller was cancelled.",
            "# TYPE im_v2_direct_room_log_append_batch_cancellations_total counter",
            "im_v2_direct_room_log_append_batch_cancellations_total \(batching.cancelledPendingRequests)",
        ])
    }
    if let batching = snapshot.readReceiptBatching {
        lines.append(contentsOf: [
            "# HELP im_v2_read_receipt_batch_pending_requests Read-receipt operations waiting for a durable batch.",
            "# TYPE im_v2_read_receipt_batch_pending_requests gauge",
            "im_v2_read_receipt_batch_pending_requests \(batching.pendingRequests)",
            "# HELP im_v2_read_receipt_batch_in_flight Durable read-receipt batches currently executing.",
            "# TYPE im_v2_read_receipt_batch_in_flight gauge",
            "im_v2_read_receipt_batch_in_flight \(batching.inFlightBatches)",
            "# HELP im_v2_read_receipt_batches_completed_total Durable read-receipt batches completed.",
            "# TYPE im_v2_read_receipt_batches_completed_total counter",
            "im_v2_read_receipt_batches_completed_total \(batching.completedBatches)",
            "# HELP im_v2_read_receipt_requests_completed_total Read-receipt operations completed through the batch path.",
            "# TYPE im_v2_read_receipt_requests_completed_total counter",
            "im_v2_read_receipt_requests_completed_total \(batching.completedRequests)",
            "# HELP im_v2_read_receipt_batch_maximum_observed_size Largest read-receipt transaction batch observed since process start.",
            "# TYPE im_v2_read_receipt_batch_maximum_observed_size gauge",
            "im_v2_read_receipt_batch_maximum_observed_size \(batching.maximumObservedBatchSize)",
            "# HELP im_v2_read_receipt_batch_rejections_total Read-receipt operations rejected by the bounded staging queue.",
            "# TYPE im_v2_read_receipt_batch_rejections_total counter",
            "im_v2_read_receipt_batch_rejections_total{reason=\"queue_full\"} \(batching.queueFullRejections)",
            "# HELP im_v2_read_receipt_batch_cancellations_total Pending read-receipt operations removed before durable dispatch.",
            "# TYPE im_v2_read_receipt_batch_cancellations_total counter",
            "im_v2_read_receipt_batch_cancellations_total \(batching.cancelledPendingRequests)",
        ])
    }
    if let stages = snapshot.directRoomLogAppendStages {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_append_stage_milliseconds Fixed-stage latency inside the authoritative direct append path.",
            "# TYPE im_v2_direct_room_log_append_stage_milliseconds histogram",
        ])
        for stage in V2DirectRoomLogAppendStage.allCases {
            let latency = stages.value(for: stage)
            for bucket in V2RuntimeLatencyBucket.allCases {
                lines.append(
                    "im_v2_direct_room_log_append_stage_milliseconds_bucket{stage=\"\(stage.rawValue)\",le=\"\(bucket.rawValue)\"} \(latency.count(atOrBelow: bucket))"
                )
            }
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_bucket{stage=\"\(stage.rawValue)\",le=\"+Inf\"} \(latency.samples)"
            )
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_sum{stage=\"\(stage.rawValue)\"} \(latency.sumMilliseconds)"
            )
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_count{stage=\"\(stage.rawValue)\"} \(latency.samples)"
            )
            lines.append(
                "im_v2_direct_room_log_append_stage_milliseconds_max{stage=\"\(stage.rawValue)\"} \(latency.maximumMilliseconds)"
            )
        }
    }
    if let lag = snapshot.gatewayEventLoopLag {
        lines.append(contentsOf: [
            "# HELP im_v2_gateway_event_loop_lag_milliseconds Delay of a low-frequency task scheduled on TLS child-channel EventLoops.",
            "# TYPE im_v2_gateway_event_loop_lag_milliseconds histogram",
        ])
        for bucket in V2RuntimeLatencyBucket.allCases {
            lines.append(
                "im_v2_gateway_event_loop_lag_milliseconds_bucket{le=\"\(bucket.rawValue)\"} \(lag.count(atOrBelow: bucket))"
            )
        }
        lines.append(contentsOf: [
            "im_v2_gateway_event_loop_lag_milliseconds_bucket{le=\"+Inf\"} \(lag.samples)",
            "im_v2_gateway_event_loop_lag_milliseconds_sum \(lag.sumMilliseconds)",
            "im_v2_gateway_event_loop_lag_milliseconds_count \(lag.samples)",
            "im_v2_gateway_event_loop_lag_milliseconds_max \(lag.maximumMilliseconds)",
        ])
    }
    if let policy = snapshot.directSendPolicy {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_send_policy_cache_entries Process-local durable-fenced direct policy snapshots.",
            "# TYPE im_v2_direct_send_policy_cache_entries gauge",
            "im_v2_direct_send_policy_cache_entries \(policy.entries)",
            "# HELP im_v2_direct_send_policy_cache_lookups_total Direct policy cache lookup outcomes.",
            "# TYPE im_v2_direct_send_policy_cache_lookups_total counter",
            "im_v2_direct_send_policy_cache_lookups_total{outcome=\"hit\"} \(policy.hits)",
            "im_v2_direct_send_policy_cache_lookups_total{outcome=\"miss\"} \(policy.misses)",
            "# HELP im_v2_direct_send_policy_cache_insertions_total New direct policy cache keys inserted.",
            "# TYPE im_v2_direct_send_policy_cache_insertions_total counter",
            "im_v2_direct_send_policy_cache_insertions_total \(policy.insertions)",
            "# HELP im_v2_direct_send_policy_cache_removals_total Direct policy cache removals by bounded reason.",
            "# TYPE im_v2_direct_send_policy_cache_removals_total counter",
            "im_v2_direct_send_policy_cache_removals_total{reason=\"capacity\"} \(policy.evictions)",
            "im_v2_direct_send_policy_cache_removals_total{reason=\"expired\"} \(policy.expirations)",
        ])
    }
    if let fastAppend = snapshot.directRoomLogFastAppend {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_fast_append_entries Bounded process-local snapshots eligible for a conditional direct append.",
            "# TYPE im_v2_direct_room_log_fast_append_entries gauge",
            "im_v2_direct_room_log_fast_append_entries \(fastAppend.entries)",
            "# HELP im_v2_direct_room_log_fast_append_lookups_total Candidate cache lookup outcomes.",
            "# TYPE im_v2_direct_room_log_fast_append_lookups_total counter",
            "im_v2_direct_room_log_fast_append_lookups_total{outcome=\"hit\"} \(fastAppend.lookupHits)",
            "im_v2_direct_room_log_fast_append_lookups_total{outcome=\"miss\"} \(fastAppend.lookupMisses)",
            "# HELP im_v2_direct_room_log_fast_append_requests_total Conditional append request outcomes.",
            "# TYPE im_v2_direct_room_log_fast_append_requests_total counter",
            "im_v2_direct_room_log_fast_append_requests_total{outcome=\"attempted\"} \(fastAppend.attemptedAppends)",
            "im_v2_direct_room_log_fast_append_requests_total{outcome=\"committed\"} \(fastAppend.committedAppends)",
            "im_v2_direct_room_log_fast_append_requests_total{outcome=\"fallback\"} \(fastAppend.fallbackAppends)",
            "# HELP im_v2_direct_room_log_fast_append_insertions_total New conditional append cache keys inserted.",
            "# TYPE im_v2_direct_room_log_fast_append_insertions_total counter",
            "im_v2_direct_room_log_fast_append_insertions_total \(fastAppend.insertions)",
            "# HELP im_v2_direct_room_log_fast_append_removals_total Conditional append cache removals by bounded reason.",
            "# TYPE im_v2_direct_room_log_fast_append_removals_total counter",
            "im_v2_direct_room_log_fast_append_removals_total{reason=\"capacity\"} \(fastAppend.evictions)",
            "im_v2_direct_room_log_fast_append_removals_total{reason=\"expired\"} \(fastAppend.expirations)",
        ])
    }
    if let eventCache = snapshot.directRoomLogEventCache {
        lines.append(contentsOf: [
            "# HELP im_v2_direct_room_log_event_cache_entries Bounded process-local plain direct event cache occupancy.",
            "# TYPE im_v2_direct_room_log_event_cache_entries gauge",
            "im_v2_direct_room_log_event_cache_entries \(eventCache.cachedEvents)",
            "# HELP im_v2_direct_room_log_event_cache_rooms Bounded process-local direct event cache room count.",
            "# TYPE im_v2_direct_room_log_event_cache_rooms gauge",
            "im_v2_direct_room_log_event_cache_rooms \(eventCache.cachedRooms)",
            "# HELP im_v2_direct_room_log_event_cache_bytes Approximate payload bytes retained by the local direct event cache.",
            "# TYPE im_v2_direct_room_log_event_cache_bytes gauge",
            "im_v2_direct_room_log_event_cache_bytes \(eventCache.cachedBytes)",
            "# HELP im_v2_direct_room_log_event_cache_lookups_total Local direct event cache lookup outcomes.",
            "# TYPE im_v2_direct_room_log_event_cache_lookups_total counter",
            "im_v2_direct_room_log_event_cache_lookups_total{outcome=\"hit\"} \(eventCache.hits)",
            "im_v2_direct_room_log_event_cache_lookups_total{outcome=\"miss\"} \(eventCache.misses)",
            "# HELP im_v2_direct_room_log_event_cache_bypassed_events_total Committed events that do not satisfy the plain direct cache contract.",
            "# TYPE im_v2_direct_room_log_event_cache_bypassed_events_total counter",
            "im_v2_direct_room_log_event_cache_bypassed_events_total \(eventCache.bypassedIneligibleEvents)",
            "# HELP im_v2_direct_room_log_event_cache_pending_writes Committed messages waiting for best-effort cache materialization.",
            "# TYPE im_v2_direct_room_log_event_cache_pending_writes gauge",
            "im_v2_direct_room_log_event_cache_pending_writes \(eventCache.pendingWrites)",
            "# HELP im_v2_direct_room_log_event_cache_dropped_writes_total Cache accelerators dropped at the bounded post-commit mailbox.",
            "# TYPE im_v2_direct_room_log_event_cache_dropped_writes_total counter",
            "im_v2_direct_room_log_event_cache_dropped_writes_total \(eventCache.droppedWrites)",
        ])
    }
    if let prepared = snapshot.preparedGroupEventPageCache {
        lines.append(contentsOf: [
            "# HELP im_v2_prepared_group_event_page_cache_entries Bounded shared encoded group-event page entries.",
            "# TYPE im_v2_prepared_group_event_page_cache_entries gauge",
            "im_v2_prepared_group_event_page_cache_entries \(prepared.entries)",
            "# HELP im_v2_prepared_group_event_page_cache_bytes Encoded payload bytes retained by the shared group-event page cache.",
            "# TYPE im_v2_prepared_group_event_page_cache_bytes gauge",
            "im_v2_prepared_group_event_page_cache_bytes \(prepared.bytes)",
            "# HELP im_v2_prepared_group_event_page_cache_lookups_total Shared encoded group-event page lookup outcomes.",
            "# TYPE im_v2_prepared_group_event_page_cache_lookups_total counter",
            "im_v2_prepared_group_event_page_cache_lookups_total{outcome=\"hit\"} \(prepared.hits)",
            "im_v2_prepared_group_event_page_cache_lookups_total{outcome=\"miss\"} \(prepared.misses)",
            "# HELP im_v2_prepared_group_event_page_cache_evictions_total Shared encoded group-event page removals caused by capacity bounds.",
            "# TYPE im_v2_prepared_group_event_page_cache_evictions_total counter",
            "im_v2_prepared_group_event_page_cache_evictions_total \(prepared.evictions)",
        ])
    }
    if let renewals = snapshot.livePresenceRenewals {
        lines.append(contentsOf: [
            "# HELP im_v2_live_presence_renewal_pending_connections Heartbeat lease renewals waiting in the bounded coalescing window.",
            "# TYPE im_v2_live_presence_renewal_pending_connections gauge",
            "im_v2_live_presence_renewal_pending_connections \(renewals.pendingConnections)",
            "# HELP im_v2_live_presence_renewal_requests_total Heartbeat lease renewal requests submitted to the batcher.",
            "# TYPE im_v2_live_presence_renewal_requests_total counter",
            "im_v2_live_presence_renewal_requests_total \(renewals.submittedRequests)",
            "# HELP im_v2_live_presence_renewal_batches_total Database renewal batch outcomes.",
            "# TYPE im_v2_live_presence_renewal_batches_total counter",
            "im_v2_live_presence_renewal_batches_total{outcome=\"executed\"} \(renewals.executedBatches)",
            "im_v2_live_presence_renewal_batches_total{outcome=\"failed\"} \(renewals.failedBatches)",
            "# HELP im_v2_live_presence_renewal_largest_batch Largest heartbeat renewal batch observed by this process.",
            "# TYPE im_v2_live_presence_renewal_largest_batch gauge",
            "im_v2_live_presence_renewal_largest_batch \(renewals.largestBatch)",
        ])
    }
    return lines.joined(separator: "\n") + "\n"
}
