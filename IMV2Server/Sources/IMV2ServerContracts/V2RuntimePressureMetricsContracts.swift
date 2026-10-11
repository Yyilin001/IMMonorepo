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
    /// 控制库房间身份初始化读取使用的连接池。
    case roomIdentityControl = "room_identity_control"
    /// 前台消息写入、控制写入和交互读取使用的连接池。
    case messageWrite = "message_write"
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

/// A granted loan remains occupied until its actual database future settles, including driver borrow wait.
/// These counters are loan admission observations, not actual connection utilization.
public struct V2DatabaseLoanClassMetrics: Equatable, Sendable {
    public let inFlight: Int
    public let queued: Int
    public let granted: UInt64
    public let rejected: UInt64
    public init(inFlight: Int = 0, queued: Int = 0, granted: UInt64 = 0, rejected: UInt64 = 0) {
        self.inFlight = inFlight; self.queued = queued
        self.granted = granted; self.rejected = rejected
    }
}

/// Closed observation labels; no physical database or request identifiers.
public enum V2DatabaseLoanObservationMetricSource: String, CaseIterable, Sendable {
    case durableOwner = "durable_owner"
    case roomSendInitialization = "room_send_initialization"
    case preparationOwnerRead = "preparation_owner_read"
    case controlReservation = "control_reservation"
    case policySnapshot = "policy_snapshot"
    case lifecycle, renewal, presence
    case roomWake = "room_wake"
    case routeLookup = "route_lookup"
    case realtimePartitionControl = "realtime_partition_control"
    case realtimeOwnerSnapshot = "realtime_owner_snapshot"
    case realtimeRecoveryHead = "realtime_recovery_head"
    case groupEventPull = "group_event_pull"
    case groupEventSubscribe = "group_event_subscribe"
    case roomRecovery = "room_recovery"
    case sync
    case userStateProjection = "user_state_projection"
    case query, maintenance, other
}

public enum V2DatabaseLoanObservationMetricStage: String, CaseIterable, Sendable {
    case gateQueued = "gate_queued"
    case awaitingDriver = "awaiting_driver"
    case betweenSQL = "between_sql"
    case sql, settled
}

/// Completed stage intervals and currently observed loans are independent.
/// `settled` is terminal, so it has no active or oldest-age export.
public struct V2DatabaseLoanObservationStageMetric: Equatable, Sendable {
    public var active = 0
    public var oldestMilliseconds: Double = 0
    public var count: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMilliseconds: Double = 0
    public init() {}
}

/// Fixed actual SQL-future classifications; concurrent lifetimes can overlap.
public enum V2DatabaseLoanObservationMetricSQLPhase: String, CaseIterable, Sendable {
    case fence
    case readBody = "read_body"
    case transactionControl = "transaction_control"
    case other
}

/// Actual completed SQL-future lifetimes, not exclusive stage wall-clock time.
public struct V2DatabaseLoanObservationSQLMetric: Equatable, Sendable {
    public var count: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMilliseconds: Double = 0
    public init() {}
}

public struct V2DatabaseLoanObservationSourceMetric: Equatable, Sendable {
    public var sqlPhases = Dictionary(uniqueKeysWithValues: V2DatabaseLoanObservationMetricSQLPhase.allCases.map {
        ($0, V2DatabaseLoanObservationSQLMetric())
    })
    public var stages = Dictionary(uniqueKeysWithValues: V2DatabaseLoanObservationMetricStage.allCases.map {
        ($0, V2DatabaseLoanObservationStageMetric())
    })
    /// Grant until actual future settlement, including driver wait and transaction finalization.
    /// This is not socket utilization or a sum of SQL execution times.
    public var actualHeldCount: UInt64 = 0
    public var actualHeldTotalMilliseconds: Double = 0
    public var actualHeldMaxMilliseconds: Double = 0
    public init() {}
}

/// Process aggregate with four fixed classes and no database or owner identifiers.
/// Activation and Sync share ordinary capacity, reported separately from general work.
public struct V2DatabaseLoanMetricsSnapshot: Equatable, Sendable {
    public let ordinary: V2DatabaseLoanClassMetrics
    public let activation: V2DatabaseLoanClassMetrics
    public let sync: V2DatabaseLoanClassMetrics
    public let renewal: V2DatabaseLoanClassMetrics
    /// Nil means no observation source; otherwise all fixed sources render zero baselines.
    public let observations: [V2DatabaseLoanObservationMetricSource: V2DatabaseLoanObservationSourceMetric]?
    public init(ordinary: V2DatabaseLoanClassMetrics = .init(), activation: V2DatabaseLoanClassMetrics = .init(),
                renewal: V2DatabaseLoanClassMetrics = .init(), sync: V2DatabaseLoanClassMetrics = .init(),
                observations: [V2DatabaseLoanObservationMetricSource: V2DatabaseLoanObservationSourceMetric]? = nil) {
        self.ordinary = ordinary; self.activation = activation; self.renewal = renewal; self.sync = sync
        self.observations = observations
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
    public let databaseLoans: V2DatabaseLoanMetricsSnapshot?
    public let databasePools: V2DatabasePoolTopologySnapshot
    /// 同步可用性提示的合并、投递和丢弃统计。
    public let syncWake: V2SyncWakeCoalescerSnapshot
    /// 已读游标微批处理的排队与事务统计，不包含用户、房间或操作标识。
    public let readReceiptBatching: V2ReadReceiptBatchMetricsSnapshot?
    /// 私聊权威追加事务的固定阶段耗时分布，阶段名来自枚举而非动态 SQL。
    public let directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot?
    /// TLS 子通道事件循环上低频探测任务观察到的调度延迟，不等同于请求耗时。
    public let gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot?
    /// 私聊发送策略提示缓存的占用、命中、淘汰与过期统计，不暴露缓存键。
    public let directSendPolicy: V2DirectSendPolicyCacheSnapshot?
    /// 尽力维护的本地私聊事件缓存统计，包含占用、查询和提交后写入状态。
    public let directRoomLogEventCache: V2DirectRoomLogEventCacheSnapshot?
    /// 共享群事件编码页缓存的条目数、字节数和查询结果，不导出缓存键。
    public let preparedGroupEventPageCache: V2PreparedGroupEventPageCacheSnapshot?
    /// 心跳租约续期的合并与数据库批处理统计，不使用连接或用户标识作为标签。
    public let livePresenceRenewals: V2LivePresenceRenewalBatcherSnapshot?
/// 本地 Actor 宿主与目录的负载指标；仅作调用方的节点不包含宿主字段。
    public let roomActors: V2RoomRuntimeMetricsSnapshot?
    public let sendOperationBatching: V2SendOperationBatchMetricsSnapshot?
    public let sendOperationOwnerBatching: V2SendOperationOwnerMetricsSnapshot?
    /// Independent durable preparation admission; never part of owner write occupancy.
    public let gatewayMessageSend: V2GatewayMessageSendMetricsSnapshot?
    public let roomRecoveryBatches: V2RoomRecoveryBatchPressureSnapshot?
    public let registryRecovery: V2RegistryRecoveryMetricsSnapshot?

    /// 从各组件的观测构造聚合值，不执行采集、不清零计数，也不校验组件间的一致性。
    ///
    /// - Parameters:
    ///   - databaseWork: 数据库准入观测。
    ///   - databasePools: 连接池配置拓扑。
    ///   - syncWake: 同步提示合并器观测。
    ///   - readReceiptBatching: 已读游标微批处理的排队与事务统计，不包含用户、房间或操作标识。 默认 `nil`，表示未提供。
    ///   - directRoomLogAppendStages: 私聊权威追加事务的固定阶段耗时分布，阶段名来自枚举而非动态 SQL。 默认 `nil`，表示未提供。
    ///   - gatewayEventLoopLag: TLS 子通道事件循环上低频探测任务观察到的调度延迟，不等同于请求耗时。 默认 `nil`，表示未提供。
    ///   - directSendPolicy: 私聊发送策略提示缓存的占用、命中、淘汰与过期统计，不暴露缓存键。 默认 `nil`，表示未提供。
    ///   - directRoomLogEventCache: 尽力维护的本地私聊事件缓存统计，包含占用、查询和提交后写入状态。 默认 `nil`，表示未提供。
    ///   - preparedGroupEventPageCache: 共享群事件编码页缓存的条目数、字节数和查询结果，不导出缓存键。 默认 `nil`，表示未提供。
    ///   - livePresenceRenewals: 心跳租约续期的合并与数据库批处理统计，不使用连接或用户标识作为标签。 默认 `nil`，表示未提供。
    public init(
        databaseWork: V2DatabaseWorkAdmissionSnapshot,
        databasePools: V2DatabasePoolTopologySnapshot,
        syncWake: V2SyncWakeCoalescerSnapshot,
        readReceiptBatching: V2ReadReceiptBatchMetricsSnapshot? = nil,
        directRoomLogAppendStages: V2DirectRoomLogAppendStageMetricsSnapshot? = nil,
        gatewayEventLoopLag: V2RuntimeLatencyHistogramSnapshot? = nil,
        directSendPolicy: V2DirectSendPolicyCacheSnapshot? = nil,
        directRoomLogEventCache: V2DirectRoomLogEventCacheSnapshot? = nil,
        preparedGroupEventPageCache: V2PreparedGroupEventPageCacheSnapshot? = nil,
        livePresenceRenewals: V2LivePresenceRenewalBatcherSnapshot? = nil,
        roomActors: V2RoomRuntimeMetricsSnapshot? = nil,
        sendOperationBatching: V2SendOperationBatchMetricsSnapshot? = nil,
        sendOperationOwnerBatching: V2SendOperationOwnerMetricsSnapshot? = nil,
        databaseLoans: V2DatabaseLoanMetricsSnapshot? = nil,
        gatewayMessageSend: V2GatewayMessageSendMetricsSnapshot? = nil,
        registryRecovery: V2RegistryRecoveryMetricsSnapshot? = nil,
        roomRecoveryBatches: V2RoomRecoveryBatchPressureSnapshot? = nil
    ) {
        self.roomRecoveryBatches = roomRecoveryBatches
        self.registryRecovery = registryRecovery
        self.gatewayMessageSend = gatewayMessageSend
        self.databaseLoans = databaseLoans
        self.databaseWork = databaseWork
        self.databasePools = databasePools
        self.syncWake = syncWake
        self.readReceiptBatching = readReceiptBatching
        self.directRoomLogAppendStages = directRoomLogAppendStages
        self.gatewayEventLoopLag = gatewayEventLoopLag
        self.directSendPolicy = directSendPolicy
        self.directRoomLogEventCache = directRoomLogEventCache
        self.preparedGroupEventPageCache = preparedGroupEventPageCache
        self.livePresenceRenewals = livePresenceRenewals
        self.roomActors = roomActors
        self.sendOperationBatching = sendOperationBatching
        self.sendOperationOwnerBatching = sendOperationOwnerBatching
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

/// Fixed TCP admission reasons; never contains connection or business identities.
public enum V2GatewayMessageSendRejectionReason: String, CaseIterable, Sendable {
    case connectionCount = "connection_count"
    case connectionBytes = "connection_bytes"
    case processBytes = "process_bytes"
}

/// Shared process reservation ownership, including tasks waiting for actual settlement.
public struct V2GatewayMessageSendMetricsSnapshot: Equatable, Sendable {
    public let inFlightRequests: Int
    public let reservedBytes: Int
    public let peakInFlightRequests: Int
    public let peakReservedBytes: Int
    public let rejections: [V2GatewayMessageSendRejectionReason: UInt64]

    public init(inFlightRequests: Int = 0, reservedBytes: Int = 0,
                peakInFlightRequests: Int = 0, peakReservedBytes: Int = 0,
                rejections: [V2GatewayMessageSendRejectionReason: UInt64] = [:]) {
        self.inFlightRequests = inFlightRequests
        self.reservedBytes = reservedBytes
        self.peakInFlightRequests = peakInFlightRequests
        self.peakReservedBytes = peakReservedBytes
        self.rejections = Dictionary(uniqueKeysWithValues:
            V2GatewayMessageSendRejectionReason.allCases.map { ($0, rejections[$0, default: 0]) })
    }
}

public enum V2RegistryRecoveryScopeKind: String, CaseIterable, Sendable {
    case account, room, presence, typing
}
public enum V2RegistryRecoveryStage: String, CaseIterable, Sendable {
    case desired, awaitingRetention = "awaiting_retention", queued, actual
    case actualScopes = "actual_scopes"
    case authorizationReturns = "authorization_returns"
    case interestActivation = "interest_activation"
    case inlineRetention = "inline_retention"
    case outboundRetention = "outbound_retention"
    case authorization, retention, coverageWrite = "coverage_write"
}
public enum V2RegistryRecoveryReason: String, CaseIterable, Sendable {
    case initial, recheck, newHead = "new_head", coverageRecovery = "coverage_recovery"
}
public struct V2RegistryRecoveryStageSnapshot: Equatable, Sendable {
    public var count: Int
    public var oldestMilliseconds: Double
    public init(count: Int = 0, oldestMilliseconds: Double = 0) {
        self.count = count; self.oldestMilliseconds = oldestMilliseconds
    }
}
/// Root ownership and actual provider query attempts are distinct from scope counts.
public enum V2RecoveryAttemptStage: String, CaseIterable, Sendable {
    case interestActivation = "interest_activation"
    case authorizationQuery = "authorization_query"
    case queryRoot = "query_root"
    case control
    public var unit: String {
        switch self {
        case .authorizationQuery: "query_attempts"
        case .interestActivation, .queryRoot, .control: "root_tasks"
        }
    }
}
/// Retired streams remain owned until their actual recovery writer drains.
public enum V2RetiredRecoveryWriterStage: String, CaseIterable, Sendable {
    case retainedStreams = "retained_streams"
    case actualDrains = "actual_drains"
    public var unit: String {
        switch self {
        case .retainedStreams: "streams"
        case .actualDrains: "worker_tasks"
        }
    }
}
/// Presence observation work has different units from recovery scope gauges.
public enum V2PresenceObservationStage: String, CaseIterable, Sendable {
    case queuedKeys = "queued_keys", actualQueries = "actual_queries"
    case resultPositions = "result_positions"
    case resultTickets = "result_tickets", settlingTickets = "settling_tickets"
    case retiredTickets = "retired_tickets"
    case ownedJobs = "owned_jobs", waiters
    public var unit: String {
        switch self {
        case .queuedKeys: "request_keys"
        case .actualQueries: "query_batches"
        case .resultPositions: "result_keys"
        case .resultTickets, .settlingTickets, .retiredTickets: "target_tickets"
        case .ownedJobs: "batch_jobs"
        case .waiters: "waiters"
        }
    }
}
/// Mutually exclusive positions in the recovery admission ledger. Prepared
/// proofs still queued for dispatch occupy queued; they are not another component.
public enum V2RecoveryPositionStage: String, CaseIterable, Sendable {
    case queued
    case authorizationReturns = "authorization_returns"
    case selectedHandoff = "selected_handoff"
    case outbound
}
public struct V2RecoveryPositionLedgerSnapshot: Equatable, Sendable {
    public var capacity: Int
    public var stages: [V2RecoveryPositionStage: V2RegistryRecoveryStageSnapshot]
    public var occupied: Int { stages.values.reduce(0) { $0 + $1.count } }
    public var oldestMilliseconds: Double { stages.values.map(\.oldestMilliseconds).max() ?? 0 }
    public init(capacity: Int = 1024,
                stages: [V2RecoveryPositionStage: V2RegistryRecoveryStageSnapshot] = [:]) {
        self.capacity = capacity; self.stages = stages
    }
}

/// Completed monotonic timing observations, independent of ownership gauges.
public enum V2RecoverySchedulingPhase: String, CaseIterable, Sendable {
    case pumpPass = "pump_pass"
    case shortOffer = "short_offer"
    case interestProvider = "interest_provider"
    case queryProvider = "query_provider"
    case controlCohort = "control_cohort"
}
public enum V2RecoverySchedulingScan: String, CaseIterable, Sendable {
    case desired, queued
}
public struct V2RecoverySchedulingTimingSnapshot: Equatable, Sendable {
    public var count: UInt64
    public var totalMilliseconds: Double
    public var maxMilliseconds: Double
    public init(count: UInt64 = 0, totalMilliseconds: Double = 0, maxMilliseconds: Double = 0) {
        self.count = count; self.totalMilliseconds = totalMilliseconds; self.maxMilliseconds = maxMilliseconds
    }
}
/// Counts failed Ready checks, not distinct operations. A retried attempt may
/// fail multiple checks; labels contain no connection, scope or room identity.
public enum V2RecoveryReadyRejectionReason: String, CaseIterable, Sendable {
    case permissionExpired = "permission_expired"
    case permissionMissing = "permission_missing"
    case generationInvalid = "generation_invalid"
    case headUnsatisfied = "head_unsatisfied"
    case coverageChanged = "coverage_changed"
    case closed
    case recovering
    case enqueueRefused = "enqueue_refused"
}
public struct V2RecoverySchedulingSnapshot: Equatable, Sendable {
    public var timings: [V2RecoverySchedulingPhase: V2RecoverySchedulingTimingSnapshot]
    public var scans: [V2RecoverySchedulingScan: UInt64]
    public var readyRejections: [V2RecoveryReadyRejectionReason: UInt64]
    public init(timings: [V2RecoverySchedulingPhase: V2RecoverySchedulingTimingSnapshot] = [:],
                scans: [V2RecoverySchedulingScan: UInt64] = [:],
                readyRejections: [V2RecoveryReadyRejectionReason: UInt64] = [:]) {
        self.timings = timings; self.scans = scans; self.readyRejections = readyRejections
    }
}

/// Scope stage gauges overlap. Actual and actualScopes alias the same root-owned scopes.
/// Outbound ownership after handoff is reported separately; root tasks and provider queries
/// have separate attempt gauges. Aliases and overlapping phases must not be added together.
/// These are Registry scopes, not Coordinator partition jobs or client-applied cursors.
public struct V2RegistryRecoveryMetricsSnapshot: Equatable, Sendable {
    public var stages: [V2RegistryRecoveryScopeKind: [V2RegistryRecoveryStage: V2RegistryRecoveryStageSnapshot]]
    public var reasons: [V2RegistryRecoveryScopeKind: [V2RegistryRecoveryReason: Int]]
    public var duplicateRetained: [V2RegistryRecoveryScopeKind: UInt64]
    public var actualReasons: [V2RegistryRecoveryScopeKind: [V2RegistryRecoveryReason: Int]]
    public var presenceObservationStages: [V2PresenceObservationStage: V2RegistryRecoveryStageSnapshot]
    public var recoveryAttemptStages: [V2RecoveryAttemptStage: V2RegistryRecoveryStageSnapshot]
    public var retiredRecoveryWriterStages: [V2RetiredRecoveryWriterStage: V2RegistryRecoveryStageSnapshot]
    public var positionLedger: V2RecoveryPositionLedgerSnapshot
    public var schedulingTelemetry: V2RecoverySchedulingSnapshot
    public init(stages: [V2RegistryRecoveryScopeKind: [V2RegistryRecoveryStage: V2RegistryRecoveryStageSnapshot]] = [:],
                reasons: [V2RegistryRecoveryScopeKind: [V2RegistryRecoveryReason: Int]] = [:],
                duplicateRetained: [V2RegistryRecoveryScopeKind: UInt64] = [:],
                actualReasons: [V2RegistryRecoveryScopeKind: [V2RegistryRecoveryReason: Int]] = [:],
                presenceObservationStages: [V2PresenceObservationStage: V2RegistryRecoveryStageSnapshot] = [:],
                recoveryAttemptStages: [V2RecoveryAttemptStage: V2RegistryRecoveryStageSnapshot] = [:],
                retiredRecoveryWriterStages: [V2RetiredRecoveryWriterStage: V2RegistryRecoveryStageSnapshot] = [:],
                positionLedger: V2RecoveryPositionLedgerSnapshot = .init(),
                schedulingTelemetry: V2RecoverySchedulingSnapshot = .init()) {
        self.stages = stages; self.reasons = reasons; self.duplicateRetained = duplicateRetained
        self.actualReasons = actualReasons
        self.presenceObservationStages = presenceObservationStages
        self.recoveryAttemptStages = recoveryAttemptStages
        self.retiredRecoveryWriterStages = retiredRecoveryWriterStages
        self.positionLedger = positionLedger
        self.schedulingTelemetry = schedulingTelemetry
    }
}
