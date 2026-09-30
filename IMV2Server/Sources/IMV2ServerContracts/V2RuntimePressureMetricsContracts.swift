import IMV2ActorContracts
import Foundation

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
    public let shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPoolSnapshot?
    /// 按房间预留命令额度的聚合统计，用于观察批量预留效果，不暴露房间或租约标识。
    public let roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPoolSnapshot?
    /// 私聊日志追加的本地排队、执行及批处理结果，使用固定模式和原因分类。
    public let directRoomLogAppendBatching: V2SendMessageBatchMetricsSnapshot?
    /// 已读游标微批处理的排队与事务统计，不包含用户、房间或操作标识。
    public let readReceiptBatching: V2ReadReceiptBatchMetricsSnapshot?
    /// 私聊权威追加事务的固定阶段耗时分布，阶段名来自枚举而非动态 SQL。
    public let directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot?
    /// TLS 子通道事件循环上低频探测任务观察到的调度延迟，不等同于请求耗时。
    public let gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot?
    /// 私聊发送策略提示缓存的占用、命中、淘汰与过期统计，不暴露缓存键。
    public let directSendPolicy: V2DirectSendPolicyCacheSnapshot?
    /// 条件式单语句追加的候选缓存及提交、回退统计，不携带业务身份标签。
    public let directRoomLogFastAppend: V2DirectRoomLogFastAppendCacheSnapshot?
    /// 尽力维护的本地私聊事件缓存统计，包含占用、查询和提交后写入状态。
    public let directRoomLogEventCache: V2DirectRoomLogEventCacheSnapshot?
    /// 共享群事件编码页缓存的条目数、字节数和查询结果，不导出缓存键。
    public let preparedGroupEventPageCache: V2PreparedGroupEventPageCacheSnapshot?
    /// 心跳租约续期的合并与数据库批处理统计，不使用连接或用户标识作为标签。
    public let livePresenceRenewals: V2LivePresenceRenewalBatcherSnapshot?
/// 本地 Actor 宿主与目录的负载指标；仅作调用方的节点不包含宿主字段。
    public let roomActors: V2RoomRuntimeMetricsSnapshot?
    public let sendOperationBatching: V2SendOperationBatchMetricsSnapshot?

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
        shardAdmissionCommandCredits: V2ShardAdmissionCommandCreditPoolSnapshot? = nil,
        roomAdmissionCommandCredits: V2RoomAdmissionCommandCreditPoolSnapshot? = nil,
        directRoomLogAppendBatching: V2SendMessageBatchMetricsSnapshot? = nil,
        readReceiptBatching: V2ReadReceiptBatchMetricsSnapshot? = nil,
        directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot? = nil,
        gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot? = nil,
        directSendPolicy: V2DirectSendPolicyCacheSnapshot? = nil,
        directRoomLogFastAppend: V2DirectRoomLogFastAppendCacheSnapshot? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCacheSnapshot? = nil,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCacheSnapshot? = nil,
        livePresenceRenewals: V2LivePresenceRenewalBatcherSnapshot? = nil,
        roomActors: V2RoomRuntimeMetricsSnapshot? = nil,
        sendOperationBatching: V2SendOperationBatchMetricsSnapshot? = nil
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
        self.sendOperationBatching = sendOperationBatching
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
