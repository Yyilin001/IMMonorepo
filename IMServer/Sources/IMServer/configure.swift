import Foundation
import Vapor

// 配置你的应用程序
public func configure(_ app: Application) async throws {
    try await configureShared(app)
    try await IMRuntimeConfigurator.configureRole(app)

    if app.imRuntimeRole.servesHTTP {
        try routes(app)
    }
}

private func configureShared(_ app: Application) async throws {
    // 本地开发从 .env.local 读取数据库和密钥配置，避免 Xcode 直接运行时丢环境变量。
    loadLocalEnvironmentIfNeeded(environment: app.environment)
    try IMProductionRuntimeValidator.validateRole(app: app)

    let authConfiguration = try AuthConfiguration.load(from: app.environment)
    let authSecurityConfiguration = try AuthSecurityConfiguration.load(from: app.environment)
    let authSessionCacheConfiguration = AuthSessionCacheConfiguration.load(from: app.environment)
    let imTCPConfiguration = IMTCPConfiguration.load(from: app.environment)
    let gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration.load()
    app.authClientIPResolver = AuthClientIPResolver.load(from: app.environment)
    app.gatewayRelayConfiguration = IMGatewayRelayConfiguration.load(from: app.environment)
    app.commandAPIIngressConfiguration = IMCommandAPIIngressConfiguration.load(from: app.environment)
    app.eventStreamConfiguration = IMEventStreamConfiguration.load(from: app.environment)
    app.searchIndexConfiguration = IMSearchIndexConfiguration.load(from: app.environment)
    app.shardTopologyConfiguration = IMShardTopologyConfiguration.load(from: app.environment)
    app.summaryStoreConfiguration = IMSummaryStoreConfiguration.load(from: app.environment)
    app.summaryReadModelConfiguration = IMSummaryReadModelConfiguration.load(from: app.environment)
    app.streamConsumerConfiguration = IMStreamConsumerConfiguration.load(from: app.environment)
    app.metricsConfiguration = IMMetricsConfiguration.load(from: app.environment)
    app.hotConversationConfiguration = IMHotConversationConfiguration.load(from: app.environment)
    app.sequenceAllocationConfiguration = IMSequenceAllocationConfiguration.load(from: app.environment)
    app.commandOwnerRoutingConfiguration = IMCommandOwnerRoutingConfiguration.load(from: app.environment)
    app.conversationMemberCacheConfiguration = IMConversationMemberCacheConfiguration.load(from: app.environment)
    app.messageWriteBatchConfiguration = IMMessageWriteBatchConfiguration.load(from: app.environment)
    app.messageCreatedRecipientInlineConfiguration = IMMessageCreatedRecipientInlineConfiguration.load(from: app.environment)
    app.domainEventRecipientSnapshotConfiguration = IMDomainEventRecipientSnapshotConfiguration.load(from: app.environment)
    app.consistencyRepairConfiguration = IMConsistencyRepairConfiguration.load(from: app.environment)
    app.imTCPConfiguration = imTCPConfiguration
    app.gatewayLocalFanoutConfiguration = gatewayLocalFanoutConfiguration

    try app.metricsConfiguration.validateStartup(environment: app.environment)
    try IMMigrationStartupPolicy.validateStartup(app: app)
    try InlineOutboxProjectionPolicy.validateStartup(app: app)
    IMDatabaseConfigurator.configureDatabases(app)
    try IMProductionRuntimeValidator.validate(app: app)
    try await app.configureAIStreamLeaseStoreIfNeeded()
    app.authConfiguration = authConfiguration
    app.authSecurityConfiguration = authSecurityConfiguration
    app.authSessionCacheConfiguration = authSessionCacheConfiguration
    app.authSessionValidationCache = await AuthSessionValidationCacheFactory.make(
        app: app,
        configuration: authSessionCacheConfiguration
    )
    app.authLoginRateLimiter = try await AuthRateLimiterFactory.make(app: app, configuration: authSecurityConfiguration)
    app.authEmailSender = try AuthEmailSenderFactory.make(app: app, configuration: authSecurityConfiguration)
    app.lifecycle.use(ConversationEventStreamProducerLifecycle())
    app.lifecycle.use(IMConsistencyRepairLifecycle())
    app.lifecycle.use(IMCleanupLifecycle())
    app.lifecycle.use(IMAIStreamRepairLifecycle())
    app.asyncCommands.use(IMProjectionWorkerCommand(), as: "worker")
    app.asyncCommands.use(IMProjectionWorkerCommand(), as: "projection-worker")
    app.asyncCommands.use(IMOutboxRelayCommand(), as: "outbox-relay")
    app.asyncCommands.use(IMStreamConsumerCommand(), as: "stream-consumer")
    app.asyncCommands.use(IMOpsCommand(), as: "ops")
    IMMigrationRegistry.registerMigrations(app)
    if try IMMigrationStartupPolicy.shouldAutoMigrate(app: app) {
        try await IMMigrationRegistry.resetIMSchemaIfRequested(app)
        try await app.autoMigrate()
    } else if app.shouldResetIMSchema {
        throw Abort(
            .forbidden,
            reason: "--reset-im-schema requires auto-migration and is only available for development/testing."
        )
    }
    try await IMSchemaValidator.validateIMSchema(app)
}

private func loadLocalEnvironmentIfNeeded(environment: Environment) {
    guard environment != .production, environment != .testing else {
        return
    }

    guard FileManager.default.isReadableFile(atPath: packageRoot.path) else {
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
