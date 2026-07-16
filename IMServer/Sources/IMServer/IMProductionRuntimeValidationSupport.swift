import Foundation
import Vapor

enum IMProductionRuntimeValidationSupport {
    static let maximumActiveCompactHintCoalesceWindowMilliseconds = 100
    static let maximumActiveCompactHintPreviewCharacters = 120

    static func validatePublicBaseURLConfiguration() throws {
        let publicBaseURL = Environment.get("PUBLIC_BASE_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imPublicBaseURL = Environment.get("IM_PUBLIC_BASE_URL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = publicBaseURL?.isEmpty == false ? "PUBLIC_BASE_URL" : "IM_PUBLIC_BASE_URL"
        let value = publicBaseURL?.isEmpty == false ? publicBaseURL : imPublicBaseURL

        guard let rawURL = value, !rawURL.isEmpty else {
            throw Abort(.internalServerError, reason: "Production requires PUBLIC_BASE_URL or IM_PUBLIC_BASE_URL to be configured.")
        }
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw Abort(.internalServerError, reason: "Production \(key) must be an HTTP URL with a host.")
        }

        guard !parseBooleanEnvironment("IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL", defaultValue: false) else {
            throw Abort(
                .internalServerError,
                reason: "Production IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL is forbidden for long-term production."
            )
        }
        guard scheme == "https" else {
            throw Abort(.internalServerError, reason: "Production \(key) must use https.")
        }

        let port = components.port ?? 443
        guard port == 443 else {
            throw Abort(.internalServerError, reason: "Production \(key) must use default HTTPS port 443.")
        }

        guard isPublicBaseURLHost(host) else {
            throw Abort(.internalServerError, reason: "Production \(key) host must be a real public DNS name and must not be localhost, an IP literal, private, link-local, carrier-grade NAT, benchmarking address space, or placeholder domain.")
        }
    }

    static func validateProductionSecretConfiguration(_ app: Application) throws {
        let authConfiguration = try AuthConfiguration.load(from: app.environment)
        for jwtSecret in authConfiguration.jwtSecrets {
            let key = jwtSecret.keyID.map { "JWT_SECRETS[\($0)]" } ?? "JWT_SECRET"
            try requireProductionSecret(key, value: jwtSecret.secret, minimumLength: 32)
        }

        try requireProductionSecret("IM_INTERNAL_SHARED_SECRET", minimumLength: 32)
    }

    static func validatePrimaryDatabaseConfiguration() throws {
        let requiredKeys = [
            "DATABASE_PRIMARY_HOST",
            "DATABASE_PRIMARY_NAME",
            "DATABASE_PRIMARY_USERNAME",
            "DATABASE_PRIMARY_PASSWORD"
        ]
        let missing = requiredKeys.filter { key in
            Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }

        guard missing.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Production requires explicit primary database configuration: \(missing.joined(separator: ", "))."
            )
        }
        try requireProductionSecret("DATABASE_PRIMARY_PASSWORD", minimumLength: 16)
    }

    static func validateDevelopmentSeedConfigurationDisabled() throws {
        let forbiddenKeys = [
            "SEED_USER_EMAIL",
            "SEED_USER_EMAILS",
            "SEED_USER_PASSWORD"
        ]
        let presentKeys = forbiddenKeys.filter { key in
            Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        guard presentKeys.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Production must not include development seed user configuration: \(presentKeys.joined(separator: ", "))."
            )
        }
    }

    static func validateAdminAPIConfiguration(_ app: Application) throws {
        guard app.adminConfiguration.isEnabled else {
            return
        }

        try requireProductionSecret("IM_ADMIN_SHARED_SECRET", minimumLength: 32)

        let adminSecret = Environment.get("IM_ADMIN_SHARED_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let internalSecret = Environment.get("IM_INTERNAL_SHARED_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let adminSecret,
           let internalSecret,
           !adminSecret.isEmpty,
           adminSecret == internalSecret {
            throw Abort(
                .internalServerError,
                reason: "Production IM_ADMIN_SHARED_SECRET must be different from IM_INTERNAL_SHARED_SECRET."
            )
        }
    }

    static func validateGatewayCommandIngressConfiguration(_ app: Application) throws {
        guard app.commandAPIIngressConfiguration.isEnabled else {
            throw Abort(.internalServerError, reason: "Production gateway requires IM_COMMAND_API_INTERNAL_BASE_URL to proxy IM command ingress.")
        }
    }

    static func validateCellIngressConfiguration(_ app: Application) throws {
        let registryConfiguration = app.cellIngressRegistryConfiguration
        if let invalidModeValue = registryConfiguration.invalidModeValue {
            throw Abort(
                .internalServerError,
                reason: "IM_CELL_INGRESS_REGISTRY_MODE must be static or database; got \(invalidModeValue)."
            )
        }
        let configuration = app.cellIngressConfiguration
        if registryConfiguration.mode == .database {
            guard let sharedSecret = configuration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
                  sharedSecret.count >= 32
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Database Cell registry requires IM_CELL_INGRESS_SHARED_SECRET or IM_INTERNAL_SHARED_SECRET with at least 32 characters."
                )
            }
            return
        }
        guard configuration.invalidEndpointEntries.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Invalid Cell ingress endpoint configuration: \(configuration.invalidEndpointEntryDescriptions.joined(separator: ", "))."
            )
        }
        guard !configuration.configuredEndpoints.isEmpty else {
            return
        }
        guard let sharedSecret = configuration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              sharedSecret.count >= 32
        else {
            throw Abort(
                .internalServerError,
                reason: "Cell ingress endpoint maps require IM_CELL_INGRESS_SHARED_SECRET or IM_INTERNAL_SHARED_SECRET with at least 32 characters."
            )
        }
        for entry in configuration.configuredEndpoints {
            let purpose = entry.purpose?.rawValue ?? "legacy"
            guard let components = URLComponents(string: entry.endpoint),
                  components.scheme?.lowercased() == "https",
                  let host = components.host,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Production \(purpose) Cell ingress endpoint for \(entry.cellID) must use https and include a host."
                )
            }
        }
    }

    static func validateNodeDispatchConfiguration(_ app: Application) throws {
        let configuration = app.nodeDispatchConfiguration
        if let invalidModeValue = configuration.invalidModeValue {
            throw Abort(
                .internalServerError,
                reason: "IM_NODE_DISPATCH_MODE must be redis or http; got \(invalidModeValue)."
            )
        }
        guard configuration.mode == .http else {
            return
        }
        guard !configuration.endpointsByNodeID.isEmpty,
              let sharedSecret = configuration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              sharedSecret.count >= 32
        else {
            throw Abort(
                .internalServerError,
                reason: "IM_NODE_DISPATCH_MODE=http requires IM_GATEWAY_NODE_DISPATCH_ENDPOINTS and IM_NODE_DISPATCH_SHARED_SECRET (or a Cell/internal fallback) with at least 32 characters."
            )
        }
        if app.imRuntimeRole == .gateway,
           configuration.endpoint(for: app.imNodeID) == nil {
            throw Abort(
                .internalServerError,
                reason: "Production HTTP node dispatch requires IM_GATEWAY_NODE_DISPATCH_ENDPOINTS to include this gateway IM_NODE_ID."
            )
        }
        for (nodeID, endpoint) in configuration.endpointsByNodeID {
            guard let components = URLComponents(string: endpoint),
                  components.scheme?.lowercased() == "https",
                  let host = components.host,
                  !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Production node dispatch endpoint for \(nodeID) must use https and include a host."
                )
            }
        }
    }

    static func validateGatewayRealtimeFanoutProtection(_ app: Application) throws {
        guard app.imTCPConfiguration.dropsRealtimeWhenNotWritable else {
            throw Abort(
                .internalServerError,
                reason: "Production gateway requires IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true so slow clients cannot retain unbounded best-effort realtime writes."
            )
        }

        let fanoutConfiguration = app.gatewayLocalFanoutConfiguration
        guard fanoutConfiguration.activeConversationFanoutEnabled else {
            throw Abort(
                .internalServerError,
                reason: "Production gateway requires IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED=true so large-group message fanout sends compact realtime hints only to active chat viewers and lets inactive users pull timelines."
            )
        }

        try validateActiveCompactHintMessageLite(
            app.streamConsumerConfiguration,
            context: "Production gateway"
        )

        guard fanoutConfiguration.batchSize <= 1024 else {
            throw Abort(
                .internalServerError,
                reason: "Production gateway requires IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE <= 1024 so one local fanout chunk cannot monopolize a gateway EventLoop with too many TCP writes."
            )
        }

        guard fanoutConfiguration.eventLoopYieldChunkCount <= 256 else {
            throw Abort(
                .internalServerError,
                reason: "Production gateway requires IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS <= 256 so hot-room local fanout periodically yields gateway EventLoops for ACKs, heartbeats, and small realtime packets."
            )
        }

        guard app.streamConsumerConfiguration.realtimeRemoteDispatchMaxInFlight > 1 else {
            throw Abort(
                .internalServerError,
                reason: "Production gateway requires IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT > 1 so cross-node realtime fanout is not serialized under large-group bursts."
            )
        }

        guard app.streamConsumerConfiguration.realtimeRemoteDispatchMaxInFlight <= 64 else {
            throw Abort(
                .internalServerError,
                reason: "Production gateway requires IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT <= 64 so one process cannot retain too many concurrent cross-node realtime relay requests under large-group bursts."
            )
        }

        guard app.streamConsumerConfiguration.realtimeRemoteDispatchUserBatchSize <= 2048 else {
            throw Abort(
                .internalServerError,
                reason: "Production gateway requires IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE <= 2048 so a single cross-node realtime relay packet cannot grow without a bounded recipient batch."
            )
        }

    }

    static func validateCommandOwnerRoutingConfiguration(_ app: Application, requiresLocalNodeID: Bool) throws {
        guard app.sequenceAllocationConfiguration.mode == .block else {
            return
        }
        guard !app.commandOwnerRoutingConfiguration.nodes.isEmpty else {
            throw Abort(.internalServerError, reason: "IM_SEQUENCE_ALLOCATION_MODE=block requires IM_COMMAND_NODE_URLS for conversation owner routing.")
        }
        guard let secret = app.commandOwnerRoutingConfiguration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty
        else {
            throw Abort(.internalServerError, reason: "IM_SEQUENCE_ALLOCATION_MODE=block requires IM_COMMAND_INTERNAL_SHARED_SECRET or IM_INTERNAL_SHARED_SECRET.")
        }
        if requiresLocalNodeID {
            guard let nodeID = app.commandOwnerRoutingConfiguration.nodeID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  app.commandOwnerRoutingConfiguration.nodes.contains(where: { $0.id == nodeID })
            else {
                throw Abort(.internalServerError, reason: "Production command-api with block sequence allocation requires IM_COMMAND_NODE_ID to match an entry in IM_COMMAND_NODE_URLS.")
            }
        }
    }

    static func validateConversationShardConfiguration(_ app: Application) throws {
        let configuredShardIDs = app.shardTopologyConfiguration.shardIDs
        let missingPrimaryShardIDs = configuredShardIDs.filter {
            app.conversationShardDatabaseIDs[$0] == nil
        }
        guard missingPrimaryShardIDs.isEmpty else {
            let missing = missingPrimaryShardIDs.joined(separator: ", ")
            throw Abort(
                .internalServerError,
                reason: "Conversation shards are missing database configuration for: \(missing). Set DATABASE_CONVERSATION_<SHARD>_* for every IM_CONVERSATION_SHARD_IDS entry in production."
            )
        }

        if configuredShardIDs.count > 1 {
            let rawCacheLimit = Environment.get("IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES")
            guard let rawCacheLimit,
                  !rawCacheLimit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Multi-shard production requires IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES so directory lookup memory and fallback load are explicit."
                )
            }
            guard app.conversationShardRoutingConfiguration.directoryCacheMaxEntries >= 1_024 else {
                throw Abort(
                    .internalServerError,
                    reason: "Multi-shard production requires IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES >= 1024."
                )
            }
            let rawCacheTTL = Environment.get("IM_CONVERSATION_SHARD_DIRECTORY_CACHE_TTL_SECONDS")
            guard let rawCacheTTL,
                  !rawCacheTTL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Multi-shard production requires IM_CONVERSATION_SHARD_DIRECTORY_CACHE_TTL_SECONDS so Cell route migration staleness is bounded."
                )
            }
            let cacheTTL = app.conversationShardRoutingConfiguration.directoryCacheTTLSeconds
            guard (1...300).contains(cacheTTL) else {
                throw Abort(
                    .internalServerError,
                    reason: "Multi-shard production requires IM_CONVERSATION_SHARD_DIRECTORY_CACHE_TTL_SECONDS between 1 and 300."
                )
            }
        }
    }

    static func validateGatewayRelayConfiguration(_ app: Application) throws {
        try validateGatewayRelayBodyLimitConfiguration(app)
        guard app.gatewayRelayConfiguration.mode == .http else {
            throw GatewayRelayConfigurationError.productionCommandAPIRequiresHTTPMode
        }
        guard let baseURL = app.gatewayRelayConfiguration.baseURL, !baseURL.isEmpty else {
            throw GatewayRelayConfigurationError.httpModeRequiresBaseURL
        }
        guard let secret = app.gatewayRelayConfiguration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty
        else {
            throw Abort(.internalServerError, reason: "Production gateway relay requires IM_INTERNAL_SHARED_SECRET.")
        }
    }

    static func validateGatewayRelayBodyLimitConfiguration(_ app: Application) throws {
        let configuration = app.gatewayRelayConfiguration
        let minimumBodyBytes = 64 * 1024
        let maximumBodyBytes = 16 * 1024 * 1024
        try validateRelayBodyLimit(
            name: "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES",
            value: configuration.domainEventPacketMaxBodyBytes,
            minimum: minimumBodyBytes,
            maximum: maximumBodyBytes
        )
        try validateRelayBodyLimit(
            name: "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES",
            value: configuration.domainEventPacketBinaryMaxBodyBytes,
            minimum: minimumBodyBytes,
            maximum: maximumBodyBytes
        )
        try validateRelayBodyLimit(
            name: "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES",
            value: configuration.domainEventPacketsMaxBodyBytes,
            minimum: minimumBodyBytes,
            maximum: maximumBodyBytes
        )
    }

    static func validateTCPTransportExposure(_ app: Application) throws {
        guard app.environment == .production,
              app.imTCPConfiguration.enabled,
              !app.imTCPConfiguration.requiresTLSTermination,
              !isPrivateOrLoopbackTCPHost(app.imTCPConfiguration.host)
        else {
            return
        }

        throw Abort(
            .internalServerError,
            reason: "Production TCP realtime on a public bind requires IM_TCP_REQUIRES_TLS_TERMINATION=true and TLS termination, VPN, or service-mesh mTLS in front of the TCP port."
        )
    }

    static func validateKafkaProducerConfiguration(_ app: Application) throws {
        guard app.eventStreamConfiguration.driver == .kafka else {
            throw Abort(.internalServerError, reason: "\(app.imRuntimeRole.rawValue) requires IM_EVENT_STREAM_DRIVER=kafka in production.")
        }
        try validateProductionKafkaStreamConfiguration(app)
        _ = try app.eventStreamConfiguration.makeProducerConfiguration(nodeID: app.imNodeID)
    }

    static func validateKafkaConsumerConfiguration(_ app: Application) throws {
        guard app.eventStreamConfiguration.driver == .kafka else {
            throw Abort(.internalServerError, reason: "\(app.imRuntimeRole.rawValue) requires IM_EVENT_STREAM_DRIVER=kafka in production.")
        }
        try validateProductionKafkaStreamConfiguration(app)
        _ = try app.eventStreamConfiguration.makeConsumerConfiguration(
            consumerGroupID: "summary-projection-consumer",
            clientSuffix: "\(app.imRuntimeRole.rawValue)-validation",
            topics: [app.eventStreamConfiguration.topic]
        )
    }

    private static func validateProductionKafkaStreamConfiguration(_ app: Application) throws {
        let configuration = app.eventStreamConfiguration
        try requireExplicitKafkaEnvironmentKey("IM_KAFKA_TOPIC", role: app.imRuntimeRole)
        try requireExplicitKafkaEnvironmentKey("IM_KAFKA_DEAD_LETTER_TOPIC", role: app.imRuntimeRole)
        try requireExplicitKafkaEnvironmentKey("IM_KAFKA_CLIENT_ID", role: app.imRuntimeRole)
        guard configuration.requiredAcknowledgements.lowercased() == "all"
            || configuration.requiredAcknowledgements == "-1"
        else {
            throw Abort(
                .internalServerError,
                reason: "\(app.imRuntimeRole.rawValue) requires IM_KAFKA_REQUIRED_ACKS=all in production so committed domain events are acknowledged by all in-sync replicas."
            )
        }
        guard configuration.autoCreateTopics == false else {
            throw Abort(
                .internalServerError,
                reason: "\(app.imRuntimeRole.rawValue) requires IM_KAFKA_AUTO_CREATE_TOPICS=false in production so topic partitioning and retention are managed explicitly."
            )
        }
        guard configuration.securityProtocol == .saslTLS else {
            throw Abort(
                .internalServerError,
                reason: "\(app.imRuntimeRole.rawValue) requires IM_KAFKA_SECURITY_PROTOCOL=sasl_tls in production."
            )
        }
        guard configuration.saslMechanism == .scramSHA512 else {
            throw Abort(
                .internalServerError,
                reason: "\(app.imRuntimeRole.rawValue) requires IM_KAFKA_SASL_MECHANISM=scram-sha-512 in production."
            )
        }
        guard configuration.saslUsername?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Abort(
                .internalServerError,
                reason: "\(app.imRuntimeRole.rawValue) requires IM_KAFKA_SASL_USERNAME in production."
            )
        }
        guard configuration.saslPassword?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Abort(
                .internalServerError,
                reason: "\(app.imRuntimeRole.rawValue) requires IM_KAFKA_SASL_PASSWORD in production."
            )
        }
        try requireProductionSecret(
            "IM_KAFKA_SASL_PASSWORD",
            value: configuration.saslPassword,
            minimumLength: 16
        )
        guard configuration.tlsCAFile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Abort(
                .internalServerError,
                reason: "\(app.imRuntimeRole.rawValue) requires IM_KAFKA_TLS_CA_FILE in production."
            )
        }
    }

    private static func requireExplicitKafkaEnvironmentKey(_ key: String, role: IMRuntimeRole) throws {
        guard Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Abort(
                .internalServerError,
                reason: "\(role.rawValue) requires \(key) in production."
            )
        }
    }

    static func validateSummaryReadModelReadConfiguration(_ app: Application) throws {
        try requireSummaryReadModelEnvironmentKey(
            "IM_SUMMARY_QUERY_READ_SOURCE",
            expectedValue: "sharded",
            role: app.imRuntimeRole
        )
        guard Environment.get("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false,
            app.summaryReadModelConfiguration.responseMemberUserIDsLimit > 0
        else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT > 0 so large-group summary/list responses do not return full member_user_ids payloads."
            )
        }
        try validateSummaryShardDatabasesConfigured(app)
    }

    static func validateSummaryReadModelWriteConfiguration(_ app: Application) throws {
        try requireSummaryReadModelEnvironmentKey(
            "IM_SUMMARY_PROJECTION_WRITE_MODE",
            expectedValue: "sharded",
            role: app.imRuntimeRole
        )
        try validateSummaryShardDatabasesConfigured(app)
    }

    private static func requireSummaryReadModelEnvironmentKey(
        _ key: String,
        expectedValue: String,
        role: IMRuntimeRole
    ) throws {
        let value = Environment.get(key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard value == expectedValue else {
            throw Abort(
                .internalServerError,
                reason: "\(role.rawValue) requires \(key)=\(expectedValue) in production."
            )
        }
    }

    static func validateSummaryShardDatabasesConfigured(_ app: Application) throws {
        let configuredShardIDs = app.summaryStoreConfiguration.shardIDs
        let missingShardIDs = configuredShardIDs.filter { app.summaryShardDatabaseIDs[$0] == nil }
        guard missingShardIDs.isEmpty else {
            let missing = missingShardIDs.joined(separator: ", ")
            throw Abort(
                .internalServerError,
                reason: "Summary read model shards are missing database configuration for: \(missing). Set DATABASE_SUMMARY_<SHARD>_* for every IM_SUMMARY_SHARD_IDS entry in production."
            )
        }
    }

    static func validateSearchConfiguration(_ app: Application) throws {
        guard app.searchIndexConfiguration.driver == .openSearch else {
            return
        }
        guard let endpoint = app.searchIndexConfiguration.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty
        else {
            throw Abort(.internalServerError, reason: "IM_SEARCH_DRIVER=opensearch requires IM_OPENSEARCH_ENDPOINT in production.")
        }
        try validateProductionHTTPSDependencyEndpoint(
            key: "IM_OPENSEARCH_ENDPOINT",
            rawValue: endpoint
        )
    }

    static func validateProductionMediaStorageConfiguration(_ app: Application) throws {
        let provider = (Environment.get("MEDIA_STORAGE_PROVIDER") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard provider == "s3compatible" else {
            throw Abort(.internalServerError, reason: "Production command-api requires MEDIA_STORAGE_PROVIDER=s3compatible.")
        }
        let requiredKeys = [
            "MEDIA_STORAGE_S3_ENDPOINT",
            "MEDIA_STORAGE_S3_BUCKET",
            "MEDIA_STORAGE_S3_ACCESS_KEY_ID",
            "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY",
            "MEDIA_STORAGE_S3_REGION",
            "MEDIA_STORAGE_S3_FORCE_PATH_STYLE"
        ]
        let missing = requiredKeys.filter {
            Environment.get($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        guard missing.isEmpty else {
            throw Abort(.internalServerError, reason: "Production S3 media storage is missing: \(missing.joined(separator: ", ")).")
        }
        guard !parseBooleanEnvironment("IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT", defaultValue: false) else {
            throw Abort(
                .internalServerError,
                reason: "Production IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT is forbidden for long-term production."
            )
        }
        try validateProductionHTTPSDependencyEndpoint(
            key: "MEDIA_STORAGE_S3_ENDPOINT",
            rawValue: Environment.get("MEDIA_STORAGE_S3_ENDPOINT") ?? ""
        )
        guard ["true", "false"].contains(
            Environment.get("MEDIA_STORAGE_S3_FORCE_PATH_STYLE")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ) else {
            throw Abort(
                .internalServerError,
                reason: "Production S3 media storage requires MEDIA_STORAGE_S3_FORCE_PATH_STYLE to be exactly true or false."
            )
        }
        try requireProductionSecret("MEDIA_STORAGE_S3_ACCESS_KEY_ID", minimumLength: 1)
        try requireProductionSecret("MEDIA_STORAGE_S3_SECRET_ACCESS_KEY", minimumLength: 16)
    }

    static func validateHotConversationProtectionConfiguration(_ app: Application) throws {
        guard app.hotConversationConfiguration.isEnabled else {
            throw Abort(.internalServerError, reason: "Production command-api requires IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT to protect ordered conversation sequence allocation.")
        }
        guard app.hotConversationConfiguration.limiterMode == .redis else {
            throw Abort(.internalServerError, reason: "Production command-api requires IM_HOT_CONVERSATION_LIMITER_MODE=redis so hot conversation limits remain global across command-api replicas.")
        }
        guard app.hotConversationConfiguration.redisURL != nil else {
            throw Abort(.internalServerError, reason: "Production command-api requires IM_HOT_CONVERSATION_LIMITER_REDIS_URL or REDIS_URL for distributed hot conversation limits.")
        }
    }

    static func validateSequenceAllocationConfiguration(_ app: Application) throws {
        guard app.sequenceAllocationConfiguration.mode == .block else {
            throw Abort(.internalServerError, reason: "Production command-api requires IM_SEQUENCE_ALLOCATION_MODE=block for scalable ordered message sequence allocation.")
        }
    }

    static func validateMessageWriteBatchConfiguration(_ app: Application) throws {
        guard app.messageWriteBatchConfiguration.isEnabled else {
            throw Abort(.internalServerError, reason: "Production command-api requires IM_MESSAGE_WRITE_BATCH_ENABLED=true for small-group write batching.")
        }
        guard app.messageCreatedRecipientInlineConfiguration.threshold > 0 else {
            throw Abort(
                .internalServerError,
                reason: "Production command-api requires IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD > 0 so large-group message_created outbox events do not inline every recipient UUID."
            )
        }
        guard app.domainEventRecipientSnapshotConfiguration.deduplicationThreshold > 0 else {
            throw Abort(
                .internalServerError,
                reason: "Production command-api requires IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD > 0 so large-group recipient snapshots reuse shared recipient sets."
            )
        }
        guard app.domainEventRecipientSnapshotConfiguration.deduplicationThreshold <= app.messageCreatedRecipientInlineConfiguration.threshold else {
            throw Abort(
                .internalServerError,
                reason: "Production command-api requires IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD <= IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD so every omitted-recipient message_created event uses recipient-set deduplication."
            )
        }
    }

    static func validateGroupMemberLimitConfiguration(_ app: Application) throws {
        guard Environment.get(IMGroupMemberLimitConfiguration.environmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        else {
            throw Abort(
                .internalServerError,
                reason: "Production command-api requires IM_GROUP_MEMBER_LIMIT to be set explicitly so large-group capacity is an intentional product and infrastructure decision."
            )
        }

        let groupMemberLimit = IMGroupMemberLimitConfiguration.load(from: app.environment).limit
        let inlineThreshold = app.messageCreatedRecipientInlineConfiguration.threshold
        guard groupMemberLimit >= inlineThreshold else {
            throw Abort(
                .internalServerError,
                reason: "Production command-api requires IM_GROUP_MEMBER_LIMIT >= IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD so large-group recipient snapshot protection can trigger before the business member limit rejects the group."
            )
        }
    }

    static func validateTimelineReadProtectionConfiguration(_ app: Application) throws {
        let requiredKeys = [
            "IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS",
            "IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_PAGES"
        ]
        let missing = requiredKeys.filter {
            Environment.get($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        guard missing.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires timeline visibility scan protection to be explicit: \(missing.joined(separator: ", "))."
            )
        }

        let timelineReadConfiguration = app.timelineReadConfiguration
        guard timelineReadConfiguration.visibilityScanMaxRows >= 100 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS >= 100 so normal timeline pages are not rejected."
            )
        }
        guard timelineReadConfiguration.visibilityScanMaxPages >= 2 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_PAGES >= 2 so filtered candidate pages can be scanned safely."
            )
        }
    }

    static func validateTimelineSinceCacheInvalidationConfiguration(_ app: Application) throws {
        let timelineReadConfiguration = app.timelineReadConfiguration
        let cacheConfigurationKeys = [
            "IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS",
            "IM_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES",
            "IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS",
            "IM_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS",
            "IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION",
            "IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS"
        ]
        let missingCacheConfiguration = cacheConfigurationKeys.filter {
            Environment.get($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        guard missingCacheConfiguration.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires timeline/since shared cache limits to be explicit: \(missingCacheConfiguration.joined(separator: ", "))."
            )
        }

        guard timelineReadConfiguration.sinceHotCacheTTLMilliseconds >= 50 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS >= 50 so hot large-group timeline/since catch-up cannot run with the exact-key cache disabled."
            )
        }
        guard timelineReadConfiguration.sinceHotCacheTTLMilliseconds <= 5_000 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS <= 5000 so shared timeline/since cache staleness stays bounded."
            )
        }
        guard timelineReadConfiguration.sinceHotCacheMaxEntries >= 1_024 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES >= 1024 so synchronized hot-group catch-up is not forced back to database reads."
            )
        }
        guard timelineReadConfiguration.sinceRecentCacheTTLMilliseconds >= 1_000 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS >= 1000 so nearby hot-group timeline/since cursors can reuse recent safe pages."
            )
        }
        guard timelineReadConfiguration.sinceRecentCacheTTLMilliseconds <= 30_000 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS <= 30000 so recent timeline/since cache staleness and memory retention stay bounded."
            )
        }
        guard timelineReadConfiguration.sinceRecentCacheMaxConversations >= 512 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS >= 512 so hot-group recent timeline/since cache capacity is not effectively disabled."
            )
        }
        guard timelineReadConfiguration.sinceRecentCacheMaxItemsPerConversation >= 128 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION >= 128 so compact-hint catch-up has a useful reusable suffix."
            )
        }
        guard timelineReadConfiguration.sinceTargetSequenceCoalesceWindowMilliseconds <= 50 else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS <= 50 so target-sequence catch-up coalescing does not hide query-api latency."
            )
        }

        let requiredKeys = [
            "IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE"
        ]
        let missing = requiredKeys.filter {
            Environment.get($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        guard missing.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires distributed timeline/since cache invalidation when any timeline/since shared cache is enabled: \(missing.joined(separator: ", "))."
            )
        }

        let invalidationConfiguration = app.timelineSinceCacheInvalidationConfiguration
        guard invalidationConfiguration.mode == .redis else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE=redis when any timeline/since shared cache is enabled."
            )
        }
        guard invalidationConfiguration.redisURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Abort(
                .internalServerError,
                reason: "Production \(app.imRuntimeRole.rawValue) requires REDIS_URL or IM_TIMELINE_SINCE_CACHE_INVALIDATION_REDIS_URL for distributed timeline/since cache invalidation."
            )
        }
    }

    static func validateStreamConsumerDeploymentIsolation(_ app: Application) throws {
        guard app.imRuntimeRole == .streamConsumer else {
            return
        }
        guard app.streamConsumerConfiguration.enabledGroups.count == 1 || app.streamConsumerConfiguration.preservesGroupedDeploymentsInProduction else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer deployments must run exactly one IM_STREAM_CONSUMER_GROUPS entry per process. Set IM_STREAM_CONSUMER_GROUPS to a single group or explicitly opt in with IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP=true for grouped test/runtime processes."
            )
        }
    }

    static func validateStreamConsumerBatchingConfiguration(_ app: Application) throws {
        guard app.imRuntimeRole == .streamConsumer else {
            return
        }
        let configuration = app.streamConsumerConfiguration
        guard configuration.streamConsumerRunBatchSize > 1 else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer requires IM_STREAM_CONSUMER_RUN_BATCH_SIZE > 1 so contiguous message_created events can be coalesced instead of processed one-by-one."
            )
        }
        guard configuration.streamConsumerQueueCapacity >= configuration.streamConsumerRunBatchSize else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer requires IM_STREAM_CONSUMER_QUEUE_CAPACITY >= IM_STREAM_CONSUMER_RUN_BATCH_SIZE so Kafka polling can fill a full processing batch without immediate producer backpressure."
            )
        }
        guard configuration.streamConsumerBatchFillWaitMilliseconds > 0 else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer requires IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS > 0 so the processing queue can briefly fill contiguous message_created runs before dispatch."
            )
        }
        guard configuration.streamConsumerBatchFillWaitMilliseconds <= 100 else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer requires IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS <= 100 to prevent batch-fill tuning from becoming user-visible event lag."
            )
        }
        if configuration.isEnabled("domain-delivery-consumer") {
            let minOwnerRecordBatchRequests = OwnerDomainEventDeliveryService.minimumPostgresRecordBatchMaxRequests
            let maxOwnerRecordBatchRequests = OwnerDomainEventDeliveryService.maximumPostgresRecordBatchMaxRequests
            guard configuration.domainDeliveryOwnerRecordBatchMaxRequests >= minOwnerRecordBatchRequests else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer requires IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS >= \(minOwnerRecordBatchRequests) so large-group owner-delivery writes do not degrade into per-owner single-row SQL."
                )
            }
            guard configuration.domainDeliveryOwnerRecordBatchMaxRequests <= maxOwnerRecordBatchRequests else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer requires IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS <= \(maxOwnerRecordBatchRequests) so owner-delivery SQL statements stay below database parameter and request-body limits."
                )
            }
        }
    }

    static func validateStreamConsumerLargeGroupProtection(_ app: Application) throws {
        guard app.imRuntimeRole == .streamConsumer else {
            return
        }

        let configuration = app.streamConsumerConfiguration
        guard configuration.streamConsumerRequiresMessageCreatedRecipientSnapshot else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer requires IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT=true so omitted-recipient message_created events cannot fall back to repeated membership expansion."
            )
        }
        let emitsRealtimeConversationSummaries = configuration.isEnabled("realtime-delivery-consumer")
            || (
                configuration.isEnabled("domain-delivery-consumer")
                    && configuration.domainDeliveryRelayAfterRecord
            )
        if emitsRealtimeConversationSummaries {
            guard Environment.get("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false,
                app.summaryReadModelConfiguration.responseMemberUserIDsLimit > 0
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Production stream-consumer realtime delivery requires IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT > 0 so membership/settings realtime summaries do not return full large-group member_user_ids payloads."
                )
            }
        }
        if configuration.isEnabled("summary-projection-consumer") {
            guard configuration.summaryProjectionMessageCreatedActivityOnlyRecipientThreshold > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production summary-projection-consumer requires IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD > 0 so large-group message_created events update conversation activity without per-owner summary/change-log writes."
                )
            }
            guard configuration.summaryProjectionActivityCoalesceWindowMilliseconds >= 50 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production summary-projection-consumer requires IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS >= 50 so hot large-group conversation activity summary writes are meaningfully coalesced instead of updating the same row once per message."
                )
            }
            guard configuration.summaryProjectionActivityCoalesceWindowMilliseconds <= 1_000 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production summary-projection-consumer requires IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS <= 1000 so conversation-list freshness remains bounded while hot large-group activity writes are coalesced."
                )
            }
        }

        if configuration.isEnabled("domain-delivery-consumer") {
            let ownerDeliverySkipThreshold = configuration
                .domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold
            if ownerDeliverySkipThreshold > 0,
               configuration.domainDeliveryMessageCreatedLargeGroupMode != .timelinePull
            {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer requires IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE=timeline-pull when IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD > 0; otherwise remove the threshold and keep owner-delivery mode explicitly."
                )
            }
            let protectsOwnerDelivery = configuration.domainDeliverySkipsMessageCreatedOwnerDelivery
                || (
                    configuration.domainDeliveryMessageCreatedLargeGroupMode == .timelinePull
                        && ownerDeliverySkipThreshold > 0
                )
            guard protectsOwnerDelivery else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer requires IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE=timeline-pull with IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD > 0 for large groups, or IM_DOMAIN_DELIVERY_SKIP_MESSAGE_CREATED_OWNER_DELIVERY=true for a dedicated no-owner-copy deployment."
                )
            }
        }

        if configuration.isEnabled("notification-consumer") {
            let protectsOwnerNotifications = configuration.notificationSkipsMessageCreatedOwnerNotifications
                || configuration.notificationMessageCreatedOwnerNotificationSkipRecipientThreshold > 0
            guard protectsOwnerNotifications else {
                throw Abort(
                    .internalServerError,
                    reason: "Production notification-consumer requires IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD > 0 for large groups, or IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS=true for a dedicated no-owner-notification deployment."
                )
            }
        }

        if configuration.isEnabled("realtime-delivery-consumer") {
            let routingConfiguration = app.imRedisRoutingConfigurationOverride
                ?? IMRedisRoutingConfiguration.load(from: app.environment)
            guard routingConfiguration.mode == .redis,
                  routingConfiguration.url?.isEmpty == false
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires REDIS_URL/IM_ROUTING_MODE=redis so it can read active conversation presence and split large-group realtime fanout before gateway relay."
                )
            }
            guard configuration.realtimeMessageCreatedLightweightRecipientThreshold > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD > 0 so large-group realtime payloads omit per-recipient conversation summaries before gateway active/inactive fanout."
                )
            }
            guard !configuration.realtimeMessageCreatedPreviewLookupEnabled else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false so large-group lightweight realtime hints cannot reintroduce per-message database reads on the hot path."
                )
            }
            guard configuration.realtimeDeliveryAsyncRelayEnabled else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=true so Kafka event processing is not blocked by gateway relay latency."
                )
            }
            guard configuration.realtimeDeliveryAsyncMaxInFlight > 1 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT > 1 so gateway relay work can progress concurrently under large-group bursts."
                )
            }
            guard configuration.realtimeDeliveryAsyncMaxQueued > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED > 0 so transient gateway relay bursts are buffered instead of dropped immediately."
                )
            }
            guard configuration.realtimeMessageCreatedCoalesceWindowMilliseconds > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS > 0 so hot large-group active compact hints are coalesced by conversation instead of relayed once per message."
                )
            }
            guard configuration.realtimeActiveCompactHintCoalesceWindowMilliseconds > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS > 0 so hot active-room compact hints are merged per recipient instead of relayed once per message."
                )
            }
            guard configuration.realtimeActiveCompactHintCoalesceWindowMilliseconds <= maximumActiveCompactHintCoalesceWindowMilliseconds else {
                throw Abort(
                    .internalServerError,
                    reason: "Production realtime-delivery-consumer requires IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS <= \(maximumActiveCompactHintCoalesceWindowMilliseconds) so active chat viewers are not delayed by inactive-list hint debounce."
                )
            }
            try validateActiveCompactHintMessageLite(
                configuration,
                context: "Production realtime-delivery-consumer"
            )
        }

        try validateStreamConsumerLargeGroupThresholdsAgainstMemberLimit(app)
    }

    static func validateStreamConsumerLargeGroupThresholdsAgainstMemberLimit(_ app: Application) throws {
        guard app.imRuntimeRole == .streamConsumer else {
            return
        }
        guard Environment.get(IMGroupMemberLimitConfiguration.environmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer requires IM_GROUP_MEMBER_LIMIT to match command-api so large-group thresholds cannot drift above the business member limit."
            )
        }

        let configuration = app.streamConsumerConfiguration
        let groupMemberLimit = IMGroupMemberLimitConfiguration.load(from: app.environment).limit
        if configuration.isEnabled("summary-projection-consumer") {
            try validateLargeGroupThreshold(
                "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD",
                configuration.summaryProjectionMessageCreatedActivityOnlyRecipientThreshold,
                doesNotExceedGroupMemberLimit: groupMemberLimit
            )
        }
        if configuration.isEnabled("domain-delivery-consumer"),
           !configuration.domainDeliverySkipsMessageCreatedOwnerDelivery {
            try validateLargeGroupThreshold(
                "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD",
                configuration.domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold,
                doesNotExceedGroupMemberLimit: groupMemberLimit
            )
        }
        if configuration.isEnabled("notification-consumer"),
           !configuration.notificationSkipsMessageCreatedOwnerNotifications {
            try validateLargeGroupThreshold(
                "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD",
                configuration.notificationMessageCreatedOwnerNotificationSkipRecipientThreshold,
                doesNotExceedGroupMemberLimit: groupMemberLimit
            )
        }

        let hasRealtimeDeliveryConsumer = configuration.isEnabled("realtime-delivery-consumer")
        let usesDomainRelayAfterRecord = configuration.isEnabled("domain-delivery-consumer")
            && configuration.domainDeliveryRelayAfterRecord
        if hasRealtimeDeliveryConsumer || usesDomainRelayAfterRecord {
            try validateLargeGroupThreshold(
                "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD",
                configuration.realtimeMessageCreatedLightweightRecipientThreshold,
                doesNotExceedGroupMemberLimit: groupMemberLimit
            )
            try validateLargeGroupThreshold(
                "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD",
                app.gatewayLocalFanoutConfiguration.activeConversationFanoutRecipientThreshold,
                doesNotExceedGroupMemberLimit: groupMemberLimit
            )
        }
    }

    static func validateLargeGroupRealtimeDeliveryPath(_ app: Application) throws {
        let configuration = app.streamConsumerConfiguration
        let hasDomainDeliveryConsumer = configuration.isEnabled("domain-delivery-consumer")
        let hasRealtimeDeliveryConsumer = configuration.isEnabled("realtime-delivery-consumer")
        let hasExternalRealtimeDeliveryConsumer = configuration.domainDeliveryExternalRealtimeDeliveryEnabled
        let hasDomainRelayAfterRecord = hasDomainDeliveryConsumer
            && configuration.domainDeliveryRelayAfterRecord

        if hasDomainDeliveryConsumer,
           (hasRealtimeDeliveryConsumer || hasExternalRealtimeDeliveryConsumer),
           configuration.domainDeliveryRelayAfterRecord
        {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer must not enable IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true when realtime-delivery-consumer is also enabled; use the dedicated realtime-delivery-consumer path to avoid duplicate realtime delivery."
            )
        }

        guard hasDomainDeliveryConsumer else {
            return
        }
        let ownerDeliverySkipThreshold = configuration.domainDeliveryMessageCreatedOwnerDeliverySkipRecipientThreshold
        let skipsMessageCreatedOwnerDelivery = configuration.domainDeliverySkipsMessageCreatedOwnerDelivery
            || (
                configuration.domainDeliveryMessageCreatedLargeGroupMode == .timelinePull
                    && ownerDeliverySkipThreshold > 0
            )
        guard skipsMessageCreatedOwnerDelivery else {
            return
        }

        guard hasRealtimeDeliveryConsumer || hasExternalRealtimeDeliveryConsumer || hasDomainRelayAfterRecord else {
            throw Abort(
                .internalServerError,
                reason: "Large-group message_created owner delivery skip requires realtime delivery. Enable realtime-delivery-consumer, set IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true on domain-delivery-consumer, or set IM_DOMAIN_DELIVERY_EXTERNAL_REALTIME_DELIVERY_ENABLED=true when a dedicated realtime-delivery-consumer runs in the same deployment."
            )
        }

        if hasDomainRelayAfterRecord {
            guard configuration.realtimeMessageCreatedLightweightRecipientThreshold > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD > 0 so skip-owner-delivery large groups still use lightweight realtime payloads."
                )
            }
            guard !configuration.realtimeMessageCreatedPreviewLookupEnabled else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false so relay-after-record large-group hints cannot reintroduce per-message database reads on the hot path."
                )
            }
            guard configuration.realtimeDeliveryAsyncRelayEnabled else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=true so relay-after-record does not block Kafka processing under large-group bursts."
                )
            }
            guard configuration.realtimeDeliveryAsyncMaxInFlight > 1 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT > 1 so gateway relay work can progress concurrently under large-group bursts."
                )
            }
            guard configuration.realtimeDeliveryAsyncMaxQueued > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED > 0 so transient relay-after-record bursts are buffered instead of dropped immediately."
                )
            }
            guard configuration.realtimeMessageCreatedCoalesceWindowMilliseconds > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS > 0 so hot large-group active compact hints are coalesced by conversation instead of relayed once per message."
                )
            }
            guard configuration.realtimeActiveCompactHintCoalesceWindowMilliseconds > 0 else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS > 0 so hot active-room compact hints are merged per recipient instead of relayed once per message."
                )
            }
            guard configuration.realtimeActiveCompactHintCoalesceWindowMilliseconds <= maximumActiveCompactHintCoalesceWindowMilliseconds else {
                throw Abort(
                    .internalServerError,
                    reason: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true requires IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS <= \(maximumActiveCompactHintCoalesceWindowMilliseconds) so active chat viewers are not delayed by inactive-list hint debounce."
                )
            }
            try validateActiveCompactHintMessageLite(
                configuration,
                context: "Production domain-delivery-consumer with IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"
            )
        }

        let fanoutConfiguration = app.gatewayLocalFanoutConfiguration
        guard fanoutConfiguration.activeConversationFanoutEnabled else {
            throw Abort(
                .internalServerError,
                reason: "Production large-group message_created owner delivery skip requires IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED=true so realtime delivery is split between active chat viewers and coalesced inactive conversation hints."
            )
        }
        guard configuration.realtimeActiveConversationRouteCacheTTLMilliseconds > 0 else {
            throw Abort(
                .internalServerError,
                reason: "Production large-group message_created owner delivery skip requires IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS > 0 so hot conversations do not re-query active room routes for every message."
            )
        }
        guard configuration.realtimeActiveConversationRouteCacheMaxEntries > 0 else {
            throw Abort(
                .internalServerError,
                reason: "Production large-group message_created owner delivery skip requires IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES > 0 so hot conversation route caching is bounded instead of disabled."
            )
        }
        if ownerDeliverySkipThreshold > 0,
           fanoutConfiguration.activeConversationFanoutRecipientThreshold > ownerDeliverySkipThreshold
        {
            throw Abort(
                .internalServerError,
                reason: "Production large-group thresholds require IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD <= IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD so every skip-owner-delivery group is protected by active/inactive fanout."
            )
        }

        let realtimeLightweightThreshold = configuration.realtimeMessageCreatedLightweightRecipientThreshold
        if ownerDeliverySkipThreshold > 0,
           realtimeLightweightThreshold > ownerDeliverySkipThreshold
        {
            throw Abort(
                .internalServerError,
                reason: "Production large-group thresholds require IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD <= IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD so every skip-owner-delivery group also uses lightweight realtime payloads."
            )
        }
        let summaryActivityOnlyThreshold = configuration.summaryProjectionMessageCreatedActivityOnlyRecipientThreshold
        if ownerDeliverySkipThreshold > 0,
           configuration.isEnabled("summary-projection-consumer"),
           summaryActivityOnlyThreshold > ownerDeliverySkipThreshold
        {
            throw Abort(
                .internalServerError,
                reason: "Production large-group thresholds require IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD <= IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD so every skip-owner-delivery group also avoids per-owner summary/change-log writes."
            )
        }
        let notificationSkipThreshold = configuration.notificationMessageCreatedOwnerNotificationSkipRecipientThreshold
        if ownerDeliverySkipThreshold > 0,
           configuration.isEnabled("notification-consumer"),
           !configuration.notificationSkipsMessageCreatedOwnerNotifications,
           notificationSkipThreshold > ownerDeliverySkipThreshold
        {
            throw Abort(
                .internalServerError,
                reason: "Production large-group thresholds require IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD <= IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD so every skip-owner-delivery group also avoids per-owner notification writes."
            )
        }
    }

    private static func validateActiveCompactHintMessageLite(
        _ configuration: IMStreamConsumerConfiguration,
        context: String
    ) throws {
        guard configuration.realtimeActiveCompactHintPreviewMaxCharacters > 0 else {
            throw Abort(
                .internalServerError,
                reason: "\(context) requires IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS > 0 so hot active-room viewers can render the new message immediately while timeline/since remains the durable catch-up source."
            )
        }
        guard configuration.realtimeActiveCompactHintPreviewMaxCharacters <= maximumActiveCompactHintPreviewCharacters else {
            throw Abort(
                .internalServerError,
                reason: "\(context) requires IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS <= \(maximumActiveCompactHintPreviewCharacters) so hot-room realtime payloads stay bounded."
            )
        }
    }

    private static func requireProductionSecret(
        _ key: String,
        minimumLength: Int
    ) throws {
        try requireProductionSecret(
            key,
            value: Environment.get(key),
            minimumLength: minimumLength
        )
    }

    private static func requireProductionSecret(
        _ key: String,
        value rawValue: String?,
        minimumLength: Int
    ) throws {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw Abort(.internalServerError, reason: "Production requires \(key) to be configured.")
        }
        guard value.count >= minimumLength else {
            throw Abort(
                .internalServerError,
                reason: "Production requires \(key) to be at least \(minimumLength) characters."
            )
        }
        guard !isPlaceholderProductionSecret(value) else {
            throw Abort(
                .internalServerError,
                reason: "Production \(key) must not use a placeholder or default test value."
            )
        }
    }

    private static func isPlaceholderProductionSecret(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "change_me",
            "changeme",
            "replace-me",
            "replace_me",
            "password",
            "password1234",
            "test",
            "demo",
            "example",
            "secret",
            "prod-secret",
            "prod-secret-key",
            "prod-db-password",
            "prod-kafka-password",
            "prod-jwt-secret",
            "prod-internal-secret",
            "dev-jwt-secret-change-me",
            "test-internal-secret",
            "database-secret",
            "im-password",
            "secret-key",
            "access-key"
        ].contains(normalized)
    }

    private static func validateProductionHTTPSDependencyEndpoint(
        key: String,
        rawValue: String
    ) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              isProductionDependencyEndpointHost(host)
        else {
            throw Abort(
                .internalServerError,
                reason: "Production \(key) must be an https URL with a real non-placeholder DNS host."
            )
        }
    }

    private static func isProductionDependencyEndpointHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        if normalized == "localhost" || normalized == "ip6-localhost" || normalized.hasSuffix(".local") {
            return false
        }
        if normalized.contains(":") {
            return false
        }
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            return false
        }
        return !isPlaceholderDomainHost(normalized)
    }

    private static func isPublicBaseURLHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        if normalized == "localhost" || normalized == "ip6-localhost" || normalized.hasSuffix(".local") {
            return false
        }
        if normalized.contains(":") {
            return false
        }
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            return false
        }
        if isPlaceholderDomainHost(normalized) {
            return false
        }
        return normalized.contains(".")
    }

    private static func isPlaceholderDomainHost(_ normalizedHost: String) -> Bool {
        let placeholderHosts: Set<String> = [
            "example",
            "example.com",
            "example.net",
            "example.org",
            "yourdomain.com"
        ]
        let placeholderSuffixes = [
            ".example",
            ".example.com",
            ".example.net",
            ".example.org",
            ".yourdomain.com",
            ".test",
            ".invalid"
        ]
        return placeholderHosts.contains(normalizedHost)
            || placeholderSuffixes.contains(where: { normalizedHost.hasSuffix($0) })
    }
}

private func validateLargeGroupThreshold(
    _ name: String,
    _ value: Int,
    doesNotExceedGroupMemberLimit groupMemberLimit: Int
) throws {
    guard value <= groupMemberLimit else {
        throw Abort(
            .internalServerError,
            reason: "Production large-group thresholds require \(name) <= IM_GROUP_MEMBER_LIMIT so large-group protection can trigger before the business member limit rejects the group."
        )
    }
}

private func validateRelayBodyLimit(
    name: String,
    value: Int,
    minimum: Int,
    maximum: Int
) throws {
    guard value >= minimum else {
        throw Abort(
            .internalServerError,
            reason: "Production gateway relay requires \(name) >= \(minimum) bytes so large-group relay batches do not fail with payload-too-large."
        )
    }
    guard value <= maximum else {
        throw Abort(
            .internalServerError,
            reason: "Production gateway relay requires \(name) <= \(maximum) bytes so oversized internal relay requests cannot retain unbounded request memory."
        )
    }
}

private func isPrivateOrLoopbackTCPHost(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.") {
        return true
    }
    if normalized.hasPrefix("10.") || normalized.hasPrefix("192.168.") {
        return true
    }
    let parts = normalized.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
        return true
    }
    return false
}
