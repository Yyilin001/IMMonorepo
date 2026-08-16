import Foundation
import IMV2Core

public protocol V2RuntimeEnvironment: Sendable {
    func value(for key: String) -> String?
}

public struct V2DictionaryRuntimeEnvironment: V2RuntimeEnvironment, Sendable {
    private let values: [String: String]
    public init(_ values: [String: String]) { self.values = values }
    public func value(for key: String) -> String? { values[key] }
}

public enum V2GatewayRuntimeConfigurationError: Error, Equatable, Sendable {
    case missing(String)
    case invalid(String)
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
    public let mediaWithdrawnRetentionSeconds: Int
    /// Server replay results outlive the first-party client retry window.
    /// Deployment may retain them longer, but never shorten this protocol
    /// fence or a delayed client could execute an already-completed command.
    public let idempotencyRetentionSeconds: Int
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
    public let groupRoomShardID: String
    public let strangerMessagePolicy: V2StrangerMessagePolicy
    public let push: V2PushRuntimeConfiguration
    /// Content review stays disabled until a separately authenticated audit
    /// principal is provisioned. Terms are deployment policy, never client
    /// input; richer AI/OCR providers use the same worker boundary.
    public let contentReviewSafetyActorUserID: UserID?
    public let contentReviewViolationTerms: [String]
    public let contentReviewEscalationTerms: [String]

    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try Self.required("IM_V2_DATABASE_URL", environment: environment)
        databasePolicy = try .init(environment: environment)
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
        try databasePolicy.validate(
            primaryDatabaseURL: databaseURL,
            userShardStorage: userShardStorage
        )
        directRoomShardID = try Self.required("IM_V2_DIRECT_ROOM_SHARD_ID", environment: environment)
        groupRoomShardID = try Self.required("IM_V2_GROUP_ROOM_SHARD_ID", environment: environment)
        strangerMessagePolicy = try .init(
            maximumMessagesPerWindow: try Self.positive("IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW", environment: environment),
            window: TimeInterval(try Self.positive("IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS", environment: environment))
        )
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
