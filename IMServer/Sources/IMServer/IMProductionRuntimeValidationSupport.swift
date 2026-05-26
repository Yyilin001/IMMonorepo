import Foundation
import Vapor

enum IMProductionRuntimeValidationSupport {
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
    }

    static func validateGatewayCommandIngressConfiguration(_ app: Application) throws {
        guard app.commandAPIIngressConfiguration.isEnabled else {
            throw Abort(.internalServerError, reason: "Production gateway requires IM_COMMAND_API_INTERNAL_BASE_URL to proxy IM command ingress.")
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
    }

    static func validateGatewayRelayConfiguration(_ app: Application) throws {
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
        _ = try app.eventStreamConfiguration.makeProducerConfiguration(nodeID: app.imNodeID)
    }

    static func validateKafkaConsumerConfiguration(_ app: Application) throws {
        guard app.eventStreamConfiguration.driver == .kafka else {
            throw Abort(.internalServerError, reason: "\(app.imRuntimeRole.rawValue) requires IM_EVENT_STREAM_DRIVER=kafka in production.")
        }
        _ = try app.eventStreamConfiguration.makeConsumerConfiguration(
            consumerGroupID: "summary-projection-consumer",
            clientSuffix: "\(app.imRuntimeRole.rawValue)-validation",
            topics: [app.eventStreamConfiguration.topic]
        )
    }

    static func productionTransitionalReadModelsAllowed(_ app: Application) -> Bool {
        guard app.environment == .production, app.imRuntimeRole == .ops else {
            return false
        }
        let configuredValue = Environment.get("IM_ALLOW_TRANSITIONAL_READ_MODELS")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return configuredValue == "1" || configuredValue == "true" || configuredValue == "yes"
    }

    static func validateSummaryReadModelReadConfiguration(_ app: Application) throws {
        try validateSummaryShardDatabasesConfigured(app)
    }

    static func validateSummaryReadModelWriteConfiguration(_ app: Application) throws {
        try validateSummaryShardDatabasesConfigured(app)
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
            "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY"
        ]
        let missing = requiredKeys.filter {
            Environment.get($0)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        guard missing.isEmpty else {
            throw Abort(.internalServerError, reason: "Production S3 media storage is missing: \(missing.joined(separator: ", ")).")
        }
    }

    static func validateHotConversationProtectionConfiguration(_ app: Application) throws {
        guard app.hotConversationConfiguration.isEnabled else {
            throw Abort(.internalServerError, reason: "Production command-api requires IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT to protect ordered conversation sequence allocation.")
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
    }

    static func validateStreamConsumerDeploymentIsolation(_ app: Application) throws {
        guard app.imRuntimeRole == .streamConsumer else {
            return
        }
        guard app.streamConsumerConfiguration.enabledGroups.count == 1 || app.streamConsumerConfiguration.preservesGroupedDeploymentsInProduction else {
            throw Abort(
                .internalServerError,
                reason: "Production stream-consumer deployments must run exactly one IM_STREAM_CONSUMER_GROUPS entry per process. Set IM_STREAM_CONSUMER_GROUPS to a single group or explicitly opt in with IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP=true for temporary transitions."
            )
        }
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
