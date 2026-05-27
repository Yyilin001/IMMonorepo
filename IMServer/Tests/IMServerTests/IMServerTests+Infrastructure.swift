@testable import IMServer
import Fluent
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Test Root Route Returns HTML")
    func rootRouteServesIndex() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "/", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.type == "text")
                #expect(res.headers.contentType?.subType == "html")
                #expect(res.body.string.contains("Vapor Hello"))
            })
        }
    }

    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Test Hello Greet Route")
    func helloGreet() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello/greet/Codex", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, Codex!")
            })
        }
    }

    @Test("Test Hello Info Route")
    func helloInfo() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello/info", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.subType == "json")
                #expect(res.body.string.contains("\"message\":\"Hello from Vapor\""))
                #expect(res.body.string.contains("\"availableRoutes\""))
                #expect(res.body.string.contains("greet"))
            })
        }
    }

    @Test("Test Hello Query Route")
    func helloQuery() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "hello/query?name=Taylor", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.subType == "json")
                #expect(res.body.string.contains("\"greeting\":\"Hello, Taylor!\""))
            })
        }
    }

    @Test("Login returns an access token and user")
    func login() async throws {
        try await withApp(configure: configure) { app in
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.content.decode(AuthResponse.self)
                #expect(!payload.accessToken.isEmpty)
                #expect(!payload.refreshToken.isEmpty)
                #expect(payload.user.email == "demo@example.com")
            })
        }
    }

    @Test("Production requires an explicit JWT secret")
    func productionRequiresJWTSecret() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        defer { restoreEnvironment("JWT_SECRET", to: originalJWTSecret) }

        unsetenv("JWT_SECRET")

        do {
            _ = try AuthConfiguration.load(from: .production)
            Issue.record("Expected production auth configuration to fail without JWT_SECRET")
        } catch AuthConfigurationError.missingJWTSecret {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Production requires Redis-backed routing")
    func productionRequiresRedisRouting() async throws {
        let app = try await Application.make(.production)
        app.imRedisRoutingConfigurationOverride = IMRedisRoutingConfiguration(
            url: nil,
            mode: .local,
            maximumConnectionCount: 2
        )

        do {
            try await app.configureConnectionRoutingServiceIfNeeded()
            Issue.record("Expected production routing configuration to require Redis")
        } catch RedisRoutingError.redisRequiredInProduction {
        } catch {
            Issue.record("Unexpected routing error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Production rejects combined runtime during startup")
    func productionRejectsCombinedRuntimeDuringStartup() async throws {
        let app = try await Application.make(.production)
        app.imRuntimeRole = .combined

        do {
            try await configure(app)
            Issue.record("Expected production combined runtime to fail during configure")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("combined runtime role"))
        } catch {
            Issue.record("Unexpected production runtime error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Production rejects projection-worker runtime during startup validation")
    func productionRejectsProjectionWorkerRuntimeDuringStartupValidation() async throws {
        let originalNodeID = Environment.get("IM_NODE_ID")
        defer { restoreEnvironment("IM_NODE_ID", to: originalNodeID) }
        setenv("IM_NODE_ID", "node-a", 1)

        let app = try await Application.make(.production)
        app.imRuntimeRole = .projectionWorker

        do {
            try IMProductionRuntimeValidator.validate(app: app)
            Issue.record("Expected production projection-worker runtime to fail validation")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("projection-worker"))
        } catch {
            Issue.record("Unexpected production runtime error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Production non-ops roles cannot enable startup auto-migration")
    func productionNonOpsRolesCannotEnableStartupAutoMigration() async throws {
        let originalValue = Environment.get(IMMigrationStartupPolicy.environmentKey)
        defer { restoreEnvironment(IMMigrationStartupPolicy.environmentKey, to: originalValue) }
        setenv(IMMigrationStartupPolicy.environmentKey, "true", 1)

        let app = try await Application.make(.production)
        app.imRuntimeRole = .gateway

        do {
            _ = try IMMigrationStartupPolicy.shouldAutoMigrate(app: app)
            Issue.record("Expected production gateway auto-migration to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("must not run auto-migration"))
        } catch {
            Issue.record("Unexpected migration startup policy error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Migration startup policy keeps local auto-migration and production ops explicit")
    func migrationStartupPolicyKeepsLocalAutoMigrationAndProductionOpsExplicit() async throws {
        let originalValue = Environment.get(IMMigrationStartupPolicy.environmentKey)
        defer { restoreEnvironment(IMMigrationStartupPolicy.environmentKey, to: originalValue) }
        unsetenv(IMMigrationStartupPolicy.environmentKey)

        let testingApp = try await Application.make(.testing)
        #expect(try IMMigrationStartupPolicy.shouldAutoMigrate(app: testingApp))
        try? await testingApp.asyncShutdown()

        let developmentApp = try await Application.make(.development)
        #expect(try IMMigrationStartupPolicy.shouldAutoMigrate(app: developmentApp))
        try? await developmentApp.asyncShutdown()

        let productionOps = try await Application.make(.production)
        productionOps.imRuntimeRole = .ops
        #expect(try IMMigrationStartupPolicy.shouldAutoMigrate(app: productionOps) == false)
        setenv(IMMigrationStartupPolicy.environmentKey, "true", 1)
        #expect(try IMMigrationStartupPolicy.shouldAutoMigrate(app: productionOps))
        try? await productionOps.asyncShutdown()
    }

    @Test("Production rejects inline outbox projection")
    func productionRejectsInlineOutboxProjection() async throws {
        let originalValue = Environment.get(InlineOutboxProjectionPolicy.environmentKey)
        defer { restoreEnvironment(InlineOutboxProjectionPolicy.environmentKey, to: originalValue) }
        setenv(InlineOutboxProjectionPolicy.environmentKey, "true", 1)

        let app = try await Application.make(.production)
        app.imRuntimeRole = .commandAPI

        do {
            try InlineOutboxProjectionPolicy.validateStartup(app: app)
            Issue.record("Expected production inline outbox projection to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("IM_INLINE_OUTBOX_PROJECTION"))
        } catch {
            Issue.record("Unexpected inline outbox projection policy error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Production media storage provider validation throws instead of trapping")
    func productionMediaStorageProviderValidationThrowsInsteadOfTrapping() async throws {
        let originalProvider = Environment.get("MEDIA_STORAGE_PROVIDER")
        defer { restoreEnvironment("MEDIA_STORAGE_PROVIDER", to: originalProvider) }
        setenv("MEDIA_STORAGE_PROVIDER", "local", 1)

        let app = try await Application.make(.production)

        do {
            _ = try MediaStorageService(app: app)
            Issue.record("Expected production local media storage provider to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("MEDIA_STORAGE_PROVIDER=s3compatible"))
        } catch {
            Issue.record("Unexpected media storage provider error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Inline outbox projection policy permits testing and development combined only")
    func inlineOutboxProjectionPolicyPermitsTestingAndDevelopmentCombinedOnly() async throws {
        let originalValue = Environment.get(InlineOutboxProjectionPolicy.environmentKey)
        defer { restoreEnvironment(InlineOutboxProjectionPolicy.environmentKey, to: originalValue) }
        unsetenv(InlineOutboxProjectionPolicy.environmentKey)

        let testingApp = try await Application.make(.testing)
        #expect(try InlineOutboxProjectionPolicy.allowsInlineProjection(app: testingApp))
        try? await testingApp.asyncShutdown()

        let developmentCombined = try await Application.make(.development)
        developmentCombined.imRuntimeRole = .combined
        #expect(try InlineOutboxProjectionPolicy.allowsInlineProjection(app: developmentCombined))
        try? await developmentCombined.asyncShutdown()

        let developmentCommand = try await Application.make(.development)
        developmentCommand.imRuntimeRole = .commandAPI
        #expect(try InlineOutboxProjectionPolicy.allowsInlineProjection(app: developmentCommand) == false)
        try? await developmentCommand.asyncShutdown()
    }

    @Test("Production runtime validator accepts complete role fixtures")
    func productionRuntimeValidatorAcceptsCompleteRoleFixtures() async throws {
        try await withProductionRuntimeEnvironment {
            for role in [
                IMRuntimeRole.gateway,
                .commandAPI,
                .queryAPI,
                .outboxRelay,
                .streamConsumer,
                .ops
            ] {
                let app = try await productionRuntimeValidationApp(role: role)
                do {
                    try IMProductionRuntimeValidator.validate(app: app)
                    try await app.asyncShutdown()
                } catch {
                    try? await app.asyncShutdown()
                    throw error
                }
            }
        }
    }

    @Test("Per-role production validators accept complete role fixtures")
    func perRoleProductionValidatorsAcceptCompleteRoleFixtures() async throws {
        try await withProductionRuntimeEnvironment {
            let validators: [(IMRuntimeRole, (Application) throws -> Void)] = [
                (.gateway, IMGatewayProductionValidator.validate(app:)),
                (.commandAPI, IMCommandAPIProductionValidator.validate(app:)),
                (.queryAPI, IMQueryAPIProductionValidator.validate(app:)),
                (.outboxRelay, IMOutboxRelayProductionValidator.validate(app:)),
                (.streamConsumer, IMStreamConsumerProductionValidator.validate(app:)),
                (.ops, IMOpsProductionValidator.validate(app:))
            ]

            for (role, validator) in validators {
                let app = try await productionRuntimeValidationApp(role: role)
                do {
                    try validator(app)
                    try await app.asyncShutdown()
                } catch {
                    try? await app.asyncShutdown()
                    throw error
                }
            }
        }
    }

    @Test("Production command API uses block sequence allocation by default")
    func productionCommandAPIUsesBlockSequenceAllocationByDefault() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_SEQUENCE_ALLOCATION_MODE")
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            #expect(app.sequenceAllocationConfiguration.mode == .block)
            try IMCommandAPIProductionValidator.validate(app: app)
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires message write batching")
    func productionCommandAPIRequiresMessageWriteBatching() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_MESSAGE_WRITE_BATCH_ENABLED")
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require message write batching")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_MESSAGE_WRITE_BATCH_ENABLED=true"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires gateway relay internal secret")
    func productionCommandAPIRequiresGatewayRelayInternalSecret() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_INTERNAL_SHARED_SECRET")
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require gateway relay internal secret")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_INTERNAL_SHARED_SECRET"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway public TCP bind requires TLS termination confirmation")
    func productionGatewayPublicTCPBindRequiresTLSTerminationConfirmation() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_TCP_REQUIRES_TLS_TERMINATION")
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to require TCP TLS termination confirmation")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TCP_REQUIRES_TLS_TERMINATION=true"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Runtime role capabilities keep production responsibilities isolated")
    func runtimeRoleCapabilitiesKeepProductionResponsibilitiesIsolated() {
        #expect(IMRuntimeRole.gateway.servesGateway)
        #expect(!IMRuntimeRole.gateway.servesCommandAPI)
        #expect(!IMRuntimeRole.gateway.servesQueryAPI)

        #expect(IMRuntimeRole.commandAPI.servesCommandAPI)
        #expect(!IMRuntimeRole.commandAPI.servesGateway)
        #expect(!IMRuntimeRole.commandAPI.servesQueryAPI)

        #expect(IMRuntimeRole.queryAPI.servesQueryAPI)
        #expect(!IMRuntimeRole.queryAPI.servesGateway)
        #expect(!IMRuntimeRole.queryAPI.servesCommandAPI)

        #expect(!IMRuntimeRole.outboxRelay.servesHTTP)
        #expect(!IMRuntimeRole.streamConsumer.servesHTTP)
        #expect(!IMRuntimeRole.ops.servesHTTP)
        #expect(IMRuntimeRole.combined.servesGateway)
        #expect(IMRuntimeRole.combined.servesCommandAPI)
        #expect(IMRuntimeRole.combined.servesQueryAPI)
    }

    @Test("Runtime role resolves IM_RUNTIME_ROLE values")
    func runtimeRoleResolvesEnvironmentValues() {
        #expect(IMRuntimeRole.resolve("gateway") == .gateway)
        #expect(IMRuntimeRole.resolve("command-api") == .commandAPI)
        #expect(IMRuntimeRole.resolve("query-api") == .queryAPI)
        #expect(IMRuntimeRole.resolve("outbox-relay") == .outboxRelay)
        #expect(IMRuntimeRole.resolve("stream-consumer") == .streamConsumer)
        #expect(IMRuntimeRole.resolve("projection-worker") == .projectionWorker)
        #expect(IMRuntimeRole.resolve("combined") == .combined)
        #expect(IMRuntimeRole.resolve("ops") == .ops)
        #expect(IMRuntimeRole.resolve("unknown") == nil)
    }

    @Test("Testing environment uses local routing by default")
    func testingUsesLocalRoutingBackendByDefault() async throws {
        try await withApp(configure: configure) { app in
            #expect(app.connectionRoutingService.routeBackendName == "local")
        }
    }

    @Test("Testing environment falls back to local routing when Redis configuration is unavailable")
    func testingFallsBackToLocalRoutingWhenRedisConfigurationUnavailable() async throws {
        try await withApp(configure: { app in
            app.imRedisRoutingConfigurationOverride = IMRedisRoutingConfiguration(
                url: nil,
                mode: .redis,
                maximumConnectionCount: 2
            )
            try await configure(app)
        }) { app in
            #expect(app.connectionRoutingService.routeBackendName == "local")
        }
    }

    @Test("Kafka event stream configuration supports broker cluster producer settings")
    func kafkaEventStreamConfigurationBuildsClusterProducerConfiguration() throws {
        let originalValues = [
            "IM_KAFKA_BROKERS": Environment.get("IM_KAFKA_BROKERS"),
            "IM_KAFKA_CLIENT_ID": Environment.get("IM_KAFKA_CLIENT_ID"),
            "IM_KAFKA_REQUIRED_ACKS": Environment.get("IM_KAFKA_REQUIRED_ACKS"),
            "IM_KAFKA_COMPRESSION": Environment.get("IM_KAFKA_COMPRESSION"),
            "IM_KAFKA_LINGER_MS": Environment.get("IM_KAFKA_LINGER_MS"),
            "IM_KAFKA_REQUEST_TIMEOUT_MS": Environment.get("IM_KAFKA_REQUEST_TIMEOUT_MS"),
            "IM_KAFKA_MESSAGE_TIMEOUT_MS": Environment.get("IM_KAFKA_MESSAGE_TIMEOUT_MS"),
            "IM_KAFKA_AUTO_CREATE_TOPICS": Environment.get("IM_KAFKA_AUTO_CREATE_TOPICS"),
            "IM_KAFKA_SECURITY_PROTOCOL": Environment.get("IM_KAFKA_SECURITY_PROTOCOL"),
            "IM_KAFKA_SASL_MECHANISM": Environment.get("IM_KAFKA_SASL_MECHANISM"),
            "IM_KAFKA_SASL_USERNAME": Environment.get("IM_KAFKA_SASL_USERNAME"),
            "IM_KAFKA_SASL_PASSWORD": Environment.get("IM_KAFKA_SASL_PASSWORD"),
            "IM_KAFKA_TLS_CA_FILE": Environment.get("IM_KAFKA_TLS_CA_FILE")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        setenv("IM_KAFKA_BROKERS", "kafka-a:9092,kafka-b:9093", 1)
        setenv("IM_KAFKA_CLIENT_ID", "im-command", 1)
        setenv("IM_KAFKA_REQUIRED_ACKS", "1", 1)
        setenv("IM_KAFKA_COMPRESSION", "gzip", 1)
        setenv("IM_KAFKA_LINGER_MS", "25", 1)
        setenv("IM_KAFKA_REQUEST_TIMEOUT_MS", "45000", 1)
        setenv("IM_KAFKA_MESSAGE_TIMEOUT_MS", "120000", 1)
        setenv("IM_KAFKA_AUTO_CREATE_TOPICS", "false", 1)
        setenv("IM_KAFKA_SECURITY_PROTOCOL", "sasl_tls", 1)
        setenv("IM_KAFKA_SASL_MECHANISM", "scram-sha-512", 1)
        setenv("IM_KAFKA_SASL_USERNAME", "im-user", 1)
        setenv("IM_KAFKA_SASL_PASSWORD", "im-password", 1)
        setenv("IM_KAFKA_TLS_CA_FILE", "/tmp/im-ca.pem", 1)

        let configuration = IMEventStreamConfiguration.load(from: .development)
        let producerConfiguration = try configuration.makeProducerConfiguration(nodeID: "node-1")
        let consumerConfiguration = try configuration.makeConsumerConfiguration(
            consumerGroupID: "summary-projection-consumer",
            clientSuffix: "summary"
        )

        #expect(configuration.brokers.count == 2)
        #expect(producerConfiguration.identifier == "im-command-node-1")
        #expect(producerConfiguration.bootstrapBrokerAddresses.count == 2)
        #expect(producerConfiguration.queue.maximumMessageQueueTime == .milliseconds(25))
        #expect(producerConfiguration.topicConfiguration.requestTimeout == .milliseconds(45_000))
        #expect(producerConfiguration.topicConfiguration.messageTimeout == .timeout(.milliseconds(120_000)))
        #expect(producerConfiguration.topicConfiguration.requiredAcknowledgements == .atLeast(1))
        #expect(producerConfiguration.topicConfiguration.compression.codec == .gzip(compressionLevel: .codecDependent))
        #expect(producerConfiguration.isAutoCreateTopicsEnabled == false)
        #expect(consumerConfiguration.identifier == "im-command-summary")
        #expect(consumerConfiguration.isAutoCommitEnabled == false)
        #expect(consumerConfiguration.bootstrapBrokerAddresses.count == 2)
    }

    @Test("Summary shard router routes by owner user ID")
    func summaryShardRouterRoutesByOwnerUserID() async throws {
        try await withApp(configure: configure) { app in
            app.summaryStoreConfiguration = IMSummaryStoreConfiguration(shardIDs: ["summary-a", "summary-b"])
            app.summaryShardDatabaseIDs = [
                "summary-a": .imSummary,
                "summary-b": .imSummary
            ]

            let router = app.summaryShardRouter
            let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let routedShard = router.shardID(forOwnerUserID: userID)

            #expect(router.shardIDs == ["summary-a", "summary-b"])
            #expect(routedShard == router.shardID(forOwnerUserID: userID))
            #expect(router.shardIDs.contains(routedShard))
        }
    }

    @Test("Summary read model configuration defaults to sharded final-state modes")
    func summaryReadModelConfigurationDefaultsToSharded() {
        let originalValues = [
            "IM_SUMMARY_PROJECTION_WRITE_MODE": Environment.get("IM_SUMMARY_PROJECTION_WRITE_MODE"),
            "IM_SUMMARY_QUERY_READ_SOURCE": Environment.get("IM_SUMMARY_QUERY_READ_SOURCE")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        unsetenv("IM_SUMMARY_PROJECTION_WRITE_MODE")
        unsetenv("IM_SUMMARY_QUERY_READ_SOURCE")

        let configuration = IMSummaryReadModelConfiguration.load(from: .development)
        #expect(configuration.projectionWriteMode == .sharded)
        #expect(configuration.queryReadSource == .sharded)
    }

    @Test("Conversation summary list order index is migrated")
    func conversationSummaryListOrderIndexIsMigrated() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            struct SQLiteIndexRow: Decodable {
                let name: String
            }

            let rows = try await sql.raw("PRAGMA index_list(\(ident: ConversationUserSummary.schema))")
                .all(decoding: SQLiteIndexRow.self)

            #expect(rows.contains { $0.name == "im_conversation_user_summaries_list_order_idx" })
        }
    }

    @Test("Production summary read model store resolves to owner-sharded store")
    func productionSummaryReadModelStoreUsesShardedStore() async throws {
        let app = try await Application.make(.production)

        app.summaryReadModelConfiguration = IMSummaryReadModelConfiguration(
            projectionWriteMode: .sharded,
            queryReadSource: .sharded
        )
        app.summaryStoreConfiguration = IMSummaryStoreConfiguration(shardIDs: ["summary-a"])
        app.summaryShardDatabaseIDs = ["summary-a": .psql]

        #expect("\(type(of: app.summaryReadModelStore))" == "OwnerShardedSummaryReadModelStore")
        try await app.asyncShutdown()
    }

    @Test("Production OpenSearch adapter does not keep database fallback")
    func productionOpenSearchAdapterDoesNotFallbackToDatabase() async throws {
        let app = try await Application.make(.production)

        app.searchIndexConfiguration = IMSearchIndexConfiguration(
            driver: .openSearch,
            endpoint: "https://opensearch.example",
            indexName: "conversation-message-search"
        )

        #expect(app.conversationSearchAdapter is OpenSearchConversationSearchAdapter)
        try await app.asyncShutdown()
    }

    @Test("Stream consumer configuration supports single-group production deployments")
    func streamConsumerConfigurationSupportsSingleGroupDeployments() {
        let originalValues = [
            "IM_STREAM_CONSUMER_GROUPS": Environment.get("IM_STREAM_CONSUMER_GROUPS"),
            "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP": Environment.get("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
        unsetenv("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")

        let configuration = IMStreamConsumerConfiguration.load(from: .production)
        #expect(configuration.orderedEnabledGroups == ["summary-projection-consumer"])
        #expect(configuration.preservesGroupedDeploymentsInProduction == false)
    }

    @Test("Stream consumer multi-group production deployments require explicit override")
    func streamConsumerMultiGroupProductionDeploymentsRequireExplicitOverride() {
        let originalValues = [
            "IM_STREAM_CONSUMER_GROUPS": Environment.get("IM_STREAM_CONSUMER_GROUPS"),
            "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP": Environment.get("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer,changes-log-consumer", 1)
        unsetenv("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")

        var configuration = IMStreamConsumerConfiguration.load(from: .production)
        #expect(configuration.orderedEnabledGroups == ["changes-log-consumer", "summary-projection-consumer"])
        #expect(configuration.preservesGroupedDeploymentsInProduction == false)

        setenv("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP", "true", 1)
        configuration = IMStreamConsumerConfiguration.load(from: .production)
        #expect(configuration.preservesGroupedDeploymentsInProduction)
    }

    @Test("Stream consumer supervision exits when a consumer task fails")
    func streamConsumerSupervisionExitsWhenTaskFails() async throws {
        let app = try await Application.make(.testing)
        let failingTask = NamedStreamConsumerTask(groupID: "summary-projection-consumer", task: Task {
            throw Abort(.internalServerError, reason: "consumer failed")
        })

        do {
            try await superviseStreamConsumerTasks([failingTask], app: app) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            Issue.record("Expected stream consumer supervision to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("consumer failed"))
        } catch {
            Issue.record("Unexpected stream consumer supervision error: \(error)")
        }
        try await app.asyncShutdown()
    }

    @Test("Stream consumer supervision cancels tasks on shutdown")
    func streamConsumerSupervisionCancelsTasksOnShutdown() async throws {
        let app = try await Application.make(.testing)
        let longRunningTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        try await superviseStreamConsumerTasks(
            [NamedStreamConsumerTask(groupID: "summary-projection-consumer", task: longRunningTask)],
            app: app,
            shutdownSignal: {}
        )
        #expect(longRunningTask.isCancelled)
        try await app.asyncShutdown()
    }

    @Test("Internal metrics endpoint returns Prometheus text only when enabled")
    func internalMetricsEndpointHonorsConfiguration() async throws {
        try await withApp(configure: configure) { app in
            app.metricsConfiguration = IMMetricsConfiguration(isEnabled: true, internalSecret: "metrics-secret")
            try await app.testing().test(.GET, "internal/metrics", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "internal/metrics", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-IM-Metrics-Secret", value: "metrics-secret")
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.type == "text")
                #expect(res.body.string.contains("im_tcp_connections"))
                #expect(res.body.string.contains("im_outbox_backlog_events"))
            })

            app.metricsConfiguration = IMMetricsConfiguration(isEnabled: false, internalSecret: nil)
            try await app.testing().test(.GET, "internal/metrics", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Production metrics require an internal secret")
    func productionMetricsRequireInternalSecret() throws {
        let originalValues = [
            "IM_METRICS_ENABLED": Environment.get("IM_METRICS_ENABLED"),
            "IM_METRICS_INTERNAL_SECRET": Environment.get("IM_METRICS_INTERNAL_SECRET"),
            "IM_INTERNAL_SHARED_SECRET": Environment.get("IM_INTERNAL_SHARED_SECRET")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        setenv("IM_METRICS_ENABLED", "true", 1)
        unsetenv("IM_METRICS_INTERNAL_SECRET")
        unsetenv("IM_INTERNAL_SHARED_SECRET")

        let configuration = IMMetricsConfiguration.load(from: .production)
        do {
            try configuration.validateStartup(environment: .production)
            Issue.record("Expected production metrics without secret to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("IM_METRICS_INTERNAL_SECRET"))
        } catch {
            Issue.record("Unexpected metrics configuration error: \(error)")
        }
    }

    @Test("Production requires explicit primary database configuration")
    func productionRequiresExplicitPrimaryDatabaseConfiguration() throws {
        let keys = [
            "DATABASE_HOST",
            "DATABASE_NAME",
            "DATABASE_USERNAME",
            "DATABASE_PASSWORD",
            "DATABASE_PRIMARY_HOST",
            "DATABASE_PRIMARY_NAME",
            "DATABASE_PRIMARY_USERNAME",
            "DATABASE_PRIMARY_PASSWORD"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for key in keys {
            unsetenv(key)
        }

        do {
            try IMProductionRuntimeValidationSupport.validatePrimaryDatabaseConfiguration()
            Issue.record("Expected missing production database configuration to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("primary database"))
        } catch {
            Issue.record("Unexpected database configuration error: \(error)")
        }

        setenv("DATABASE_PRIMARY_HOST", "db.internal", 1)
        setenv("DATABASE_PRIMARY_NAME", "imserver", 1)
        setenv("DATABASE_PRIMARY_USERNAME", "imserver", 1)
        setenv("DATABASE_PRIMARY_PASSWORD", "secret", 1)
        try IMProductionRuntimeValidationSupport.validatePrimaryDatabaseConfiguration()
    }

    @Test("Projection worker role does not register API routes")
    func projectionWorkerRoleDoesNotRegisterAPIRoutes() async throws {
        try await withApp(configure: { app in
            app.imRuntimeRole = .projectionWorker
            try await configure(app)
        }) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Ops role does not register API routes")
    func opsRoleDoesNotRegisterAPIRoutes() async throws {
        try await withApp(configure: { app in
            app.imRuntimeRole = .ops
            try await configure(app)
        }) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Outbox relay role does not register API routes")
    func outboxRelayRoleDoesNotRegisterAPIRoutes() async throws {
        try await withApp(configure: { app in
            app.imRuntimeRole = .outboxRelay
            try await configure(app)
        }) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Stream consumer role does not register API routes")
    func streamConsumerRoleDoesNotRegisterAPIRoutes() async throws {
        try await withApp(configure: { app in
            app.imRuntimeRole = .streamConsumer
            try await configure(app)
        }) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Gateway role registers auth routes but not IM HTTP routes")
    func gatewayRoleRegistersAuthRoutesButNotIMRoutes() async throws {
        try await withApp(configure: { app in
            app.imRuntimeRole = .gateway
            try await configure(app)
        }) { app in
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "api/im/conversations", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Gateway command bridge registers every command route when enabled")
    func gatewayCommandBridgeRegistersEveryCommandRouteWhenEnabled() async throws {
        let originalBaseURL = Environment.get("IM_COMMAND_API_INTERNAL_BASE_URL")
        defer { restoreEnvironment("IM_COMMAND_API_INTERNAL_BASE_URL", to: originalBaseURL) }
        setenv("IM_COMMAND_API_INTERNAL_BASE_URL", "http://command.internal", 1)

        try await withApp(configure: { app in
            app.imRuntimeRole = .gateway
            try await configure(app)
        }) { app in
            for route in IMConversationCommandRoute.allCases {
                let path = "api/im/" + route.path.map { component in
                    let raw = component.description
                    if raw.hasPrefix(":") {
                        switch raw {
                        case ":conversationID", ":memberUserID", ":messageID":
                            return UUID().uuidString
                        case ":token":
                            return "invite-token"
                        default:
                            return "value"
                        }
                    }
                    return raw
                }.joined(separator: "/")

                try await app.testing().test(route.method, path, afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                })
            }

            try await app.testing().test(.GET, "api/im/conversations", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Command API role registers IM mutate routes but not IM query or auth routes")
    func commandAPIRoleSeparatesRoutes() async throws {
        try await withApp(configure: { app in
            app.imRuntimeRole = .commandAPI
            try await configure(app)
        }) { app in
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.GET, "api/im/conversations", afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.POST, "api/im/conversations", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            #expect(app.hasConnectionRoutingServiceConfigured == false)
        }
    }

    @Test("Query API role registers IM query routes but not IM mutate or auth routes")
    func queryAPIRoleSeparatesRoutes() async throws {
        try await withApp(configure: { app in
            app.imRuntimeRole = .queryAPI
            try await configure(app)
        }) { app in
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.GET, "api/im/conversations", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.POST, "api/im/conversations", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }


}

private func withProductionRuntimeEnvironment(_ body: () async throws -> Void) async throws {
    let values = [
        "IM_NODE_ID": "node-a",
        "IM_COMMAND_API_INTERNAL_BASE_URL": "http://command.internal",
        "IM_GATEWAY_RELAY_MODE": "http",
        "IM_GATEWAY_INTERNAL_BASE_URL": "http://gateway.internal",
        "IM_INTERNAL_SHARED_SECRET": "test-internal-secret",
        "IM_TCP_REQUIRES_TLS_TERMINATION": "true",
        "IM_EVENT_STREAM_DRIVER": "kafka",
        "IM_KAFKA_BROKERS": "kafka-a:9092",
        "IM_KAFKA_SECURITY_PROTOCOL": "plaintext",
        "IM_SUMMARY_PROJECTION_WRITE_MODE": "sharded",
        "IM_SUMMARY_QUERY_READ_SOURCE": "sharded",
        "IM_SEARCH_DRIVER": "opensearch",
        "IM_OPENSEARCH_ENDPOINT": "https://opensearch.internal",
        "IM_STREAM_CONSUMER_GROUPS": "summary-projection-consumer",
        "IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT": "100",
        "IM_SEQUENCE_ALLOCATION_MODE": "block",
        "IM_SEQUENCE_BLOCK_SIZE": "256",
        "IM_MESSAGE_WRITE_BATCH_ENABLED": "true",
        "IM_MESSAGE_WRITE_BATCH_MAX_SIZE": "32",
        "IM_MESSAGE_WRITE_BATCH_MAX_DELAY_MS": "10",
        "IM_COMMAND_NODE_ID": "command-a",
        "IM_COMMAND_NODE_URLS": "command-a=http://command-a.internal,command-b=http://command-b.internal",
        "MEDIA_STORAGE_PROVIDER": "s3compatible",
        "MEDIA_STORAGE_S3_ENDPOINT": "https://s3.internal",
        "MEDIA_STORAGE_S3_BUCKET": "im-media",
        "MEDIA_STORAGE_S3_ACCESS_KEY_ID": "access-key",
        "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY": "secret-key",
        "DATABASE_PRIMARY_HOST": "primary-db",
        "DATABASE_PRIMARY_NAME": "imserver",
        "DATABASE_PRIMARY_USERNAME": "imserver",
        "DATABASE_PRIMARY_PASSWORD": "database-secret",
        "IM_SUMMARY_SHARD_IDS": "summary-0",
        "DATABASE_SUMMARY_SUMMARY_0_HOST": "summary-db",
        "DATABASE_SUMMARY_SUMMARY_0_NAME": "imserver_summary",
        "DATABASE_SUMMARY_SUMMARY_0_USERNAME": "imserver",
        "DATABASE_SUMMARY_SUMMARY_0_PASSWORD": "database-secret"
    ]
    let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
    defer {
        for (key, value) in originalValues {
            restoreProductionRuntimeEnvironment(key, to: value)
        }
    }

    for (key, value) in values {
        setenv(key, value, 1)
    }

    try await body()
}

private func restoreProductionRuntimeEnvironment(_ key: String, to value: String?) {
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
}

private func productionRuntimeValidationApp(role: IMRuntimeRole) async throws -> Application {
    let app = try await Application.make(.production)
    app.imRuntimeRole = role
    app.gatewayRelayConfiguration = IMGatewayRelayConfiguration.load(from: .production)
    app.commandAPIIngressConfiguration = IMCommandAPIIngressConfiguration.load(from: .production)
    app.eventStreamConfiguration = IMEventStreamConfiguration.load(from: .production)
    app.searchIndexConfiguration = IMSearchIndexConfiguration.load(from: .production)
    app.shardTopologyConfiguration = IMShardTopologyConfiguration.load(from: .production)
    app.summaryStoreConfiguration = IMSummaryStoreConfiguration.load(from: .production)
    app.summaryReadModelConfiguration = IMSummaryReadModelConfiguration.load(from: .production)
    app.streamConsumerConfiguration = IMStreamConsumerConfiguration.load(from: .production)
    app.hotConversationConfiguration = IMHotConversationConfiguration.load(from: .production)
    app.sequenceAllocationConfiguration = IMSequenceAllocationConfiguration.load(from: .production)
    app.messageWriteBatchConfiguration = IMMessageWriteBatchConfiguration.load(from: .production)
    app.commandOwnerRoutingConfiguration = IMCommandOwnerRoutingConfiguration.load(from: .production)
    app.imTCPConfiguration = IMTCPConfiguration.load(from: .production)
    IMDatabaseConfigurator.configureDatabases(app)
    return app
}
