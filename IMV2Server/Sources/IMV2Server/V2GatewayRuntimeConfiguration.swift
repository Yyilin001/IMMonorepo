import Foundation
import IMV2Core

public protocol V2RuntimeEnvironment: Sendable {
    func value(for key: String) -> String?
}

public enum V2GatewayRuntimeConfigurationError: Error, Equatable, Sendable {
    case missing(String)
    case invalid(String)
}

/// Controls whether accepted or edited message content enters the durable
/// review pipeline. Disabling the lane leaves existing jobs untouched and
/// deliberately does not backfill messages created while it is disabled.
public enum V2ContentReviewMode: String, Equatable, Sendable {
    case enabled
    case disabled

    var enqueuesJobs: Bool { self == .enabled }
}

public enum V2MessageProjectionWriteMode: String, Equatable, Sendable {
    case inline
    case dual
    case shared
}

public enum V2MessageProjectionReadMode: String, Equatable, Sendable {
    case inline
    case preferShared = "prefer_shared"
    case shared
}

/// Selects how the fixed two-user audience of a direct message becomes
/// durable delivery work. `preplanned` still uses the ordinary Delivery,
/// Inbox and completion fences; it only removes the redundant outbox and
/// membership-enumeration phases. This is deployment policy, never client
/// input, so a rollout can be reversed without changing the wire protocol.
public enum V2DirectFanoutMode: String, Equatable, Sendable {
    case planner
    case preplanned
    /// The direct room event log is the durable source of truth. Clients
    /// recover by room cursor and foreground subscriptions receive only a
    /// best-effort waterline hint, so no per-message user projection or
    /// delivery lease is needed for the fixed two-user audience.
    case roomLog = "room_log"
}

/// Controls which durable command-rate fence applies to ordinary direct
/// messages when their canonical delivery record is the room event log.
/// This is deployment policy, never client input.
///
/// `room` preserves the original per-room command window. `shardOnly` keeps
/// the durable shard command window, gateway user/device rate limits, direct
/// policy checks and stranger quota, but does not rewrite the otherwise idle
/// per-room command counter for every direct message. It is intentionally
/// valid only together with `V2DirectFanoutMode.roomLog`.
public enum V2DirectRoomLogAdmissionMode: String, Equatable, Sendable {
    case room
    case shardOnly = "shard_only"
}

/// Controls whether an accepted-message incremental sync body is retained in
/// the fan-out payload table or represented by its immutable message-state
/// reference. Readers always support both forms so this can be rolled out
/// after every binary has the reference join and rolled back without data
/// loss before compaction.
public enum V2FanoutPayloadWriteMode: String, Equatable, Sendable {
    case body
    case reference
}

/// Metrics are intentionally bound to a loopback-only listener. A collector
/// must run in the same host or pod namespace; exposing these operational
/// details through the public realtime or media listeners is forbidden.
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

/// Deployment-only mapping from a logical bucket to a physical database. It
/// is parsed at startup, never written into fan-out records, logs or API
/// responses. Omitting the JSON keeps the single-bucket deployment explicit.
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

    /// Decodes the deployment-only registry shared by gateway and operator
    /// processes. The caller remains responsible for requiring the local
    /// bucket appropriate to its role.
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

/// Push remains disabled until every APNs secret and topic is explicitly
/// provisioned. The endpoint-encryption secret is required only in the process
/// that actually resolves endpoint plaintext for a provider request.
public enum V2PushRuntimeConfiguration: Sendable {
    case disabled
    case apns(V2APNSRuntimeConfiguration)
}

public enum V2FanoutHintRuntimeConfiguration: Sendable {
    case durablePollingOnly
    case nats(V2NATSFanoutHintConfiguration)
}

/// Hybrid foreground wake routing is optional for a single gateway but must
/// use a shared broker when active viewers can be connected to other replicas.
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

/// All production-affecting V2 values are explicit. There are intentionally no
/// development defaults for credentials, frame/queue limits, or capacity
/// policy: an incomplete deployment must fail before opening a public port.
public struct V2GatewayRuntimeConfiguration: Sendable {
    public let databaseURL: String
    public let databasePolicy: V2PostgresRuntimePolicy
    public let databaseWorkloadPoolBudget: V2PostgresWorkloadPoolBudget
    public let databaseWorkloadPoolIsolationEnabled: Bool
    /// Fluent defaults to a single PostgreSQL connection per event loop. The
    /// gateway runs foreground commands and durable fan-out in the same
    /// process, so deployment must size this explicitly rather than allowing a
    /// fan-out transaction to starve sync or command work on one event loop.
    public var databaseMaxConnectionsPerEventLoop: Int {
        databasePolicy.maximumConnectionsPerEventLoop
    }
    public let tls: V2TLSListenerConfiguration
    public let accessTokenKey: V2AccessTokenHMACKey
    public let capacityProfile: V2CapacityProfile
    public let messageLimits: V2MessageCommandLimits
    public let frameLimits: V2FrameLimits
    public let maximumProtobufMessageDepth: Int
    public let connectionLimits: V2ConnectionLimits
    /// Hard process-local admission ceiling, including unauthenticated TLS
    /// sockets. This bounds per-connection queues, actors and TLS state.
    public let maximumConnections: Int
    public let authenticatedConnectionAdmissionPolicy: V2AuthenticatedConnectionAdmissionPolicy
    public let commandRateLimitPolicy: V2GatewayCommandRateLimitPolicy
    public let maximumQueuedInboundBytes: Int
    /// Complements the byte bound so a stream of one-byte TCP fragments cannot
    /// create an unbounded number of queued `Data` allocations.
    public let maximumQueuedInboundChunks: Int
    /// Absolute time from accepted channel to authenticated session. Unlike
    /// idle timeout it cannot be extended by trickling bytes.
    public let authenticationTimeoutMilliseconds: Int
    public let idleTimeoutMilliseconds: Int
    public let capabilityProfile: String
    public let workerBatchSize: Int
    public let workerPollIntervalMilliseconds: Int
    /// Independent projection claim loops per unique user schema. Multiple
    /// schemas may share one physical database pool; the startup connection
    /// budget accounts for every schema's workers plus its snapshot builder.
    /// The checkpoint `SKIP LOCKED` fence preserves one ordered stream per user.
    public let userProjectionConcurrency: Int
    /// Busy projector transactions run back-to-back, but these two independent
    /// budgets force a cooperative executor yield under a sustained backlog.
    public let userProjectionMaximumConsecutiveBusyPasses: Int
    public let userProjectionBusyDrainBudgetMilliseconds: Int
    /// Process-local database admission bounds reject overload before a
    /// request spends the much longer Fluent pool timeout waiting for a slot.
    /// Durable message writes, control-plane writes, and interactive reads
    /// reserve capacity independently. Their sum is validated against the
    /// same physical foreground pool; this is admission isolation, not
    /// additional database connections.
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
    /// Best-effort sync hints are coalesced by user; cursor pull remains the
    /// authoritative recovery mechanism.
    public let syncWakeCoalescingMilliseconds: Int
    public let syncWakeMaximumPendingUsers: Int
    public let syncWakeDeliveryConcurrency: Int
    public let syncWakeCoalescingEnabled: Bool
    public let acceptedMessageProjectionBatchEnabled: Bool
    /// Successful command logs are sampled independently from complete
    /// Prometheus accounting. Rejections, failures and slow commands remain
    /// unsampled.
    public let commandSuccessLogSamplePermille: Int
    public let commandSlowLogThresholdMilliseconds: Int
    /// Maximum number of co-located target projections committed in one
    /// database transaction. Keeping this small bounds rollback work, lock
    /// hold time and WAL burst size.
    public let fanoutDeliveryCommitBatchSize: Int
    /// Maximum number of remote-user-shard effects a cross-store worker
    /// projects before its separate control-store acknowledgement. This is
    /// intentionally distinct from the co-located transaction boundary:
    /// remote delivery pays one target and one control database round-trip per
    /// batch, so the validated optimum is larger without widening the
    /// co-located lock/WAL critical section.
    public let crossStoreFanoutDeliveryCommitBatchSize: Int
    /// Maximum same-claim remote commit batches in flight for one physical
    /// user-shard bucket. This overlaps independent target/control database
    /// transactions but is intentionally capped below general worker
    /// concurrency to avoid fragmenting claim ownership or amplifying locks.
    public let crossStoreFanoutDeliveryCommitConcurrency: Int
    /// Maximum number of durable delivery leases one delivery worker claims in
    /// one pass. This is intentionally separate from the generic worker
    /// batch, which controls outbox and planning work as well.
    public let fanoutDeliveryClaimBatchSize: Int
    /// Number of full fresh-lane claim passes before a recovery-first pass.
    /// This is explicit deployment policy because it bounds recovery latency
    /// under an indefinitely busy new-message stream.
    public let fanoutFreshBurstPasses: Int
    public let durableRetryPolicy: V2DurableRetryPolicy
    public let fanoutHint: V2FanoutHintRuntimeConfiguration
    public let groupEventWake: V2GroupEventWakeRuntimeConfiguration
    public let maintenancePollIntervalMilliseconds: Int
    /// High-volume retention tables use a separate backlog-drain loop. Busy
    /// passes run back-to-back within these cooperative budgets; an empty pass
    /// falls back to the independently configured idle poll interval.
    public let backlogMaintenanceIdlePollIntervalMilliseconds: Int
    public let backlogMaintenanceMaximumConsecutiveBusyPasses: Int
    public let backlogMaintenanceBusyDrainBudgetMilliseconds: Int
    public let mediaWithdrawnRetentionSeconds: Int
    /// Server replay results outlive the first-party client retry window.
    /// Deployment may retain them longer, but never shorten this protocol
    /// fence or a delayed client could execute an already-completed command.
    public let idempotencyRetentionSeconds: Int
    public let messageProjectionWriteMode: V2MessageProjectionWriteMode
    public let messageProjectionReadMode: V2MessageProjectionReadMode
    public let directFanoutMode: V2DirectFanoutMode
    /// A direct room-log-only deployment fence. The default retains exact
    /// legacy room admission semantics.
    public let directRoomLogAdmissionMode: V2DirectRoomLogAdmissionMode
    /// Zero preserves exact per-message shard admission. A positive value is
    /// an explicit, direct-room-log-only batch size for pre-charged command
    /// credits; it is never enabled by a client request.
    public let directRoomLogShardAdmissionCreditBatchSize: Int
    /// Zero keeps direct room-log appends one command per transaction.  A
    /// positive value enables only the deliberately narrow, ordered plain
    /// direct-message micro-batch; non-eligible commands transparently use
    /// the established single-command write path.
    public let directRoomLogAppendBatchSize: Int
    /// Maximum extra server-side queueing time for an append micro-batch.
    /// This has meaning only when `directRoomLogAppendBatchSize` is positive.
    public let directRoomLogAppendBatchMaximumDelayMilliseconds: Int
    /// Optional sustained-arrival policy for append micro-batches. The base
    /// delay remains the interactive default; this longer cap is selected
    /// only after the bounded detector sees enough arrivals in its configured
    /// monotonic observation window.
    public let directRoomLogAppendBatchHighActivityMaximumDelayMilliseconds: Int?
    public let directRoomLogAppendBatchHighActivityMinimumRequests: Int?
    public let directRoomLogAppendBatchHighActivityWindowMilliseconds: Int?
    /// Zero disables the process-local direct event cache. Cached entries are
    /// never authorization state and are always validated against PostgreSQL
    /// before being served.
    public let directRoomLogEventCacheMaximumEntries: Int
    public let directRoomLogEventCacheMaximumBytes: Int
    public let directRoomLogEventCacheMaximumEntriesPerRoom: Int
    public let fanoutPayloadWriteMode: V2FanoutPayloadWriteMode
    /// Unreferenced immutable revisions remain recoverable for this grace.
    /// The default is seven days; deployments may lengthen it independently
    /// of user projection MVCC retention.
    public let messageProjectionStateRetentionSeconds: Int
    public let metrics: V2MetricsListenerConfiguration
    public let metricsMinimumRefreshIntervalMilliseconds: Int
    public let metricsRefreshTimeoutMilliseconds: Int
    public let gatewayNodeID: String
    /// The explicit deployment topology fence for process-local wake routing.
    /// All replicas of one logical deployment must receive the same value.
    public let gatewayReplicaCount: Int
    public let userShardRoute: V2UserShardRoute
    public let userShardStorage: [V2UserShardStorageConfiguration]
    public let directRoomShardID: String
    /// Parsed at process start so an invalid room-owner route fails readiness
    /// rather than the first direct-room creation request.
    public let directRoomShardRouter: V2DirectRoomShardRouter
    public let groupRoomShardID: String
    public let strangerMessagePolicy: V2StrangerMessagePolicy
    public let push: V2PushRuntimeConfiguration
    /// The mode controls durable job creation and worker startup. A separately
    /// authenticated audit principal is additionally required to run the
    /// worker. Terms are deployment policy, never client input; richer
    /// AI/OCR providers use the same worker boundary.
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
        connectionLimits = try .init(maximumInFlightRequests: try Self.integer("IM_V2_MAX_IN_FLIGHT_REQUESTS", environment: environment))
        maximumConnections = try Self.boundedPositive("IM_V2_MAX_CONNECTIONS", maximum: 1_000_000, environment: environment)
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
        idleTimeoutMilliseconds = try Self.positive("IM_V2_IDLE_TIMEOUT_MS", environment: environment)
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
        acceptedMessageProjectionBatchEnabled = try Self.explicitBoolean(
            "IM_V2_ACCEPTED_MESSAGE_PROJECTION_BATCH_ENABLED", environment: environment
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
        let rawProjectionWriteMode = Self.optional(
            "IM_V2_MESSAGE_PROJECTION_WRITE_MODE", environment: environment
        )?.lowercased() ?? V2MessageProjectionWriteMode.dual.rawValue
        let rawProjectionReadMode = Self.optional(
            "IM_V2_MESSAGE_PROJECTION_READ_MODE", environment: environment
        )?.lowercased() ?? V2MessageProjectionReadMode.preferShared.rawValue
        guard let projectionWriteMode = V2MessageProjectionWriteMode(rawValue: rawProjectionWriteMode),
              let projectionReadMode = V2MessageProjectionReadMode(rawValue: rawProjectionReadMode),
              !(projectionWriteMode == .shared && projectionReadMode == .inline)
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_MESSAGE_PROJECTION_WRITE_MODE/IM_V2_MESSAGE_PROJECTION_READ_MODE"
            )
        }
        messageProjectionWriteMode = projectionWriteMode
        messageProjectionReadMode = projectionReadMode
        let rawDirectFanoutMode = Self.optional(
            "IM_V2_DIRECT_FANOUT_MODE", environment: environment
        )?.lowercased() ?? V2DirectFanoutMode.planner.rawValue
        guard let parsedDirectFanoutMode = V2DirectFanoutMode(rawValue: rawDirectFanoutMode) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DIRECT_FANOUT_MODE")
        }
        directFanoutMode = parsedDirectFanoutMode
        let rawDirectRoomLogAdmissionMode = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE", environment: environment
        )?.lowercased() ?? V2DirectRoomLogAdmissionMode.room.rawValue
        guard let parsedDirectRoomLogAdmissionMode = V2DirectRoomLogAdmissionMode(
            rawValue: rawDirectRoomLogAdmissionMode
        ), parsedDirectRoomLogAdmissionMode == .room || parsedDirectFanoutMode == .roomLog
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_ADMISSION_MODE"
            )
        }
        directRoomLogAdmissionMode = parsedDirectRoomLogAdmissionMode
        let rawDirectRoomLogShardCreditBatchSize = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE", environment: environment
        ) ?? "0"
        guard let parsedDirectRoomLogShardCreditBatchSize = Int(rawDirectRoomLogShardCreditBatchSize),
              (0 ... 128).contains(parsedDirectRoomLogShardCreditBatchSize),
              parsedDirectRoomLogShardCreditBatchSize == 0 || parsedDirectFanoutMode == .roomLog
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_SHARD_CREDIT_BATCH_SIZE"
            )
        }
        directRoomLogShardAdmissionCreditBatchSize = parsedDirectRoomLogShardCreditBatchSize
        let rawDirectRoomLogAppendBatchSize = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE", environment: environment
        ) ?? "0"
        guard let parsedDirectRoomLogAppendBatchSize = Int(rawDirectRoomLogAppendBatchSize),
              parsedDirectRoomLogAppendBatchSize == 0 || (2 ... 32).contains(parsedDirectRoomLogAppendBatchSize),
              parsedDirectRoomLogAppendBatchSize == 0 || (
                  parsedDirectFanoutMode == .roomLog
                      && parsedDirectRoomLogShardCreditBatchSize > 0
              )
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_APPEND_BATCH_SIZE"
            )
        }
        directRoomLogAppendBatchSize = parsedDirectRoomLogAppendBatchSize
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
                  parsedHighActivityAppendMinimumRequests <= foregroundWriteDatabaseWorkMaximumQueued,
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
        let rawDirectRoomLogEventCacheEntries = Self.optional(
            "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES", environment: environment
        ) ?? "0"
        guard let parsedDirectRoomLogEventCacheEntries = Int(rawDirectRoomLogEventCacheEntries),
              (0 ... 131_072).contains(parsedDirectRoomLogEventCacheEntries),
              parsedDirectRoomLogEventCacheEntries == 0
                || parsedDirectFanoutMode == .roomLog
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES"
            )
        }
        directRoomLogEventCacheMaximumEntries = parsedDirectRoomLogEventCacheEntries
        if parsedDirectRoomLogEventCacheEntries == 0 {
            directRoomLogEventCacheMaximumBytes = 0
            directRoomLogEventCacheMaximumEntriesPerRoom = 0
        } else {
            let rawDirectRoomLogEventCacheBytes = Self.optional(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_BYTES", environment: environment
            ) ?? "33554432"
            let rawDirectRoomLogEventCacheEntriesPerRoom = Self.optional(
                "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM", environment: environment
            ) ?? "64"
            guard let parsedDirectRoomLogEventCacheBytes = Int(rawDirectRoomLogEventCacheBytes),
                  let parsedDirectRoomLogEventCacheEntriesPerRoom = Int(rawDirectRoomLogEventCacheEntriesPerRoom),
                  (1_048_576 ... 536_870_912).contains(parsedDirectRoomLogEventCacheBytes),
                  (1 ... 512).contains(parsedDirectRoomLogEventCacheEntriesPerRoom)
            else {
                throw V2GatewayRuntimeConfigurationError.invalid(
                    "IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_BYTES/IM_V2_DIRECT_ROOM_LOG_EVENT_CACHE_MAX_ENTRIES_PER_ROOM"
                )
            }
            directRoomLogEventCacheMaximumBytes = parsedDirectRoomLogEventCacheBytes
            directRoomLogEventCacheMaximumEntriesPerRoom = parsedDirectRoomLogEventCacheEntriesPerRoom
        }
        let rawFanoutPayloadWriteMode = Self.optional(
            "IM_V2_FANOUT_PAYLOAD_WRITE_MODE", environment: environment
        )?.lowercased() ?? V2FanoutPayloadWriteMode.body.rawValue
        guard let parsedFanoutPayloadWriteMode = V2FanoutPayloadWriteMode(
            rawValue: rawFanoutPayloadWriteMode
        ) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_FANOUT_PAYLOAD_WRITE_MODE")
        }
        fanoutPayloadWriteMode = parsedFanoutPayloadWriteMode
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
        fanoutDeliveryCommitBatchSize = try Self.deliveryCommitBatchSize(environment: environment)
        crossStoreFanoutDeliveryCommitBatchSize = try Self.crossStoreDeliveryCommitBatchSize(environment: environment)
        crossStoreFanoutDeliveryCommitConcurrency = try Self.crossStoreDeliveryCommitConcurrency(environment: environment)
        fanoutDeliveryClaimBatchSize = try Self.deliveryClaimBatchSize(environment: environment)
        fanoutFreshBurstPasses = try Self.positive("IM_V2_FANOUT_FRESH_BURST_PASSES", environment: environment)
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
        fanoutHint = try Self.fanoutHintConfiguration(environment: environment)
        gatewayReplicaCount = try Self.positive("IM_V2_GATEWAY_REPLICA_COUNT", environment: environment)
        groupEventWake = try Self.groupEventWakeConfiguration(
            environment: environment,
            gatewayReplicaCount: gatewayReplicaCount
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
        userShardStorage = try Self.userShardStorage(
            rawValue: Self.optional("IM_V2_USER_SHARD_STORES_JSON", environment: environment),
            localBucket: userShardRoute.bucket,
            localDatabaseURL: databaseURL
        )
        guard databaseWorkloadPoolBudget.totalConnectionsPerEventLoop <=
                databasePolicy.maximumConnectionsPerEventLoop
        else {
            throw V2GatewayRuntimeConfigurationError.invalid(
                "IM_V2_DATABASE_WORKLOAD_POOL_BUDGET"
            )
        }
        guard userShardStorage.count <= databasePolicy.maximumUserShardStores else {
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
        try databasePolicy.validate(
            databaseURLs: [databaseURL] + userShardStorage.map(\.databaseURL),
            connectionsPerEventLoopPerPhysicalStore:
                databaseWorkloadPoolIsolationEnabled
                    ? databaseWorkloadPoolBudget.totalConnectionsPerEventLoop
                    : databasePolicy.maximumConnectionsPerEventLoop
        )
        directRoomShardID = try Self.required("IM_V2_DIRECT_ROOM_SHARD_ID", environment: environment)
        do {
            directRoomShardRouter = try .init(rawValue: directRoomShardID)
        } catch {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_DIRECT_ROOM_SHARD_ID")
        }
        groupRoomShardID = try Self.required("IM_V2_GROUP_ROOM_SHARD_ID", environment: environment)
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
                maxFanoutUnitsPerWindow: try Self.integer("IM_V2_MAX_FANOUT_UNITS_PER_WINDOW", environment: environment),
                maxOutstandingFanoutUnits: try Self.integer("IM_V2_MAX_OUTSTANDING_FANOUT_UNITS", environment: environment),
                maxOutstandingPlans: try Self.integer("IM_V2_MAX_OUTSTANDING_PLANS", environment: environment),
                maxEnumerationPageSize: try Self.integer("IM_V2_MAX_ENUMERATION_PAGE_SIZE", environment: environment),
                maxPlannerConcurrency: try Self.integer("IM_V2_MAX_PLANNER_CONCURRENCY", environment: environment),
                maxDeliveryConcurrency: try Self.integer("IM_V2_MAX_DELIVERY_CONCURRENCY", environment: environment),
                retryAfterSeconds: try Self.integer("IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS", environment: environment)
            )
        )
    }

    private static func deliveryCommitBatchSize(environment: any V2RuntimeEnvironment) throws -> Int {
        let value = try positive("IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE", environment: environment)
        guard value <= 128 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")
        }
        return value
    }

    private static func crossStoreDeliveryCommitBatchSize(environment: any V2RuntimeEnvironment) throws -> Int {
        let value = try positive("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE", environment: environment)
        guard value <= 256 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_BATCH_SIZE")
        }
        return value
    }

    private static func crossStoreDeliveryCommitConcurrency(environment: any V2RuntimeEnvironment) throws -> Int {
        let value = try positive("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY", environment: environment)
        guard value <= 2 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_CROSS_STORE_FANOUT_DELIVERY_COMMIT_CONCURRENCY")
        }
        return value
    }

    private static func deliveryClaimBatchSize(environment: any V2RuntimeEnvironment) throws -> Int {
        let value = try positive("IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE", environment: environment)
        // A worker processes claimed leases sequentially in commit-sized
        // transactions. Keep the in-flight lease set bounded to the validated
        // 100k profile so a slow database cannot turn an aggressive setting
        // into a lease-recovery burst.
        guard value <= 2_000 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE")
        }
        return value
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

    private static func nonNegative(_ key: String, environment: any V2RuntimeEnvironment) throws -> Int64 {
        let result = try integer(key, environment: environment)
        guard result >= 0 else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
        return Int64(result)
    }

    /// The durable revocation cursor is keyed by this value. Restrict it to a
    /// bounded deployment identifier so it cannot turn an environment typo
    /// into unbounded cursor-table growth or unsafe SQL/log metadata.
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

    private static func fanoutHintConfiguration(environment: any V2RuntimeEnvironment) throws -> V2FanoutHintRuntimeConfiguration {
        let rawURL = optional("IM_V2_NATS_URL", environment: environment)
        let subject = optional("IM_V2_NATS_SUBJECT", environment: environment)
        let token = optional("IM_V2_NATS_TOKEN", environment: environment)
        switch (rawURL, subject) {
        case (nil, nil):
            guard token == nil else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_TOKEN") }
            return .durablePollingOnly
        case let (rawURL?, subject?):
            guard let url = URL(string: rawURL) else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_URL") }
            do { return .nats(try .init(url: url, subject: subject, token: token)) }
            catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_URL/IM_V2_NATS_SUBJECT") }
        default: throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_URL/IM_V2_NATS_SUBJECT")
        }
    }

    private static func groupEventWakeConfiguration(
        environment: any V2RuntimeEnvironment,
        gatewayReplicaCount: Int
    ) throws -> V2GroupEventWakeRuntimeConfiguration {
        let rawURL = optional("IM_V2_GROUP_WAKE_NATS_URL", environment: environment)
        let subject = optional("IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX", environment: environment)
        let token = optional("IM_V2_GROUP_WAKE_NATS_TOKEN", environment: environment)
        let routingKeyBase64 = optional("IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64", environment: environment)
        switch (rawURL, subject, routingKeyBase64) {
        case (nil, nil, nil):
            guard token == nil else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_TOKEN") }
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
            do { return .nats(try .init(url: url, subjectPrefix: subject, token: token, routingKey: routingKey)) }
            catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64") }
        default: throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_WAKE_NATS_URL/IM_V2_GROUP_WAKE_NATS_SUBJECT_PREFIX/IM_V2_GROUP_WAKE_ROUTING_KEY_BASE64")
        }
    }

}
