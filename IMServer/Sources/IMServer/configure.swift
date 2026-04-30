import Foundation
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import JWTKit
import SQLKit
import Vapor

// 配置你的应用程序
public func configure(_ app: Application) async throws {
    try await configureShared(app)

    switch app.imRuntimeRole {
    case .gateway:
        try await configureGatewayRuntime(app)
    case .commandAPI:
        try await configureCommandAPIRuntime(app)
    case .queryAPI:
        try await configureQueryAPIRuntime(app)
    case .outboxRelay:
        try await configureOutboxRelayRuntime(app)
    case .streamConsumer:
        try await configureStreamConsumerRuntime(app)
    case .projectionWorker:
        try await configureProjectionWorkerRuntime(app)
    case .combined:
        try await configureGatewayRuntime(app)
        try await configureCommandAPIRuntime(app)
        try await configureQueryAPIRuntime(app)
        try await configureProjectionWorkerRuntime(app)
    case .ops:
        try await configureOpsRuntime(app)
    }

    if app.imRuntimeRole.servesHTTP {
        try routes(app)
    }
}

private func configureShared(_ app: Application) async throws {
    if app.environment == .production, app.imRuntimeRole == .combined {
        throw Abort(.internalServerError, reason: "IM combined runtime role is only supported in development/testing.")
    }

    // 本地开发从 .env.local 读取数据库和密钥配置，避免 Xcode 直接运行时丢环境变量。
    loadLocalEnvironmentIfNeeded(environment: app.environment)

    let authConfiguration = try AuthConfiguration.load(from: app.environment)
    let imTCPConfiguration = IMTCPConfiguration.load(from: app.environment)
    app.authClientIPResolver = AuthClientIPResolver.load(from: app.environment)
    app.gatewayRelayConfiguration = IMGatewayRelayConfiguration.load(from: app.environment)
    app.commandAPIIngressConfiguration = IMCommandAPIIngressConfiguration.load(from: app.environment)
    app.eventStreamConfiguration = IMEventStreamConfiguration.load(from: app.environment)
    app.searchIndexConfiguration = IMSearchIndexConfiguration.load(from: app.environment)
    app.shardTopologyConfiguration = IMShardTopologyConfiguration.load(from: app.environment)
    app.summaryStoreConfiguration = IMSummaryStoreConfiguration.load(from: app.environment)
    app.summaryReadModelConfiguration = IMSummaryReadModelConfiguration.load(from: app.environment)
    app.streamConsumerConfiguration = IMStreamConsumerConfiguration.load(from: app.environment)

    configureDatabases(app)
    try validateProductionInfrastructureConfiguration(app)
    app.authConfiguration = authConfiguration
    app.imTCPConfiguration = imTCPConfiguration
    app.lifecycle.use(ConversationEventStreamProducerLifecycle())
    app.asyncCommands.use(IMProjectionWorkerCommand(), as: "worker")
    app.asyncCommands.use(IMProjectionWorkerCommand(), as: "projection-worker")
    app.asyncCommands.use(IMOutboxRelayCommand(), as: "outbox-relay")
    app.asyncCommands.use(IMStreamConsumerCommand(), as: "stream-consumer")
    app.asyncCommands.use(IMOpsCommand(), as: "ops")
    registerMigrations(app)
    try await resetIMSchemaIfRequested(app)
    try await app.autoMigrate()
    try await validateIMSchema(app)
}

private func configureHTTPRuntimeBase(_ app: Application) async throws {
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    await app.jwtKeys.add(hmac: HMACKey(from: app.authConfiguration.jwtSecret), digestAlgorithm: .sha256)
}

private func configureGatewayRuntime(_ app: Application) async throws {
    try await configureHTTPRuntimeBase(app)
    if !app.hasConnectionRoutingServiceConfigured {
        _ = app.imConnectionRegistry
        try await app.configureConnectionRoutingServiceIfNeeded()
        app.lifecycle.use(IMTCPServerLifecycle())
        app.lifecycle.use(ConnectionRoutingLifecycle())
    }
    try await seedDevelopmentUserIfNeeded(in: app)
}

private func configureCommandAPIRuntime(_ app: Application) async throws {
    try await configureHTTPRuntimeBase(app)
    if !app.imRuntimeRole.servesGateway {
        switch app.gatewayRelayConfiguration.mode {
        case .local:
            if app.environment == .production {
                throw GatewayRelayConfigurationError.productionCommandAPIRequiresHTTPMode
            }
        case .http:
            guard let baseURL = app.gatewayRelayConfiguration.baseURL, !baseURL.isEmpty else {
                throw GatewayRelayConfigurationError.httpModeRequiresBaseURL
            }
        }
    }
    try await MediaStorageService(app: app).prepareStorage()
    try FileStorageService(app: app).prepareStorage()
}

private func configureQueryAPIRuntime(_ app: Application) async throws {
    try await configureHTTPRuntimeBase(app)
}

private func configureProjectionWorkerRuntime(_ app: Application) async throws {
    guard app.environment != .production else {
        throw Abort(.internalServerError, reason: "projection-worker is a development/testing fallback only; use stream-consumer in production.")
    }
    app.lifecycle.use(ConversationProjectionWorkerLifecycle())
}

private func configureOutboxRelayRuntime(_ app: Application) async throws {
    guard app.eventStreamConfiguration.driver == .kafka || app.environment != .production else {
        throw Abort(.internalServerError, reason: "outbox-relay requires IM_EVENT_STREAM_DRIVER=kafka in production.")
    }
}

private func configureStreamConsumerRuntime(_ app: Application) async throws {
    guard app.eventStreamConfiguration.driver == .kafka || app.environment != .production else {
        throw Abort(.internalServerError, reason: "stream-consumer requires IM_EVENT_STREAM_DRIVER=kafka in production.")
    }
}

private func configureOpsRuntime(_ app: Application) async throws {
}

private func validateProductionInfrastructureConfiguration(_ app: Application) throws {
    guard app.environment == .production else {
        return
    }

    guard let configuredNodeID = Environment.get("IM_NODE_ID")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !configuredNodeID.isEmpty
    else {
        throw Abort(.internalServerError, reason: "Production requires IM_NODE_ID to be explicitly configured.")
    }

    switch app.imRuntimeRole {
    case .gateway:
        try validateGatewayCommandIngressConfiguration(app)
        break
    case .commandAPI:
        try validateConversationShardConfiguration(app)
        try validateGatewayRelayConfiguration(app)
        try validateKafkaProducerConfiguration(app)
    case .queryAPI:
        try validateConversationShardConfiguration(app)
        try validateSummaryReadModelReadConfiguration(app)
        try validateSearchConfiguration(app)
    case .outboxRelay:
        try validateConversationShardConfiguration(app)
        try validateKafkaProducerConfiguration(app)
    case .streamConsumer:
        try validateConversationShardConfiguration(app)
        try validateKafkaConsumerConfiguration(app)
        try validateStreamConsumerDeploymentIsolation(app)
        try validateSummaryReadModelWriteConfiguration(app)
        try validateSearchConfiguration(app)
    case .ops:
        try validateConversationShardConfiguration(app)
        if app.eventStreamConfiguration.driver == .kafka {
            try validateKafkaProducerConfiguration(app)
        }
        try validateSummaryReadModelWriteConfiguration(app)
        try validateSummaryReadModelReadConfiguration(app)
    case .projectionWorker:
        throw Abort(.internalServerError, reason: "projection-worker is a development/testing fallback only; use stream-consumer in production.")
    case .combined:
        throw Abort(.internalServerError, reason: "combined runtime role is not supported in production.")
    }
}

private func validateGatewayCommandIngressConfiguration(_ app: Application) throws {
    guard app.commandAPIIngressConfiguration.isEnabled else {
        throw Abort(.internalServerError, reason: "Production gateway requires IM_COMMAND_API_INTERNAL_BASE_URL to proxy IM command ingress.")
    }
}

private func validateConversationShardConfiguration(_ app: Application) throws {
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

private func validateGatewayRelayConfiguration(_ app: Application) throws {
    guard app.gatewayRelayConfiguration.mode == .http else {
        throw GatewayRelayConfigurationError.productionCommandAPIRequiresHTTPMode
    }
    guard let baseURL = app.gatewayRelayConfiguration.baseURL, !baseURL.isEmpty else {
        throw GatewayRelayConfigurationError.httpModeRequiresBaseURL
    }
}

private func validateKafkaProducerConfiguration(_ app: Application) throws {
    guard app.eventStreamConfiguration.driver == .kafka else {
        throw Abort(.internalServerError, reason: "\(app.imRuntimeRole.rawValue) requires IM_EVENT_STREAM_DRIVER=kafka in production.")
    }
    _ = try app.eventStreamConfiguration.makeProducerConfiguration(nodeID: app.imNodeID)
}

private func validateKafkaConsumerConfiguration(_ app: Application) throws {
    guard app.eventStreamConfiguration.driver == .kafka else {
        throw Abort(.internalServerError, reason: "\(app.imRuntimeRole.rawValue) requires IM_EVENT_STREAM_DRIVER=kafka in production.")
    }
    _ = try app.eventStreamConfiguration.makeConsumerConfiguration(
        consumerGroupID: "summary-projection-consumer",
        clientSuffix: "\(app.imRuntimeRole.rawValue)-validation",
        topics: [app.eventStreamConfiguration.topic]
    )
}

private func productionTransitionalReadModelsAllowed(_ app: Application) -> Bool {
    guard app.environment == .production, app.imRuntimeRole == .ops else {
        return false
    }
    let configuredValue = Environment.get("IM_ALLOW_TRANSITIONAL_READ_MODELS")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return configuredValue == "1" || configuredValue == "true" || configuredValue == "yes"
}

private func validateSummaryReadModelReadConfiguration(_ app: Application) throws {
    if app.environment == .production,
       app.summaryReadModelConfiguration.queryReadSource != .sharded,
       !productionTransitionalReadModelsAllowed(app)
    {
        throw Abort(
            .internalServerError,
            reason: "Production summary query reads must use IM_SUMMARY_QUERY_READ_SOURCE=sharded. Temporary legacy reads are only allowed for ops with IM_ALLOW_TRANSITIONAL_READ_MODELS=true."
        )
    }

    switch app.summaryReadModelConfiguration.queryReadSource {
    case .legacy:
        guard app.imSummaryDatabaseEnabled else {
            throw Abort(.internalServerError, reason: "IM_SUMMARY_QUERY_READ_SOURCE=legacy requires DATABASE_SUMMARY_* to be configured in production.")
        }
    case .sharded:
        try validateSummaryShardDatabasesConfigured(app)
    }
}

private func validateSummaryReadModelWriteConfiguration(_ app: Application) throws {
    if app.environment == .production,
       app.summaryReadModelConfiguration.projectionWriteMode != .sharded,
       !productionTransitionalReadModelsAllowed(app)
    {
        throw Abort(
            .internalServerError,
            reason: "Production summary projection writes must use IM_SUMMARY_PROJECTION_WRITE_MODE=sharded. Temporary legacy or dual-write modes are only allowed for ops with IM_ALLOW_TRANSITIONAL_READ_MODELS=true."
        )
    }

    switch app.summaryReadModelConfiguration.projectionWriteMode {
    case .legacy:
        guard app.imSummaryDatabaseEnabled else {
            throw Abort(.internalServerError, reason: "IM_SUMMARY_PROJECTION_WRITE_MODE=legacy requires DATABASE_SUMMARY_* to be configured in production.")
        }
    case .sharded:
        try validateSummaryShardDatabasesConfigured(app)
    case .dualWrite:
        guard app.imSummaryDatabaseEnabled else {
            throw Abort(.internalServerError, reason: "IM_SUMMARY_PROJECTION_WRITE_MODE=dual-write requires DATABASE_SUMMARY_* to be configured in production.")
        }
        try validateSummaryShardDatabasesConfigured(app)
    }
}

private func validateSummaryShardDatabasesConfigured(_ app: Application) throws {
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

private func validateSearchConfiguration(_ app: Application) throws {
    if app.environment == .production {
        switch app.imRuntimeRole {
        case .queryAPI:
            guard app.searchIndexConfiguration.driver == .openSearch else {
                throw Abort(.internalServerError, reason: "Production query-api requires IM_SEARCH_DRIVER=opensearch.")
            }
        case .streamConsumer:
            if app.streamConsumerConfiguration.isEnabled("search-index-consumer") {
                guard app.searchIndexConfiguration.driver == .openSearch else {
                    throw Abort(.internalServerError, reason: "Production search-index-consumer requires IM_SEARCH_DRIVER=opensearch.")
                }
            }
        default:
            break
        }
    }

    guard app.searchIndexConfiguration.driver == .openSearch else {
        return
    }
    guard let endpoint = app.searchIndexConfiguration.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
          !endpoint.isEmpty
    else {
        throw Abort(.internalServerError, reason: "IM_SEARCH_DRIVER=opensearch requires IM_OPENSEARCH_ENDPOINT in production.")
    }
}

private func validateStreamConsumerDeploymentIsolation(_ app: Application) throws {
    guard app.environment == .production, app.imRuntimeRole == .streamConsumer else {
        return
    }
    guard app.streamConsumerConfiguration.enabledGroups.count == 1 || app.streamConsumerConfiguration.preservesGroupedDeploymentsInProduction else {
        throw Abort(
            .internalServerError,
            reason: "Production stream-consumer deployments must run exactly one IM_STREAM_CONSUMER_GROUPS entry per process. Set IM_STREAM_CONSUMER_GROUPS to a single group or explicitly opt in with IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP=true for temporary transitions."
        )
    }
}

private func configureDatabases(_ app: Application) {
    // 测试环境使用内存 SQLite，保证测试隔离和速度；开发/生产统一使用 PostgreSQL。
    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.imReplicaDatabaseEnabled = false
        app.imSummaryDatabaseEnabled = false
        app.conversationShardDatabaseIDs = [:]
        app.conversationShardReplicaDatabaseIDs = [:]
        app.summaryShardDatabaseIDs = [:]
    } else {
        let databasePair = databaseConfigurationPair(for: app.environment)
        app.databases.use(.postgres(configuration: databasePair.primary), as: .psql)
        if let replica = databasePair.replica {
            app.databases.use(.postgres(configuration: replica), as: .imReplica)
            app.imReplicaDatabaseEnabled = true
        } else {
            app.imReplicaDatabaseEnabled = false
        }
        if let summary = databasePair.summary {
            app.databases.use(.postgres(configuration: summary), as: .imSummary)
            app.imSummaryDatabaseEnabled = true
        } else {
            app.imSummaryDatabaseEnabled = false
        }
        app.conversationShardDatabaseIDs = [:]
        app.conversationShardReplicaDatabaseIDs = [:]
        for (shardID, configuration) in databasePair.conversationShards {
            let databaseID = DatabaseID(string: "im-conversation-\(shardID)")
            app.databases.use(.postgres(configuration: configuration), as: databaseID)
            app.conversationShardDatabaseIDs[shardID] = databaseID
        }
        for (shardID, configuration) in databasePair.conversationShardReplicas {
            let databaseID = DatabaseID(string: "im-conversation-\(shardID)-replica")
            app.databases.use(.postgres(configuration: configuration), as: databaseID)
            app.conversationShardReplicaDatabaseIDs[shardID] = databaseID
        }
        app.summaryShardDatabaseIDs = [:]
        for (shardID, configuration) in databasePair.summaryShards {
            let databaseID = DatabaseID(string: "im-summary-\(shardID)")
            app.databases.use(.postgres(configuration: configuration), as: databaseID)
            app.summaryShardDatabaseIDs[shardID] = databaseID
        }
    }
}

private func registerMigrations(_ app: Application) {
    // 认证链路依赖 users + auth_sessions 两张表，以及后续的索引/约束迁移。
    app.migrations.add(CreateUser())
    app.migrations.add(AddUserProfileFields())
    app.migrations.add(CreateUserContact())
    app.migrations.add(AddUserContactRemark())
    app.migrations.add(BackfillReciprocalUserContacts())
    app.migrations.add(CreateFriendRequest())
    app.migrations.add(CreateAuthSession())
    app.migrations.add(AddAuthIndexes())
    app.migrations.add(EnforceSingleActiveDeviceSession())
    app.migrations.add(CreateConversation())
    app.migrations.add(AddConversationLastMessageSequence())
    app.migrations.add(CreateConversationMember())
    app.migrations.add(AddConversationMemberLastReadSequence())
    app.migrations.add(AddConversationKind())
    app.migrations.add(AddConversationDirectMessagingState())
    app.migrations.add(AddConversationMemberRole())
    app.migrations.add(AddConversationMetadataAndPreferences())
    app.migrations.add(CreateConversationMessage())
    app.migrations.add(AddConversationMessageDerivedState())
    app.migrations.add(AddConversationMessageClientMessageID())
    app.migrations.add(AddConversationMessageClientMessageIDUniqueIndex())
    app.migrations.add(CreateConversationDomainEvent())
    app.migrations.add(AddConversationDomainEventRetryCount())
    app.migrations.add(AddConversationDomainEventStreamPublicationFields())
    app.migrations.add(AddConversationDomainEventIndexes())
    app.migrations.add(CreateConversationRoutingDirectories())
    app.migrations.add(CreateConversationMessageSearchIndex())
    app.migrations.add(AddConversationMessageSearchIndexIndexes())
    app.migrations.add(CreateConversationUserSummary())
    app.migrations.add(AddConversationUserSummaryDirectPeerProfileFields())
    app.migrations.add(AddConversationUserSummaryIndexes())
    app.migrations.add(CreateConversationSummaryReadModelTables())
    app.migrations.add(AddConversationSummaryReadModelIndexes())
    app.migrations.add(CreateConversationEventAuxiliaryReadModelTables())
    app.migrations.add(AddConversationEventAuxiliaryReadModelIndexes())
}

private func databaseConfigurationPair(for environment: Environment) -> IMPostgresDatabasePairConfiguration {
    let isProduction = environment == .production
    let defaultUsername = isProduction ? "vapor" : NSUserName()
    let defaultPassword = isProduction ? "vapor_password" : ""
    let base = PostgresConnectionParameters(
        host: Environment.get("DATABASE_HOST") ?? (isProduction ? "db" : "127.0.0.1"),
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432,
        username: Environment.get("DATABASE_USERNAME") ?? defaultUsername,
        password: Environment.get("DATABASE_PASSWORD") ?? defaultPassword,
        database: Environment.get("DATABASE_NAME") ?? "vapor_auth"
    )

    let primaryParameters = PostgresConnectionParameters(
        host: Environment.get("DATABASE_PRIMARY_HOST") ?? base.host,
        port: Environment.get("DATABASE_PRIMARY_PORT").flatMap(Int.init(_:)) ?? base.port,
        username: Environment.get("DATABASE_PRIMARY_USERNAME") ?? base.username,
        password: Environment.get("DATABASE_PRIMARY_PASSWORD") ?? base.password,
        database: Environment.get("DATABASE_PRIMARY_NAME") ?? base.database
    )

    let replica = Environment.get("DATABASE_REPLICA_HOST").map { host in
        PostgresConnectionParameters(
            host: host,
            port: Environment.get("DATABASE_REPLICA_PORT").flatMap(Int.init(_:)) ?? primaryParameters.port,
            username: Environment.get("DATABASE_REPLICA_USERNAME") ?? primaryParameters.username,
            password: Environment.get("DATABASE_REPLICA_PASSWORD") ?? primaryParameters.password,
            database: Environment.get("DATABASE_REPLICA_NAME") ?? primaryParameters.database
        )
    }

    let summary = Environment.get("DATABASE_SUMMARY_HOST").map { host in
        PostgresConnectionParameters(
            host: host,
            port: Environment.get("DATABASE_SUMMARY_PORT").flatMap(Int.init(_:)) ?? primaryParameters.port,
            username: Environment.get("DATABASE_SUMMARY_USERNAME") ?? primaryParameters.username,
            password: Environment.get("DATABASE_SUMMARY_PASSWORD") ?? primaryParameters.password,
            database: Environment.get("DATABASE_SUMMARY_NAME") ?? primaryParameters.database
        )
    }

    let conversationShardPairs: [(String, SQLPostgresConfiguration)] = IMShardTopologyConfiguration.load(from: environment).shardIDs.compactMap { shardID in
        guard let parameters = conversationShardParameters(
            shardID: shardID,
            primaryParameters: primaryParameters
        ) else {
            return nil
        }
        return (shardID, parameters.configuration)
    }
    let conversationShardReplicaPairs: [(String, SQLPostgresConfiguration)] = IMShardTopologyConfiguration.load(from: environment).shardIDs.compactMap { shardID in
        guard let parameters = conversationShardReplicaParameters(
            shardID: shardID,
            primaryParameters: primaryParameters,
            replicaParameters: replica
        ) else {
            return nil
        }
        return (shardID, parameters.configuration)
    }

    let summaryShardPairs: [(String, SQLPostgresConfiguration)] = IMSummaryStoreConfiguration.load(from: environment).shardIDs.compactMap { shardID in
            guard let parameters = summaryShardParameters(
                shardID: shardID,
                primaryParameters: primaryParameters,
                legacySummary: summary
            ) else {
                return nil
            }
            return (shardID, parameters.configuration)
        }
    let summaryShardConfigurations = Dictionary(uniqueKeysWithValues: summaryShardPairs)

    return IMPostgresDatabasePairConfiguration(
        primary: primaryParameters.configuration,
        replica: replica?.configuration,
        conversationShards: Dictionary(uniqueKeysWithValues: conversationShardPairs),
        conversationShardReplicas: Dictionary(uniqueKeysWithValues: conversationShardReplicaPairs),
        summary: summary?.configuration,
        summaryShards: summaryShardConfigurations
    )
}

private func conversationShardParameters(
    shardID: String,
    primaryParameters: PostgresConnectionParameters
) -> PostgresConnectionParameters? {
    let envComponent = normalizedEnvironmentComponent(shardID)
    let hostKey = "DATABASE_CONVERSATION_\(envComponent)_HOST"
    if let host = Environment.get(hostKey) {
        return PostgresConnectionParameters(
            host: host,
            port: Environment.get("DATABASE_CONVERSATION_\(envComponent)_PORT").flatMap(Int.init(_:)) ?? primaryParameters.port,
            username: Environment.get("DATABASE_CONVERSATION_\(envComponent)_USERNAME") ?? primaryParameters.username,
            password: Environment.get("DATABASE_CONVERSATION_\(envComponent)_PASSWORD") ?? primaryParameters.password,
            database: Environment.get("DATABASE_CONVERSATION_\(envComponent)_NAME") ?? primaryParameters.database
        )
    }

    if shardID == SingleShardConversationShardRouter.defaultShardID {
        return primaryParameters
    }

    return nil
}

private func conversationShardReplicaParameters(
    shardID: String,
    primaryParameters: PostgresConnectionParameters,
    replicaParameters: PostgresConnectionParameters?
) -> PostgresConnectionParameters? {
    let envComponent = normalizedEnvironmentComponent(shardID)
    let hostKey = "DATABASE_CONVERSATION_\(envComponent)_REPLICA_HOST"
    if let host = Environment.get(hostKey) {
        return PostgresConnectionParameters(
            host: host,
            port: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_PORT").flatMap(Int.init(_:)) ?? replicaParameters?.port ?? primaryParameters.port,
            username: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_USERNAME") ?? replicaParameters?.username ?? primaryParameters.username,
            password: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_PASSWORD") ?? replicaParameters?.password ?? primaryParameters.password,
            database: Environment.get("DATABASE_CONVERSATION_\(envComponent)_REPLICA_NAME") ?? replicaParameters?.database ?? primaryParameters.database
        )
    }

    if shardID == SingleShardConversationShardRouter.defaultShardID {
        return replicaParameters
    }

    return nil
}

private struct PostgresConnectionParameters {
    let host: String
    let port: Int
    let username: String
    let password: String
    let database: String

    var configuration: SQLPostgresConfiguration {
        SQLPostgresConfiguration(
            hostname: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
    }
}

private func summaryShardParameters(
    shardID: String,
    primaryParameters: PostgresConnectionParameters,
    legacySummary: PostgresConnectionParameters?
) -> PostgresConnectionParameters? {
    let envComponent = normalizedEnvironmentComponent(shardID)
    let hostKey = "DATABASE_SUMMARY_\(envComponent)_HOST"
    if let host = Environment.get(hostKey) {
        return PostgresConnectionParameters(
            host: host,
            port: Environment.get("DATABASE_SUMMARY_\(envComponent)_PORT").flatMap(Int.init(_:)) ?? legacySummary?.port ?? primaryParameters.port,
            username: Environment.get("DATABASE_SUMMARY_\(envComponent)_USERNAME") ?? legacySummary?.username ?? primaryParameters.username,
            password: Environment.get("DATABASE_SUMMARY_\(envComponent)_PASSWORD") ?? legacySummary?.password ?? primaryParameters.password,
            database: Environment.get("DATABASE_SUMMARY_\(envComponent)_NAME") ?? legacySummary?.database ?? primaryParameters.database
        )
    }

    if shardID == IMSummaryStoreConfiguration.defaultShardID {
        return legacySummary
    }

    return nil
}

private func normalizedEnvironmentComponent(_ rawValue: String) -> String {
    let scalars = rawValue.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) {
            return Character(String(scalar).uppercased())
        }
        return "_"
    }
    return String(scalars)
}

private func loadLocalEnvironmentIfNeeded(environment: Environment) {
    guard environment != .production, environment != .testing else {
        return
    }

    // 优先读取 .env.local，其次兜底 .env，且不会覆盖已经注入的环境变量。
    let candidates = [
        packageRoot.appendingPathComponent(".env.local"),
        packageRoot.appendingPathComponent(".env")
    ]

    for fileURL in candidates where FileManager.default.fileExists(atPath: fileURL.path) {
        loadEnvironmentFile(at: fileURL)
        return
    }
}

private func loadEnvironmentFile(at fileURL: URL) {
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
        return
    }

    for rawLine in contents.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
            continue
        }

        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, Environment.get(key) == nil else {
            continue
        }

        let valueStart = line.index(after: separator)
        let rawValue = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = unquote(rawValue)

        setenv(key, value, 0)
    }
}

private func unquote(_ value: String) -> String {
    guard value.count >= 2 else {
        return value
    }

    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
        return String(value.dropFirst().dropLast())
    }

    return value
}

private var packageRoot: URL {
    let sourceFileURL = URL(fileURLWithPath: #filePath)
    return sourceFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func seedDevelopmentUserIfNeeded(in app: Application) async throws {
    guard app.environment != .production else {
        return
    }

    // 本地开发自动补一个演示账号，减少第一次联调成本。
    let email = Environment.get("SEED_USER_EMAIL") ?? "demo@example.com"
    let password = Environment.get("SEED_USER_PASSWORD") ?? "password1234"
    let normalizedEmail = User.normalize(email)

    guard try await User.query(on: app.imWriteDB)
        .filter(\.$email == normalizedEmail)
        .first() == nil
    else {
        return
    }

    let user = User(
        email: normalizedEmail,
        passwordHash: try Bcrypt.hash(password),
        status: .active
    )
    try await user.create(on: app.imWriteDB)

    app.logger.notice(
        "Seeded development login",
        metadata: [
            "email": .string(email),
            "password": .string(password)
        ]
    )
}

private func resetIMSchemaIfRequested(_ app: Application) async throws {
    guard app.shouldResetIMSchema else {
        return
    }

    guard app.environment == .development || app.environment == .testing else {
        throw Abort(.forbidden, reason: "--reset-im-schema is only available in development or testing.")
    }

    guard let sql = app.imWriteDB as? any SQLDatabase else {
        throw Abort(.badRequest, reason: "--reset-im-schema requires an SQL database.")
    }

    app.logger.notice("Resetting IM schema before auto-migrate")

    let tablesToDrop = [
        DirectConversationIndexEntry.schema,
        ConversationDirectoryEntry.schema,
        ConversationReadModelToken.schema,
        ConversationChangesLogEntry.schema,
        ConversationReplayRecord.schema,
        ConversationNotificationEntry.schema,
        ConversationUserSummary.schema,
        ConversationMessageSearchIndex.schema,
        ConversationDomainEvent.schema,
        ConversationMessage.schema,
        ConversationMember.schema,
        Conversation.schema
    ]
    let dropSuffix = sql.dialect.name == "postgresql" ? " CASCADE" : ""

    for table in tablesToDrop {
        try await sql.raw("DROP TABLE IF EXISTS \(unsafeRaw: table)\(unsafeRaw: dropSuffix)").run()
    }

    if try await fluentMigrationTableExists(on: sql) {
        for migrationName in imMigrationNames {
            try await sql.raw(
                """
                DELETE FROM \(unsafeRaw: "_fluent_migrations")
                WHERE \(unsafeRaw: "name") = \(bind: migrationName)
                   OR \(unsafeRaw: "name") LIKE \(bind: "%.\(migrationName)")
                """
            ).run()
        }
    }
}

private func validateIMSchema(_ app: Application) async throws {
    guard let writeSQL = app.imWriteDB as? any SQLDatabase else {
        return
    }

    try await validateIMSchema(
        on: writeSQL,
        role: "primary",
        environment: app.environment,
        logger: app.logger,
        resetAllowed: app.environment == .development || app.environment == .testing
    )

    if app.imReplicaDatabaseEnabled,
       let readSQL = app.imReadDB as? any SQLDatabase {
        try await validateIMSchema(
            on: readSQL,
            role: "replica",
            environment: app.environment,
            logger: app.logger,
            resetAllowed: false
        )
    }
}

private func validateIMSchema(
    on sql: any SQLDatabase,
    role: String,
    environment: Environment,
    logger: Logger,
    resetAllowed: Bool
) async throws {
    for requirement in imSchemaRequirements {
        let existingColumns = try await fetchColumnNames(
            in: requirement.table,
            on: sql
        )
        let missingColumns = requirement.requiredColumns.subtracting(existingColumns)
        guard missingColumns.isEmpty else {
            let missing = missingColumns.sorted().joined(separator: ", ")
            let reason: String
            if resetAllowed {
                reason = "IM schema validation failed on \(role): table \(requirement.table) is missing columns [\(missing)]. This database is from an older incompatible IM schema. Restart with --reset-im-schema to rebuild the IM tables from current migrations."
            } else {
                reason = "IM schema validation failed on \(role): table \(requirement.table) is missing columns [\(missing)]. The database schema does not match the current IM server build."
            }

            logger.critical(.init(stringLiteral: reason))
            throw Abort(.internalServerError, reason: reason)
        }
    }
}

private func fetchColumnNames(
    in table: String,
    on sql: any SQLDatabase
) async throws -> Set<String> {
    switch sql.dialect.name {
    case "postgresql":
        struct PostgresColumnRow: Decodable {
            let column_name: String
        }

        let rows = try await sql.raw(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = \(bind: table)
            """
        ).all(decoding: PostgresColumnRow.self)
        return Set(rows.map(\.column_name))

    case "sqlite":
        struct SQLiteColumnRow: Decodable {
            let name: String
        }

        let rows = try await sql.raw(
            "PRAGMA table_info(\(unsafeRaw: table));"
        ).all(decoding: SQLiteColumnRow.self)
        return Set(rows.map(\.name))

    default:
        return []
    }
}

private struct IMTableSchemaRequirement {
    let table: String
    let requiredColumns: Set<String>
}

private let imSchemaRequirements: [IMTableSchemaRequirement] = [
    IMTableSchemaRequirement(
        table: Conversation.schema,
        requiredColumns: [
            "id",
            "title",
            "notice",
            "kind",
            "avatar_preset",
            "direct_messaging_state",
            "last_message_sequence",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationMember.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "user_id",
            "visible_from_sequence",
            "last_read_sequence",
            "role",
            "joined_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationMessage.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "sender_user_id",
            "kind",
            "body_json",
            "client_message_id",
            "server_sequence",
            "derived_state_json",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationDomainEvent.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "event_type",
            "payload_json",
            "status",
            "retry_count",
            "processing_started_at",
            "processed_at",
            "error_message",
            "created_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationMessageSearchIndex.schema,
        requiredColumns: [
            "id",
            "conversation_id",
            "message_id",
            "server_sequence",
            "searchable_text",
            "message_type",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationUserSummary.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "conversation_id",
            "title",
            "notice",
            "avatar_preset",
            "kind",
            "direct_messaging_state",
            "direct_peer_user_id",
            "direct_peer_email",
            "direct_peer_display_name",
            "direct_peer_avatar_preset",
            "member_count",
            "member_user_ids_json",
            "last_message_json",
            "last_read_sequence",
            "unread_count",
            "last_activity_at",
            "is_removed",
            "is_pinned",
            "is_muted",
            "pinned_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationChangesLogEntry.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "conversation_id",
            "summary_record_id",
            "updated_at",
            "is_removed"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationReadModelToken.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "target_token",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationNotificationEntry.schema,
        requiredColumns: [
            "id",
            "owner_user_id",
            "event_id",
            "conversation_id",
            "event_type",
            "payload_json",
            "created_at",
            "updated_at"
        ]
    ),
    IMTableSchemaRequirement(
        table: ConversationReplayRecord.schema,
        requiredColumns: [
            "id",
            "event_id",
            "consumer_group_id",
            "source_topic",
            "conversation_id",
            "event_type",
            "producer_shard",
            "payload_json",
            "status",
            "last_error",
            "receive_count",
            "replayed_at",
            "created_at",
            "updated_at"
        ]
    )
]

private func fluentMigrationTableExists(on sql: any SQLDatabase) async throws -> Bool {
    switch sql.dialect.name {
    case "postgresql":
        struct PostgresFluentMigrationTableRow: Decodable {
            let exists: String?
        }

        let row = try await sql.raw(
            "SELECT to_regclass('public._fluent_migrations') AS exists"
        ).first(decoding: PostgresFluentMigrationTableRow.self)
        return row?.exists != nil

    case "sqlite":
        struct SQLiteFluentMigrationTableRow: Decodable {
            let name: String?
        }

        let row = try await sql.raw(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '_fluent_migrations' LIMIT 1"
        ).first(decoding: SQLiteFluentMigrationTableRow.self)
        return row?.name != nil

    default:
        return false
    }
}

private let imMigrationNames: [String] = [
    "CreateConversation",
    "AddConversationLastMessageSequence",
    "CreateConversationMember",
    "AddConversationMemberLastReadSequence",
    "AddConversationKind",
    "AddConversationDirectMessagingState",
    "AddConversationMemberRole",
    "AddConversationMetadataAndPreferences",
    "CreateConversationMessage",
    "AddConversationMessageDerivedState",
    "AddConversationMessageClientMessageID",
    "AddConversationMessageClientMessageIDUniqueIndex",
    "CreateConversationDomainEvent",
    "AddConversationDomainEventRetryCount",
    "AddConversationDomainEventStreamPublicationFields",
    "AddConversationDomainEventIndexes",
    "CreateConversationMessageSearchIndex",
    "AddConversationMessageSearchIndexIndexes",
    "CreateConversationUserSummary",
    "AddConversationUserSummaryDirectPeerProfileFields",
    "AddConversationUserSummaryIndexes",
    "CreateConversationSummaryReadModelTables",
    "AddConversationSummaryReadModelIndexes",
    "CreateConversationEventAuxiliaryReadModelTables",
    "AddConversationEventAuxiliaryReadModelIndexes"
]

private struct ResetIMSchemaStorageKey: StorageKey {
    typealias Value = Bool
}

extension Application {
    var shouldResetIMSchema: Bool {
        get { storage[ResetIMSchemaStorageKey.self] ?? false }
        set { storage[ResetIMSchemaStorageKey.self] = newValue }
    }
}
