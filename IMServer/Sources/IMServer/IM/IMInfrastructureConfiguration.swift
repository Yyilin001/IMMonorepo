import Foundation
import Kafka
import Vapor

struct IMGatewayRelayConfiguration: Sendable {
    static let defaultDomainEventPacketMaxBodyBytes = 1_048_576
    static let defaultDomainEventPacketBinaryMaxBodyBytes = 1_048_576
    static let defaultDomainEventPacketsMaxBodyBytes = 262_144

    enum Mode: String, Sendable {
        case local
        case http
    }

    let mode: Mode
    let baseURL: String?
    let sharedSecret: String?
    let domainEventPacketMaxBodyBytes: Int
    let domainEventPacketBinaryMaxBodyBytes: Int
    let domainEventPacketsMaxBodyBytes: Int

    init(
        mode: Mode,
        baseURL: String?,
        sharedSecret: String?,
        domainEventPacketMaxBodyBytes: Int = IMGatewayRelayConfiguration.defaultDomainEventPacketMaxBodyBytes,
        domainEventPacketBinaryMaxBodyBytes: Int = IMGatewayRelayConfiguration.defaultDomainEventPacketBinaryMaxBodyBytes,
        domainEventPacketsMaxBodyBytes: Int = IMGatewayRelayConfiguration.defaultDomainEventPacketsMaxBodyBytes
    ) {
        self.mode = mode
        self.baseURL = baseURL
        self.sharedSecret = sharedSecret
        self.domainEventPacketMaxBodyBytes = max(1, domainEventPacketMaxBodyBytes)
        self.domainEventPacketBinaryMaxBodyBytes = max(1, domainEventPacketBinaryMaxBodyBytes)
        self.domainEventPacketsMaxBodyBytes = max(1, domainEventPacketsMaxBodyBytes)
    }

    var domainEventPacketMaxBodySize: ByteCount {
        ByteCount(value: domainEventPacketMaxBodyBytes)
    }

    var domainEventPacketBinaryMaxBodySize: ByteCount {
        ByteCount(value: domainEventPacketBinaryMaxBodyBytes)
    }

    var domainEventPacketsMaxBodySize: ByteCount {
        ByteCount(value: domainEventPacketsMaxBodyBytes)
    }

    static func load(from environment: Environment) -> IMGatewayRelayConfiguration {
        let mode = Environment.get("IM_GATEWAY_RELAY_MODE")
            .flatMap(Mode.init(rawValue:))
            ?? (Environment.get("IM_GATEWAY_INTERNAL_BASE_URL") == nil ? .local : .http)
        return IMGatewayRelayConfiguration(
            mode: mode,
            baseURL: Environment.get("IM_GATEWAY_INTERNAL_BASE_URL"),
            sharedSecret: Environment.get("IM_INTERNAL_SHARED_SECRET"),
            domainEventPacketMaxBodyBytes: Environment.get("IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES")
                .flatMap(Int.init(_:)) ?? defaultDomainEventPacketMaxBodyBytes,
            domainEventPacketBinaryMaxBodyBytes: Environment.get("IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES")
                .flatMap(Int.init(_:)) ?? defaultDomainEventPacketBinaryMaxBodyBytes,
            domainEventPacketsMaxBodyBytes: Environment.get("IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES")
                .flatMap(Int.init(_:)) ?? defaultDomainEventPacketsMaxBodyBytes
        )
    }
}

struct IMCommandAPIIngressConfiguration: Sendable {
    let baseURL: String?
    let sharedSecret: String?

    var isEnabled: Bool {
        guard let baseURL else { return false }
        return !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load(from environment: Environment) -> IMCommandAPIIngressConfiguration {
        IMCommandAPIIngressConfiguration(
            baseURL: Environment.get("IM_COMMAND_API_INTERNAL_BASE_URL"),
            sharedSecret: Environment.get("IM_INTERNAL_SHARED_SECRET")
        )
    }
}

struct IMEventStreamConfiguration: Sendable {
    enum Driver: String, Sendable {
        case databaseOutbox = "database-outbox"
        case kafka
    }

    enum SecurityProtocolMode: String, Sendable {
        case plaintext
        case tls
        case saslPlaintext = "sasl_plaintext"
        case saslTLS = "sasl_tls"
    }

    enum SASLMechanismMode: String, Sendable {
        case plain
        case scramSHA256 = "scram-sha-256"
        case scramSHA512 = "scram-sha-512"
    }

    let driver: Driver
    let brokers: [String]
    let topic: String
    let deadLetterTopic: String
    let clientID: String
    let requiredAcknowledgements: String
    let compressionCodec: String
    let queueLingerMilliseconds: Int
    let requestTimeoutMilliseconds: Int
    let messageTimeoutMilliseconds: Int
    let pollIntervalMilliseconds: Int
    let flushTimeoutMilliseconds: Int
    let autoCreateTopics: Bool
    let securityProtocol: SecurityProtocolMode
    let saslMechanism: SASLMechanismMode
    let saslUsername: String?
    let saslPassword: String?
    let tlsCAFile: String?
    let tlsCertificateFile: String?
    let tlsPrivateKeyFile: String?
    let tlsPrivateKeyPassword: String?

    static func load(from environment: Environment) -> IMEventStreamConfiguration {
        let driver = Environment.get("IM_EVENT_STREAM_DRIVER")
            .flatMap(Driver.init(rawValue:))
            ?? .databaseOutbox
        let brokers = (Environment.get("IM_KAFKA_BROKERS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return IMEventStreamConfiguration(
            driver: driver,
            brokers: brokers,
            topic: Environment.get("IM_KAFKA_TOPIC") ?? "conversation-domain-events",
            deadLetterTopic: Environment.get("IM_KAFKA_DEAD_LETTER_TOPIC") ?? "conversation-domain-events-dead-letter",
            clientID: Environment.get("IM_KAFKA_CLIENT_ID") ?? "imserver",
            requiredAcknowledgements: Environment.get("IM_KAFKA_REQUIRED_ACKS") ?? "all",
            compressionCodec: Environment.get("IM_KAFKA_COMPRESSION") ?? "snappy",
            queueLingerMilliseconds: Environment.get("IM_KAFKA_LINGER_MS").flatMap(Int.init(_:)) ?? 5,
            requestTimeoutMilliseconds: Environment.get("IM_KAFKA_REQUEST_TIMEOUT_MS").flatMap(Int.init(_:)) ?? 30_000,
            messageTimeoutMilliseconds: Environment.get("IM_KAFKA_MESSAGE_TIMEOUT_MS").flatMap(Int.init(_:)) ?? 300_000,
            pollIntervalMilliseconds: Environment.get("IM_KAFKA_POLL_INTERVAL_MS").flatMap(Int.init(_:)) ?? 100,
            flushTimeoutMilliseconds: Environment.get("IM_KAFKA_FLUSH_TIMEOUT_MS").flatMap(Int.init(_:)) ?? 10_000,
            autoCreateTopics: parseBooleanEnvironment("IM_KAFKA_AUTO_CREATE_TOPICS", defaultValue: false),
            securityProtocol: Environment.get("IM_KAFKA_SECURITY_PROTOCOL")
                .flatMap(SecurityProtocolMode.init(rawValue:))
                ?? .saslTLS,
            saslMechanism: Environment.get("IM_KAFKA_SASL_MECHANISM")
                .flatMap(SASLMechanismMode.init(rawValue:))
                ?? .scramSHA512,
            saslUsername: Environment.get("IM_KAFKA_SASL_USERNAME"),
            saslPassword: Environment.get("IM_KAFKA_SASL_PASSWORD"),
            tlsCAFile: Environment.get("IM_KAFKA_TLS_CA_FILE"),
            tlsCertificateFile: Environment.get("IM_KAFKA_TLS_CERT_FILE"),
            tlsPrivateKeyFile: Environment.get("IM_KAFKA_TLS_KEY_FILE"),
            tlsPrivateKeyPassword: Environment.get("IM_KAFKA_TLS_KEY_PASSWORD")
        )
    }

    func kafkaBrokerAddresses() throws -> [KafkaConfiguration.BrokerAddress] {
        guard !brokers.isEmpty else {
            throw Abort(.internalServerError, reason: "IM_EVENT_STREAM_DRIVER=kafka requires IM_KAFKA_BROKERS.")
        }

        return try brokers.map { broker in
            let parts = broker.split(separator: ":", maxSplits: 1).map(String.init)
            let host = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !host.isEmpty else {
                throw Abort(.internalServerError, reason: "Invalid Kafka broker entry: \(broker)")
            }
            let port = parts.count == 2 ? (Int(parts[1]) ?? 9092) : 9092
            return KafkaConfiguration.BrokerAddress(host: host, port: port)
        }
    }

    func makeProducerConfiguration(nodeID: String) throws -> KafkaProducerConfiguration {
        var configuration = KafkaProducerConfiguration(
            bootstrapBrokerAddresses: try kafkaBrokerAddresses()
        )
        configuration.identifier = "\(clientID)-\(nodeID)"
        configuration.isIdempotenceEnabled = true
        configuration.maximumInFlightRequestsPerConnection = 5
        configuration.pollInterval = .milliseconds(pollIntervalMilliseconds)
        configuration.flushTimeoutMilliseconds = flushTimeoutMilliseconds
        configuration.isAutoCreateTopicsEnabled = autoCreateTopics
        configuration.queue.maximumMessageQueueTime = .milliseconds(queueLingerMilliseconds)
        configuration.topicConfiguration.requestTimeout = .milliseconds(requestTimeoutMilliseconds)
        configuration.topicConfiguration.messageTimeout = .timeout(.milliseconds(messageTimeoutMilliseconds))
        configuration.topicConfiguration.requiredAcknowledgements = try parseRequiredAcknowledgements()
        configuration.topicConfiguration.compression.codec = try parseCompressionCodec()
        configuration.securityProtocol = try makeSecurityProtocol()
        return configuration
    }

    func makeConsumerConfiguration(
        consumerGroupID: String,
        clientSuffix: String,
        topics: [String]? = nil,
        autoOffsetReset: KafkaConsumerConfiguration.AutoOffsetReset = .earliest
    ) throws -> KafkaConsumerConfiguration {
        let configuredTopics = topics?.filter { !$0.isEmpty } ?? [topic]
        var configuration = KafkaConsumerConfiguration(
            consumptionStrategy: .group(id: consumerGroupID, topics: configuredTopics),
            bootstrapBrokerAddresses: try kafkaBrokerAddresses()
        )
        configuration.identifier = "\(clientID)-\(clientSuffix)"
        configuration.pollInterval = .milliseconds(pollIntervalMilliseconds)
        configuration.isAutoCommitEnabled = false
        configuration.isAutoCreateTopicsEnabled = autoCreateTopics
        configuration.autoOffsetReset = autoOffsetReset
        configuration.maximumPollInterval = .milliseconds(messageTimeoutMilliseconds)
        configuration.securityProtocol = try makeSecurityProtocol()
        return configuration
    }

    private func parseRequiredAcknowledgements() throws -> KafkaTopicConfiguration.RequiredAcknowledgments {
        switch requiredAcknowledgements.lowercased() {
        case "all", "-1":
            return .all
        case "none", "0":
            return .noAcknowledgments
        default:
            guard let value = Int(requiredAcknowledgements), value > 0 else {
                throw Abort(.internalServerError, reason: "Invalid IM_KAFKA_REQUIRED_ACKS value: \(requiredAcknowledgements)")
            }
            return .atLeast(value)
        }
    }

    private func parseCompressionCodec() throws -> KafkaTopicConfiguration.Compression.Codec {
        switch compressionCodec.lowercased() {
        case "none":
            return .none
        case "gzip":
            return .gzip(compressionLevel: .codecDependent)
        case "snappy":
            return .snappy
        case "inherit":
            return .inherit
        default:
            throw Abort(.internalServerError, reason: "Unsupported IM_KAFKA_COMPRESSION value: \(compressionCodec)")
        }
    }

    private func makeSecurityProtocol() throws -> KafkaConfiguration.SecurityProtocol {
        switch securityProtocol {
        case .plaintext:
            return .plaintext
        case .tls:
            return .tls(configuration: makeTLSConfiguration())
        case .saslPlaintext:
            return .saslPlaintext(mechanism: try makeSASLMechanism())
        case .saslTLS:
            return .saslTLS(
                saslMechanism: try makeSASLMechanism(),
                tlsConfiguration: makeTLSConfiguration()
            )
        }
    }

    private func makeSASLMechanism() throws -> KafkaConfiguration.SASLMechanism {
        guard let saslUsername, !saslUsername.isEmpty else {
            throw Abort(.internalServerError, reason: "Kafka SASL requires IM_KAFKA_SASL_USERNAME.")
        }
        guard let saslPassword, !saslPassword.isEmpty else {
            throw Abort(.internalServerError, reason: "Kafka SASL requires IM_KAFKA_SASL_PASSWORD.")
        }

        switch saslMechanism {
        case .plain:
            return .plain(username: saslUsername, password: saslPassword)
        case .scramSHA256:
            return .scramSHA256(username: saslUsername, password: saslPassword)
        case .scramSHA512:
            return .scramSHA512(username: saslUsername, password: saslPassword)
        }
    }

    private func makeTLSConfiguration() -> KafkaConfiguration.TLSConfiguration {
        var configuration = KafkaConfiguration.TLSConfiguration()
        if let tlsCAFile, !tlsCAFile.isEmpty {
            configuration.brokerVerification = .verify(trustRoots: .file(location: tlsCAFile))
        }
        if let tlsCertificateFile, !tlsCertificateFile.isEmpty,
           let tlsPrivateKeyFile, !tlsPrivateKeyFile.isEmpty {
            configuration.clientIdentity = .keyPair(
                privateKey: .init(
                    location: .file(location: tlsPrivateKeyFile),
                    password: tlsPrivateKeyPassword ?? ""
                ),
                certificates: .file(location: tlsCertificateFile)
            )
        }
        return configuration
    }
}

struct IMSummaryStoreConfiguration: Sendable {
    static let defaultShardID = "summary-0"

    let shardIDs: [String]

    static func load(from environment: Environment) -> IMSummaryStoreConfiguration {
        let shardIDs = (Environment.get("IM_SUMMARY_SHARD_IDS") ?? defaultShardID)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return IMSummaryStoreConfiguration(
            shardIDs: shardIDs.isEmpty ? [defaultShardID] : shardIDs
        )
    }
}

struct IMSummaryReadModelConfiguration: Sendable {
    enum ProjectionWriteMode: String, Sendable {
        case sharded
    }

    enum QueryReadSource: String, Sendable {
        case sharded
    }

    let projectionWriteMode: ProjectionWriteMode
    let queryReadSource: QueryReadSource
    let responseMemberUserIDsLimit: Int

    init(
        projectionWriteMode: ProjectionWriteMode,
        queryReadSource: QueryReadSource,
        responseMemberUserIDsLimit: Int = 0
    ) {
        self.projectionWriteMode = projectionWriteMode
        self.queryReadSource = queryReadSource
        self.responseMemberUserIDsLimit = max(0, responseMemberUserIDsLimit)
    }

    static func load(from environment: Environment) -> IMSummaryReadModelConfiguration {
        IMSummaryReadModelConfiguration(
            projectionWriteMode: .sharded,
            queryReadSource: .sharded,
            responseMemberUserIDsLimit: max(
                0,
                Environment.get("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT")
                    .flatMap(Int.init(_:)) ?? 0
            )
        )
    }
}

struct IMSearchIndexConfiguration: Sendable {
    enum Driver: String, Sendable {
        case database
        case openSearch = "opensearch"
    }

    let driver: Driver
    let endpoint: String?
    let indexName: String

    static func load(from environment: Environment) -> IMSearchIndexConfiguration {
        IMSearchIndexConfiguration(
            driver: Environment.get("IM_SEARCH_DRIVER")
                .flatMap(Driver.init(rawValue:))
                ?? .database,
            endpoint: Environment.get("IM_OPENSEARCH_ENDPOINT"),
            indexName: Environment.get("IM_OPENSEARCH_INDEX") ?? "conversation-message-search"
        )
    }
}

struct IMStreamConsumerConfiguration: Sendable {
    enum MessageCreatedLargeGroupDeliveryMode: String, Sendable {
        case ownerDelivery = "owner-delivery"
        case timelinePull = "timeline-pull"
    }

    enum ActiveCompactHintBody: String, Sendable {
        case timelineGap = "timeline-gap"
        case conversationActivity = "conversation-activity"
    }

    static let defaultGroups = [
        "summary-projection-consumer",
        "realtime-delivery-consumer",
        "domain-delivery-consumer",
        "changes-log-consumer",
        "search-index-consumer",
        "notification-consumer",
        "repair-replay-consumer"
    ]

    let enabledGroups: Set<String>
    let preservesGroupedDeploymentsInProduction: Bool
    let streamConsumerQueueCapacity: Int
    let streamConsumerRunBatchSize: Int
    let streamConsumerBatchFillWaitMilliseconds: Int
    let domainDeliveryFanoutConcurrency: Int
    let domainDeliveryRelayBatchSize: Int
    let domainDeliveryOwnerRecordBatchMaxRequests: Int
    let domainDeliveryReplayRecordsEnabled: Bool
    let domainDeliveryRelayAfterRecord: Bool
    let domainDeliverySkipsMessageCreatedOwnerDelivery: Bool
    let domainDeliveryMessageCreatedLargeGroupMode: MessageCreatedLargeGroupDeliveryMode
    let domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold: Int
    let notificationSkipsMessageCreatedOwnerNotifications: Bool
    let notificationMessageCreatedOwnerNotificationSkipRecipientThreshold: Int
    let realtimeDeliveryAsyncRelayEnabled: Bool
    let realtimeDeliveryAsyncMaxInFlight: Int
    let realtimeDeliveryAsyncMaxQueued: Int
    let realtimeDeliverySlowLogMilliseconds: Int
    let realtimeRemoteDispatchUserBatchSize: Int
    let realtimeRemoteDispatchMaxInFlight: Int
    let realtimeMessageCreatedLightweightRecipientThreshold: Int
    let realtimeActiveCompactHintBody: ActiveCompactHintBody
    let realtimeMessageCreatedLightweightPreviewMaxCharacters: Int
    let realtimeActiveCompactHintPreviewMaxCharacters: Int
    let realtimeMessageCreatedPreviewLookupEnabled: Bool
    let realtimeActiveConversationUnsplitFallbackEnabled: Bool
    let realtimeActiveConversationRouteCacheTTLMilliseconds: Int
    let realtimeActiveConversationRouteCacheMaxEntries: Int
    let realtimeMessageCreatedCoalesceWindowMilliseconds: Int
    let realtimeActiveCompactHintCoalesceWindowMilliseconds: Int
    let summaryProjectionMessageCreatedActivityOnlyRecipientThreshold: Int
    let summaryProjectionActivityCoalesceWindowMilliseconds: Int
    let streamConsumerRequiresMessageCreatedRecipientSnapshot: Bool
    let domainDeliveryTransientMaxAttempts: Int
    let domainDeliveryTimelineNoticeMaxWaitMilliseconds: Int
    let domainDeliveryTimelineNoticeRetryDelayMilliseconds: Int

    static func load(from environment: Environment) -> IMStreamConsumerConfiguration {
        let configured = (Environment.get("IM_STREAM_CONSUMER_GROUPS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold = max(
            0,
            Environment.get("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD")
                .flatMap(Int.init(_:)) ?? 0
        )
        let domainDeliveryMessageCreatedLargeGroupMode = Environment.get(
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE"
        )
        .flatMap {
            MessageCreatedLargeGroupDeliveryMode(
                rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        } ?? (domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold > 0 ? .timelinePull : .ownerDelivery)
        return IMStreamConsumerConfiguration(
            enabledGroups: Set(configured.isEmpty ? defaultGroups : configured),
            preservesGroupedDeploymentsInProduction: Environment.get("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")
                .map { ["1", "true", "yes"].contains($0.lowercased()) }
                ?? false,
            streamConsumerQueueCapacity: max(
                1,
                Environment.get("IM_STREAM_CONSUMER_QUEUE_CAPACITY").flatMap(Int.init(_:)) ?? 512
            ),
            streamConsumerRunBatchSize: max(
                1,
                Environment.get("IM_STREAM_CONSUMER_RUN_BATCH_SIZE").flatMap(Int.init(_:)) ?? 32
            ),
            streamConsumerBatchFillWaitMilliseconds: min(
                1_000,
                max(
                    0,
                    Environment.get("IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS").flatMap(Int.init(_:)) ?? 0
                )
            ),
            domainDeliveryFanoutConcurrency: max(1, Environment.get("IM_DOMAIN_DELIVERY_FANOUT_CONCURRENCY").flatMap(Int.init(_:)) ?? 4),
            domainDeliveryRelayBatchSize: max(1, Environment.get("IM_DOMAIN_DELIVERY_RELAY_BATCH_SIZE").flatMap(Int.init(_:)) ?? 16),
            domainDeliveryOwnerRecordBatchMaxRequests: max(
                1,
                Environment.get("IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS")
                    .flatMap(Int.init(_:)) ?? OwnerDomainEventDeliveryService.defaultPostgresRecordBatchMaxRequests
            ),
            domainDeliveryReplayRecordsEnabled: parseBooleanEnvironment(
                "IM_DOMAIN_DELIVERY_REPLAY_RECORDS_ENABLED",
                defaultValue: false
            ),
            domainDeliveryRelayAfterRecord: parseBooleanEnvironment(
                "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD",
                defaultValue: !Set(configured.isEmpty ? defaultGroups : configured).contains("realtime-delivery-consumer")
            ),
            domainDeliverySkipsMessageCreatedOwnerDelivery: parseBooleanEnvironment(
                "IM_DOMAIN_DELIVERY_SKIP_MESSAGE_CREATED_OWNER_DELIVERY",
                defaultValue: false
            ),
            domainDeliveryMessageCreatedLargeGroupMode: domainDeliveryMessageCreatedLargeGroupMode,
            domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold: domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold,
            notificationSkipsMessageCreatedOwnerNotifications: parseBooleanEnvironment(
                "IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS",
                defaultValue: false
            ),
            notificationMessageCreatedOwnerNotificationSkipRecipientThreshold: max(
                0,
                Environment.get("IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD")
                    .flatMap(Int.init(_:)) ?? 0
            ),
            realtimeDeliveryAsyncRelayEnabled: parseBooleanEnvironment(
                "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED",
                defaultValue: false
            ),
            realtimeDeliveryAsyncMaxInFlight: max(
                1,
                Environment.get("IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT").flatMap(Int.init(_:)) ?? 32
            ),
            realtimeDeliveryAsyncMaxQueued: max(
                0,
                Environment.get("IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED").flatMap(Int.init(_:)) ?? 1024
            ),
            realtimeDeliverySlowLogMilliseconds: max(
                0,
                Environment.get("IM_REALTIME_DELIVERY_SLOW_LOG_MS").flatMap(Int.init(_:)) ?? 1000
            ),
            realtimeRemoteDispatchUserBatchSize: max(
                1,
                Environment.get("IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE").flatMap(Int.init(_:)) ?? 512
            ),
            realtimeRemoteDispatchMaxInFlight: max(
                1,
                Environment.get("IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT").flatMap(Int.init(_:)) ?? 8
            ),
            realtimeMessageCreatedLightweightRecipientThreshold: max(
                0,
                Environment.get("IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD").flatMap(Int.init(_:)) ?? 0
            ),
            realtimeActiveCompactHintBody: Environment.get("IM_REALTIME_ACTIVE_COMPACT_HINT_BODY")
                .flatMap {
                    ActiveCompactHintBody(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                ?? .timelineGap,
            realtimeMessageCreatedLightweightPreviewMaxCharacters: max(
                0,
                Environment.get("IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_PREVIEW_MAX_CHARS").flatMap(Int.init(_:)) ?? 120
            ),
            realtimeActiveCompactHintPreviewMaxCharacters: max(
                0,
                Environment.get("IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS").flatMap(Int.init(_:)) ?? 0
            ),
            realtimeMessageCreatedPreviewLookupEnabled: parseBooleanEnvironment(
                "IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED",
                defaultValue: true
            ),
            realtimeActiveConversationUnsplitFallbackEnabled: parseBooleanEnvironment(
                "IM_REALTIME_ACTIVE_CONVERSATION_UNSPLIT_FALLBACK_ENABLED",
                defaultValue: false
            ),
            realtimeActiveConversationRouteCacheTTLMilliseconds: max(
                0,
                Environment.get("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS").flatMap(Int.init(_:)) ?? 1000
            ),
            realtimeActiveConversationRouteCacheMaxEntries: max(
                0,
                Environment.get("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES").flatMap(Int.init(_:)) ?? 4096
            ),
            realtimeMessageCreatedCoalesceWindowMilliseconds: max(
                0,
                Environment.get("IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS").flatMap(Int.init(_:)) ?? 0
            ),
            realtimeActiveCompactHintCoalesceWindowMilliseconds: max(
                0,
                Environment.get("IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS").flatMap(Int.init(_:)) ?? 0
            ),
            summaryProjectionMessageCreatedActivityOnlyRecipientThreshold: max(
                0,
                Environment.get("IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD")
                    .flatMap(Int.init(_:)) ?? 0
            ),
            summaryProjectionActivityCoalesceWindowMilliseconds: max(
                0,
                Environment.get("IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS")
                    .flatMap(Int.init(_:)) ?? 0
            ),
            streamConsumerRequiresMessageCreatedRecipientSnapshot: parseBooleanEnvironment(
                "IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT",
                defaultValue: false
            ),
            domainDeliveryTransientMaxAttempts: max(
                1,
                Environment.get("IM_DOMAIN_DELIVERY_TRANSIENT_MAX_ATTEMPTS").flatMap(Int.init(_:)) ?? 3
            ),
            domainDeliveryTimelineNoticeMaxWaitMilliseconds: max(
                100,
                Environment.get("IM_DOMAIN_DELIVERY_TIMELINE_NOTICE_MAX_WAIT_MS").flatMap(Int.init(_:)) ?? 10_000
            ),
            domainDeliveryTimelineNoticeRetryDelayMilliseconds: max(
                10,
                Environment.get("IM_DOMAIN_DELIVERY_TIMELINE_NOTICE_RETRY_DELAY_MS").flatMap(Int.init(_:)) ?? 100
            )
        )
    }

    func isEnabled(_ groupID: String) -> Bool {
        enabledGroups.contains(groupID)
    }

    var orderedEnabledGroups: [String] {
        enabledGroups.sorted()
    }
}

struct IMShardTopologyConfiguration: Sendable {
    let shardIDs: [String]

    static func load(from environment: Environment) -> IMShardTopologyConfiguration {
        let shardIDs = (Environment.get("IM_CONVERSATION_SHARD_IDS") ?? SingleShardConversationShardRouter.defaultShardID)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return IMShardTopologyConfiguration(
            shardIDs: shardIDs.isEmpty ? [SingleShardConversationShardRouter.defaultShardID] : shardIDs
        )
    }
}

enum GatewayRelayConfigurationError: Error {
    case httpModeRequiresBaseURL
    case productionCommandAPIRequiresHTTPMode
}

private struct IMGatewayRelayConfigurationStorageKey: StorageKey {
    typealias Value = IMGatewayRelayConfiguration
}

private struct IMCommandAPIIngressConfigurationStorageKey: StorageKey {
    typealias Value = IMCommandAPIIngressConfiguration
}

private struct IMEventStreamConfigurationStorageKey: StorageKey {
    typealias Value = IMEventStreamConfiguration
}

private struct IMSearchIndexConfigurationStorageKey: StorageKey {
    typealias Value = IMSearchIndexConfiguration
}

private struct IMShardTopologyConfigurationStorageKey: StorageKey {
    typealias Value = IMShardTopologyConfiguration
}

private struct IMSummaryStoreConfigurationStorageKey: StorageKey {
    typealias Value = IMSummaryStoreConfiguration
}

private struct IMSummaryReadModelConfigurationStorageKey: StorageKey {
    typealias Value = IMSummaryReadModelConfiguration
}

private struct IMStreamConsumerConfigurationStorageKey: StorageKey {
    typealias Value = IMStreamConsumerConfiguration
}

extension Application {
    var gatewayRelayConfiguration: IMGatewayRelayConfiguration {
        get {
            if let configuration = storage[IMGatewayRelayConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMGatewayRelayConfiguration.load(from: environment)
            storage[IMGatewayRelayConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMGatewayRelayConfigurationStorageKey.self] = newValue }
    }

    var commandAPIIngressConfiguration: IMCommandAPIIngressConfiguration {
        get {
            if let configuration = storage[IMCommandAPIIngressConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMCommandAPIIngressConfiguration.load(from: environment)
            storage[IMCommandAPIIngressConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMCommandAPIIngressConfigurationStorageKey.self] = newValue }
    }

    var eventStreamConfiguration: IMEventStreamConfiguration {
        get {
            if let configuration = storage[IMEventStreamConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMEventStreamConfiguration.load(from: environment)
            storage[IMEventStreamConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMEventStreamConfigurationStorageKey.self] = newValue }
    }

    var searchIndexConfiguration: IMSearchIndexConfiguration {
        get {
            if let configuration = storage[IMSearchIndexConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMSearchIndexConfiguration.load(from: environment)
            storage[IMSearchIndexConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMSearchIndexConfigurationStorageKey.self] = newValue }
    }

    var shardTopologyConfiguration: IMShardTopologyConfiguration {
        get {
            if let configuration = storage[IMShardTopologyConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMShardTopologyConfiguration.load(from: environment)
            storage[IMShardTopologyConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMShardTopologyConfigurationStorageKey.self] = newValue }
    }

    var summaryStoreConfiguration: IMSummaryStoreConfiguration {
        get {
            if let configuration = storage[IMSummaryStoreConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMSummaryStoreConfiguration.load(from: environment)
            storage[IMSummaryStoreConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMSummaryStoreConfigurationStorageKey.self] = newValue }
    }

    var summaryReadModelConfiguration: IMSummaryReadModelConfiguration {
        get {
            if let configuration = storage[IMSummaryReadModelConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMSummaryReadModelConfiguration.load(from: environment)
            storage[IMSummaryReadModelConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMSummaryReadModelConfigurationStorageKey.self] = newValue }
    }

    var streamConsumerConfiguration: IMStreamConsumerConfiguration {
        get {
            if let configuration = storage[IMStreamConsumerConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMStreamConsumerConfiguration.load(from: environment)
            storage[IMStreamConsumerConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMStreamConsumerConfigurationStorageKey.self] = newValue }
    }
}

func parseBooleanEnvironment(_ key: String, defaultValue: Bool) -> Bool {
    guard let rawValue = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return defaultValue
    }

    switch rawValue {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return defaultValue
    }
}
