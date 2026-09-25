import Foundation
import IMV2Compression
import IMV2Core

public protocol V2RuntimeEnvironment: Sendable {
    func value(for key: String) -> String?
}

public enum V2GatewayRuntimeConfigurationError: Error, Equatable, Sendable {
    case missing(String)
    case invalid(String)
}

/// 控制已接受或已编辑的消息内容是否进入持久审核流水线。
///
/// 关闭该通道不会改动既有任务，
/// 且刻意不会回填在关闭期间产生的消息。
public enum V2ContentReviewMode: String, Equatable, Sendable {
    case enabled
    case disabled

    var enqueuesJobs: Bool { self == .enabled }
}

/// 指标刻意只绑定到 loopback 监听器。
///
/// 采集器必须运行在同一主机或 Pod 命名空间内；
/// 禁止通过公开的实时或媒体监听器暴露这些运行细节。
public struct V2MetricsListenerConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) throws {
        guard host == "127.0.0.1" || host == "::1", (1...65_535).contains(port) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_METRICS_HOST/IM_V2_METRICS_PORT")
        }
        self.host = host
        self.port = port
    }
}

/// 仅用于部署的「逻辑桶到物理数据库」映射。
///
/// 它在启动时解析，绝不写入扇出记录、日志或 API 响应。
/// 省略该 JSON 会让单桶部署保持显式。
public struct V2UserShardStorageConfiguration: Codable, Equatable, Sendable {
    public let bucket: String
    public let databaseURL: String
    public let schema: String

    public init(bucket: String, databaseURL: String, schema: String = "im_v2") throws {
        let normalizedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBucket.isEmpty, !normalizedURL.isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON") }
        self.bucket = normalizedBucket
        self.databaseURL = normalizedURL
        self.schema = schema
    }

    enum CodingKeys: String, CodingKey { case bucket; case databaseURL = "database_url"; case schema }

    /// 解码网关与运维进程共享的、仅用于部署的注册表。
    ///
    /// 调用方仍需自行负责要求与其角色相符的本地桶。
    ///
    /// - Parameter rawValue: 注册表 JSON 文本。
    /// - Returns: 解码出的存储配置列表。
    /// - Throws: JSON 非法、为空或存在重复桶/地址时抛出。
    public static func parseRegistryJSON(_ rawValue: String) throws -> [Self] {
        guard let data = rawValue.data(using: .utf8) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON")
        }
        let decoded: [Self]
        do { decoded = try JSONDecoder().decode([Self].self, from: data) }
        catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON") }
        guard !decoded.isEmpty,
              Set(decoded.map(\.bucket)).count == decoded.count,
              Set(decoded.map { "\($0.databaseURL)|\($0.schema)" }).count == decoded.count
        else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON") }
        return decoded
    }
}

/// 仅用于部署的房间写入物理归属注册表。
///
/// 一行的持久 `room_shard_id` 会选中其中一项；
/// 该注册表必须覆盖本网关能够创建或服务的每个分片。
/// 在分阶段灰度期间，多个逻辑分片可以刻意共享同一个数据库，
/// 因此重复的地址是合法的，而重复的分片 ID 不是。
public struct V2RoomShardStorageConfiguration: Codable, Equatable, Sendable {
    public let shardID: String
    public let databaseURL: String
    public let schema: String

    public init(shardID: String, databaseURL: String, schema: String = "im_v2") throws {
        let normalizedShard = shardID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedShard.isEmpty, !normalizedURL.isEmpty,
              // Room-owner stores currently qualify every canonical table as
              // `im_v2.*`. Accepting another schema would pass readiness but
              // silently execute hot-path SQL against the wrong location.
              // Keep the topology honest until those stores receive the same
              // schema-aware SQL boundary already used by user shards.
              schema == "im_v2"
        else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON") }
        self.shardID = normalizedShard
        self.databaseURL = normalizedURL
        self.schema = schema
    }

    enum CodingKeys: String, CodingKey {
        case shardID = "shard_id"
        case databaseURL = "database_url"
        case schema
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            shardID: container.decode(String.self, forKey: .shardID),
            databaseURL: container.decode(String.self, forKey: .databaseURL),
            schema: container.decodeIfPresent(String.self, forKey: .schema) ?? "im_v2"
        )
    }

    public static func parseRegistryJSON(_ rawValue: String) throws -> [Self] {
        guard let data = rawValue.data(using: .utf8) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON")
        }
        let decoded: [Self]
        do { decoded = try JSONDecoder().decode([Self].self, from: data) }
        catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON") }
        guard !decoded.isEmpty, Set(decoded.map(\.shardID)).count == decoded.count else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON")
        }
        return decoded
    }
}

/// 推送运行时配置。
///
/// 在每组 APNs 密钥与主题都显式配置之前，推送保持关闭。
/// 端点加密密钥只在真正为提供方请求解析端点明文的那一个进程中是必需的。
public enum V2PushRuntimeConfiguration: Sendable {
    case disabled
    case apns(V2APNSRuntimeConfiguration)
}

/// 混合前台唤醒路由配置。
///
/// 对单个网关它是可选的；
/// 但当活跃观看者可能连接在其他副本上时，必须使用共享 broker。
public enum V2GroupEventWakeRuntimeConfiguration: Sendable {
    case localOnly
    case nats(V2NATSGroupEventWakeConfiguration)
}

public struct V2APNSRuntimeConfiguration: Sendable {
    public let teamID: String
    public let keyID: String
    public let privateKeyRawBase64: String
    public let topic: String
    public let endpointEnvelopeKey: V2PushEndpointEnvelopeKey

    init(
        teamID: String,
        keyID: String,
        privateKeyRawBase64: String,
        topic: String,
        endpointEnvelopeKey: V2PushEndpointEnvelopeKey
    ) {
        self.teamID = teamID
        self.keyID = keyID
        self.privateKeyRawBase64 = privateKeyRawBase64
        self.topic = topic
        self.endpointEnvelopeKey = endpointEnvelopeKey
    }
}

/// 所有会影响生产行为的 V2 取值都是显式的。
///
/// 对凭据、帧/队列上限或容量策略刻意不提供开发默认值：
/// 一个不完整的部署必须在打开公开端口之前失败。
public struct V2GatewayRuntimeConfiguration: Sendable {
    /// 窗口模式下读者不再钉住日志下界的默认宽限秒数（30 天）。
    ///
    /// 只在部署显式选择 `window` 模式时生效；默认的 `permanent` 模式不裁剪任何历史。
    public static let defaultRoomLogRetentionWindowSeconds: TimeInterval = 30 * 24 * 60 * 60

    public let databaseURL: String
    public let databasePolicy: V2PostgresRuntimePolicy
    public let databaseWorkloadPoolBudget: V2PostgresWorkloadPoolBudget
    public let databaseWorkloadPoolIsolationEnabled: Bool
    /// Independent authoritative direct-send pool; matches foreground per-loop capacity.
    public let directSendControlConnectionsPerEventLoop: Int
    public let directAuthorizationResolutionDatabaseURLs: [String]
    /// 每个事件循环允许的数据库连接数。
    ///
    /// Fluent 默认每个事件循环只用一个 PostgreSQL 连接。
    /// 网关在同一进程中同时运行前台命令与持久扇出，
    /// 因此部署必须显式设定该值，而不能放任一次扇出事务在某个事件循环上饿死同步或命令工作。
    public var databaseMaxConnectionsPerEventLoop: Int {
        databasePolicy.maximumConnectionsPerEventLoop
    }
    public let tls: V2TLSListenerConfiguration
    public let accessTokenKey: V2AccessTokenHMACKey
    public let capacityProfile: V2CapacityProfile
    public let messageLimits: V2MessageCommandLimits
    public let frameLimits: V2FrameLimits
    public let maximumProtobufMessageDepth: Int
    public let frameCompression: V2NegotiatedFrameCompression?
    public let frameCompressionThresholdBytes: Int
    public let frameCompressionMaximumExpansionRatio: Int
    public let foregroundGroupBatchMaximumEvents: Int
    public let foregroundGroupPendingMaximumEventsPerRoom: Int
    public let foregroundGroupBatchDelayMilliseconds: Int
    public let foregroundGroupBatchExtensionDelayMilliseconds: Int
    public let foregroundGroupBatchExtensionMinimumEvents: Int
    /// 群组已读游标仍各自幂等且持久，但相互独立的操作可以共享同一个有界的 PostgreSQL 事务。
    ///
    /// 这些部署控制项把延迟与吞吐之间的取舍显式化，
    /// 而不是把某个基准测试专用值硬编码进 `main`。
    public let readReceiptBatchSize: Int
    public let readReceiptBatchMaximumDelayMilliseconds: Int
    public let readReceiptBatchMaximumInFlightBatches: Int
    public let readReceiptBatchMaximumPendingRequests: Int
    public let preparedGroupEventPageCacheMaximumEntries: Int
    public let preparedGroupEventPageCacheMaximumBytes: Int
    public let preparedGroupEventPageCacheShardCount: Int
    public let connectionLimits: V2ConnectionLimits
    /// 进程本地准入的硬上限，包含尚未认证的 TLS 套接字。
    ///
    /// 它为每连接队列、actor 与 TLS 状态设界。
    public let maximumConnections: Int
    /// TLS 监听器请求的内核监听队列长度。
    ///
    /// 显式设置可避免 SwiftNIO 那个刻意保守的默认值 128——
    /// 对于高在线 IM 网关上的集中重连，128 太小。
    /// 实际生效值仍受宿主机的 somaxconn 限制。
    public let listenBacklog: Int
    /// 单次监听器可读就绪事件中最多接受的套接字数。
    ///
    /// SwiftNIO 默认是 4，刻意保守，
    /// 但会在重连期间让一个较长的监听队列排空得过慢。
    public let acceptBatchSize: Int
    public let authenticatedConnectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy
    public let livePresenceRenewalBatchSize: Int
    public let livePresenceRenewalMaximumDelayMilliseconds: Int
    public let commandRateLimitPolicy: V2GatewayCommandRateLimitPolicy
    public let maximumQueuedInboundBytes: Int
    /// 与字节上限互补，使一串单字节 TCP 分片不会制造出无界数量的排队 `Data` 分配。
    public let maximumQueuedInboundChunks: Int
    /// 从接受通道到会话完成认证的绝对时限。
    ///
    /// 与空闲超时不同，它无法通过挤牙膏式地发送字节来延长。
    public let authenticationTimeoutMilliseconds: Int
    public let idleTimeoutMilliseconds: Int
    /// 公开监听器关闭之后允许的最大协作排空时间。
    ///
    /// 硬性截止时间可防止某个未观察到取消的数据库操作超出容器终止宽限期。
    public let shutdownGraceMilliseconds: Int
    public let capabilityProfile: String
    public let workerBatchSize: Int
    public let workerPollIntervalMilliseconds: Int
    /// 每个唯一用户 schema 各自的独立投影认领循环数量。
    ///
    /// 多个 schema 可以共享同一个物理数据库连接池；
    /// 启动时的连接预算会为每个 schema 的工作者及其快照构建器计入开销。
    /// 检查点的 `SKIP LOCKED` 围栏为每个用户保持一条有序流。
    public let userProjectionConcurrency: Int
    /// 繁忙的投影事务会背靠背执行，
    /// 但这两个独立预算会在持续积压时强制协作式地让出执行器。
    public let userProjectionMaximumConsecutiveBusyPasses: Int
    public let userProjectionBusyDrainBudgetMilliseconds: Int
    /// 进程本地数据库准入上限会在请求花费漫长得多的 Fluent 连接池超时等待槽位之前就拒绝过载。
    ///
    /// 持久消息写入、控制面写入与交互式读取各自独立预留容量。
    /// 它们之和会针对同一个物理前台连接池进行校验；这是准入隔离，而不是额外的数据库连接。
    public let foregroundWriteDatabaseWorkLimit: Int
    public let foregroundControlWriteDatabaseWorkLimit: Int
    public let interactiveReadDatabaseWorkLimit: Int
    public let syncDatabaseWorkLimit: Int
    public let foregroundWriteDatabaseWorkMaximumQueued: Int
    public let foregroundControlWriteDatabaseWorkMaximumQueued: Int
    public let interactiveReadDatabaseWorkMaximumQueued: Int
    public let syncDatabaseWorkMaximumQueued: Int
    public let databaseWorkAdmissionTimeoutMilliseconds: Int
    public let databaseWorkAdmissionEnabled: Bool
    /// 尽力而为的同步提示按用户合并；游标拉取仍是权威恢复机制。
    public let syncWakeCoalescingMilliseconds: Int
    public let syncWakeMaximumPendingUsers: Int
    public let syncWakeDeliveryConcurrency: Int
    public let syncWakeCoalescingEnabled: Bool
    /// 成功命令日志独立于完整的 Prometheus 记账进行采样。
    ///
    /// 慢命令、被拒绝命令与失败命令的日志会为每种结果保留一小的突发量，
    /// 但整体有界，使过载不会把 stdout 格式化变成正反馈循环。
    public let commandSuccessLogSamplePermille: Int
    public let commandSlowLogThresholdMilliseconds: Int
    public let commandDiagnosticLogMaximumPerSecond: Int
    public let durableRetryPolicy: V2DurableRetryPolicy
    public let groupEventWake: V2GroupEventWakeRuntimeConfiguration
    /// 持久混合群组元数据唤醒的节律。
    ///
    /// 完整前台载荷走各自独立的低延迟路径；
    /// 这个合并发件箱是恢复提示，刻意落后于该路径，
    /// 以免让每个活跃客户端都去修复一次短暂的跨 Gateway 发布缺口。
    public let groupEventWakePollIntervalMilliseconds: Int
    public let maintenancePollIntervalMilliseconds: Int
    /// 高吞吐的保留表使用单独的积压排空循环。
    ///
    /// 繁忙轮次会在这些协作预算内背靠背运行；
    /// 空轮次则回退到独立配置的闲时轮询间隔。
    public let backlogMaintenanceIdlePollIntervalMilliseconds: Int
    public let backlogMaintenanceMaximumConsecutiveBusyPasses: Int
    public let backlogMaintenanceBusyDrainBudgetMilliseconds: Int
    public let mediaWithdrawnRetentionSeconds: Int
    /// 服务端重放结果的保留时长会超过第一方客户端的重试窗口。
    ///
    /// 部署可以延长保留时间，但绝不能缩短这道协议围栏，
    /// 否则一个延迟的客户端可能会执行一条已完成的命令。
    public let idempotencyRetentionSeconds: Int
    /// 房间日志的保留模式。默认 `permanent`：计入全部历史读者，与既有行为一致，
    /// 也就是不裁剪任何历史。
    public let roomLogRetentionMode: V2RoomLogRetentionMode
    /// 窗口模式下读者不再钉住日志下界的宽限秒数；永久模式不使用该值。
    public let roomLogRetentionWindowSeconds: TimeInterval
    /// 仅用于 direct-room-log 部署的分片额度预扣优化。
    ///
    /// 取零表示保留精确的每消息分片准入；每房间准入始终有效。
    ///
    /// 正值是一个显式的、仅用于 direct-room-log 的预扣命令额度批大小；
    /// 它绝不会由客户端请求开启。
    public let directRoomLogShardAdmissionCreditBatchSize: Int
    /// 取零表示为每条已接受单聊命令保留一次精确的房间准入更新。
    ///
    /// 正值会以有界批次预扣既有的每房间命令窗口，
    /// 在保留房间上限的同时，避免对每个符合条件的微批条目都做一次 `room_admission` 锁/更新。
    public let directRoomLogRoomAdmissionCreditBatchSize: Int
    /// 取零表示单聊房间日志追加保持每条命令一个事务。
    ///
    /// 正值只开启那条刻意收窄的、有序的普通单聊消息微批；
    /// 不符合条件的命令会透明地走既有的单命令写入路径。
    public let directRoomLogAppendBatchSize: Int
    /// 可并发执行的追加微批数量上限。
    ///
    /// 默认值保留原先的八批部署行为；
    /// 正值覆盖是一次经过明确测量的吞吐实验，绝不是客户端可控的并发设置。
    public let directRoomLogAppendBatchMaximumInFlightBatches: Int
    /// 在分配给持久微批之前最多保留的单聊追加请求数。
    ///
    /// 它刻意独立于数据库工作队列：一个排队的数据库操作可能代表许多追加请求，
    /// 因此把操作数当作请求数复用会过早拒绝本应有界的流量突发。
    public let directRoomLogAppendMaximumPendingRequests: Int
    /// 稳定的、按房间建键的调度通道数。
    ///
    /// 在途与待处理预算在各通道之间共享，而不是乘以该值。
    public let directRoomLogAppendLaneCount: Int
    /// 追加微批在服务端额外等待的最长时间。
    ///
    /// 只有当 `directRoomLogAppendBatchSize` 为正时才有意义。
    public let directRoomLogAppendBatchMaximumDelayMilliseconds: Int
    /// 追加微批的可选持续到达策略。
    ///
    /// 基础延迟仍为交互式默认值；
    /// 只有当有界检测器在其配置的单调观察窗口内看到足够多的到达之后，才会选用这个更长的上限。
    public let directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds: Int?
    public let directRoomLogAppendBatchHighActivityMinimumRequests: Int?
    public let directRoomLogAppendBatchHighActivityWindowMilliseconds: Int?
    /// 稳定单聊策略快照的有界 LRU 容量。
    ///
    /// 该缓存只是加速提示；每次 PostgreSQL 追加仍保留持久的修订围栏。
    public let directSendPolicyCacheMaximumEntries: Int
    /// 条件式房间日志追加快照的有界 LRU 容量。
    ///
    /// 这些条目只携带受修订围栏保护的提示；
    /// 对每条已接受消息而言，PostgreSQL 仍是游标、成员与授权的权威。
    public let directRoomLogFastAppendCacheMaximumEntries: Int
    /// 受修订围栏保护的条件式追加提示的存活时长。
    ///
    /// 过期条目只会让 PostgreSQL 拒绝该快速尝试并回退；它永远无法授权消息，
    /// 因此该时长可以安全地覆盖稀疏活跃房间的再次访问间隔，同时仍受 LRU 容量约束。
    public let directRoomLogFastAppendCacheLifetimeSeconds: Int
    /// 取零会关闭进程本地单聊事件缓存。
    ///
    /// 缓存条目永远不是授权状态，在被提供出去之前总会先经 PostgreSQL 校验。
    public let directRoomLogEventCacheMaximumEntries: Int
    public let directRoomLogEventCacheMaximumBytes: Int
    public let directRoomLogEventCacheMaximumEntriesPerRoom: Int
    public let directRoomLogEventCacheShardCount: Int
    public let directRoomLogEventCacheMaximumPendingWrites: Int
    /// 未被引用的不可变修订在该宽限期内仍可恢复。
    ///
    /// 默认是七天；部署可以独立于用户投影的 MVCC 保留策略单独延长它。
    public let messageProjectionStateRetentionSeconds: Int
    public let metrics: V2MetricsListenerConfiguration
    public let metricsMinimumRefreshIntervalMilliseconds: Int
    public let metricsRefreshTimeoutMilliseconds: Int
    public let gatewayNodeID: String
    /// 用于进程本地唤醒路由的显式部署拓扑围栏。
    ///
    /// 同一逻辑部署的所有副本必须收到相同的值。
    public let gatewayReplicaCount: Int
    public let userShardRoute: V2UserShardRoute
    public let userShardStorage: [V2UserShardStorageConfiguration]
    /// 房间写入分片的物理归属位置。
    ///
    /// 这些是部署事实；既有房间保留其已持久化的逻辑归属。
    public let roomShardStorage: [V2RoomShardStorageConfiguration]
    public let directRoomShardID: String
    /// 单聊房间分片路由器。
    ///
    /// 它在进程启动时解析，使非法的房间归属路由在就绪阶段就失败，
    /// 而不是等到首个建群/建单聊请求才暴露。
    public let directRoomShardRouter: V2DirectRoomShardRouter
    /// 新建群组的候选归属。
    ///
    /// 既有房间始终使用其持久的控制面路由，绝不会根据这份部署列表重新哈希。
    public let groupRoomShardIDs: [String]
    /// 供那些其路由存储会忽略所提议归属的服务 API 使用的兼容值。
    ///
    /// 单归属部署保留其完全相同的行为。
    public var groupRoomShardID: String { groupRoomShardIDs[0] }
    public let strangerMessagePolicy: V2StrangerMessagePolicy
    public let push: V2PushRuntimeConfiguration
    /// 该模式控制持久任务的创建与工作者的启动。
    ///
    /// 运行工作者还需要一个单独认证的审核主体。
    /// 词表属于部署策略而非客户端输入；更丰富的 AI/OCR 提供方使用同一个工作者边界。
    public let contentReviewMode: V2ContentReviewMode
    public let contentReviewSafetyActorUserID: UserID?
    public let contentReviewViolationTerms: [String]
    public let contentReviewEscalationTerms: [String]

    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try Self.required("IM_V2_DATABASE_URL", environment: environment)
        databasePolicy = try .init(environment: environment)
        databaseWorkloadPoolBudget = try .init(environment: environment)
        databaseWorkloadPoolIsolationEnabled = try Self.explicitBoolean(
            "IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED", environment: environment
        )
        directSendControlConnectionsPerEventLoop = databaseWorkloadPoolIsolationEnabled
            ? databaseWorkloadPoolBudget.foregroundConnectionsPerEventLoop
            : databasePolicy.maximumConnectionsPerEventLoop
        tls = try .init(
            host: try Self.required("IM_V2_TLS_HOST", environment: environment),
            port: try Self.integer("IM_V2_TLS_PORT", environment: environment),
            certificateChainPath: try Self.required("IM_V2_TLS_CERTIFICATE_CHAIN_PATH", environment: environment),
            privateKeyPath: try Self.required("IM_V2_TLS_PRIVATE_KEY_PATH", environment: environment)
        )
        accessTokenKey = try .init(base64Encoded: try Self.required("IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64", environment: environment))
        capabilityProfile = try Self.required("IM_V2_CAPABILITY_PROFILE", environment: environment)
        messageLimits = try .init(maxUTF8Bytes: try Self.integer("IM_V2_MAX_MESSAGE_UTF8_BYTES", environment: environment))
        frameLimits = try .init(maximumPayloadBytes: try Self.integer("IM_V2_MAX_FRAME_BYTES", environment: environment), acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        maximumProtobufMessageDepth = try Self.positive("IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH", environment: environment)
        switch Self.optional("IM_V2_FRAME_COMPRESSION", environment: environment)?.lowercased() {
        case nil, "none", "disabled": frameCompression = nil
        case "zlib": frameCompression = .zlib
        default: throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_FRAME_COMPRESSION")
        }
        frameCompressionThresholdBytes = try Self.nonNegativeWithDefault(
            "IM_V2_FRAME_COMPRESSION_THRESHOLD_BYTES",
            defaultValue: V2ServerProtobufFrameCodec.defaultCompressionThresholdBytes,
            maximum: frameLimits.maximumPayloadBytes,
            environment: environment
        )
        let parsedMaximumExpansionRatio = try Self.nonNegativeWithDefault(
            "IM_V2_FRAME_COMPRESSION_MAX_EXPANSION_RATIO",
            defaultValue: V2ZlibFrameCompression.defaultMaximumExpansionRatio,
            maximum: 1_024,
            environment: environment
        )
        guard parsedMaximumExpansionRatio > 0 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_FRAME_COMPRESSION_MAX_EXPANSION_RATIO")
        }
        frameCompressionMaximumExpansionRatio = parsedMaximumExpansionRatio
        foregroundGroupBatchMaximumEvents = try Self.nonNegativeWithDefault(
            "IM_V2_FOREGROUND_GROUP_BATCH_MAX_EVENTS",
            defaultValue: 64,
            maximum: 1_024,
            environment: environment
        )
        foregroundGroupPendingMaximumEventsPerRoom = try Self.nonNegativeWithDefault(
            "IM_V2_FOREGROUND_GROUP_PENDING_MAX_EVENTS_PER_ROOM",
            defaultValue: 1_024,
            maximum: 65_536,
            environment: environment
        )
        foregroundGroupBatchDelayMilliseconds = try Self.nonNegativeWithDefault(
            "IM_V2_FOREGROUND_GROUP_BATCH_DELAY_MS",
            defaultValue: 10,
            maximum: 100,
            environment: environment
        )
        foregroundGroupBatchExtensionDelayMilliseconds = try Self.nonNegativeWithDefault(
            "IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_DELAY_MS",
            defaultValue: 10,
            maximum: 100,
            environment: environment
        )
        foregroundGroupBatchExtensionMinimumEvents = try Self.nonNegativeWithDefault(
            "IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_MIN_EVENTS",
            defaultValue: 8,
            maximum: 1_024,
            environment: environment
        )
        guard foregroundGroupBatchMaximumEvents > 0,
              foregroundGroupPendingMaximumEventsPerRoom
                >= foregroundGroupBatchMaximumEvents,
              foregroundGroupBatchExtensionMinimumEvents > 0,
              foregroundGroupBatchExtensionMinimumEvents
                <= foregroundGroupBatchMaximumEvents,
              foregroundGroupBatchDelayMilliseconds
                + foregroundGroupBatchExtensionDelayMilliseconds <= 100
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_FOREGROUND_GROUP_BATCH_MAX_EVENTS/IM_V2_FOREGROUND_GROUP_PENDING_MAX_EVENTS_PER_ROOM/IM_V2_FOREGROUND_GROUP_BATCH_DELAY_MS/IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_DELAY_MS/IM_V2_FOREGROUND_GROUP_BATCH_EXTENSION_MIN_EVENTS"
            )
        }
        preparedGroupEventPageCacheMaximumEntries = try Self.nonNegativeWithDefault(
            "IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_ENTRIES",
            defaultValue: 0,
            maximum: 1_000_000,
            environment: environment
        )
        preparedGroupEventPageCacheMaximumBytes = try Self.nonNegativeWithDefault(
            "IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_BYTES",
            defaultValue: 0,
            maximum: 2_147_483_648,
            environment: environment
        )
        preparedGroupEventPageCacheShardCount = try Self.nonNegativeWithDefault(
            "IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_SHARDS",
            defaultValue: 0,
            maximum: 64,
            environment: environment
        )
        let preparedCacheFields = [
            preparedGroupEventPageCacheMaximumEntries,
            preparedGroupEventPageCacheMaximumBytes,
            preparedGroupEventPageCacheShardCount,
        ]
        guard preparedCacheFields.allSatisfy({ $0 == 0 }) ||
                (preparedCacheFields.allSatisfy({ $0 > 0 }) &&
                 preparedGroupEventPageCacheShardCount <= preparedGroupEventPageCacheMaximumEntries &&
                 preparedGroupEventPageCacheShardCount <= preparedGroupEventPageCacheMaximumBytes)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_ENTRIES/IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_MAX_BYTES/IM_V2_PREPARED_GROUP_EVENT_PAGE_CACHE_SHARDS"
            )
        }
        connectionLimits = try .init(maximumInFlightRequests: try Self.integer("IM_V2_MAX_IN_FLIGHT_REQUESTS", environment: environment))
        maximumConnections = try Self.boundedPositive("IM_V2_MAX_CONNECTIONS", maximum: 1_000_000, environment: environment)
        listenBacklog = try Self.boundedPositive("IM_V2_LISTEN_BACKLOG", maximum: 1_000_000, environment: environment)
        acceptBatchSize = try Self.boundedPositive("IM_V2_ACCEPT_BATCH_SIZE", maximum: 4_096, environment: environment)
        let maximumConnectionsPerDevice = try Self.boundedPositive(
            "IM_V2_MAX_CONNECTIONS_PER_DEVICE", maximum: 64, environment: environment
        )
        let maximumConnectionsPerUser = try Self.boundedPositive(
            "IM_V2_MAX_CONNECTIONS_PER_USER", maximum: 1_024, environment: environment
        )
        guard maximumConnectionsPerUser >= maximumConnectionsPerDevice else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_MAX_CONNECTIONS_PER_DEVICE/IM_V2_MAX_CONNECTIONS_PER_USER"
            )
        }
        authenticatedConnectionAdmissionPolicy = .init(
            maximumConnectionsPerDevice: maximumConnectionsPerDevice,
            maximumConnectionsPerUser: maximumConnectionsPerUser
        )
        let parsedLivePresenceRenewalBatchSize = try Self.nonNegativeWithDefault(
            "IM_V2_LIVE_PRESENCE_RENEWAL_BATCH_SIZE",
            defaultValue: 256,
            maximum: 1_024,
            environment: environment
        )
        guard parsedLivePresenceRenewalBatchSize > 0 else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_LIVE_PRESENCE_RENEWAL_BATCH_SIZE"
            )
        }
        livePresenceRenewalBatchSize = parsedLivePresenceRenewalBatchSize
        livePresenceRenewalMaximumDelayMilliseconds = try Self.nonNegativeWithDefault(
            "IM_V2_LIVE_PRESENCE_RENEWAL_MAX_DELAY_MS",
            defaultValue: 2,
            maximum: 100,
            environment: environment
        )
        let deviceCommandsPerSecond = try Self.boundedPositive(
            "IM_V2_DEVICE_COMMANDS_PER_SECOND", maximum: 100_000, environment: environment
        )
        let deviceCommandBurst = try Self.boundedPositive(
            "IM_V2_DEVICE_COMMAND_BURST", maximum: 100_000, environment: environment
        )
        let userCommandsPerSecond = try Self.boundedPositive(
            "IM_V2_USER_COMMANDS_PER_SECOND", maximum: 1_000_000, environment: environment
        )
        let userCommandBurst = try Self.boundedPositive(
            "IM_V2_USER_COMMAND_BURST", maximum: 1_000_000, environment: environment
        )
        let maximumTrackedRateLimitIdentities = try Self.boundedPositive(
            "IM_V2_RATE_LIMIT_MAX_TRACKED_IDENTITIES", maximum: 2_000_000, environment: environment
        )
        let (minimumTrackedIdentities, trackedOverflow) = maximumConnections.multipliedReportingOverflow(by: 2)
        guard !trackedOverflow,
              userCommandsPerSecond >= deviceCommandsPerSecond,
              userCommandBurst >= deviceCommandBurst,
              maximumTrackedRateLimitIdentities >= minimumTrackedIdentities
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DEVICE_COMMANDS_PER_SECOND/IM_V2_DEVICE_COMMAND_BURST/IM_V2_USER_COMMANDS_PER_SECOND/IM_V2_USER_COMMAND_BURST/IM_V2_RATE_LIMIT_MAX_TRACKED_IDENTITIES"
            )
        }
        commandRateLimitPolicy = .init(
            deviceCommandsPerSecond: deviceCommandsPerSecond,
            deviceBurst: deviceCommandBurst,
            userCommandsPerSecond: userCommandsPerSecond,
            userBurst: userCommandBurst,
            maximumTrackedIdentities: maximumTrackedRateLimitIdentities
        )
        maximumQueuedInboundBytes = try Self.positive("IM_V2_MAX_QUEUED_INBOUND_BYTES", environment: environment)
        maximumQueuedInboundChunks = try Self.boundedPositive("IM_V2_MAX_QUEUED_INBOUND_CHUNKS", maximum: 4_096, environment: environment)
        authenticationTimeoutMilliseconds = try Self.boundedPositive("IM_V2_AUTHENTICATION_TIMEOUT_MS", maximum: 300_000, environment: environment)
        idleTimeoutMilliseconds = try Self.boundedPositive("IM_V2_IDLE_TIMEOUT_MS", maximum: V2GatewayConnectionTimeouts.maximumMilliseconds, environment: environment)
        shutdownGraceMilliseconds = try Self.nonNegativeWithDefault(
            "IM_V2_SHUTDOWN_GRACE_MS",
            defaultValue: 20_000,
            maximum: 120_000,
            environment: environment
        )
        guard shutdownGraceMilliseconds > 0 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_SHUTDOWN_GRACE_MS")
        }
        workerBatchSize = try Self.positive("IM_V2_WORKER_BATCH_SIZE", environment: environment)
        workerPollIntervalMilliseconds = try Self.positive("IM_V2_WORKER_POLL_INTERVAL_MS", environment: environment)
        userProjectionConcurrency = try Self.boundedPositive(
            "IM_V2_USER_PROJECTION_CONCURRENCY", maximum: 16, environment: environment
        )
        userProjectionMaximumConsecutiveBusyPasses = try Self.boundedPositive(
            "IM_V2_USER_PROJECTION_MAX_CONSECUTIVE_BUSY_PASSES",
            maximum: 1_024,
            environment: environment
        )
        userProjectionBusyDrainBudgetMilliseconds = try Self.boundedPositive(
            "IM_V2_USER_PROJECTION_BUSY_DRAIN_BUDGET_MS",
            maximum: 60_000,
            environment: environment
        )
        foregroundWriteDatabaseWorkLimit = try Self.boundedPositive(
            "IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT", maximum: 100_000, environment: environment
        )
        foregroundControlWriteDatabaseWorkLimit = try Self.nonNegativeWithDefault(
            "IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT",
            defaultValue: 0,
            maximum: 100_000,
            environment: environment
        )
        interactiveReadDatabaseWorkLimit = try Self.boundedPositive(
            "IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT", maximum: 100_000, environment: environment
        )
        syncDatabaseWorkLimit = try Self.boundedPositive(
            "IM_V2_SYNC_DATABASE_WORK_LIMIT", maximum: 100_000, environment: environment
        )
        foregroundWriteDatabaseWorkMaximumQueued = try Self.boundedPositive(
            "IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED",
            maximum: 1_000_000,
            environment: environment
        )
        foregroundControlWriteDatabaseWorkMaximumQueued = try Self.nonNegativeWithDefault(
            "IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_MAX_QUEUED",
            defaultValue: 0,
            maximum: 1_000_000,
            environment: environment
        )
        interactiveReadDatabaseWorkMaximumQueued = try Self.boundedPositive(
            "IM_V2_INTERACTIVE_READ_DATABASE_WORK_MAX_QUEUED",
            maximum: 1_000_000,
            environment: environment
        )
        syncDatabaseWorkMaximumQueued = try Self.boundedPositive(
            "IM_V2_SYNC_DATABASE_WORK_MAX_QUEUED",
            maximum: 1_000_000,
            environment: environment
        )
        let rawReadReceiptBatchSize = Self.optional(
            "IM_V2_READ_RECEIPT_BATCH_SIZE", environment: environment
        ) ?? "32"
        guard let parsedReadReceiptBatchSize = Int(rawReadReceiptBatchSize),
              (2 ... 128).contains(parsedReadReceiptBatchSize)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_READ_RECEIPT_BATCH_SIZE"
            )
        }
        readReceiptBatchSize = parsedReadReceiptBatchSize
        let rawReadReceiptBatchDelay = Self.optional(
            "IM_V2_READ_RECEIPT_BATCH_MAX_DELAY_MS", environment: environment
        ) ?? "2"
        guard let parsedReadReceiptBatchDelay = Int(rawReadReceiptBatchDelay),
              (1 ... 25).contains(parsedReadReceiptBatchDelay)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_READ_RECEIPT_BATCH_MAX_DELAY_MS"
            )
        }
        readReceiptBatchMaximumDelayMilliseconds = parsedReadReceiptBatchDelay
        let maximumReadReceiptBatchConcurrency = min(
            128,
            databasePolicy.eventLoopThreads * foregroundWriteDatabaseWorkLimit
        )
        let rawReadReceiptBatchMaximumInFlight = Self.optional(
            "IM_V2_READ_RECEIPT_BATCH_MAX_IN_FLIGHT", environment: environment
        )
        if let rawReadReceiptBatchMaximumInFlight {
            guard let parsed = Int(rawReadReceiptBatchMaximumInFlight),
                  (1 ... maximumReadReceiptBatchConcurrency).contains(parsed)
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_READ_RECEIPT_BATCH_MAX_IN_FLIGHT"
                )
            }
            readReceiptBatchMaximumInFlightBatches = parsed
        } else {
            readReceiptBatchMaximumInFlightBatches = min(
                8, maximumReadReceiptBatchConcurrency
            )
        }
        let rawReadReceiptBatchMaximumPending = Self.optional(
            "IM_V2_READ_RECEIPT_BATCH_MAX_PENDING_REQUESTS",
            environment: environment
        )
        if let rawReadReceiptBatchMaximumPending {
            guard let parsed = Int(rawReadReceiptBatchMaximumPending),
                  (readReceiptBatchSize ... 1_048_576).contains(parsed)
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_READ_RECEIPT_BATCH_MAX_PENDING_REQUESTS"
                )
            }
            readReceiptBatchMaximumPendingRequests = parsed
        } else {
            readReceiptBatchMaximumPendingRequests = max(
                readReceiptBatchSize,
                foregroundWriteDatabaseWorkMaximumQueued
            )
        }
        databaseWorkAdmissionTimeoutMilliseconds = try Self.boundedPositive(
            "IM_V2_DATABASE_WORK_ADMISSION_TIMEOUT_MS", maximum: 5_000, environment: environment
        )
        databaseWorkAdmissionEnabled = try Self.explicitBoolean(
            "IM_V2_DATABASE_WORK_ADMISSION_ENABLED", environment: environment
        )
        syncWakeCoalescingMilliseconds = try Self.boundedPositive(
            "IM_V2_SYNC_WAKE_COALESCING_MS", maximum: 1_000, environment: environment
        )
        syncWakeMaximumPendingUsers = try Self.boundedPositive(
            "IM_V2_SYNC_WAKE_MAX_PENDING_USERS", maximum: 1_000_000, environment: environment
        )
        syncWakeDeliveryConcurrency = try Self.boundedPositive(
            "IM_V2_SYNC_WAKE_DELIVERY_CONCURRENCY",
            maximum: 1_024,
            environment: environment
        )
        syncWakeCoalescingEnabled = try Self.explicitBoolean(
            "IM_V2_SYNC_WAKE_COALESCING_ENABLED", environment: environment
        )
        commandSuccessLogSamplePermille = try Self.integer(
            "IM_V2_COMMAND_SUCCESS_LOG_SAMPLE_PERMILLE", environment: environment
        )
        guard (0 ... 1_000).contains(commandSuccessLogSamplePermille) else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_COMMAND_SUCCESS_LOG_SAMPLE_PERMILLE"
            )
        }
        commandSlowLogThresholdMilliseconds = try Self.boundedPositive(
            "IM_V2_COMMAND_SLOW_LOG_THRESHOLD_MS", maximum: 300_000, environment: environment
        )
        commandDiagnosticLogMaximumPerSecond = try Self.boundedPositive(
            "IM_V2_COMMAND_DIAGNOSTIC_LOG_MAX_PER_SECOND",
            maximum: 10_000,
            environment: environment
        )
        // 房间日志保留窗口。默认永久 = 不裁剪，保持既有行为；切到 window 需要同时给出
        // 宽限秒数（默认 30 天），并明确知晓"超出窗口的读者返回时会看到历史不完整"。
        let rawRoomLogRetention = Self.optional(
            "IM_V2_ROOM_LOG_RETENTION_MODE", environment: environment
        )?.lowercased() ?? V2RoomLogRetentionMode.permanent.rawValue
        guard let parsedRoomLogRetention = V2RoomLogRetentionMode(rawValue: rawRoomLogRetention) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_LOG_RETENTION_MODE")
        }
        roomLogRetentionMode = parsedRoomLogRetention
        let rawRetentionWindow = Self.optional(
            "IM_V2_ROOM_LOG_RETENTION_WINDOW_SECONDS", environment: environment
        ) ?? "\(Int(V2GatewayRuntimeConfiguration.defaultRoomLogRetentionWindowSeconds))"
        guard let retentionWindow = TimeInterval(rawRetentionWindow), retentionWindow > 0 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_LOG_RETENTION_WINDOW_SECONDS")
        }
        roomLogRetentionWindowSeconds = retentionWindow
        guard environment.value(for: "IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE") == nil else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE"
            )
        }
        let rawDirectRoomLogShardCreditBatchSize = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE", environment: environment
        ) ?? "0"
        guard let parsedDirectRoomLogShardCreditBatchSize = Int(rawDirectRoomLogShardCreditBatchSize),
              (0 ... 128).contains(parsedDirectRoomLogShardCreditBatchSize)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"
            )
        }
        directRoomLogShardAdmissionCreditBatchSize = parsedDirectRoomLogShardCreditBatchSize
        let rawDirectRoomLogRoomCreditBatchSize = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE", environment: environment
        ) ?? "0"
        guard let parsedDirectRoomLogRoomCreditBatchSize = Int(rawDirectRoomLogRoomCreditBatchSize),
              (0 ... 32).contains(parsedDirectRoomLogRoomCreditBatchSize),
              parsedDirectRoomLogRoomCreditBatchSize == 0 || parsedDirectRoomLogShardCreditBatchSize > 0
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_ROOM_CREDIT_BATCH_SIZE"
            )
        }
        directRoomLogRoomAdmissionCreditBatchSize = parsedDirectRoomLogRoomCreditBatchSize
        let rawDirectRoomLogAppendBatchSize = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE", environment: environment
        ) ?? "0"
        guard let parsedDirectRoomLogAppendBatchSize = Int(rawDirectRoomLogAppendBatchSize),
              parsedDirectRoomLogAppendBatchSize == 0 || (2 ... 128).contains(parsedDirectRoomLogAppendBatchSize),
              parsedDirectRoomLogAppendBatchSize == 0 || (
                  parsedDirectRoomLogShardCreditBatchSize > 0
              )
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"
            )
        }
        directRoomLogAppendBatchSize = parsedDirectRoomLogAppendBatchSize
        let rawDirectRoomLogAppendMaximumPending = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS",
            environment: environment
        )
        if let rawDirectRoomLogAppendMaximumPending {
            guard parsedDirectRoomLogAppendBatchSize > 0,
                  let parsedDirectRoomLogAppendMaximumPending = Int(
                      rawDirectRoomLogAppendMaximumPending
                  ),
                  (parsedDirectRoomLogAppendBatchSize ... 1_048_576).contains(
                      parsedDirectRoomLogAppendMaximumPending
                  )
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_DIRECT_ROOM_LOG_APPEND_MAX_PENDING_REQUESTS"
                )
            }
            directRoomLogAppendMaximumPendingRequests =
                parsedDirectRoomLogAppendMaximumPending
        } else {
            // Retain the pre-existing bound unless a deployment explicitly
            // sizes the message-request staging queue for measured bursts.
            directRoomLogAppendMaximumPendingRequests =
                foregroundWriteDatabaseWorkMaximumQueued
        }
        let maximumAppendBatchConcurrency = databasePolicy.eventLoopThreads *
            foregroundWriteDatabaseWorkLimit
        let rawDirectRoomLogAppendBatchMaximumInFlight = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT", environment: environment
        )
        if let rawDirectRoomLogAppendBatchMaximumInFlight {
            guard let parsedDirectRoomLogAppendBatchMaximumInFlight = Int(
                rawDirectRoomLogAppendBatchMaximumInFlight
            ),
            parsedDirectRoomLogAppendBatchSize > 0,
            (1 ... maximumAppendBatchConcurrency).contains(
                parsedDirectRoomLogAppendBatchMaximumInFlight
            )
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_IN_FLIGHT"
                )
            }
            directRoomLogAppendBatchMaximumInFlightBatches =
                parsedDirectRoomLogAppendBatchMaximumInFlight
        } else {
            // Preserve the pre-existing application wiring exactly unless an
            // operator deliberately opts in to a measured override.
            directRoomLogAppendBatchMaximumInFlightBatches = min(
                8,
                foregroundWriteDatabaseWorkLimit
            )
        }
        let rawDirectRoomLogAppendLaneCount = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_LANES", environment: environment
        ) ?? "1"
        guard let parsedDirectRoomLogAppendLaneCount = Int(rawDirectRoomLogAppendLaneCount),
              parsedDirectRoomLogAppendLaneCount >= 1,
              parsedDirectRoomLogAppendLaneCount <= 64,
              parsedDirectRoomLogAppendLaneCount == 1 || (
                  parsedDirectRoomLogAppendBatchSize > 0
                      && parsedDirectRoomLogAppendLaneCount
                          <= directRoomLogAppendBatchMaximumInFlightBatches
                      && parsedDirectRoomLogAppendLaneCount
                          <= directRoomLogAppendMaximumPendingRequests
              )
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_APPEND_LANES"
            )
        }
        directRoomLogAppendLaneCount = parsedDirectRoomLogAppendLaneCount
        let rawDirectRoomLogAppendBatchDelay = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS", environment: environment
        ) ?? "2"
        guard let parsedDirectRoomLogAppendBatchDelay = Int(rawDirectRoomLogAppendBatchDelay),
              // A bounded high-activity profile may trade a small, explicit
              // amount of queueing for fewer room-log transactions.  Keep a
              // hard interactive ceiling: this is not a general retry or
              // backoff knob and must never grow without a latency review.
              (1 ... 25).contains(parsedDirectRoomLogAppendBatchDelay)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_MAX_DELAY_MS"
            )
        }
        directRoomLogAppendBatchMaximumDelayMilliseconds = parsedDirectRoomLogAppendBatchDelay
        let rawHighActivityAppendDelay = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS",
            environment: environment
        )
        let rawHighActivityAppendMinimumRequests = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_MIN_REQUESTS",
            environment: environment
        )
        let rawHighActivityAppendWindow = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_WINDOW_MS",
            environment: environment
        )
        let highActivityAppendValues = [
            rawHighActivityAppendDelay,
            rawHighActivityAppendMinimumRequests,
            rawHighActivityAppendWindow,
        ]
        if highActivityAppendValues.allSatisfy({ $0 == nil }) {
            directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds = nil
            directRoomLogAppendBatchHighActivityMinimumRequests = nil
            directRoomLogAppendBatchHighActivityWindowMilliseconds = nil
        } else {
            guard parsedDirectRoomLogAppendBatchSize > 0,
                  let rawHighActivityAppendDelay,
                  let rawHighActivityAppendMinimumRequests,
                  let rawHighActivityAppendWindow,
                  let parsedHighActivityAppendDelay = Int(rawHighActivityAppendDelay),
                  let parsedHighActivityAppendMinimumRequests = Int(rawHighActivityAppendMinimumRequests),
                  let parsedHighActivityAppendWindow = Int(rawHighActivityAppendWindow),
                  parsedHighActivityAppendDelay > parsedDirectRoomLogAppendBatchDelay,
                  parsedHighActivityAppendDelay <= 25,
                  parsedHighActivityAppendMinimumRequests >= 2,
                  parsedHighActivityAppendMinimumRequests
                      <= directRoomLogAppendMaximumPendingRequests,
                  (1 ... 1_000).contains(parsedHighActivityAppendWindow)
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_DELAY_MS/IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_MIN_REQUESTS/IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_HIGH_ACTIVITY_WINDOW_MS"
                )
            }
            directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds = parsedHighActivityAppendDelay
            directRoomLogAppendBatchHighActivityMinimumRequests = parsedHighActivityAppendMinimumRequests
            directRoomLogAppendBatchHighActivityWindowMilliseconds = parsedHighActivityAppendWindow
        }
        let rawDirectSendPolicyCacheMaximumEntries = Self.optional(
            "IM_V2_DIRECT_SEND_POLICY_CACHE_MAX_ENTRIES", environment: environment
        ) ?? "50000"
        guard let parsedDirectSendPolicyCacheMaximumEntries = Int(
            rawDirectSendPolicyCacheMaximumEntries
        ), (1 ... 1_048_576).contains(parsedDirectSendPolicyCacheMaximumEntries) else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_SEND_POLICY_CACHE_MAX_ENTRIES"
            )
        }
        directSendPolicyCacheMaximumEntries = parsedDirectSendPolicyCacheMaximumEntries
        let rawDirectRoomLogFastAppendCacheMaximumEntries = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_MAX_ENTRIES",
            environment: environment
        ) ?? "50000"
        guard let parsedDirectRoomLogFastAppendCacheMaximumEntries = Int(
            rawDirectRoomLogFastAppendCacheMaximumEntries
        ), (1 ... 1_048_576).contains(parsedDirectRoomLogFastAppendCacheMaximumEntries) else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_MAX_ENTRIES"
            )
        }
        directRoomLogFastAppendCacheMaximumEntries =
            parsedDirectRoomLogFastAppendCacheMaximumEntries
        let rawDirectRoomLogFastAppendCacheLifetimeSeconds = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_TTL_SECONDS",
            environment: environment
        ) ?? "600"
        guard let parsedDirectRoomLogFastAppendCacheLifetimeSeconds = Int(
            rawDirectRoomLogFastAppendCacheLifetimeSeconds
        ), (1 ... 3_600).contains(parsedDirectRoomLogFastAppendCacheLifetimeSeconds) else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_FAST_APPEND_CACHE_TTL_SECONDS"
            )
        }
        directRoomLogFastAppendCacheLifetimeSeconds =
            parsedDirectRoomLogFastAppendCacheLifetimeSeconds
        let rawDirectRoomLogEventCacheEntries = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES", environment: environment
        ) ?? "0"
        guard let parsedDirectRoomLogEventCacheEntries = Int(rawDirectRoomLogEventCacheEntries),
              (0 ... 1_048_576).contains(parsedDirectRoomLogEventCacheEntries)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES"
            )
        }
        directRoomLogEventCacheMaximumEntries = parsedDirectRoomLogEventCacheEntries
        if parsedDirectRoomLogEventCacheEntries == 0 {
            directRoomLogEventCacheMaximumBytes = 0
            directRoomLogEventCacheMaximumEntriesPerRoom = 0
            directRoomLogEventCacheShardCount = 0
            directRoomLogEventCacheMaximumPendingWrites = 0
        } else {
            let rawDirectRoomLogEventCacheBytes = Self.optional(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_BYTES", environment: environment
            ) ?? "33554432"
            let rawDirectRoomLogEventCacheEntriesPerRoom = Self.optional(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM", environment: environment
            ) ?? "64"
            let rawDirectRoomLogEventCacheShardCount = Self.optional(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_SHARDS", environment: environment
            ) ?? "16"
            let rawDirectRoomLogEventCacheMaximumPendingWrites = Self.optional(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_PENDING_WRITES", environment: environment
            ) ?? "4096"
            guard let parsedDirectRoomLogEventCacheBytes = Int(rawDirectRoomLogEventCacheBytes),
                  let parsedDirectRoomLogEventCacheEntriesPerRoom = Int(rawDirectRoomLogEventCacheEntriesPerRoom),
                  let parsedDirectRoomLogEventCacheShardCount = Int(rawDirectRoomLogEventCacheShardCount),
                  let parsedDirectRoomLogEventCacheMaximumPendingWrites = Int(rawDirectRoomLogEventCacheMaximumPendingWrites),
                  (1_048_576 ... 536_870_912).contains(parsedDirectRoomLogEventCacheBytes),
                  (1 ... 16_384).contains(parsedDirectRoomLogEventCacheEntriesPerRoom),
                  (1 ... 64).contains(parsedDirectRoomLogEventCacheShardCount),
                  (1 ... 131_072).contains(parsedDirectRoomLogEventCacheMaximumPendingWrites)
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_BYTES/IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM/IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_SHARDS/IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_PENDING_WRITES"
                )
            }
            directRoomLogEventCacheMaximumBytes = parsedDirectRoomLogEventCacheBytes
            directRoomLogEventCacheMaximumEntriesPerRoom = parsedDirectRoomLogEventCacheEntriesPerRoom
            directRoomLogEventCacheShardCount = parsedDirectRoomLogEventCacheShardCount
            directRoomLogEventCacheMaximumPendingWrites = parsedDirectRoomLogEventCacheMaximumPendingWrites
        }
        let rawProjectionStateRetention = Self.optional(
            "IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS",
            environment: environment
        ) ?? "604800"
        guard let projectionStateRetention = Int(rawProjectionStateRetention),
              (86_400 ... 365 * 86_400).contains(projectionStateRetention)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS"
            )
        }
        messageProjectionStateRetentionSeconds = projectionStateRetention
        let retryInitialDelayMilliseconds = try Self.positive("IM_V2_DURABLE_RETRY_INITIAL_DELAY_MS", environment: environment)
        let retryMaximumDelayMilliseconds = try Self.positive("IM_V2_DURABLE_RETRY_MAX_DELAY_MS", environment: environment)
        guard retryMaximumDelayMilliseconds >= retryInitialDelayMilliseconds else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DURABLE_RETRY_MAX_DELAY_MS")
        }
        durableRetryPolicy = try .init(
            initialDelay: TimeInterval(retryInitialDelayMilliseconds) / 1_000,
            maximumDelay: TimeInterval(retryMaximumDelayMilliseconds) / 1_000,
            maximumAttempts: Self.positive("IM_V2_DURABLE_RETRY_MAX_ATTEMPTS", environment: environment),
            jitterFraction: Self.percentage("IM_V2_DURABLE_RETRY_JITTER_PERCENT", environment: environment)
        )
        gatewayReplicaCount = try Self.positive("IM_V2_GATEWAY_REPLICA_COUNT", environment: environment)
        groupEventWake = try Self.groupEventWakeConfiguration(
            environment: environment,
            gatewayReplicaCount: gatewayReplicaCount
        )
        groupEventWakePollIntervalMilliseconds = try Self.positiveWithDefault(
            "IM_V2_GROUP_EVENT_WAKE_POLL_INTERVAL_MS",
            defaultValue: 500,
            maximum: 2_000,
            environment: environment
        )
        maintenancePollIntervalMilliseconds = try Self.positive("IM_V2_MAINTENANCE_POLL_INTERVAL_MS", environment: environment)
        backlogMaintenanceIdlePollIntervalMilliseconds = try Self.boundedPositive(
            "IM_V2_BACKLOG_MAINTENANCE_IDLE_POLL_INTERVAL_MS",
            maximum: 2_000,
            environment: environment
        )
        backlogMaintenanceMaximumConsecutiveBusyPasses = try Self.boundedPositive(
            "IM_V2_BACKLOG_MAINTENANCE_MAX_CONSECUTIVE_BUSY_PASSES",
            maximum: 1_024,
            environment: environment
        )
        backlogMaintenanceBusyDrainBudgetMilliseconds = try Self.boundedPositive(
            "IM_V2_BACKLOG_MAINTENANCE_BUSY_DRAIN_BUDGET_MS",
            maximum: 60_000,
            environment: environment
        )
        mediaWithdrawnRetentionSeconds = try Self.positive("IM_V2_MEDIA_WITHDRAWN_RETENTION_SECONDS", environment: environment)
        idempotencyRetentionSeconds = try Self.boundedPositive(
            "IM_V2_IDEMPOTENCY_RETENTION_SECONDS",
            maximum: 10 * 365 * 86_400,
            environment: environment
        )
        guard TimeInterval(idempotencyRetentionSeconds) >= V2IdempotencyPolicy.minimumServerRetention else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_IDEMPOTENCY_RETENTION_SECONDS")
        }
        metrics = try .init(
            host: Self.required("IM_V2_METRICS_HOST", environment: environment),
            port: Self.integer("IM_V2_METRICS_PORT", environment: environment)
        )
        metricsRefreshTimeoutMilliseconds = try Self.boundedPositive(
            "IM_V2_METRICS_REFRESH_TIMEOUT_MS", maximum: 60_000, environment: environment
        )
        metricsMinimumRefreshIntervalMilliseconds = try Self.boundedPositive(
            "IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS", maximum: 3_600_000, environment: environment
        )
        guard metricsRefreshTimeoutMilliseconds <= databasePolicy.statementTimeoutMilliseconds,
              metricsRefreshTimeoutMilliseconds <= metricsMinimumRefreshIntervalMilliseconds
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_METRICS_REFRESH_TIMEOUT_MS/IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS/IM_V2_DATABASE_STATEMENT_TIMEOUT_MS"
            )
        }
        gatewayNodeID = try Self.gatewayNodeID(environment: environment)
        userShardRoute = try .init(
            bucket: Self.required("IM_V2_USER_SHARD_BUCKET", environment: environment),
            observedRouterEpoch: try Self.nonNegative("IM_V2_USER_SHARD_ROUTER_EPOCH", environment: environment)
        )
        directRoomShardID = try Self.required("IM_V2_DIRECT_ROOM_SHARD_ID", environment: environment)
        do {
            directRoomShardRouter = try .init(rawValue: directRoomShardID)
        } catch {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DIRECT_ROOM_SHARD_ID")
        }
        do {
            groupRoomShardIDs = try V2GroupRoomShardSelector(
                rawValue: Self.required(
                    "IM_V2_GROUP_ROOM_SHARD_ID", environment: environment
                )
            ).shardIDs
        } catch {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_GROUP_ROOM_SHARD_ID"
            )
        }
        userShardStorage = try Self.userShardStorage(
            rawValue: Self.optional("IM_V2_USER_SHARD_STORES_JSON", environment: environment),
            localBucket: userShardRoute.bucket,
            localDatabaseURL: databaseURL
        )
        roomShardStorage = try Self.roomShardStorage(
            rawValue: Self.optional("IM_V2_ROOM_SHARD_STORES_JSON", environment: environment),
            requiredShardIDs: Set(
                directRoomShardRouter.shardIDs + groupRoomShardIDs
            ),
            localDatabaseURL: databaseURL
        )
        guard databaseWorkloadPoolBudget.totalConnectionsPerEventLoop <=
                databasePolicy.maximumConnectionsPerEventLoop
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DATABASE_WORKLOAD_POOL_BUDGET"
            )
        }
        guard userShardStorage.count <= databasePolicy.maximumUserShardStores,
              roomShardStorage.count <= databasePolicy.maximumUserShardStores else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_MAX_USER_SHARD_STORES")
        }
        let foregroundPoolCapacity = databasePolicy.eventLoopThreads * (
            databaseWorkloadPoolIsolationEnabled
                ? databaseWorkloadPoolBudget.foregroundConnectionsPerEventLoop
                : databasePolicy.maximumConnectionsPerEventLoop
        )
        let syncPoolCapacity = databasePolicy.eventLoopThreads * (
            databaseWorkloadPoolIsolationEnabled
                ? databaseWorkloadPoolBudget.syncConnectionsPerEventLoop
                : databasePolicy.maximumConnectionsPerEventLoop
        )
        if databaseWorkloadPoolIsolationEnabled {
            guard foregroundWriteDatabaseWorkLimit + foregroundControlWriteDatabaseWorkLimit +
                    interactiveReadDatabaseWorkLimit <= foregroundPoolCapacity,
                  syncDatabaseWorkLimit <= syncPoolCapacity
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT/IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT/IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT/IM_V2_SYNC_DATABASE_WORK_LIMIT"
                )
            }
            let projectionPoolCapacity = databasePolicy.eventLoopThreads *
                databaseWorkloadPoolBudget.projectionConnectionsPerEventLoop
            let projectionStoreCountsByURL = Dictionary(
                grouping: userShardStorage,
                by: \.databaseURL
            ).mapValues { stores in
                Set(stores.map(\.schema)).count
            }
            let configuredUserProjectionConcurrency = userProjectionConcurrency
            let maximumProjectionLanesPerPhysicalStore =
                projectionStoreCountsByURL.values.map {
                    $0 * (configuredUserProjectionConcurrency + 1)
                }.max() ?? 0
            guard projectionPoolCapacity > 1,
                  maximumProjectionLanesPerPhysicalStore <= projectionPoolCapacity
            else {
                // Every unique schema owns its own projector lanes and one
                // snapshot-artifact builder. They share the physical pool
                // when several logical stores use the same database URL.
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_USER_PROJECTION_CONCURRENCY/IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP"
                )
            }
        } else {
            // Admission must end before Fluent's pool wait. Keep the two
            // admitted lanes within the one shared physical pool; the
            // remaining connections stay available to durable workers.
            guard foregroundWriteDatabaseWorkLimit + foregroundControlWriteDatabaseWorkLimit +
                    interactiveReadDatabaseWorkLimit +
                    syncDatabaseWorkLimit <=
                    foregroundPoolCapacity
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT/IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT/IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT/IM_V2_SYNC_DATABASE_WORK_LIMIT"
                )
            }
        }
        directAuthorizationResolutionDatabaseURLs = Set([databaseURL] + roomShardStorage.map(\.databaseURL)).sorted()
        let (baseDedicated, baseOverflow) = directSendControlConnectionsPerEventLoop.addingReportingOverflow(1)
        let (dedicatedPerLoop, dedicatedOverflow) = baseDedicated.addingReportingOverflow(directAuthorizationResolutionDatabaseURLs.count)
        let (dedicatedConnections, dedicatedTotalOverflow) = databasePolicy.eventLoopThreads.multipliedReportingOverflow(by: dedicatedPerLoop)
        guard !baseOverflow, !dedicatedOverflow, !dedicatedTotalOverflow else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS")
        }
        try databasePolicy.validate(
            databaseURLs: [databaseURL] + userShardStorage.map(\.databaseURL) + roomShardStorage.map(\.databaseURL),
            connectionsPerEventLoopPerPhysicalStore:
                databaseWorkloadPoolIsolationEnabled
                    ? databaseWorkloadPoolBudget.totalConnectionsPerEventLoop
                    : databasePolicy.maximumConnectionsPerEventLoop,
            // Route, reservation and resolution pools never borrow foreground connections.
            additionalConnections: dedicatedConnections
        )
        strangerMessagePolicy = try .init(
            maximumMessagesPerWindow: try Self.positive("IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW", environment: environment),
            window: TimeInterval(try Self.positive("IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS", environment: environment))
        )
        let rawContentReviewMode = try Self.required("IM_V2_CONTENT_REVIEW_MODE", environment: environment).lowercased()
        guard let parsedContentReviewMode = V2ContentReviewMode(rawValue: rawContentReviewMode) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_CONTENT_REVIEW_MODE")
        }
        contentReviewMode = parsedContentReviewMode
        if let rawSafetyActor = Self.optional("IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID", environment: environment) {
            do {
                guard UUID(uuidString: rawSafetyActor) != nil else {
                    throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID")
                }
                contentReviewSafetyActorUserID = try .init(rawSafetyActor)
            }
            catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID") }
        } else {
            contentReviewSafetyActorUserID = nil
        }
        contentReviewViolationTerms = Self.csv("IM_V2_CONTENT_REVIEW_VIOLATION_TERMS", environment: environment)
        contentReviewEscalationTerms = Self.csv("IM_V2_CONTENT_REVIEW_ESCALATION_TERMS", environment: environment)
        switch Self.optional("IM_V2_PUSH_PROVIDER", environment: environment)?.lowercased() {
        case nil, "disabled":
            push = .disabled
        case "apns":
            let endpointKey = try V2PushEndpointEnvelopeKey(
                base64Encoded: Self.required("IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64", environment: environment)
            )
            let apnsTeamID = try Self.required("IM_V2_APNS_TEAM_ID", environment: environment)
            let apnsKeyID = try Self.required("IM_V2_APNS_KEY_ID", environment: environment)
            let apnsPrivateKey = try Self.required("IM_V2_APNS_PRIVATE_KEY_RAW_BASE64", environment: environment)
            let apnsTopic = try Self.required("IM_V2_APNS_TOPIC", environment: environment)
            let apns = try V2APNSJWTAuthorizer(
                teamID: apnsTeamID,
                keyID: apnsKeyID,
                privateKeyRawBase64: apnsPrivateKey
            )
            _ = apns
            push = .apns(.init(
                teamID: apnsTeamID,
                keyID: apnsKeyID,
                privateKeyRawBase64: apnsPrivateKey,
                topic: apnsTopic,
                endpointEnvelopeKey: endpointKey
            ))
        default:
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_PUSH_PROVIDER")
        }
        capacityProfile = try .init(
            id: try Self.required("IM_V2_CAPACITY_PROFILE_ID", environment: environment),
            limits: .init(
                maxEligibleMembers: try Self.integer("IM_V2_MAX_ELIGIBLE_MEMBERS", environment: environment),
                maxCommandsPerWindow: try Self.integer("IM_V2_MAX_COMMANDS_PER_WINDOW", environment: environment),

                retryAfterSeconds: try Self.integer("IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS", environment: environment)
            )
        )
    }

    private static func required(_ key: String, environment: any V2RuntimeEnvironment) throws -> String {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw V2GatewayRuntimeConfigurationError.missing(key)
        }
        return value
    }

    private static func optional(_ key: String, environment: any V2RuntimeEnvironment) -> String? {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func csv(_ key: String, environment: any V2RuntimeEnvironment) -> [String] {
        guard let raw = optional(key, environment: environment) else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func integer(_ key: String, environment: any V2RuntimeEnvironment) throws -> Int {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw V2GatewayRuntimeConfigurationError.missing(key)
        }
        guard let integer = Int(value) else {
            throw V2GatewayRuntimeConfigurationError.invalid(key)
        }
        return integer
    }

    private static func positive(_ key: String, environment: any V2RuntimeEnvironment) throws -> Int {
        let result = try integer(key, environment: environment)
        guard result > 0 else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
        return result
    }

    private static func boundedPositive(
        _ key: String,
        maximum: Int,
        environment: any V2RuntimeEnvironment
    ) throws -> Int {
        let result = try positive(key, environment: environment)
        guard result <= maximum else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
        return result
    }

    private static func nonNegativeWithDefault(
        _ key: String,
        defaultValue: Int,
        maximum: Int,
        environment: any V2RuntimeEnvironment
    ) throws -> Int {
        guard let raw = optional(key, environment: environment) else { return defaultValue }
        guard let value = Int(raw), (0...maximum).contains(value) else {
            throw V2GatewayRuntimeConfigurationError.invalid(key)
        }
        return value
    }

    private static func positiveWithDefault(
        _ key: String,
        defaultValue: Int,
        maximum: Int,
        environment: any V2RuntimeEnvironment
    ) throws -> Int {
        precondition(defaultValue > 0 && defaultValue <= maximum)
        guard let raw = optional(key, environment: environment) else {
            return defaultValue
        }
        guard let value = Int(raw), (1...maximum).contains(value) else {
            throw V2GatewayRuntimeConfigurationError.invalid(key)
        }
        return value
    }

    private static func nonNegative(_ key: String, environment: any V2RuntimeEnvironment) throws -> Int64 {
        let result = try integer(key, environment: environment)
        guard result >= 0 else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
        return Int64(result)
    }

    /// 读取并校验网关节点 ID。
    ///
    /// 持久吊销游标以该值为键。因此把它限制为一个有界的部署标识符，
    /// 使一次环境变量拼写错误不会演变成游标表无界增长或不安全的 SQL/日志元数据。
    ///
    /// - Parameter environment: 运行时环境变量来源。
    /// - Returns: 合法且已规范化的节点 ID。
    /// - Throws: 变量缺失或格式非法时抛出。
    private static func gatewayNodeID(environment: any V2RuntimeEnvironment) throws -> String {
        let value = try required("IM_V2_GATEWAY_NODE_ID", environment: environment)
        guard value.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GATEWAY_NODE_ID")
        }
        return value
    }

    private static func percentage(_ key: String, environment: any V2RuntimeEnvironment) throws -> Double {
        let result = try integer(key, environment: environment)
        guard (0...100).contains(result) else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
        return Double(result) / 100
    }

    private static func explicitBoolean(
        _ key: String,
        environment: any V2RuntimeEnvironment
    ) throws -> Bool {
        switch try required(key, environment: environment).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: throw V2GatewayRuntimeConfigurationError.invalid(key)
        }
    }

    private static func userShardStorage(
        rawValue: String?, localBucket: String, localDatabaseURL: String
    ) throws -> [V2UserShardStorageConfiguration] {
        guard let rawValue else {
            return [try .init(bucket: localBucket, databaseURL: localDatabaseURL)]
        }
        let decoded = try V2UserShardStorageConfiguration.parseRegistryJSON(rawValue)
        guard decoded.contains(where: { $0.bucket == localBucket })
        else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON") }
        return decoded
    }

    private static func roomShardStorage(
        rawValue: String?, requiredShardIDs: Set<String>, localDatabaseURL: String
    ) throws -> [V2RoomShardStorageConfiguration] {
        guard let rawValue else {
            return try requiredShardIDs.sorted().map {
                try .init(shardID: $0, databaseURL: localDatabaseURL)
            }
        }
        let decoded = try V2RoomShardStorageConfiguration.parseRegistryJSON(rawValue)
        guard Set(decoded.map(\.shardID)) == requiredShardIDs else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON")
        }
        return decoded
    }

    private static func groupEventWakeConfiguration(
        environment: any V2RuntimeEnvironment,
        gatewayReplicaCount: Int
    ) throws -> V2GroupEventWakeRuntimeConfiguration {
        let rawURL = optional("IM_V2_GROUP_WAKE_NATS_URL", environment: environment)
        let subject = optional("IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX", environment: environment)
        let token = optional("IM_V2_GROUP_WAKE_NATS_TOKEN", environment: environment)
        let routingKeyBase64 = optional("IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64", environment: environment)
        let tlsCAPath = optional("IM_V2_GROUP_WAKE_NATS_TLS_CA_PATH", environment: environment)
        let tlsServerName = optional("IM_V2_GROUP_WAKE_NATS_TLS_SERVER_NAME", environment: environment)
        let rawWakeDeferralDelay = optional(
            "IM_V2_GROUP_WAKE_DEFERRAL_MS",
            environment: environment
        )
        switch (rawURL, subject, routingKeyBase64) {
        case (nil, nil, nil):
            guard token == nil else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_TOKEN") }
            guard tlsCAPath == nil, tlsServerName == nil else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_GROUP_WAKE_NATS_TLS_CA_PATH/IM_V2_GROUP_WAKE_NATS_TLS_SERVER_NAME"
                )
            }
            guard rawWakeDeferralDelay == nil else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_GROUP_WAKE_DEFERRAL_MS"
                )
            }
            guard gatewayReplicaCount == 1 else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_GATEWAY_REPLICA_COUNT/IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64"
                )
            }
            return .localOnly
        case let (rawURL?, subject?, routingKeyBase64?):
            guard let url = URL(string: rawURL) else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_URL") }
            guard let routingKey = Data(base64Encoded: routingKeyBase64) else {
                throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64")
            }
            let wakeDeferralDelayMilliseconds: Int
            if let rawWakeDeferralDelay {
                guard let parsed = Int(rawWakeDeferralDelay),
                      (0 ... 1_000).contains(parsed)
                else {
                    throw V2GatewayRuntimeConfigurationError.invalid(
                        "IM_V2_GROUP_WAKE_DEFERRAL_MS"
                    )
                }
                wakeDeferralDelayMilliseconds = parsed
            } else {
                wakeDeferralDelayMilliseconds = 60
            }
            do {
                return .nats(try .init(
                    url: url,
                    subjectPrefix: subject,
                    token: token,
                    routingKey: routingKey,
                    tlsCAPath: tlsCAPath,
                    tlsServerName: tlsServerName,
                    wakeDeferralDelayMilliseconds:
                        wakeDeferralDelayMilliseconds
                ))
            }
            catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64") }
        default: throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64")
        }
    }

}
