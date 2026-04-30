import Foundation
import Kafka
import Vapor

struct IMGatewayRelayConfiguration: Sendable {
    enum Mode: String, Sendable {
        case local
        case http
    }

    let mode: Mode
    let baseURL: String?
    let sharedSecret: String?

    static func load(from environment: Environment) -> IMGatewayRelayConfiguration {
        let mode = Environment.get("IM_GATEWAY_RELAY_MODE")
            .flatMap(Mode.init(rawValue:))
            ?? (Environment.get("IM_GATEWAY_INTERNAL_BASE_URL") == nil ? .local : .http)
        return IMGatewayRelayConfiguration(
            mode: mode,
            baseURL: Environment.get("IM_GATEWAY_INTERNAL_BASE_URL"),
            sharedSecret: Environment.get("IM_INTERNAL_SHARED_SECRET")
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
        topics: [String]? = nil
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
        configuration.autoOffsetReset = .earliest
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
        case legacy
        case sharded
        case dualWrite = "dual-write"
    }

    enum QueryReadSource: String, Sendable {
        case legacy
        case sharded
    }

    let projectionWriteMode: ProjectionWriteMode
    let queryReadSource: QueryReadSource

    static func load(from environment: Environment) -> IMSummaryReadModelConfiguration {
        IMSummaryReadModelConfiguration(
            projectionWriteMode: Environment.get("IM_SUMMARY_PROJECTION_WRITE_MODE")
                .flatMap(ProjectionWriteMode.init(rawValue:))
                ?? .sharded,
            queryReadSource: Environment.get("IM_SUMMARY_QUERY_READ_SOURCE")
                .flatMap(QueryReadSource.init(rawValue:))
                ?? .sharded
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
    static let defaultGroups = [
        "summary-projection-consumer",
        "changes-log-consumer",
        "search-index-consumer",
        "notification-consumer",
        "repair-replay-consumer"
    ]

    let enabledGroups: Set<String>
    let preservesGroupedDeploymentsInProduction: Bool

    static func load(from environment: Environment) -> IMStreamConsumerConfiguration {
        let configured = (Environment.get("IM_STREAM_CONSUMER_GROUPS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return IMStreamConsumerConfiguration(
            enabledGroups: Set(configured.isEmpty ? defaultGroups : configured),
            preservesGroupedDeploymentsInProduction: Environment.get("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")
                .map { ["1", "true", "yes"].contains($0.lowercased()) }
                ?? false
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

private func parseBooleanEnvironment(_ key: String, defaultValue: Bool) -> Bool {
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
