@testable import IMServer
import Fluent
import FluentSQLiteDriver
import NIOCore
import SQLKit
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    @Test("Database Cell ingress registry resolves role endpoints and fails closed for disabled Cells")
    func databaseCellIngressRegistryResolvesRoleEndpoints() async throws {
        try await withApp(configure: configure) { app in
            app.cellIngressRegistryConfiguration = IMCellIngressRegistryConfiguration(
                mode: .database,
                cacheTTLSeconds: 60
            )
            let registry = IMCellIngressRegistryService(app: app)
            _ = try await registry.upsert(
                cellID: "cell-registry-b",
                status: .active,
                commandEndpoint: "https://command.cell-registry-b.internal",
                queryEndpoint: "https://query.cell-registry-b.internal",
                realtimeEndpoint: "https://gateway.cell-registry-b.internal"
            )

            #expect(
                try await app.cellIngressEndpointResolver.endpoint(for: "cell-registry-b", purpose: .command)
                    == "https://command.cell-registry-b.internal"
            )
            #expect(
                try await app.cellIngressEndpointResolver.endpoint(for: "cell-registry-b", purpose: .query)
                    == "https://query.cell-registry-b.internal"
            )
            #expect(
                try await app.cellIngressEndpointResolver.endpoint(for: "cell-registry-b", purpose: .realtime)
                    == "https://gateway.cell-registry-b.internal"
            )

            _ = try await registry.upsert(
                cellID: "cell-registry-b",
                status: .disabled,
                commandEndpoint: "https://command.cell-registry-b.internal",
                queryEndpoint: "https://query.cell-registry-b.internal",
                realtimeEndpoint: "https://gateway.cell-registry-b.internal"
            )
            #expect(
                try await app.cellIngressEndpointResolver.endpoint(for: "cell-registry-b", purpose: .command) == nil
            )
        }
    }

    @Test("Cell ingress configuration routes command query and realtime traffic independently with a legacy fallback")
    func cellIngressConfigurationSelectsPurposeEndpoints() {
        let configuration = IMCellIngressConfiguration(
            endpointsByCellID: ["legacy-cell": "https://legacy.internal"],
            commandEndpointsByCellID: ["cell-b": "https://command.cell-b.internal"],
            queryEndpointsByCellID: ["cell-b": "https://query.cell-b.internal"],
            realtimeEndpointsByCellID: ["cell-b": "https://gateway.cell-b.internal"],
            sharedSecret: "cell-ingress-test-secret"
        )

        #expect(configuration.endpoint(for: "cell-b", purpose: .command) == "https://command.cell-b.internal")
        #expect(configuration.endpoint(for: "cell-b", purpose: .query) == "https://query.cell-b.internal")
        #expect(configuration.endpoint(for: "cell-b", purpose: .realtime) == "https://gateway.cell-b.internal")
        #expect(configuration.endpoint(for: "legacy-cell", purpose: .command) == "https://legacy.internal")
        #expect(configuration.endpoint(for: "legacy-cell", purpose: .query) == "https://legacy.internal")
        #expect(configuration.endpoint(for: "legacy-cell", purpose: .realtime) == "https://legacy.internal")
        #expect(configuration.configuredEndpoints.count == 4)
    }

    @Test("Cell ingress configuration retains malformed endpoint entries for production validation")
    func cellIngressConfigurationRecordsMalformedEndpointEntries() {
        let key = IMCellIngressEndpointSource.command.rawValue
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "cell-b=https://command.cell-b.internal,not-an-endpoint", 1)

        let configuration = IMCellIngressConfiguration.load(from: .testing)

        #expect(configuration.endpoint(for: "cell-b", purpose: .command) == "https://command.cell-b.internal")
        #expect(configuration.invalidEndpointEntries == [
            IMInvalidCellIngressEndpointEntry(source: .command, position: 2)
        ])
    }

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

    @Test("Production requires rotated JWT secrets")
    func productionRequiresJWTSecrets() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        let originalJWTSecrets = Environment.get("JWT_SECRETS")
        let originalActiveKeyID = Environment.get("JWT_ACTIVE_KID")
        defer {
            restoreEnvironment("JWT_SECRET", to: originalJWTSecret)
            restoreEnvironment("JWT_SECRETS", to: originalJWTSecrets)
            restoreEnvironment("JWT_ACTIVE_KID", to: originalActiveKeyID)
        }

        unsetenv("JWT_SECRET")
        unsetenv("JWT_SECRETS")
        unsetenv("JWT_ACTIVE_KID")

        do {
            _ = try AuthConfiguration.load(from: .production)
            Issue.record("Expected production auth configuration to fail without JWT_SECRETS")
        } catch AuthConfigurationError.missingJWTSecret {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Development JWT fallback is generated per process")
    func developmentJWTFallbackIsGeneratedPerProcess() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        let originalJWTSecrets = Environment.get("JWT_SECRETS")
        let originalActiveKeyID = Environment.get("JWT_ACTIVE_KID")
        defer {
            restoreEnvironment("JWT_SECRET", to: originalJWTSecret)
            restoreEnvironment("JWT_SECRETS", to: originalJWTSecrets)
            restoreEnvironment("JWT_ACTIVE_KID", to: originalActiveKeyID)
        }

        unsetenv("JWT_SECRET")
        unsetenv("JWT_SECRETS")
        unsetenv("JWT_ACTIVE_KID")

        let first = try AuthConfiguration.load(from: .development)
        let second = try AuthConfiguration.load(from: .development)

        #expect(first.jwtSecret == second.jwtSecret)
        #expect(first.jwtSecret.count >= 32)
        #expect(first.jwtSecret != "dev-jwt-secret-change-me")
        #expect(first.jwtSecrets.count == 1)
        #expect(first.activeJWTKeyID == nil)
    }

    @Test("Production rejects legacy single JWT secret")
    func productionRejectsLegacySingleJWTSecret() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        let originalJWTSecrets = Environment.get("JWT_SECRETS")
        let originalActiveKeyID = Environment.get("JWT_ACTIVE_KID")
        defer {
            restoreEnvironment("JWT_SECRET", to: originalJWTSecret)
            restoreEnvironment("JWT_SECRETS", to: originalJWTSecrets)
            restoreEnvironment("JWT_ACTIVE_KID", to: originalActiveKeyID)
        }

        setenv("JWT_SECRET", "0123456789abcdef0123456789abcdef", 1)
        unsetenv("JWT_SECRETS")
        unsetenv("JWT_ACTIVE_KID")

        do {
            _ = try AuthConfiguration.load(from: .production)
            Issue.record("Expected production auth configuration to reject JWT_SECRET")
        } catch AuthConfigurationError.legacyJWTSecretInProduction {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Production requires active JWT key id")
    func productionRequiresActiveJWTKeyID() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        let originalJWTSecrets = Environment.get("JWT_SECRETS")
        let originalActiveKeyID = Environment.get("JWT_ACTIVE_KID")
        defer {
            restoreEnvironment("JWT_SECRET", to: originalJWTSecret)
            restoreEnvironment("JWT_SECRETS", to: originalJWTSecrets)
            restoreEnvironment("JWT_ACTIVE_KID", to: originalActiveKeyID)
        }

        unsetenv("JWT_SECRET")
        setenv("JWT_SECRETS", "active:0123456789abcdef0123456789abcdef", 1)
        unsetenv("JWT_ACTIVE_KID")

        do {
            _ = try AuthConfiguration.load(from: .production)
            Issue.record("Expected production auth configuration to require JWT_ACTIVE_KID")
        } catch AuthConfigurationError.missingActiveJWTKeyID {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Production rejects weak JWT signing secrets during auth configuration load")
    func productionRejectsWeakJWTSigningSecretsDuringAuthConfigurationLoad() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        let originalJWTSecrets = Environment.get("JWT_SECRETS")
        let originalActiveKeyID = Environment.get("JWT_ACTIVE_KID")
        defer {
            restoreEnvironment("JWT_SECRET", to: originalJWTSecret)
            restoreEnvironment("JWT_SECRETS", to: originalJWTSecrets)
            restoreEnvironment("JWT_ACTIVE_KID", to: originalActiveKeyID)
        }

        unsetenv("JWT_SECRET")
        setenv("JWT_SECRETS", "active:short", 1)
        setenv("JWT_ACTIVE_KID", "active", 1)

        do {
            _ = try AuthConfiguration.load(from: .production)
            Issue.record("Expected production auth configuration to reject short JWT_SECRETS")
        } catch AuthConfigurationError.weakJWTSecret("active") {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Production rejects placeholder JWT signing secrets during auth configuration load")
    func productionRejectsPlaceholderJWTSigningSecretsDuringAuthConfigurationLoad() throws {
        let originalJWTSecret = Environment.get("JWT_SECRET")
        let originalJWTSecrets = Environment.get("JWT_SECRETS")
        let originalActiveKeyID = Environment.get("JWT_ACTIVE_KID")
        defer {
            restoreEnvironment("JWT_SECRET", to: originalJWTSecret)
            restoreEnvironment("JWT_SECRETS", to: originalJWTSecrets)
            restoreEnvironment("JWT_ACTIVE_KID", to: originalActiveKeyID)
        }

        unsetenv("JWT_SECRET")
        setenv("JWT_SECRETS", "active:password1234password1234password1234", 1)
        setenv("JWT_ACTIVE_KID", "active", 1)

        do {
            _ = try AuthConfiguration.load(from: .production)
            Issue.record("Expected production auth configuration to reject placeholder JWT_SECRETS")
        } catch AuthConfigurationError.placeholderJWTSecret("active") {
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

    @Test("Routing rejects an unsupported Redis Cluster topology before startup")
    func routingRejectsUnsupportedRedisClusterTopology() async throws {
        let app = try await Application.make(.testing)
        app.imRedisRoutingConfigurationOverride = IMRedisRoutingConfiguration(
            url: "redis://redis.internal:6379",
            mode: .redis,
            deploymentTopology: .cluster,
            maximumConnectionCount: 2
        )

        do {
            try await app.configureConnectionRoutingServiceIfNeeded()
            Issue.record("Expected Redis Cluster topology to be rejected before backend startup")
        } catch RedisRoutingError.redisClusterTopologyUnsupported {
        } catch {
            Issue.record("Unexpected routing error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Cluster topology identifies every remaining RediStack consumer before startup")
    func redisClusterTopologyReportsRemainingStandaloneConsumers() async throws {
        let app = try await Application.make(.testing)
        app.imRuntimeRole = .gateway
        let routingConfiguration = IMRedisRoutingConfiguration(
            url: "redis://redis.internal:6379",
            mode: .redis,
            deploymentTopology: .cluster,
            maximumConnectionCount: 2
        )
        let authSessionCacheConfiguration = AuthSessionCacheConfiguration.load(from: .testing)
        let authSecurityConfiguration = try AuthSecurityConfiguration.load(from: .testing)
        let consumers = IMRedisTopologyCompatibility.configuredStandaloneConsumers(
            app: app,
            routingConfiguration: routingConfiguration,
            authSessionCacheConfiguration: authSessionCacheConfiguration,
            authSecurityConfiguration: authSecurityConfiguration
        )

        #expect(consumers == [.nodeRealtimeDispatch])

        do {
            try IMRedisTopologyCompatibility.validate(
                topology: .cluster,
                standaloneConsumers: consumers
            )
            Issue.record("Expected Cluster topology to be rejected before any RediStack consumer starts")
        } catch RedisRoutingError.redisClusterTopologyUnsupportedByComponents(let componentNames) {
            #expect(componentNames == ["node-realtime-dispatch"])
        } catch {
            Issue.record("Unexpected Redis topology error: \(error)")
        }

        try? await app.asyncShutdown()
    }

    @Test("Cluster topology does not reject deployments with no legacy Redis consumer")
    func redisClusterTopologyPermitsNoLegacyRedisConsumers() throws {
        try IMRedisTopologyCompatibility.validate(
            topology: .cluster,
            standaloneConsumers: []
        )
    }

    @Test("Cluster topology permits Cluster-native state with Valkey Stream node dispatch")
    func redisClusterTopologyPermitsValkeyStreamNodeDispatch() async throws {
        let app = try await Application.make(.testing)
        app.imRuntimeRole = .gateway
        app.nodeDispatchConfiguration = IMNodeDispatchConfiguration(
            mode: .valkeyStream,
            endpointsByNodeID: [:],
            sharedSecret: nil
        )
        let routingConfiguration = IMRedisRoutingConfiguration(
            url: "redis://redis.internal:6379",
            mode: .redis,
            deploymentTopology: .cluster,
            maximumConnectionCount: 2,
            clusterSeedEndpoints: [
                IMRedisClusterSeedEndpoint(environmentValue: "redis-1.internal:6379")!
            ]
        )
        let consumers = IMRedisTopologyCompatibility.configuredStandaloneConsumers(
            app: app,
            routingConfiguration: routingConfiguration,
            authSessionCacheConfiguration: AuthSessionCacheConfiguration.load(from: .testing),
            authSecurityConfiguration: try AuthSecurityConfiguration.load(from: .testing)
        )

        #expect(consumers.isEmpty)
        try IMRedisTopologyCompatibility.validate(
            topology: .cluster,
            standaloneConsumers: consumers
        )
        try? await app.asyncShutdown()
    }

    @Test("Redis Cluster routing requires explicit seed endpoints")
    func redisClusterRoutingRequiresExplicitSeedEndpoints() throws {
        let configuration = IMRedisRoutingConfiguration(
            url: "redis://cache.internal:6379",
            mode: .redis,
            deploymentTopology: .cluster,
            maximumConnectionCount: 4
        )

        do {
            _ = try configuration.requireClusterSeedEndpoints()
            Issue.record("Expected missing Cluster seed endpoints to be rejected")
        } catch RedisRoutingError.invalidRedisClusterSeed {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Redis Cluster seed endpoint accepts host and port")
    func redisClusterSeedEndpointParsesHostAndPort() {
        let seed = IMRedisClusterSeedEndpoint(environmentValue: "cache-1.internal:6380")

        #expect(seed == IMRedisClusterSeedEndpoint(environmentValue: "redis://cache-1.internal:6380"))
        #expect(seed?.host == "cache-1.internal")
        #expect(seed?.port == 6380)
        #expect(IMRedisClusterSeedEndpoint(environmentValue: "not a valid seed") == nil)
    }

    @Test("Redis keyspace can pin a conversation-scoped key to one Cluster slot")
    func redisKeyspacePinsConversationScopedKeyToOneClusterSlot() {
        let conversationID = "7d2d597b-2ee3-4a65-9fea-4ecb5af4ef10"
        let key = IMRealtimeRedisKeyspace(cellID: "cell-a").key(
            hashedBy: conversationID,
            suffix: "hot-conversation:\(conversationID):1700000000"
        )

        #expect(key == "im:cell:cell-a:{\(conversationID)}:hot-conversation:\(conversationID):1700000000")
    }

    @Test("Auth cache uses independently routed session and revision keys")
    func authCacheUsesClusterSafeSessionAndRevisionKeys() {
        let sessionID = UUID(uuidString: "7d2d597b-2ee3-4a65-9fea-4ecb5af4ef10")!
        let userID = UUID(uuidString: "bce61bc9-0f1f-47cf-9b79-053875b1d46b")!

        #expect(AuthSessionRedisKeyspace.sessionKey(sessionID: sessionID).rawValue == "im:auth:session:{7d2d597b-2ee3-4a65-9fea-4ecb5af4ef10}")
        #expect(AuthSessionRedisKeyspace.userRevisionKey(userID: userID).rawValue == "im:auth:user:{bce61bc9-0f1f-47cf-9b79-053875b1d46b}:session-cache-revision")
        #expect(AuthSessionRedisKeyspace.globalEpochKey.rawValue == "im:auth:session-cache:{global}:epoch")
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

    @Test("Production gateway rejects implicit best-effort Redis node dispatch")
    func productionGatewayRejectsImplicitBestEffortRedisNodeDispatch() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_ALLOW_BEST_EFFORT_NODE_DISPATCH"
            let originalValue = Environment.get(key)
            defer { restoreProductionRuntimeEnvironment(key, to: originalValue) }
            unsetenv(key)

            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production gateway to reject implicit Redis Pub/Sub node dispatch")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_ALLOW_BEST_EFFORT_NODE_DISPATCH=true"))
            } catch {
                Issue.record("Unexpected node dispatch configuration error: \(error)")
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Production runtime rejects malformed Cell ingress endpoint configuration")
    func productionRuntimeRejectsMalformedCellIngressEndpointConfiguration() async throws {
        try await withProductionRuntimeEnvironment {
            let key = IMCellIngressEndpointSource.command.rawValue
            let originalValue = Environment.get(key)
            defer { restoreProductionRuntimeEnvironment(key, to: originalValue) }
            setenv(key, "cell-b=https://command.cell-b.internal,not-an-endpoint", 1)

            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime validation to reject malformed Cell ingress endpoints")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains(key))
                #expect(abort.reason.contains("entry 2"))
            } catch {
                Issue.record("Unexpected Cell ingress configuration error: \(error)")
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Multi-shard production requires an explicit usable directory cache limit")
    func multiShardProductionRequiresDirectoryCacheLimit() async throws {
        try await withProductionRuntimeEnvironment {
            let values = [
                "IM_CONVERSATION_SHARD_IDS": "shard-a,shard-b",
                "DATABASE_CONVERSATION_SHARD_A_HOST": "conversation-a-db",
                "DATABASE_CONVERSATION_SHARD_A_NAME": "imserver_conversation_a",
                "DATABASE_CONVERSATION_SHARD_A_USERNAME": "imserver",
                "DATABASE_CONVERSATION_SHARD_A_PASSWORD": "database-0123456789abcdef",
                "DATABASE_CONVERSATION_SHARD_B_HOST": "conversation-b-db",
                "DATABASE_CONVERSATION_SHARD_B_NAME": "imserver_conversation_b",
                "DATABASE_CONVERSATION_SHARD_B_USERNAME": "imserver",
                "DATABASE_CONVERSATION_SHARD_B_PASSWORD": "database-0123456789abcdef",
                "IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES": "",
                "IM_CONVERSATION_SHARD_DIRECTORY_CACHE_TTL_SECONDS": ""
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

            let missingLimitApp = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMProductionRuntimeValidationSupport.validateConversationShardConfiguration(missingLimitApp)
                Issue.record("Expected multi-shard validation to require a directory cache limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES"))
            } catch {
                Issue.record("Unexpected conversation shard configuration error: \(error)")
            }
            try await missingLimitApp.asyncShutdown()

            setenv("IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES", "50000", 1)
            setenv("IM_CONVERSATION_SHARD_DIRECTORY_CACHE_TTL_SECONDS", "15", 1)
            let validApp = try await productionRuntimeValidationApp(role: .commandAPI)
            try IMProductionRuntimeValidationSupport.validateConversationShardConfiguration(validApp)
            try await validApp.asyncShutdown()
        }
    }

    @Test("Realtime cell namespaces Redis routing and rejects invalid production configuration")
    func realtimeCellNamespacesRedisRoutingAndRejectsInvalidProductionConfiguration() async throws {
        let cellA = IMRealtimeRedisKeyspace(cellID: "cell-a")
        let cellB = IMRealtimeRedisKeyspace(cellID: "cell-b")
        #expect(cellA.key("route:active_nodes") == "im:cell:cell-a:route:active_nodes")
        #expect(cellA.key("dispatch:node:gateway-a") == "im:cell:cell-a:dispatch:node:gateway-a")
        #expect(cellA.key("route:active_nodes") != cellB.key("route:active_nodes"))
        #expect(IMRealtimeCellConfiguration.isValid(cellID: "cell_a-01"))
        #expect(!IMRealtimeCellConfiguration.isValid(cellID: "Cell-A"))
        #expect(!IMRealtimeCellConfiguration.isValid(cellID: "cell a"))

        try await withProductionRuntimeEnvironment {
            let originalCellID = Environment.get("IM_REALTIME_CELL_ID")
            defer { restoreProductionRuntimeEnvironment("IM_REALTIME_CELL_ID", to: originalCellID) }
            unsetenv("IM_REALTIME_CELL_ID")

            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime validation to require IM_REALTIME_CELL_ID")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_CELL_ID"))
            } catch {
                Issue.record("Unexpected realtime cell configuration error: \(error)")
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Conversation directory stores cell routes and fails closed for a remote cell")
    func conversationDirectoryStoresCellRoutesAndFailsClosedForRemoteCell() async throws {
        try await withApp(configure: configure) { app in
            let conversationID = UUID()
            let directory = DatabaseConversationDirectory(db: app.db, localCellID: "cell-a")
            try await directory.registerConversation(
                conversationID: conversationID,
                shardID: "shard-b",
                cellID: "cell-b"
            )

            let route = try await directory.route(for: conversationID)
            #expect(route == ConversationRoute(cellID: "cell-b", shardID: "shard-b"))
            do {
                _ = try await directory.shardID(for: conversationID)
                Issue.record("Expected a remote conversation route to fail closed")
            } catch let abort as any AbortError {
                #expect(abort.status == .serviceUnavailable)
                #expect(abort.reason.contains("cell-b"))
            } catch {
                Issue.record("Unexpected remote conversation route error: \(error)")
            }

            do {
                _ = try await directory.route(for: UUID())
                Issue.record("Expected an unregistered conversation route to fail closed")
            } catch let abort as any AbortError {
                #expect(abort.status == .notFound)
                #expect(abort.reason.contains("not registered"))
            } catch {
                Issue.record("Unexpected missing conversation route error: \(error)")
            }
        }
    }

    @Test("Directory backed conversation shard router rejects a remote cell route")
    func directoryBackedConversationShardRouterRejectsRemoteCellRoute() async throws {
        try await withApp(configure: configure) { app in
            app.imRealtimeCellConfiguration = IMRealtimeCellConfiguration(cellID: "cell-a")
            let conversationID = UUID()
            let directory = DatabaseConversationDirectory(db: app.db, localCellID: "cell-a")
            try await directory.registerConversation(
                conversationID: conversationID,
                shardID: "shard-b",
                cellID: "cell-b"
            )
            let router = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: ["shard-a", "shard-b"],
                shardDatabaseIDs: [:],
                shardReplicaDatabaseIDs: [:],
                directory: directory
            )

            do {
                _ = try await router.commandDatabase(forConversationID: conversationID)
                Issue.record("Expected a remote conversation route to reject local database access")
            } catch let abort as any AbortError {
                #expect(abort.status == .serviceUnavailable)
                #expect(abort.reason.contains("cell-b"))
                #expect(abort.reason.contains("cell-a"))
            } catch {
                Issue.record("Unexpected remote router error: \(error)")
            }

            let metrics = await app.conversationShardRoutingMetrics.currentSnapshot()
            #expect(metrics.directoryLookupCount == 1)
            #expect(metrics.remoteCellRouteRejectedCount == 1)
            #expect(metrics.cacheEntryCount == 0)
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

    @Test("Production command API requires distributed hot conversation limiting")
    func productionCommandAPIRequiresDistributedHotConversationLimiting() async throws {
        try await withProductionRuntimeEnvironment {
            let originalMode = Environment.get("IM_HOT_CONVERSATION_LIMITER_MODE")
            defer { restoreProductionRuntimeEnvironment("IM_HOT_CONVERSATION_LIMITER_MODE", to: originalMode) }
            setenv("IM_HOT_CONVERSATION_LIMITER_MODE", "local", 1)

            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMProductionRuntimeValidationSupport.validateHotConversationProtectionConfiguration(app)
                Issue.record("Expected production validation to reject local hot conversation limiting")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_HOT_CONVERSATION_LIMITER_MODE=redis"))
            } catch {
                Issue.record("Unexpected hot conversation limiter configuration error: \(error)")
            }
            try await app.asyncShutdown()
        }
    }

    @Test("Production command API requires recipient snapshot deduplication")
    func productionCommandAPIRequiresRecipientSnapshotDeduplication() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD", "0", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require recipient snapshot deduplication")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD > 0"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires recipient snapshot deduplication to cover omitted recipients")
    func productionCommandAPIRequiresRecipientSnapshotDeduplicationToCoverOmittedRecipients() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD", "500", 1)
            setenv("IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD", "1000", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require recipient snapshot deduplication threshold coverage")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD <= IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires explicit group member limit")
    func productionCommandAPIRequiresExplicitGroupMemberLimit() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_GROUP_MEMBER_LIMIT")
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require explicit group member limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_GROUP_MEMBER_LIMIT"))
                #expect(abort.reason.contains("explicitly"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API group limit must cover recipient snapshot threshold")
    func productionCommandAPIGroupLimitMustCoverRecipientSnapshotThreshold() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_GROUP_MEMBER_LIMIT", "499", 1)
            setenv("IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD", "500", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to reject group limit below recipient inline threshold")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_GROUP_MEMBER_LIMIT >= IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires timeline read scan protection")
    func productionQueryAPIRequiresTimelineReadScanProtection() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS")
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to require timeline read scan protection")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires timeline since distributed invalidation")
    func productionQueryAPIRequiresTimelineSinceDistributedInvalidation() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE")
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to require timeline/since distributed invalidation")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires explicit timeline since shared cache limits")
    func productionQueryAPIRequiresExplicitTimelineSinceSharedCacheLimits() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS")
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to require explicit timeline/since cache limits")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS"))
                #expect(abort.reason.contains("explicit"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires enabled timeline since hot cache")
    func productionQueryAPIRequiresEnabledTimelineSinceHotCache() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS", "0", 1)
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to reject disabled timeline/since hot cache")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS >= 50"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires useful timeline since recent cache capacity")
    func productionQueryAPIRequiresUsefulTimelineSinceRecentCacheCapacity() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION", "0", 1)
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to reject disabled timeline/since recent cache")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION >= 128"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API accepts dedicated timeline since invalidation Redis URL")
    func productionQueryAPIAcceptsDedicatedTimelineSinceInvalidationRedisURL() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("REDIS_URL")
            setenv("IM_TIMELINE_SINCE_CACHE_INVALIDATION_REDIS_URL", "redis://timeline-cache.example:6379", 1)
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
            } catch {
                Issue.record("Expected query-api validation to accept dedicated timeline/since invalidation Redis URL: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires invalidation for timeline since cache")
    func productionQueryAPIRequiresInvalidationForTimelineSinceCache() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE")
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to require invalidation for timeline/since cache")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE"))
                #expect(abort.reason.contains("timeline/since"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
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

    @Test("Production command API requires separate admin secret when admin is enabled")
    func productionCommandAPIRequiresSeparateAdminSecretWhenAdminIsEnabled() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_ADMIN_API_ENABLED", "true", 1)
            unsetenv("IM_ADMIN_SHARED_SECRET")
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require admin secret when admin is enabled")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_ADMIN_SHARED_SECRET"))
            } catch {
                Issue.record("Unexpected command-api admin validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }

        try await withProductionRuntimeEnvironment {
            setenv("IM_ADMIN_API_ENABLED", "true", 1)
            setenv("IM_ADMIN_SHARED_SECRET", "fedcba9876543210fedcba9876543210", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to reject reused internal secret")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("different from IM_INTERNAL_SHARED_SECRET"))
            } catch {
                Issue.record("Unexpected command-api admin validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain delivery consumer requires gateway relay configuration")
    func productionDomainDeliveryConsumerRequiresGatewayRelayConfiguration() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "domain-delivery-consumer", 1)
            unsetenv("IM_GATEWAY_INTERNAL_BASE_URL")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain-delivery-consumer validation to require gateway relay base URL")
            } catch GatewayRelayConfigurationError.httpModeRequiresBaseURL {
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires gateway relay configuration")
    func productionRealtimeDeliveryConsumerRequiresGatewayRelayConfiguration() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            unsetenv("IM_GATEWAY_INTERNAL_BASE_URL")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require gateway relay base URL")
            } catch GatewayRelayConfigurationError.httpModeRequiresBaseURL {
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway requires realtime backpressure recovery")
    func productionGatewayRequiresRealtimeBackpressureRecovery() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE", "false", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to require realtime backpressure recovery")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway requires active conversation fanout")
    func productionGatewayRequiresActiveConversationFanout() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED", "false", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to require active conversation fanout")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED=true"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway bounds local fanout event loop yield chunks")
    func productionGatewayBoundsLocalFanoutEventLoopYieldChunks() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv(key, "1000", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to reject oversized local fanout EventLoop yield chunks")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS <= 256"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway bounds local fanout batch size")
    func productionGatewayBoundsLocalFanoutBatchSize() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv(key, "5000", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to reject oversized local fanout batch size")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE <= 1024"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway requires sane relay body limits")
    func productionGatewayRequiresSaneRelayBodyLimits() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES", "1024", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to reject undersized relay body limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES >= 65536"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production summary projection consumer requires activity-only large-group projection")
    func productionSummaryProjectionConsumerRequiresActivityOnlyLargeGroupProjection() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            unsetenv("IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected summary-projection-consumer validation to require activity-only large-group projection")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production summary projection consumer requires activity coalescing window")
    func productionSummaryProjectionConsumerRequiresActivityCoalescingWindow() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            unsetenv("IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected summary-projection-consumer validation to require activity coalescing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS >= 50"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production summary projection consumer bounds activity coalescing window")
    func productionSummaryProjectionConsumerBoundsActivityCoalescingWindow() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            setenv("IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS", "5000", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected summary-projection-consumer validation to bound activity coalescing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS <= 1000"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer requires messageCreated recipient snapshots")
    func productionStreamConsumerRequiresMessageCreatedRecipientSnapshots() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            setenv(key, "false", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require messageCreated recipient snapshots")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT=true"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer requires explicit group member limit")
    func productionStreamConsumerRequiresExplicitGroupMemberLimit() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_GROUP_MEMBER_LIMIT")
            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require explicit group member limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_GROUP_MEMBER_LIMIT"))
                #expect(abort.reason.contains("command-api"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer thresholds must not exceed group member limit")
    func productionStreamConsumerThresholdsMustNotExceedGroupMemberLimit() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            setenv("IM_GROUP_MEMBER_LIMIT", "1000", 1)
            setenv("IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD", "1001", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to reject large-group threshold above member limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD <= IM_GROUP_MEMBER_LIMIT"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime fanout threshold must not exceed group member limit")
    func productionRealtimeFanoutThresholdMustNotExceedGroupMemberLimit() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv("IM_GROUP_MEMBER_LIMIT", "1000", 1)
            setenv("IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD", "1001", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to reject fanout threshold above member limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD <= IM_GROUP_MEMBER_LIMIT"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain delivery consumer requires large-group owner delivery skip")
    func productionDomainDeliveryConsumerRequiresLargeGroupOwnerDeliverySkip() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "domain-delivery-consumer", 1)
            unsetenv("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain-delivery-consumer validation to require large-group owner delivery skip")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain delivery consumer requires timeline-pull mode for large-group skip threshold")
    func productionDomainDeliveryConsumerRequiresTimelinePullModeForLargeGroupSkipThreshold() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "domain-delivery-consumer", 1)
            setenv("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE", "owner-delivery", 1)
            setenv("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD", "500", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain-delivery-consumer validation to require timeline-pull mode")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE=timeline-pull"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain delivery owner record batch max requests is bounded")
    func productionDomainDeliveryOwnerRecordBatchMaxRequestsIsBounded() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let batchMaxKey = "IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalBatchMaxValue = Environment.get(batchMaxKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(batchMaxKey, to: originalBatchMaxValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(batchMaxKey, "10000", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain-delivery-consumer validation to reject oversized owner record batch max requests")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS <="))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain delivery owner record batch max requests has minimum")
    func productionDomainDeliveryOwnerRecordBatchMaxRequestsHasMinimum() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let batchMaxKey = "IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalBatchMaxValue = Environment.get(batchMaxKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(batchMaxKey, to: originalBatchMaxValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(batchMaxKey, "1", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain-delivery-consumer validation to reject undersized owner record batch max requests")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS >="))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires lightweight large-group payloads")
    func productionRealtimeDeliveryConsumerRequiresLightweightLargeGroupPayloads() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            unsetenv("IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require lightweight large-group payloads")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires summary member IDs response limit")
    func productionRealtimeDeliveryConsumerRequiresSummaryMemberIDsResponseLimit() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            unsetenv("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require summary member IDs response limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer disables messageCreated preview lookup")
    func productionRealtimeDeliveryConsumerDisablesMessageCreatedPreviewLookup() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv("IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED", "true", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to disable messageCreated preview lookup")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires async relay")
    func productionRealtimeDeliveryConsumerRequiresAsyncRelay() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            unsetenv("IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require async relay")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=true"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires async relay concurrency")
    func productionRealtimeDeliveryConsumerRequiresAsyncRelayConcurrency() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv(key, "1", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require async relay concurrency")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT > 1"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires async relay queue")
    func productionRealtimeDeliveryConsumerRequiresAsyncRelayQueue() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv(key, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require async relay queue")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires messageCreated coalescing window")
    func productionRealtimeDeliveryConsumerRequiresMessageCreatedCoalescingWindow() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv(key, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require messageCreated coalescing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer caps active compact hint coalescing")
    func productionRealtimeDeliveryConsumerCapsActiveCompactHintCoalescing() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv(key, "1000", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to cap active compact hint coalescing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS <= 100"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires active compact hint coalescing")
    func productionRealtimeDeliveryConsumerRequiresActiveCompactHintCoalescing() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv(key, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require active compact hint coalescing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer bounds active compact hint preview")
    func productionRealtimeDeliveryConsumerBoundsActiveCompactHintPreview() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            setenv(key, "1000", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to bound active compact hint preview")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS <= 120"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group realtime path requires active conversation route cache")
    func productionLargeGroupRealtimePathRequiresActiveConversationRouteCache() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS"
            let originalValue = Environment.get(key)
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let originalRelayAfterRecord = Environment.get(relayAfterRecordKey)
            defer {
                restoreEnvironment(key, to: originalValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecord)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(key, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected large-group realtime validation to require active conversation route cache")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group realtime path requires bounded active conversation route cache")
    func productionLargeGroupRealtimePathRequiresBoundedActiveConversationRouteCache() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES"
            let originalValue = Environment.get(key)
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let originalRelayAfterRecord = Environment.get(relayAfterRecordKey)
            defer {
                restoreEnvironment(key, to: originalValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecord)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(key, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected large-group realtime validation to require bounded active conversation route cache")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production realtime delivery consumer requires Redis routing")
    func productionRealtimeDeliveryConsumerRequiresRedisRouting() async throws {
        try await withProductionRuntimeEnvironment {
            let redisURLKey = "REDIS_URL"
            let routingModeKey = "IM_ROUTING_MODE"
            let originalRedisURL = Environment.get(redisURLKey)
            let originalRoutingMode = Environment.get(routingModeKey)
            defer {
                restoreEnvironment(redisURLKey, to: originalRedisURL)
                restoreEnvironment(routingModeKey, to: originalRoutingMode)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "realtime-delivery-consumer", 1)
            unsetenv(redisURLKey)
            setenv(routingModeKey, "local", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected realtime-delivery-consumer validation to require Redis routing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("REDIS_URL"))
                #expect(abort.reason.contains("active conversation presence"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer requires batched processing")
    func productionStreamConsumerRequiresBatchedProcessing() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_STREAM_CONSUMER_RUN_BATCH_SIZE"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            setenv(key, "1", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require batched processing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_STREAM_CONSUMER_RUN_BATCH_SIZE > 1"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer queue capacity must cover run batch size")
    func productionStreamConsumerQueueCapacityMustCoverRunBatchSize() async throws {
        try await withProductionRuntimeEnvironment {
            let queueKey = "IM_STREAM_CONSUMER_QUEUE_CAPACITY"
            let batchKey = "IM_STREAM_CONSUMER_RUN_BATCH_SIZE"
            let originalQueueValue = Environment.get(queueKey)
            let originalBatchValue = Environment.get(batchKey)
            defer {
                restoreEnvironment(queueKey, to: originalQueueValue)
                restoreEnvironment(batchKey, to: originalBatchValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            setenv(queueKey, "8", 1)
            setenv(batchKey, "32", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require queue capacity covering run batch size")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_STREAM_CONSUMER_QUEUE_CAPACITY >= IM_STREAM_CONSUMER_RUN_BATCH_SIZE"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer requires batch fill wait")
    func productionStreamConsumerRequiresBatchFillWait() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            setenv(key, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require batch fill wait")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer bounds batch fill wait")
    func productionStreamConsumerBoundsBatchFillWait() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
            setenv(key, "101", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to bound batch fill wait")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS <= 100"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway requires non-empty active compact hint preview")
    func productionGatewayRequiresNonEmptyActiveCompactHintPreview() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS"
            let originalValue = Environment.get(key)
            defer { restoreEnvironment(key, to: originalValue) }
            setenv(key, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to require non-empty active compact hint preview")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS > 0"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway requires concurrent remote realtime dispatch")
    func productionGatewayRequiresConcurrentRemoteRealtimeDispatch() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv(key, "1", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to require concurrent remote realtime dispatch")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT > 1"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway bounds remote realtime dispatch concurrency")
    func productionGatewayBoundsRemoteRealtimeDispatchConcurrency() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv(key, "128", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to reject oversized remote realtime dispatch concurrency")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT <= 64"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production gateway bounds remote realtime dispatch user batch size")
    func productionGatewayBoundsRemoteRealtimeDispatchUserBatchSize() async throws {
        try await withProductionRuntimeEnvironment {
            let key = "IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE"
            let originalValue = Environment.get(key)
            defer {
                restoreEnvironment(key, to: originalValue)
            }

            setenv(key, "5000", 1)
            let app = try await productionRuntimeValidationApp(role: .gateway)
            do {
                try IMGatewayProductionValidator.validate(app: app)
                Issue.record("Expected gateway validation to reject oversized remote realtime dispatch user batch size")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE <= 2048"))
            } catch {
                Issue.record("Unexpected gateway validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group owner delivery skip requires realtime delivery path")
    func productionLargeGroupOwnerDeliverySkipRequiresRealtimeDeliveryPath() async throws {
        try await withProductionRuntimeEnvironment {
            let skipThresholdKey = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let originalSkipThresholdValue = Environment.get(skipThresholdKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            defer {
                restoreEnvironment(skipThresholdKey, to: originalSkipThresholdValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
            }
            setenv("IM_STREAM_CONSUMER_GROUPS", "domain-delivery-consumer", 1)
            setenv(skipThresholdKey, "500", 1)
            setenv(relayAfterRecordKey, "false", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require realtime delivery path")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("realtime-delivery-consumer"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production notification consumer requires large-group owner notification skip")
    func productionNotificationConsumerRequiresLargeGroupOwnerNotificationSkip() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let thresholdKey = "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD"
            let fullSkipKey = "IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalThresholdValue = Environment.get(thresholdKey)
            let originalFullSkipValue = Environment.get(fullSkipKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(thresholdKey, to: originalThresholdValue)
                restoreEnvironment(fullSkipKey, to: originalFullSkipValue)
            }

            setenv(groupsKey, "notification-consumer", 1)
            unsetenv(thresholdKey)
            setenv(fullSkipKey, "false", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected notification-consumer validation to require large-group notification skip")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer rejects duplicate realtime relay paths")
    func productionStreamConsumerRejectsDuplicateRealtimeRelayPaths() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let allowMultiGroupKey = "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalAllowMultiGroupValue = Environment.get(allowMultiGroupKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(allowMultiGroupKey, to: originalAllowMultiGroupValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
            }

            setenv(groupsKey, "domain-delivery-consumer,realtime-delivery-consumer", 1)
            setenv(allowMultiGroupKey, "true", 1)
            setenv(relayAfterRecordKey, "true", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to reject duplicate realtime relay paths")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"))
                #expect(abort.reason.contains("realtime-delivery-consumer"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain relay after record requires lightweight realtime payload threshold")
    func productionDomainRelayAfterRecordRequiresLightweightRealtimePayloadThreshold() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let realtimeThresholdKey = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalRealtimeThresholdValue = Environment.get(realtimeThresholdKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(realtimeThresholdKey, to: originalRealtimeThresholdValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            unsetenv(realtimeThresholdKey)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain relay-after-record validation to require lightweight realtime payload threshold")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"))
                #expect(abort.reason.contains("IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain relay after record disables messageCreated preview lookup")
    func productionDomainRelayAfterRecordDisablesMessageCreatedPreviewLookup() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let previewLookupKey = "IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalPreviewLookupValue = Environment.get(previewLookupKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(previewLookupKey, to: originalPreviewLookupValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(previewLookupKey, "true", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain relay-after-record validation to disable messageCreated preview lookup")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"))
                #expect(abort.reason.contains("IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain relay after record requires async relay")
    func productionDomainRelayAfterRecordRequiresAsyncRelay() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let asyncRelayKey = "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalAsyncRelayValue = Environment.get(asyncRelayKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(asyncRelayKey, to: originalAsyncRelayValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            unsetenv(asyncRelayKey)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain relay-after-record validation to require async relay")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"))
                #expect(abort.reason.contains("IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=true"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain relay after record requires messageCreated coalescing window")
    func productionDomainRelayAfterRecordRequiresMessageCreatedCoalescingWindow() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let coalesceWindowKey = "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalCoalesceWindowValue = Environment.get(coalesceWindowKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(coalesceWindowKey, to: originalCoalesceWindowValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(coalesceWindowKey, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain relay-after-record validation to require messageCreated coalescing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"))
                #expect(abort.reason.contains("IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production domain relay after record requires active compact hint coalescing")
    func productionDomainRelayAfterRecordRequiresActiveCompactHintCoalescing() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let activeCompactWindowKey = "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalActiveCompactWindowValue = Environment.get(activeCompactWindowKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(activeCompactWindowKey, to: originalActiveCompactWindowValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(activeCompactWindowKey, "0", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected domain relay-after-record validation to require active compact hint coalescing")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true"))
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS > 0"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group owner delivery skip requires active conversation fanout")
    func productionLargeGroupOwnerDeliverySkipRequiresActiveConversationFanout() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let fanoutEnabledKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalFanoutEnabledValue = Environment.get(fanoutEnabledKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(fanoutEnabledKey, to: originalFanoutEnabledValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(fanoutEnabledKey, "false", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected large-group owner-delivery skip validation to require active conversation fanout")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED=true"))
                #expect(abort.reason.contains("owner delivery skip"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group active fanout threshold must cover owner delivery skip threshold")
    func productionLargeGroupActiveFanoutThresholdMustCoverOwnerDeliverySkipThreshold() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let ownerSkipThresholdKey = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
            let activeFanoutThresholdKey = "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalOwnerSkipThresholdValue = Environment.get(ownerSkipThresholdKey)
            let originalActiveFanoutThresholdValue = Environment.get(activeFanoutThresholdKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(ownerSkipThresholdKey, to: originalOwnerSkipThresholdValue)
                restoreEnvironment(activeFanoutThresholdKey, to: originalActiveFanoutThresholdValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(ownerSkipThresholdKey, "500", 1)
            setenv(activeFanoutThresholdKey, "1000", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected large-group validation to reject active fanout threshold above owner delivery skip threshold")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD <="))
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group realtime threshold must cover owner delivery skip threshold")
    func productionLargeGroupRealtimeThresholdMustCoverOwnerDeliverySkipThreshold() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let ownerSkipThresholdKey = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
            let realtimeThresholdKey = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalOwnerSkipThresholdValue = Environment.get(ownerSkipThresholdKey)
            let originalRealtimeThresholdValue = Environment.get(realtimeThresholdKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(ownerSkipThresholdKey, to: originalOwnerSkipThresholdValue)
                restoreEnvironment(realtimeThresholdKey, to: originalRealtimeThresholdValue)
            }

            setenv(groupsKey, "domain-delivery-consumer", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(ownerSkipThresholdKey, "500", 1)
            setenv(realtimeThresholdKey, "1000", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected large-group validation to reject realtime threshold above owner delivery skip threshold")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD <="))
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group summary activity threshold must cover owner delivery skip threshold")
    func productionLargeGroupSummaryActivityThresholdMustCoverOwnerDeliverySkipThreshold() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let allowMultiGroupKey = "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let ownerSkipThresholdKey = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
            let summaryThresholdKey = "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD"
            let realtimeThresholdKey = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalAllowMultiGroupValue = Environment.get(allowMultiGroupKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalOwnerSkipThresholdValue = Environment.get(ownerSkipThresholdKey)
            let originalSummaryThresholdValue = Environment.get(summaryThresholdKey)
            let originalRealtimeThresholdValue = Environment.get(realtimeThresholdKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(allowMultiGroupKey, to: originalAllowMultiGroupValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(ownerSkipThresholdKey, to: originalOwnerSkipThresholdValue)
                restoreEnvironment(summaryThresholdKey, to: originalSummaryThresholdValue)
                restoreEnvironment(realtimeThresholdKey, to: originalRealtimeThresholdValue)
            }

            setenv(groupsKey, "domain-delivery-consumer,summary-projection-consumer", 1)
            setenv(allowMultiGroupKey, "true", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(ownerSkipThresholdKey, "500", 1)
            setenv(summaryThresholdKey, "1000", 1)
            setenv(realtimeThresholdKey, "500", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected large-group validation to reject summary threshold above owner delivery skip threshold")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD <="))
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production large-group notification threshold must cover owner delivery skip threshold")
    func productionLargeGroupNotificationThresholdMustCoverOwnerDeliverySkipThreshold() async throws {
        try await withProductionRuntimeEnvironment {
            let groupsKey = "IM_STREAM_CONSUMER_GROUPS"
            let allowMultiGroupKey = "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP"
            let relayAfterRecordKey = "IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD"
            let ownerSkipThresholdKey = "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"
            let notificationThresholdKey = "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD"
            let notificationFullSkipKey = "IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS"
            let realtimeThresholdKey = "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD"
            let originalGroupsValue = Environment.get(groupsKey)
            let originalAllowMultiGroupValue = Environment.get(allowMultiGroupKey)
            let originalRelayAfterRecordValue = Environment.get(relayAfterRecordKey)
            let originalOwnerSkipThresholdValue = Environment.get(ownerSkipThresholdKey)
            let originalNotificationThresholdValue = Environment.get(notificationThresholdKey)
            let originalNotificationFullSkipValue = Environment.get(notificationFullSkipKey)
            let originalRealtimeThresholdValue = Environment.get(realtimeThresholdKey)
            defer {
                restoreEnvironment(groupsKey, to: originalGroupsValue)
                restoreEnvironment(allowMultiGroupKey, to: originalAllowMultiGroupValue)
                restoreEnvironment(relayAfterRecordKey, to: originalRelayAfterRecordValue)
                restoreEnvironment(ownerSkipThresholdKey, to: originalOwnerSkipThresholdValue)
                restoreEnvironment(notificationThresholdKey, to: originalNotificationThresholdValue)
                restoreEnvironment(notificationFullSkipKey, to: originalNotificationFullSkipValue)
                restoreEnvironment(realtimeThresholdKey, to: originalRealtimeThresholdValue)
            }

            setenv(groupsKey, "domain-delivery-consumer,notification-consumer", 1)
            setenv(allowMultiGroupKey, "true", 1)
            setenv(relayAfterRecordKey, "true", 1)
            setenv(ownerSkipThresholdKey, "500", 1)
            setenv(notificationThresholdKey, "1000", 1)
            setenv(notificationFullSkipKey, "false", 1)
            setenv(realtimeThresholdKey, "500", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected large-group validation to reject notification threshold above owner delivery skip threshold")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD <="))
                #expect(abort.reason.contains("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
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
        #expect(producerConfiguration.isIdempotenceEnabled == true)
        #expect(producerConfiguration.maximumInFlightRequestsPerConnection == 5)
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

    @Test("Production command API requires Kafka all acknowledgements")
    func productionCommandAPIRequiresKafkaAllAcknowledgements() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_KAFKA_REQUIRED_ACKS", "1", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require Kafka all acknowledgements")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_KAFKA_REQUIRED_ACKS=all"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires explicit Kafka topic")
    func productionCommandAPIRequiresExplicitKafkaTopic() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_KAFKA_TOPIC")
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require explicit Kafka topic")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_KAFKA_TOPIC"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer requires explicit Kafka dead-letter topic")
    func productionStreamConsumerRequiresExplicitKafkaDeadLetterTopic() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_KAFKA_DEAD_LETTER_TOPIC")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require explicit Kafka dead-letter topic")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_KAFKA_DEAD_LETTER_TOPIC"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer disables Kafka auto topic creation")
    func productionStreamConsumerDisablesKafkaAutoTopicCreation() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_KAFKA_AUTO_CREATE_TOPICS", "true", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to reject Kafka auto topic creation")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_KAFKA_AUTO_CREATE_TOPICS=false"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires Kafka SASL TLS")
    func productionCommandAPIRequiresKafkaSASLTLS() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_KAFKA_SECURITY_PROTOCOL", "plaintext", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require Kafka sasl_tls")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_KAFKA_SECURITY_PROTOCOL=sasl_tls"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer requires Kafka SASL password")
    func productionStreamConsumerRequiresKafkaSASLPassword() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_KAFKA_SASL_PASSWORD")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require Kafka SASL password")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_KAFKA_SASL_PASSWORD"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer rejects weak Kafka SASL password")
    func productionStreamConsumerRejectsWeakKafkaSASLPassword() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_KAFKA_SASL_PASSWORD", "im-password", 1)
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to reject weak Kafka SASL password")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_KAFKA_SASL_PASSWORD"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API rejects placeholder S3 media secrets")
    func productionCommandAPIRejectsPlaceholderS3MediaSecrets() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("MEDIA_STORAGE_S3_ACCESS_KEY_ID", "access-key", 1)
            setenv("MEDIA_STORAGE_S3_SECRET_ACCESS_KEY", "secret-key", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to reject placeholder S3 media secrets")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(
                    abort.reason.contains("MEDIA_STORAGE_S3_ACCESS_KEY_ID")
                    || abort.reason.contains("MEDIA_STORAGE_S3_SECRET_ACCESS_KEY")
                )
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires explicit S3 media region")
    func productionCommandAPIRequiresExplicitS3MediaRegion() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("MEDIA_STORAGE_S3_REGION")
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to require S3 media region")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("MEDIA_STORAGE_S3_REGION"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires explicit lowercase S3 path style flag")
    func productionCommandAPIRequiresExplicitLowercaseS3PathStyleFlag() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("MEDIA_STORAGE_S3_FORCE_PATH_STYLE", "TRUE", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to reject invalid S3 force path style")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("MEDIA_STORAGE_S3_FORCE_PATH_STYLE"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API requires HTTPS S3 media endpoint by default")
    func productionCommandAPIRequiresHTTPSS3MediaEndpointByDefault() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("MEDIA_STORAGE_S3_ENDPOINT", "http://s3.internal", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to reject insecure S3 endpoint")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("MEDIA_STORAGE_S3_ENDPOINT"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API rejects placeholder S3 media endpoint")
    func productionCommandAPIRejectsPlaceholderS3MediaEndpoint() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("MEDIA_STORAGE_S3_ENDPOINT", "https://oss.example.com", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to reject placeholder S3 endpoint")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("MEDIA_STORAGE_S3_ENDPOINT"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production command API rejects insecure S3 endpoint override")
    func productionCommandAPIRejectsInsecureS3EndpointOverride() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("MEDIA_STORAGE_S3_ENDPOINT", "http://s3.internal", 1)
            setenv("IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT", "true", 1)
            let app = try await productionRuntimeValidationApp(role: .commandAPI)
            do {
                try IMCommandAPIProductionValidator.validate(app: app)
                Issue.record("Expected command-api validation to reject insecure S3 endpoint override")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT"))
            } catch {
                Issue.record("Unexpected command-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires HTTPS OpenSearch endpoint")
    func productionQueryAPIRequiresHTTPSOpenSearchEndpoint() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_OPENSEARCH_ENDPOINT", "http://opensearch.internal", 1)
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to reject insecure OpenSearch endpoint")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_OPENSEARCH_ENDPOINT"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API rejects placeholder OpenSearch endpoint")
    func productionQueryAPIRejectsPlaceholderOpenSearchEndpoint() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_OPENSEARCH_ENDPOINT", "https://search.example.com", 1)
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to reject placeholder OpenSearch endpoint")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_OPENSEARCH_ENDPOINT"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production ops role requires Kafka event stream")
    func productionOpsRoleRequiresKafkaEventStream() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("IM_EVENT_STREAM_DRIVER", "database-outbox", 1)
            let app = try await productionRuntimeValidationApp(role: .ops)
            do {
                try IMOpsProductionValidator.validate(app: app)
                Issue.record("Expected ops validation to require Kafka event stream")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_EVENT_STREAM_DRIVER=kafka"))
            } catch {
                Issue.record("Unexpected ops validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires explicit sharded summary read source")
    func productionQueryAPIRequiresExplicitShardedSummaryReadSource() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_SUMMARY_QUERY_READ_SOURCE")
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to require sharded summary read source")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_QUERY_READ_SOURCE=sharded"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production query API requires summary member IDs response limit")
    func productionQueryAPIRequiresSummaryMemberIDsResponseLimit() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT")
            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMQueryAPIProductionValidator.validate(app: app)
                Issue.record("Expected query-api validation to require summary member IDs response limit")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT"))
            } catch {
                Issue.record("Unexpected query-api validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production stream consumer requires explicit sharded summary write mode")
    func productionStreamConsumerRequiresExplicitShardedSummaryWriteMode() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_SUMMARY_PROJECTION_WRITE_MODE")
            let app = try await productionRuntimeValidationApp(role: .streamConsumer)
            do {
                try IMStreamConsumerProductionValidator.validate(app: app)
                Issue.record("Expected stream-consumer validation to require sharded summary write mode")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_PROJECTION_WRITE_MODE=sharded"))
            } catch {
                Issue.record("Unexpected stream-consumer validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production ops role requires explicit sharded summary write mode")
    func productionOpsRoleRequiresExplicitShardedSummaryWriteMode() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("IM_SUMMARY_PROJECTION_WRITE_MODE")
            let app = try await productionRuntimeValidationApp(role: .ops)
            do {
                try IMOpsProductionValidator.validate(app: app)
                Issue.record("Expected ops validation to require sharded summary write mode")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_SUMMARY_PROJECTION_WRITE_MODE=sharded"))
            } catch {
                Issue.record("Unexpected ops validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Summary shard router routes by owner user ID")
    func summaryShardRouterRoutesByOwnerUserID() async throws {
        try await withApp(configure: configure) { app in
            app.summaryStoreConfiguration = IMSummaryStoreConfiguration(shardIDs: ["summary-a", "summary-b"])
            app.summaryShardDatabaseIDs = [
                "summary-a": .imSummary,
                "summary-b": .imSummary
            ]
            app.summaryShardRouter = OwnerHashSummaryShardRouter(
                app: app,
                shardIDs: app.summaryStoreConfiguration.shardIDs,
                shardDatabaseIDs: app.summaryShardDatabaseIDs
            )

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

    @Test("Large-group summary read path indexes are migrated")
    func largeGroupSummaryReadPathIndexesAreMigrated() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            struct SQLiteIndexRow: Decodable {
                let name: String
            }

            let summaryIndexes = try await sql.raw("PRAGMA index_list(\(ident: ConversationUserSummary.schema))")
                .all(decoding: SQLiteIndexRow.self)
            let changesIndexes = try await sql.raw("PRAGMA index_list(\(ident: ConversationChangesLogEntry.schema))")
                .all(decoding: SQLiteIndexRow.self)

            #expect(summaryIndexes.contains { $0.name == "im_conversation_user_summaries_kind_list_order_idx" })
            #expect(changesIndexes.contains { $0.name == "conversation_changes_log_owner_conversation_updated_idx" })
        }
    }

    @Test("Timeline read path indexes are migrated")
    func timelineReadPathIndexesAreMigrated() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            struct SQLiteIndexRow: Decodable {
                let name: String
            }

            let messageIndexes = try await sql.raw("PRAGMA index_list(\(ident: ConversationMessage.schema))")
                .all(decoding: SQLiteIndexRow.self)

            #expect(messageIndexes.contains { $0.name == "im_messages_conversation_timeline_server_sequence_idx" })
        }
    }

    @Test("IM schema validator requires timeline read path indexes")
    func imSchemaValidatorRequiresTimelineReadPathIndexes() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            try await sql.raw("DROP INDEX IF EXISTS im_messages_conversation_timeline_server_sequence_idx").run()

            do {
                try await IMSchemaValidator.validateIMSchema(app)
                Issue.record("Expected schema validation to fail when a timeline read path index is missing.")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("im_messages_conversation_timeline_server_sequence_idx"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("IM schema validator requires Cross-Cell realtime dispatch outbox indexes")
    func imSchemaValidatorRequiresCrossCellRealtimeDispatchOutboxIndexes() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            try await sql.raw("DROP INDEX IF EXISTS cross_cell_realtime_dispatch_ready_idx").run()

            do {
                try await IMSchemaValidator.validateIMSchema(app)
                Issue.record("Expected schema validation to fail when the Cross-Cell dispatch outbox index is missing.")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("cross_cell_realtime_dispatch_ready_idx"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("IM schema validator requires Cross-Cell realtime dispatch outbox dedupe index")
    func imSchemaValidatorRequiresCrossCellRealtimeDispatchOutboxDedupeIndex() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            try await sql.raw("DROP INDEX IF EXISTS cross_cell_realtime_dispatch_dedupe_uidx").run()

            do {
                try await IMSchemaValidator.validateIMSchema(app)
                Issue.record("Expected schema validation to fail when the Cross-Cell dispatch dedupe index is missing.")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("cross_cell_realtime_dispatch_dedupe_uidx"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("IM schema validator requires large-group summary read path indexes")
    func imSchemaValidatorRequiresLargeGroupSummaryReadPathIndexes() async throws {
        try await withApp(configure: configure) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected SQL database")
                return
            }

            try await sql.raw("DROP INDEX IF EXISTS im_conversation_user_summaries_kind_list_order_idx").run()

            do {
                try await IMSchemaValidator.validateIMSchema(app)
                Issue.record("Expected schema validation to fail when a large-group read path index is missing.")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("im_conversation_user_summaries_kind_list_order_idx"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("IM schema validator checks configured summary shards")
    func imSchemaValidatorChecksConfiguredSummaryShards() async throws {
        try await withApp(configure: configure) { app in
            let summaryDatabaseID = DatabaseID(string: "summary-validator-test")
            app.databases.use(.sqlite(.memory), as: summaryDatabaseID)
            let summaryDB = app.db(summaryDatabaseID)
            try await prepareSummaryReadModelSchema(on: summaryDB)
            app.summaryShardDatabaseIDs = ["summary-validator-test": summaryDatabaseID]
            app.summaryShardRouter = FixedSummaryShardRouter(
                shardID: "summary-validator-test",
                fixedDatabase: summaryDB
            )

            try await IMSchemaValidator.validateIMSchema(app)

            guard let summarySQL = summaryDB as? any SQLDatabase else {
                Issue.record("Expected SQL summary database")
                return
            }
            try await summarySQL.raw("DROP INDEX IF EXISTS conversation_changes_log_owner_conversation_updated_idx").run()

            do {
                try await IMSchemaValidator.validateIMSchema(app)
                Issue.record("Expected schema validation to fail when a summary shard index is missing.")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("summary-shard:summary-validator-test"))
                #expect(abort.reason.contains("conversation_changes_log_owner_conversation_updated_idx"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Migration registry registers summary read model migrations for configured summary shards")
    func migrationRegistryRegistersSummaryReadModelMigrationsForConfiguredSummaryShards() async throws {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        let summaryDatabaseID = DatabaseID(string: "summary-migration-test")
        app.databases.use(.sqlite(.memory), as: summaryDatabaseID)
        app.summaryStoreConfiguration = IMSummaryStoreConfiguration(shardIDs: ["summary-migration-test"])
        app.summaryShardDatabaseIDs = ["summary-migration-test": summaryDatabaseID]
        do {
            IMMigrationRegistry.registerMigrations(app)
            try await app.autoMigrate()

            try await IMSchemaValidator.validateIMSchema(app)

            guard let summarySQL = app.db(summaryDatabaseID) as? any SQLDatabase else {
                Issue.record("Expected SQL summary database")
                try await app.asyncShutdown()
                return
            }

            struct SQLiteTableRow: Decodable {
                let name: String
            }
            struct SQLiteIndexRow: Decodable {
                let name: String
            }

            let tables = try await summarySQL.raw("""
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                """).all(decoding: SQLiteTableRow.self)
            let summaryIndexes = try await summarySQL.raw("PRAGMA index_list(\(ident: ConversationUserSummary.schema))")
                .all(decoding: SQLiteIndexRow.self)
            let changesIndexes = try await summarySQL.raw("PRAGMA index_list(\(ident: ConversationChangesLogEntry.schema))")
                .all(decoding: SQLiteIndexRow.self)

            #expect(tables.contains { $0.name == ConversationUserSummary.schema })
            #expect(tables.contains { $0.name == ConversationChangesLogEntry.schema })
            #expect(tables.contains { $0.name == ConversationReadModelToken.schema })
            #expect(tables.contains { $0.name == ConversationActivitySummary.schema })
            #expect(summaryIndexes.contains { $0.name == "im_conversation_user_summaries_kind_list_order_idx" })
            #expect(changesIndexes.contains { $0.name == "conversation_changes_log_owner_conversation_updated_idx" })

            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("Migration registry provisions and validates independent conversation shards")
    func migrationRegistryProvisionsConversationShardSchema() async throws {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        let shardDatabaseID = DatabaseID(string: "conversation-migration-test")
        app.databases.use(.sqlite(.memory), as: shardDatabaseID)
        app.conversationShardDatabaseIDs = ["conversation-migration-test": shardDatabaseID]

        do {
            IMMigrationRegistry.registerMigrations(app)
            try await app.autoMigrate()
            app.conversationShardRouter = DirectoryBackedConversationShardRouter(
                app: app,
                shardIDs: ["conversation-migration-test"],
                shardDatabaseIDs: ["conversation-migration-test": shardDatabaseID],
                shardReplicaDatabaseIDs: [:],
                directory: DatabaseConversationDirectory(db: app.db)
            )

            try await IMSchemaValidator.validateIMSchema(app)

            guard let shardSQL = app.db(shardDatabaseID) as? any SQLDatabase else {
                Issue.record("Expected SQL conversation shard database")
                try await app.asyncShutdown()
                return
            }

            struct SQLiteTableRow: Decodable {
                let name: String
            }
            struct SQLiteIndexRow: Decodable {
                let name: String
            }

            let tables = try await shardSQL.raw("""
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                """).all(decoding: SQLiteTableRow.self)
            let eventIndexes = try await shardSQL.raw(
                "PRAGMA index_list(\(ident: ConversationDomainEvent.schema))"
            ).all(decoding: SQLiteIndexRow.self)

            #expect(tables.contains { $0.name == Conversation.schema })
            #expect(tables.contains { $0.name == ConversationDomainEvent.schema })
            #expect(tables.contains { $0.name == ConversationDomainEventSequence.schema })
            #expect(tables.contains { $0.name == ConversationTimelineNotice.schema })
            #expect(tables.contains { $0.name == ConversationUserSummary.schema } == false)
            #expect(tables.contains { $0.name == User.schema } == false)
            #expect(eventIndexes.contains { $0.name == "conversation_domain_events_status_created_idx" })

            try await shardSQL.raw("DROP INDEX IF EXISTS conversation_domain_events_status_created_idx").run()
            do {
                try await IMSchemaValidator.validateIMSchema(app)
                Issue.record("Expected conversation shard schema validation to fail when an outbox index is missing.")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("conversation-shard:conversation-migration-test"))
                #expect(abort.reason.contains("conversation_domain_events_status_created_idx"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
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
            endpoint: "https://opensearch.internal",
            indexName: "conversation-message-search"
        )

        #expect(app.conversationSearchAdapter is OpenSearchConversationSearchAdapter)
        try await app.asyncShutdown()
    }

    @Test("Stream consumer configuration supports single-group production deployments")
    func streamConsumerConfigurationSupportsSingleGroupDeployments() {
        let originalValues = [
            "IM_STREAM_CONSUMER_GROUPS": Environment.get("IM_STREAM_CONSUMER_GROUPS"),
            "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP": Environment.get("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP"),
            "IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED": Environment.get("IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED"),
            "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS": Environment.get("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS"),
            "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES": Environment.get("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        setenv("IM_STREAM_CONSUMER_GROUPS", "summary-projection-consumer", 1)
        unsetenv("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")
        setenv("IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED", "17", 1)
        setenv("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS", "250", 1)
        setenv("IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES", "123", 1)

        let configuration = IMStreamConsumerConfiguration.load(from: .production)
        #expect(configuration.orderedEnabledGroups == ["summary-projection-consumer"])
        #expect(configuration.preservesGroupedDeploymentsInProduction == false)
        #expect(configuration.realtimeDeliveryAsyncMaxQueued == 17)
        #expect(configuration.realtimeActiveConversationRouteCacheTTLMilliseconds == 250)
        #expect(configuration.realtimeActiveConversationRouteCacheMaxEntries == 123)
    }

    @Test("Active conversation route lookup cache expires and bounds entries")
    func activeConversationRouteLookupCacheExpiresAndBoundsEntries() async {
        let cache = ActiveConversationRouteLookupCache()
        let conversationA = UUID()
        let conversationB = UUID()
        let conversationC = UUID()
        let userA = UUID()
        let userB = UUID()
        let userC = UUID()
        let now = Date(timeIntervalSince1970: 1_711_000_000)
        let keyA = ActiveConversationRouteLookupCache.Key(conversationID: conversationA, recipientUserIDs: [userA])
        let keyB = ActiveConversationRouteLookupCache.Key(conversationID: conversationB, recipientUserIDs: [userB])
        let keyC = ActiveConversationRouteLookupCache.Key(conversationID: conversationC, recipientUserIDs: [userC])

        await cache.store([userA: ["gateway-a"]], for: keyA, ttlMilliseconds: 1000, maxEntries: 2, now: now)
        await cache.store([userB: ["gateway-b"]], for: keyB, ttlMilliseconds: 500, maxEntries: 2, now: now)
        await cache.store([userC: ["gateway-c"]], for: keyC, ttlMilliseconds: 1000, maxEntries: 2, now: now)

        #expect(await cache.routes(for: keyA, now: now)?[userA] == Set(["gateway-a"]))
        #expect(await cache.routes(for: keyB, now: now) == nil)
        #expect(await cache.routes(for: keyC, now: now)?[userC] == Set(["gateway-c"]))

        await cache.store([userB: ["gateway-b"]], for: keyB, ttlMilliseconds: 1, maxEntries: 2, now: now)
        #expect(await cache.routes(for: keyB, now: now.addingTimeInterval(1)) == nil)

        await cache.store([userA: ["gateway-a"]], for: keyA, ttlMilliseconds: 1000, maxEntries: 0, now: now)
        #expect(await cache.routes(for: keyA, now: now) == nil)
    }

    @Test("Active conversation route lookup cache joins concurrent misses")
    func activeConversationRouteLookupCacheJoinsConcurrentMisses() async throws {
        let cache = ActiveConversationRouteLookupCache()
        let conversationID = UUID()
        let userA = UUID()
        let userB = UUID()
        let loadCounter = ActiveConversationRouteLoadCounter()

        async let first = cache.resolve(
            conversationID: conversationID,
            recipientUserIDs: [userA, userB],
            ttlMilliseconds: 1000,
            maxEntries: 10
        ) { missingUserIDs in
            await loadCounter.recordStart(missingUserIDs: missingUserIDs)
            try await Task.sleep(nanoseconds: 100_000_000)
            return [userA: ["gateway-a"]]
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        async let second = cache.resolve(
            conversationID: conversationID,
            recipientUserIDs: [userB, userA],
            ttlMilliseconds: 1000,
            maxEntries: 10
        ) { missingUserIDs in
            await loadCounter.recordStart(missingUserIDs: missingUserIDs)
            try await Task.sleep(nanoseconds: 100_000_000)
            return [userA: ["gateway-a"]]
        }

        let results = try await [first, second]
        #expect(await loadCounter.startCount == 1)
        #expect(results.map(\.joinedInFlight).filter { $0 }.count == 1)
        #expect(results.allSatisfy { $0.routes[userA] == Set(["gateway-a"]) })
        #expect(results.allSatisfy { $0.missedUserCount == 2 })
    }

    @Test("Active conversation route lookup cache bounds active snapshots")
    func activeConversationRouteLookupCacheBoundsActiveSnapshots() async throws {
        let cache = ActiveConversationRouteLookupCache()
        let conversationA = UUID()
        let conversationB = UUID()
        let userA = UUID()
        let now = Date(timeIntervalSince1970: 1_711_000_000)

        let first = try await cache.resolveActiveConversation(
            conversationID: conversationA,
            ttlMilliseconds: 1000,
            maxEntries: 1,
            now: now
        ) {
            [userA: ["gateway-a"]]
        }
        #expect(first.cacheHit == false)
        #expect(first.routes[userA] == Set(["gateway-a"]))

        let second = try await cache.resolveActiveConversation(
            conversationID: conversationA,
            ttlMilliseconds: 1000,
            maxEntries: 1,
            now: now
        ) {
            [:]
        }
        #expect(second.cacheHit == true)

        _ = try await cache.resolveActiveConversation(
            conversationID: conversationB,
            ttlMilliseconds: 1000,
            maxEntries: 1,
            now: now
        ) {
            [:]
        }

        let reloaded = try await cache.resolveActiveConversation(
            conversationID: conversationA,
            ttlMilliseconds: 1000,
            maxEntries: 1,
            now: now
        ) {
            [userA: ["gateway-b"]]
        }
        #expect(reloaded.cacheHit == false)
        #expect(reloaded.routes[userA] == Set(["gateway-b"]))
    }

    @Test("Stream consumer default groups include domain delivery")
    func streamConsumerDefaultGroupsIncludeDomainDelivery() {
        let originalValues = [
            "IM_STREAM_CONSUMER_GROUPS": Environment.get("IM_STREAM_CONSUMER_GROUPS"),
            "IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP": Environment.get("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        unsetenv("IM_STREAM_CONSUMER_GROUPS")
        unsetenv("IM_STREAM_CONSUMER_ALLOW_MULTI_GROUP")

        let configuration = IMStreamConsumerConfiguration.load(from: .development)
        #expect(configuration.enabledGroups.contains("summary-projection-consumer"))
        #expect(configuration.enabledGroups.contains("domain-delivery-consumer"))
    }

    @Test("Stream consumer large-group messageCreated delivery mode is explicit")
    func streamConsumerLargeGroupMessageCreatedDeliveryModeIsExplicit() {
        let originalValues = [
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE": Environment.get("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE"),
            "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD": Environment.get("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD")
        ]
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        unsetenv("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE")
        setenv("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD", "500", 1)
        var configuration = IMStreamConsumerConfiguration.load(from: .production)
        #expect(configuration.domainDeliveryMessageCreatedLargeGroupMode == .timelinePull)

        setenv("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE", "owner-delivery", 1)
        configuration = IMStreamConsumerConfiguration.load(from: .production)
        #expect(configuration.domainDeliveryMessageCreatedLargeGroupMode == .ownerDelivery)

        setenv("IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE", "timeline-pull", 1)
        configuration = IMStreamConsumerConfiguration.load(from: .production)
        #expect(configuration.domainDeliveryMessageCreatedLargeGroupMode == .timelinePull)
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
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardAttempt()
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardSuccess(elapsedMilliseconds: 8)
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardAttempt()
            await app.conversationShardRoutingMetrics.recordRemoteCellForwardFailure(elapsedMilliseconds: 12)
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
                #expect(res.body.string.contains("im_conversation_shard_remote_cell_forward_attempts_total 2"))
                #expect(res.body.string.contains("im_conversation_shard_remote_cell_forward_successes_total 1"))
                #expect(res.body.string.contains("im_conversation_shard_remote_cell_forward_failures_total 1"))
                #expect(res.body.string.contains("im_conversation_shard_remote_cell_forward_latency_avg_millis 10"))
                #expect(res.body.string.contains("im_conversation_shard_remote_cell_forward_latency_max_millis 12"))
                #expect(res.body.string.contains("im_auth_session_cache_hits_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_splits_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_downgraded_active_recipients_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_backpressure_downgraded_active_recipients_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_route_split_drops_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_route_split_drop_recipients_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_route_lookup_failures_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_route_lookup_failure_recipients_total"))
                #expect(res.body.string.contains("im_realtime_remote_active_conversation_fanout_splits_total"))
                #expect(res.body.string.contains("im_realtime_remote_active_conversation_fanout_full_recipients_total"))
                #expect(res.body.string.contains("im_realtime_remote_active_conversation_fanout_route_split_drops_total"))
                #expect(res.body.string.contains("im_realtime_remote_active_conversation_fanout_route_split_drop_recipients_total"))
                #expect(res.body.string.contains("im_cross_node_dispatch_latency_avg_millis"))
                #expect(res.body.string.contains("im_cross_node_dispatch_latency_max_millis"))
                #expect(res.body.string.contains("im_realtime_remote_dispatch_config_user_batch_size"))
                #expect(res.body.string.contains("im_realtime_remote_dispatch_config_max_in_flight"))
                #expect(res.body.string.contains("im_remote_domain_event_encoded_packet_bytes_total"))
                #expect(res.body.string.contains("im_remote_domain_event_max_encoded_packet_bytes"))
                #expect(res.body.string.contains("im_gateway_http_relay_work_items_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_recipients_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_request_attempts_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_request_failures_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_request_latency_millis_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_request_body_bytes_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_request_max_body_bytes"))
                #expect(res.body.string.contains("im_gateway_http_relay_binary_fallbacks_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_inbound_requests_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_inbound_failures_total"))
                #expect(res.body.string.contains("im_gateway_http_relay_inbound_latency_millis_total"))
                #expect(res.body.string.contains("im_realtime_inactive_conversation_hint_recipients_total"))
                #expect(res.body.string.contains("im_realtime_inactive_conversation_hint_suppressed_recipients_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_compact_active_recipients_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_max_compact_active_recipients_per_split"))
                #expect(res.body.string.contains("im_realtime_remote_active_conversation_fanout_compact_recipients_total"))
                #expect(res.body.string.contains("im_realtime_remote_active_conversation_fanout_max_compact_recipients_per_split"))
                #expect(res.body.string.contains("im_realtime_delivery_consumer_inactive_hint_relay_payload_batches_total"))
                #expect(res.body.string.contains("im_realtime_delivery_consumer_inactive_hint_relay_recipients_total"))
                #expect(res.body.string.contains("im_realtime_delivery_consumer_inactive_hint_suppressed_recipients_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_pre_split_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_pre_split_active_recipients_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_pre_split_compact_active_recipients_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_pre_split_route_drops_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_pre_split_route_lookup_failures_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_inactive_hint_suppressed_recipients_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_active_route_cache_hits_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_active_route_cache_partial_hits_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_active_route_cache_misses_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_active_route_cache_cached_users_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_active_route_cache_missed_users_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_active_route_cache_joined_in_flight_total"))
                #expect(res.body.string.contains("im_domain_relay_after_record_pre_split_max_compact_active_recipients"))
                #expect(res.body.string.contains("im_realtime_active_conversation_route_cache_hits_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_route_cache_partial_hits_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_route_cache_misses_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_route_cache_cached_users_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_route_cache_missed_users_total"))
                #expect(res.body.string.contains("im_realtime_active_conversation_route_cache_joined_in_flight_total"))
                #expect(res.body.string.contains("im_redis_presence_active_conversation_node_index_lookups_total"))
                #expect(res.body.string.contains("im_redis_presence_active_conversation_node_index_lookup_nodes_total"))
                #expect(res.body.string.contains("im_domain_event_recipient_resolve_missing_snapshot_total"))
                #expect(res.body.string.contains("im_domain_event_recipient_snapshot_deduplicated_stores_total"))
                #expect(res.body.string.contains("im_domain_event_recipient_snapshot_resolve_shared_set_hits_total"))
                #expect(res.body.string.contains("im_domain_event_recipient_snapshot_resolve_shared_set_missing_total"))
                #expect(res.body.string.contains("im_domain_event_owner_delivery_batch_writes_total"))
                #expect(res.body.string.contains("im_domain_event_owner_delivery_batch_write_latency_avg_millis"))
                #expect(res.body.string.contains("im_domain_event_owner_delivery_batch_write_materialized_fast_paths_total"))
                #expect(res.body.string.contains("im_domain_event_message_created_preview_embedded_total"))
                #expect(res.body.string.contains("im_domain_event_message_created_preview_message_lookup_total"))
                #expect(res.body.string.contains("im_domain_event_message_created_preview_missing_total"))
                #expect(res.body.string.contains("im_summary_read_summary_latency_avg_millis"))
                #expect(res.body.string.contains("im_summary_read_list_latency_avg_millis"))
                #expect(res.body.string.contains("im_summary_read_changes_latency_avg_millis"))
                #expect(res.body.string.contains("im_timeline_read_since_total"))
                #expect(res.body.string.contains("im_timeline_read_visibility_scan_rows_total"))
                #expect(res.body.string.contains("im_timeline_read_visibility_scan_limit_exceeded_total"))
                #expect(res.body.string.contains("im_timeline_read_latency_millis_bucket"))
                #expect(res.body.string.contains("im_timeline_read_latency_millis_bucket{kind=\"since\",le=\"+Inf\"}"))
                #expect(res.body.string.contains("im_timeline_read_latency_millis_count{kind=\"since\"}"))
                #expect(res.body.string.contains("im_timeline_read_latency_millis_sum{kind=\"since\"}"))
                #expect(res.body.string.contains("im_timeline_since_visibility_notice_bypasses_total"))
                #expect(res.body.string.contains("im_timeline_since_response_singleflight_notice_bypasses_total"))
                #expect(res.body.string.contains("im_timeline_since_hot_cache_target_sequence_bypasses_total"))
                #expect(res.body.string.contains("im_timeline_since_recent_cache_target_sequence_bypasses_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_requests_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_eventual_satisfied_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_strong_fallbacks_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_strong_satisfied_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_strong_misses_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_errors_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_singleflight_joined_total"))
                #expect(res.body.string.contains("im_timeline_since_target_sequence_window_joined_total"))
                #expect(res.body.string.contains("im_realtime_async_relay_tasks_started_total"))
                #expect(res.body.string.contains("im_realtime_async_relay_tasks_completed_total"))
                #expect(res.body.string.contains("im_realtime_async_relay_in_flight"))
                #expect(res.body.string.contains("im_realtime_async_relay_latency_avg_millis"))
                #expect(res.body.string.contains("im_local_fanout_chunks_total"))
                #expect(res.body.string.contains("im_local_fanout_max_chunks_per_event_loop_job"))
                #expect(res.body.string.contains("im_local_fanout_encoded_packet_bytes_total"))
                #expect(res.body.string.contains("im_local_fanout_max_encoded_packet_bytes"))
                #expect(res.body.string.contains("im_local_fanout_estimated_outbound_bytes_total"))
                #expect(res.body.string.contains("im_local_fanout_max_estimated_outbound_bytes_per_packet"))
                #expect(res.body.string.contains("im_local_fanout_event_loop_jobs_started_total"))
                #expect(res.body.string.contains("im_local_fanout_event_loop_job_start_lag_avg_millis"))
                #expect(res.body.string.contains("im_local_fanout_event_loop_job_start_lag_max_millis"))
                #expect(res.body.string.contains("im_gateway_local_fanout_config_batch_size"))
                #expect(res.body.string.contains("im_gateway_local_fanout_config_event_loop_yield_chunks"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_config_enabled"))
                #expect(res.body.string.contains("im_realtime_active_conversation_fanout_config_recipient_threshold"))
            })

            app.metricsConfiguration = IMMetricsConfiguration(isEnabled: false, internalSecret: nil)
            try await app.testing().test(.GET, "internal/metrics", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Gateway drain control rejects unauthenticated changes and gates new TCP admissions")
    func gatewayDrainControlGatesTCPAdmission() async throws {
        let key = "IM_GATEWAY_CONTROL_SHARED_SECRET"
        let originalValue = Environment.get(key)
        defer { restoreEnvironment(key, to: originalValue) }
        setenv(key, "gateway-drain-control-secret-at-least-32-bytes", 1)

        struct DrainRequest: Content {
            let draining: Bool
            let disconnectExisting: Bool
        }

        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "internal/gateway/drain", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.PUT, "internal/gateway/drain", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "gateway-drain-control-secret-at-least-32-bytes")
                try req.content.encode(DrainRequest(draining: true, disconnectExisting: false))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("\"draining\":true"))
            })
            #expect(app.imTCPAdmissionController.acquire().rejectionReason == .gatewayDraining)

            try await app.testing().test(.PUT, "internal/gateway/drain", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: "gateway-drain-control-secret-at-least-32-bytes")
                try req.content.encode(DrainRequest(draining: false, disconnectExisting: false))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("\"draining\":false"))
            })
            #expect(app.imTCPAdmissionController.acquire().isAccepted)
        }
    }

    @Test("Timeline read metrics record latency histogram buckets")
    func timelineReadMetricsRecordLatencyHistogramBuckets() async {
        let metrics = IMTimelineReadMetrics()
        await metrics.recordRead(
            kind: .history,
            itemCount: 1,
            scannedRows: 1,
            scannedPages: 1,
            elapsedMilliseconds: 4
        )
        await metrics.recordRead(
            kind: .since,
            itemCount: 1,
            scannedRows: 1,
            scannedPages: 1,
            elapsedMilliseconds: 10
        )
        await metrics.recordRead(
            kind: .since,
            itemCount: 1,
            scannedRows: 1,
            scannedPages: 1,
            elapsedMilliseconds: 31_000
        )

        let snapshot = await metrics.currentSnapshot()
        #expect(snapshot.historyLatencyHistogram.count == 1)
        #expect(snapshot.historyLatencyHistogram.sumMilliseconds == 4)
        #expect(snapshot.historyLatencyHistogram.bucketCounts.allSatisfy { $0 == 1 })
        #expect(snapshot.sinceLatencyHistogram.count == 2)
        #expect(snapshot.sinceLatencyHistogram.sumMilliseconds == 31_010)
        #expect(snapshot.sinceLatencyHistogram.overflowCount == 1)
        #expect(snapshot.sinceLatencyHistogram.bucketCounts.first == 0)
        #expect(snapshot.sinceLatencyHistogram.bucketCounts.dropFirst().allSatisfy { $0 == 1 })
    }

    @Test("Routing metrics records cross-node dispatch latency")
    func routingMetricsRecordsCrossNodeDispatchLatency() async throws {
        let metrics = RoutingMetrics()
        await metrics.recordCrossNodeDispatchSucceeded(latencyMilliseconds: 12)
        await metrics.recordCrossNodeDispatchFailed(latencyMilliseconds: 35)

        let snapshot = await metrics.currentSnapshot()
        #expect(snapshot.crossNodeDispatchCount == 1)
        #expect(snapshot.crossNodeDispatchFailureCount == 1)
        #expect(snapshot.crossNodeDispatchTotalLatencyMillis == 47)
        #expect(snapshot.crossNodeDispatchMaxLatencyMillis == 35)
    }

    @Test("Client health reports aggregate into internal metrics")
    func clientHealthReportsAggregateIntoInternalMetrics() async throws {
        try await withApp(configure: configure) { app in
            app.metricsConfiguration = IMMetricsConfiguration(isEnabled: true, internalSecret: "metrics-secret")
            let accessToken = try await loginAccessToken(using: app)
            let report = IMClientHealthReportRequest(
                snapshot: IMClientHealthSnapshotRequest(
                    domainEventCursor: 42,
                    deferredDomainEventCount: 3,
                    fullRefreshConversationCount: 1,
                    domainEventMetrics: IMClientDomainEventDebugMetricsRequest(
                        invalidDomainEventMetadata: 1,
                        deferredStored: 4,
                        deferredReplayApplied: 2,
                        cacheDroppedCanonicalMessages: 1,
                        invalidProjectionDTOs: 1,
                        catchUpCursorGap: 2,
                        catchUpStoppedBeforeCursorAdvance: 1
                    ),
                    timelineCatchUpDiagnostics: IMClientTimelineCatchUpDiagnosticsRequest(
                        hintQueuedCount: 3,
                        hintSkippedAlreadyLoadedCount: 1,
                        deferredCount: 1,
                        sinceRequestCount: 2,
                        sinceSuccessCount: 1,
                        sinceFailureCount: 1,
                        appliedPageCount: 1,
                        appliedItemCount: 5,
                        lastHintToRequestMilliseconds: 120,
                        lastRequestMilliseconds: 80,
                        lastHintToApplyMilliseconds: 230
                    ),
                    timelineCatchUpConfiguration: IMClientTimelineCatchUpConfigurationRequest(
                        selectedHintInitialJitterMilliseconds: 125,
                        selectedHintMinimumIntervalMilliseconds: 250,
                        selectedHintMicroBatchMilliseconds: 75
                    )
                ),
                reason: "test-sync",
                reportedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            for _ in 0..<2 {
                try await app.testing().test(.POST, "api/im/client-health", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: accessToken)
                    try req.content.encode(report)
                }, afterResponse: { res async in
                    #expect(res.status == .noContent)
                })
            }
            await app.conversationDomainEventMetrics.recordMessageCreatedOwnerDeliverySkipped(recipientCount: 123)
            await app.conversationDomainEventMetrics.recordMessageCreatedTimelinePullDelivery(recipientCount: 123)
            await app.conversationDomainEventMetrics.recordMessageCreatedOwnerNotificationSkipped(recipientCount: 234)
            await app.conversationDomainEventMetrics.recordMessageCreatedSummaryActivityOnly(recipientCount: 456)
            await app.conversationDomainEventMetrics.recordSummaryActivityCoalescedReplacement()
            await app.conversationDomainEventMetrics.recordSummaryActivityCoalescedFlush(
                requestCount: 3,
                elapsedMilliseconds: 30
            )
            await app.conversationDomainEventMetrics.recordSummaryActivityCoalescedFlushFailure(
                requestCount: 2,
                elapsedMilliseconds: 50
            )
            await app.conversationDomainEventMetrics.recordRecipientResolutionMissingSnapshot()
            await app.conversationDomainEventMetrics.recordRecipientSnapshotStored(
                recipientCount: 10,
                deduplicated: false
            )
            await app.conversationDomainEventMetrics.recordRecipientSnapshotStored(
                recipientCount: 500,
                deduplicated: true
            )
            await app.conversationDomainEventMetrics.recordRecipientSnapshotResolved(
                usedSharedSet: false,
                recipientCount: 10,
                elapsedMilliseconds: 40
            )
            await app.conversationDomainEventMetrics.recordRecipientSnapshotResolved(
                usedSharedSet: true,
                recipientCount: 500,
                elapsedMilliseconds: 60
            )
            await app.conversationDomainEventMetrics.recordRecipientSnapshotSharedSetMissing(
                elapsedMilliseconds: 20
            )
            await app.conversationDomainEventMetrics.recordRecipientSetCleanup(
                scannedCount: 12,
                deletedCount: 3
            )
            await app.conversationDomainEventMetrics.recordOwnerDeliveryBatchWrite(
                requestCount: 5,
                insertedRowCount: 4,
                returnedRowCount: 5,
                elapsedMilliseconds: 120,
                usedFallback: false,
                usedCanonicalFastPath: true,
                usedMaterializedFastPath: true
            )
            await app.conversationDomainEventMetrics.recordOwnerDeliveryBatchWrite(
                requestCount: 2,
                insertedRowCount: 0,
                returnedRowCount: 2,
                elapsedMilliseconds: 80,
                usedFallback: true
            )
            await app.conversationDomainEventMetrics.recordOwnerDeliveryBatchWriteChunking(
                requestCount: 10_000,
                chunkCount: 10
            )
            await app.summaryReadMetrics.recordSummaryRead(elapsedMilliseconds: 40)
            await app.summaryReadMetrics.recordSummaryReadError(elapsedMilliseconds: 60)
            await app.summaryReadMetrics.recordListRead(
                path: .joined,
                itemCount: 3,
                elapsedMilliseconds: 30,
                usedFallback: false
            )
            await app.summaryReadMetrics.recordListRead(
                path: .fluent,
                itemCount: 2,
                elapsedMilliseconds: 50,
                usedFallback: true
            )
            await app.summaryReadMetrics.recordListReadError(elapsedMilliseconds: 70)
            await app.summaryReadMetrics.recordChangesRead(
                path: .joined,
                upsertCount: 2,
                removedCount: 1,
                elapsedMilliseconds: 20,
                usedFallback: false
            )
            await app.summaryReadMetrics.recordChangesRead(
                path: .fluent,
                upsertCount: 1,
                removedCount: 1,
                elapsedMilliseconds: 40,
                usedFallback: true
            )
            await app.summaryReadMetrics.recordChangesReadError(elapsedMilliseconds: 80)
            await app.routingMetrics.recordGatewayHTTPRelay(
                workItemCount: 3,
                payloadBatchCount: 2,
                recipientCount: 5,
                skippedRecipientCount: 1,
                encodedPayloadBytes: 512,
                maxRecipientsPerWorkItem: 2
            )
            await app.routingMetrics.recordGatewayHTTPRelayRequest(
                didSucceed: true,
                latencyMilliseconds: 40,
                bodyBytes: 128
            )
            await app.routingMetrics.recordGatewayHTTPRelayRequest(
                didSucceed: false,
                latencyMilliseconds: 80,
                bodyBytes: 384
            )
            await app.routingMetrics.recordGatewayHTTPRelayBinaryFallback()
            await app.routingMetrics.recordGatewayHTTPRelayInboundRequest(
                statusCode: 200,
                durationMilliseconds: 30,
                bodyBytes: 128
            )
            await app.routingMetrics.recordGatewayHTTPRelayInboundRequest(
                statusCode: 500,
                durationMilliseconds: 70,
                bodyBytes: 256
            )
            await app.routingMetrics.recordRealtimePayloadBuilt(
                payloadCount: 3,
                recipientDeliveryCount: 9,
                conversationSummaryCount: 2,
                omittedSummaryMemberIDPayloadCount: 1,
                omittedSummaryMemberIDTotalMembers: 1000,
                emittedSummaryMemberIDPayloadCount: 1,
                emittedSummaryMemberIDTotalMembers: 3
            )
            await app.routingMetrics.recordInactiveConversationHintSuppressed(recipientCount: 6)
            await app.routingMetrics.recordRealtimeAsyncRelayTaskStarted(taskStartLagMilliseconds: 10, inFlight: 2)
            await app.routingMetrics.recordRealtimeAsyncRelayTaskStarted(taskStartLagMilliseconds: 20, inFlight: 3)
            await app.routingMetrics.recordRealtimeAsyncRelayTaskCompleted(relayMilliseconds: 60, inFlight: 2)
            await app.routingMetrics.recordRealtimeAsyncRelayTaskCompleted(relayMilliseconds: 100, inFlight: 1)
            await app.routingMetrics.recordDomainRelayAfterRecordPreSplit(
                activeRecipientCount: 2,
                compactActiveRecipientCount: 1,
                inactiveHintRecipientCount: 3,
                downgradedActiveRecipientCount: 1
            )
            await app.routingMetrics.recordDomainRelayAfterRecordPreSplitRouteDrop()
            await app.routingMetrics.recordDomainRelayAfterRecordInactiveHintCoalescing(suppressedRecipientCount: 4)
            await app.routingMetrics.recordDomainRelayAfterRecordActiveRouteCache(hit: true, cachedUserCount: 2)
            await app.routingMetrics.recordDomainRelayAfterRecordActiveRouteCache(hit: false, partialHit: true, cachedUserCount: 3, missedUserCount: 1)
            await app.routingMetrics.recordDomainRelayAfterRecordActiveRouteCache(hit: false, missedUserCount: 4, joinedInFlight: true)
            await app.routingMetrics.recordRealtimeActiveConversationRouteCache(hit: true, cachedUserCount: 2)
            await app.routingMetrics.recordRealtimeActiveConversationRouteCache(hit: false, partialHit: true, cachedUserCount: 3, missedUserCount: 1)
            await app.routingMetrics.recordRealtimeActiveConversationRouteCache(hit: false, missedUserCount: 4, joinedInFlight: true)
            await app.routingMetrics.recordRedisPresenceActiveConversationNodeIndexLookup(nodeCount: 2)
            await app.streamMetrics.recordRun(
                groupID: "realtime-delivery-consumer",
                eventCount: 4,
                isMessageCreatedRun: true,
                durationMillis: 25,
                eventLagMillis: 150,
                slowThresholdMillis: 100
            )
            await app.streamMetrics.recordProcessingBatch(
                groupID: "realtime-delivery-consumer",
                eventCount: 6,
                batchFillWaitMillis: 10,
                batchFillEventCount: 2
            )
            await app.streamMetrics.recordProcessingBatch(
                groupID: "realtime-delivery-consumer",
                eventCount: 1,
                batchFillSkipped: true
            )
            await app.streamMetrics.recordQueueDepth(groupID: "realtime-delivery-consumer", depth: 7)
            await app.streamMetrics.recordQueueProducerWait(groupID: "realtime-delivery-consumer")

            try await app.testing().test(.GET, "internal/metrics", beforeRequest: { req in
                req.headers.replaceOrAdd(name: "X-IM-Metrics-Secret", value: "metrics-secret")
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("im_client_health_reports_total 2"))
                #expect(body.contains("im_client_health_reporting_users 1"))
                #expect(body.contains("im_client_deferred_domain_events 3"))
                #expect(body.contains("im_client_domain_event_cursor_max 42"))
                #expect(body.contains("im_client_domain_event_cursor_gap_total 2"))
                #expect(body.contains("im_client_deferred_domain_events_stored_total 4"))
                #expect(body.contains("im_client_invalid_projection_dtos_total 1"))
                #expect(body.contains("im_client_timeline_catch_up_hint_queued_total 3"))
                #expect(body.contains("im_client_timeline_catch_up_skipped_already_loaded_total 1"))
                #expect(body.contains("im_client_timeline_catch_up_deferred_total 1"))
                #expect(body.contains("im_client_timeline_catch_up_since_requests_total 2"))
                #expect(body.contains("im_client_timeline_catch_up_since_successes_total 1"))
                #expect(body.contains("im_client_timeline_catch_up_since_failures_total 1"))
                #expect(body.contains("im_client_timeline_catch_up_applied_pages_total 1"))
                #expect(body.contains("im_client_timeline_catch_up_applied_items_total 5"))
                #expect(body.contains("im_client_timeline_catch_up_hint_to_request_max_millis 120"))
                #expect(body.contains("im_client_timeline_catch_up_hint_to_request_avg_millis 120"))
                #expect(body.contains("im_client_timeline_catch_up_request_max_millis 80"))
                #expect(body.contains("im_client_timeline_catch_up_request_avg_millis 80"))
                #expect(body.contains("im_client_timeline_catch_up_hint_to_apply_max_millis 230"))
                #expect(body.contains("im_client_timeline_catch_up_hint_to_apply_avg_millis 230"))
                #expect(body.contains("im_client_timeline_catch_up_config_selected_hint_initial_jitter_max_millis 125"))
                #expect(body.contains("im_client_timeline_catch_up_config_selected_hint_initial_jitter_avg_millis 125"))
                #expect(body.contains("im_client_timeline_catch_up_config_selected_hint_min_interval_max_millis 250"))
                #expect(body.contains("im_client_timeline_catch_up_config_selected_hint_min_interval_avg_millis 250"))
                #expect(body.contains("im_client_timeline_catch_up_config_selected_hint_micro_batch_max_millis 75"))
                #expect(body.contains("im_client_timeline_catch_up_config_selected_hint_micro_batch_avg_millis 75"))
                #expect(body.contains("im_domain_event_message_created_owner_delivery_skipped_total 1"))
                #expect(body.contains("im_domain_event_message_created_owner_delivery_skipped_recipients_total 123"))
                #expect(body.contains("im_domain_event_message_created_timeline_pull_delivery_total 1"))
                #expect(body.contains("im_domain_event_message_created_timeline_pull_delivery_recipients_total 123"))
                #expect(body.contains("im_domain_event_message_created_owner_notification_skipped_total 1"))
                #expect(body.contains("im_domain_event_message_created_owner_notification_skipped_recipients_total 234"))
                #expect(body.contains("im_domain_event_message_created_summary_activity_only_total 1"))
                #expect(body.contains("im_domain_event_message_created_summary_activity_only_recipients_total 456"))
                #expect(body.contains("im_domain_event_summary_activity_coalesced_replacements_total 1"))
                #expect(body.contains("im_domain_event_summary_activity_coalesced_flushes_total 1"))
                #expect(body.contains("im_domain_event_summary_activity_coalesced_flush_requests_total 3"))
                #expect(body.contains("im_domain_event_summary_activity_coalesced_flush_failures_total 1"))
                #expect(body.contains("im_domain_event_summary_activity_coalesced_flush_failure_requests_total 2"))
                #expect(body.contains("im_domain_event_summary_activity_coalesced_flush_latency_avg_millis 40"))
                #expect(body.contains("im_domain_event_summary_activity_coalesced_flush_latency_max_millis 50"))
                #expect(body.contains("im_domain_event_recipient_resolve_missing_snapshot_total 1"))
                #expect(body.contains("im_domain_event_recipient_snapshot_inline_stores_total 1"))
                #expect(body.contains("im_domain_event_recipient_snapshot_inline_store_recipients_total 10"))
                #expect(body.contains("im_domain_event_recipient_snapshot_deduplicated_stores_total 1"))
                #expect(body.contains("im_domain_event_recipient_snapshot_deduplicated_store_recipients_total 500"))
                #expect(body.contains("im_domain_event_recipient_snapshot_resolve_inline_total 1"))
                #expect(body.contains("im_domain_event_recipient_snapshot_resolve_shared_set_hits_total 1"))
                #expect(body.contains("im_domain_event_recipient_snapshot_resolve_shared_set_missing_total 1"))
                #expect(body.contains("im_domain_event_recipient_snapshot_resolve_recipients_total 510"))
                #expect(body.contains("im_domain_event_recipient_snapshot_resolve_latency_avg_millis 40"))
                #expect(body.contains("im_domain_event_recipient_snapshot_resolve_latency_max_millis 60"))
                #expect(body.contains("im_domain_event_recipient_snapshot_resolve_max_recipients 500"))
                #expect(body.contains("im_domain_event_recipient_set_cleanup_runs_total 1"))
                #expect(body.contains("im_domain_event_recipient_set_cleanup_scanned_total 12"))
                #expect(body.contains("im_domain_event_recipient_set_cleanup_deleted_total 3"))
                #expect(body.contains("im_domain_event_recipient_set_cleanup_max_deleted 3"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_writes_total 2"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_requests_total 7"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_inserted_rows_total 4"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_returned_rows_total 7"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_fallbacks_total 1"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_canonical_fast_paths_total 1"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_materialized_fast_paths_total 1"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_chunked_total 1"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_chunks_total 10"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_chunked_max_requests 10000"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_latency_avg_millis 100"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_latency_max_millis 120"))
                #expect(body.contains("im_domain_event_owner_delivery_batch_write_max_requests 5"))
                #expect(body.contains("im_summary_read_summary_total 1"))
                #expect(body.contains("im_summary_read_summary_errors_total 1"))
                #expect(body.contains("im_summary_read_summary_latency_avg_millis 50"))
                #expect(body.contains("im_summary_read_summary_latency_max_millis 60"))
                #expect(body.contains("im_summary_read_list_total 2"))
                #expect(body.contains("im_summary_read_list_errors_total 1"))
                #expect(body.contains("im_summary_read_list_joined_total 1"))
                #expect(body.contains("im_summary_read_list_fluent_total 1"))
                #expect(body.contains("im_summary_read_list_fallbacks_total 1"))
                #expect(body.contains("im_summary_read_list_items_total 5"))
                #expect(body.contains("im_summary_read_list_max_items 3"))
                #expect(body.contains("im_summary_read_list_latency_avg_millis 50"))
                #expect(body.contains("im_summary_read_list_latency_max_millis 70"))
                #expect(body.contains("im_summary_read_changes_total 2"))
                #expect(body.contains("im_summary_read_changes_errors_total 1"))
                #expect(body.contains("im_summary_read_changes_joined_total 1"))
                #expect(body.contains("im_summary_read_changes_fluent_total 1"))
                #expect(body.contains("im_summary_read_changes_fallbacks_total 1"))
                #expect(body.contains("im_summary_read_changes_upserts_total 3"))
                #expect(body.contains("im_summary_read_changes_removed_total 2"))
                #expect(body.contains("im_summary_read_changes_max_items 3"))
                #expect(body.contains("im_summary_read_changes_latency_avg_millis 46"))
                #expect(body.contains("im_summary_read_changes_latency_max_millis 80"))
                #expect(body.contains("im_gateway_http_relay_work_items_total 3"))
                #expect(body.contains("im_gateway_http_relay_payload_batches_total 2"))
                #expect(body.contains("im_gateway_http_relay_recipients_total 5"))
                #expect(body.contains("im_gateway_http_relay_skipped_recipients_total 1"))
                #expect(body.contains("im_gateway_http_relay_encoded_payload_bytes_total 512"))
                #expect(body.contains("im_gateway_http_relay_max_recipients_per_work_item 2"))
                #expect(body.contains("im_gateway_http_relay_request_attempts_total 2"))
                #expect(body.contains("im_gateway_http_relay_request_successes_total 1"))
                #expect(body.contains("im_gateway_http_relay_request_failures_total 1"))
                #expect(body.contains("im_gateway_http_relay_request_latency_millis_total 120"))
                #expect(body.contains("im_gateway_http_relay_request_latency_avg_millis 60"))
                #expect(body.contains("im_gateway_http_relay_request_latency_max_millis 80"))
                #expect(body.contains("im_gateway_http_relay_request_body_bytes_total 512"))
                #expect(body.contains("im_gateway_http_relay_request_max_body_bytes 384"))
                #expect(body.contains("im_gateway_http_relay_binary_fallbacks_total 1"))
                #expect(body.contains("im_gateway_http_relay_inbound_requests_total 2"))
                #expect(body.contains("im_gateway_http_relay_inbound_successes_total 1"))
                #expect(body.contains("im_gateway_http_relay_inbound_failures_total 1"))
                #expect(body.contains("im_gateway_http_relay_inbound_latency_millis_total 100"))
                #expect(body.contains("im_gateway_http_relay_inbound_body_bytes_total 384"))
                #expect(body.contains("im_gateway_http_relay_inbound_max_body_bytes 256"))
                #expect(body.contains("im_gateway_http_relay_inbound_latency_avg_millis 50"))
                #expect(body.contains("im_gateway_http_relay_inbound_latency_max_millis 70"))
                #expect(body.contains("im_realtime_payloads_built_total 3"))
                #expect(body.contains("im_realtime_payload_recipient_deliveries_total 9"))
                #expect(body.contains("im_realtime_payloads_with_conversation_summary_total 2"))
                #expect(body.contains("im_realtime_payload_summary_member_ids_omitted_total 1"))
                #expect(body.contains("im_realtime_payload_summary_member_ids_omitted_members_total 1000"))
                #expect(body.contains("im_realtime_payload_summary_member_ids_emitted_total 1"))
                #expect(body.contains("im_realtime_payload_summary_member_ids_emitted_members_total 3"))
                #expect(body.contains("im_realtime_inactive_conversation_hint_suppressed_recipients_total 6"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_total 1"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_active_recipients_total 2"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_compact_active_recipients_total 1"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_inactive_hint_recipients_total 3"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_downgraded_active_recipients_total 1"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_route_drops_total 1"))
                #expect(body.contains("im_domain_relay_after_record_inactive_hint_suppressed_recipients_total 4"))
                #expect(body.contains("im_domain_relay_after_record_active_route_cache_hits_total 1"))
                #expect(body.contains("im_domain_relay_after_record_active_route_cache_partial_hits_total 1"))
                #expect(body.contains("im_domain_relay_after_record_active_route_cache_misses_total 1"))
                #expect(body.contains("im_domain_relay_after_record_active_route_cache_cached_users_total 5"))
                #expect(body.contains("im_domain_relay_after_record_active_route_cache_missed_users_total 5"))
                #expect(body.contains("im_domain_relay_after_record_active_route_cache_joined_in_flight_total 1"))
                #expect(body.contains("im_realtime_active_conversation_route_cache_hits_total 1"))
                #expect(body.contains("im_realtime_active_conversation_route_cache_partial_hits_total 1"))
                #expect(body.contains("im_realtime_active_conversation_route_cache_misses_total 1"))
                #expect(body.contains("im_realtime_active_conversation_route_cache_cached_users_total 5"))
                #expect(body.contains("im_realtime_active_conversation_route_cache_missed_users_total 5"))
                #expect(body.contains("im_realtime_active_conversation_route_cache_joined_in_flight_total 1"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_max_active_recipients 2"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_max_compact_active_recipients 1"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_max_inactive_hint_recipients 3"))
                #expect(body.contains("im_domain_relay_after_record_pre_split_max_downgraded_active_recipients 1"))
                #expect(body.contains("im_redis_presence_active_conversation_node_index_lookups_total 1"))
                #expect(body.contains("im_redis_presence_active_conversation_node_index_lookup_nodes_total 2"))
                #expect(body.contains("im_realtime_async_relay_tasks_started_total 2"))
                #expect(body.contains("im_realtime_async_relay_tasks_completed_total 2"))
                #expect(body.contains("im_realtime_async_relay_in_flight 1"))
                #expect(body.contains("im_realtime_async_relay_max_in_flight 3"))
                #expect(body.contains("im_realtime_async_relay_task_start_lag_avg_millis 15"))
                #expect(body.contains("im_realtime_async_relay_task_start_lag_max_millis 20"))
                #expect(body.contains("im_realtime_async_relay_latency_avg_millis 80"))
                #expect(body.contains("im_realtime_async_relay_latency_max_millis 100"))
                #expect(body.contains("im_stream_processed_runs_total 1"))
                #expect(body.contains("im_stream_processed_runs_total{consumer_group=\"realtime-delivery-consumer\"} 1"))
                #expect(body.contains("im_stream_message_created_runs_total 1"))
                #expect(body.contains("im_stream_message_created_run_events_total 4"))
                #expect(body.contains("im_stream_message_created_run_events_total{consumer_group=\"realtime-delivery-consumer\"} 4"))
                #expect(body.contains("im_stream_message_created_run_events_avg 4"))
                #expect(body.contains("im_stream_message_created_run_max_events 4"))
                #expect(body.contains("im_stream_slow_processing_runs_total 0"))
                #expect(body.contains("im_stream_lagged_runs_total 1"))
                #expect(body.contains("im_stream_processing_batches_total 2"))
                #expect(body.contains("im_stream_processing_batches_total{consumer_group=\"realtime-delivery-consumer\"} 2"))
                #expect(body.contains("im_stream_processing_batch_events_total 7"))
                #expect(body.contains("im_stream_processing_batch_events_total{consumer_group=\"realtime-delivery-consumer\"} 7"))
                #expect(body.contains("im_stream_processing_batch_events_avg 3"))
                #expect(body.contains("im_stream_processing_batch_max_events 6"))
                #expect(body.contains("im_stream_batch_fill_waits_total 1"))
                #expect(body.contains("im_stream_batch_fill_waits_total{consumer_group=\"realtime-delivery-consumer\"} 1"))
                #expect(body.contains("im_stream_batch_fill_wait_millis_total 10"))
                #expect(body.contains("im_stream_batch_fill_wait_avg_millis 10"))
                #expect(body.contains("im_stream_batch_fill_events_total 2"))
                #expect(body.contains("im_stream_batch_fill_events_total{consumer_group=\"realtime-delivery-consumer\"} 2"))
                #expect(body.contains("im_stream_batch_fill_skipped_batches_total 1"))
                #expect(body.contains("im_stream_batch_fill_skipped_batches_total{consumer_group=\"realtime-delivery-consumer\"} 1"))
                #expect(body.contains("im_stream_queue_producer_waits_total 1"))
                #expect(body.contains("im_stream_queue_depth 7"))
                #expect(body.contains("im_stream_queue_depth{consumer_group=\"realtime-delivery-consumer\"} 7"))
                #expect(body.contains("im_stream_queue_max_depth 7"))
                #expect(body.contains("im_stream_run_events_total 4"))
                #expect(body.contains("im_stream_run_events_total{consumer_group=\"realtime-delivery-consumer\"} 4"))
                #expect(body.contains("im_stream_run_max_events 4"))
                #expect(body.contains("im_stream_run_processing_latency_avg_millis 25"))
                #expect(body.contains("im_stream_run_processing_latency_avg_millis{consumer_group=\"realtime-delivery-consumer\"} 25"))
                #expect(body.contains("im_stream_run_processing_latency_max_millis 25"))
                #expect(body.contains("im_stream_run_event_lag_avg_millis 150"))
                #expect(body.contains("im_stream_run_event_lag_max_millis 150"))
            })
        }
    }

    @Test("Stream metrics aggregate single events and messageCreated runs")
    func streamMetricsAggregateSingleEventsAndMessageCreatedRuns() async throws {
        let metrics = IMStreamMetrics()

        await metrics.recordRun(
            groupID: "summary-consumer",
            eventCount: 1,
            isMessageCreatedRun: false,
            durationMillis: 10,
            eventLagMillis: 100,
            slowThresholdMillis: 50
        )
        await metrics.recordRun(
            groupID: "realtime-delivery-consumer",
            eventCount: 4,
            isMessageCreatedRun: true,
            durationMillis: 30,
            eventLagMillis: 300,
            slowThresholdMillis: 20
        )
        await metrics.recordQueueDepth(groupID: "realtime-delivery-consumer", depth: 3, revision: 3)
        await metrics.recordQueueDepth(groupID: "realtime-delivery-consumer", depth: 1, revision: 4)
        await metrics.recordQueueDepth(groupID: "realtime-delivery-consumer", depth: 9, revision: 2)
        await metrics.recordQueueProducerWait(groupID: "realtime-delivery-consumer")
        await metrics.recordProcessingBatch(
            groupID: "realtime-delivery-consumer",
            eventCount: 6,
            batchFillWaitMillis: 10,
            batchFillEventCount: 2
        )
        await metrics.recordProcessingBatch(
            groupID: "summary-consumer",
            eventCount: 2,
            batchFillWaitMillis: 0,
            batchFillEventCount: 0,
            batchFillSkipped: true
        )
        await metrics.recordQueueDepth(groupID: "summary-consumer", depth: 2, revision: 1)

        let snapshot = await metrics.currentSnapshot()
        let groupSnapshots = await metrics.currentGroupSnapshots()
        let groupsByID = Dictionary(uniqueKeysWithValues: groupSnapshots.map { ($0.groupID, $0.snapshot) })
        let realtimeGroup = try #require(groupsByID["realtime-delivery-consumer"])
        let summaryGroup = try #require(groupsByID["summary-consumer"])
        #expect(snapshot.processedRuns == 2)
        #expect(snapshot.messageCreatedRuns == 1)
        #expect(snapshot.messageCreatedRunEventCount == 4)
        #expect(snapshot.averageMessageCreatedRunEventCount == 4)
        #expect(snapshot.maxMessageCreatedRunEventCount == 4)
        #expect(snapshot.runEventCount == 5)
        #expect(snapshot.maxRunEventCount == 4)
        #expect(snapshot.averageRunProcessingMillis == 20)
        #expect(snapshot.maxRunProcessingMillis == 30)
        #expect(snapshot.averageRunEventLagMillis == 200)
        #expect(snapshot.maxRunEventLagMillis == 300)
        #expect(snapshot.slowProcessingRuns == 1)
        #expect(snapshot.laggedRuns == 2)
        #expect(snapshot.processingBatches == 2)
        #expect(snapshot.processingBatchEventCount == 8)
        #expect(snapshot.averageProcessingBatchEventCount == 4)
        #expect(snapshot.maxProcessingBatchEventCount == 6)
        #expect(snapshot.batchFillWaits == 1)
        #expect(snapshot.batchFillWaitMillis == 10)
        #expect(snapshot.averageBatchFillWaitMillis == 10)
        #expect(snapshot.batchFillEventCount == 2)
        #expect(snapshot.batchFillSkippedBatches == 1)
        #expect(snapshot.queueCurrentDepth == 3)
        #expect(snapshot.queueMaxDepth == 3)
        #expect(snapshot.queueDepthRevision == 4)
        #expect(snapshot.queueProducerWaits == 1)
        #expect(snapshot.lastConsumerGroupID == "summary-consumer")
        #expect(realtimeGroup.processedRuns == 1)
        #expect(realtimeGroup.messageCreatedRuns == 1)
        #expect(realtimeGroup.messageCreatedRunEventCount == 4)
        #expect(realtimeGroup.averageMessageCreatedRunEventCount == 4)
        #expect(realtimeGroup.maxMessageCreatedRunEventCount == 4)
        #expect(realtimeGroup.queueCurrentDepth == 1)
        #expect(realtimeGroup.queueMaxDepth == 3)
        #expect(realtimeGroup.queueDepthRevision == 4)
        #expect(realtimeGroup.queueProducerWaits == 1)
        #expect(realtimeGroup.processingBatches == 1)
        #expect(realtimeGroup.processingBatchEventCount == 6)
        #expect(realtimeGroup.averageProcessingBatchEventCount == 6)
        #expect(realtimeGroup.maxProcessingBatchEventCount == 6)
        #expect(realtimeGroup.batchFillWaits == 1)
        #expect(realtimeGroup.batchFillWaitMillis == 10)
        #expect(realtimeGroup.averageBatchFillWaitMillis == 10)
        #expect(realtimeGroup.batchFillEventCount == 2)
        #expect(realtimeGroup.batchFillSkippedBatches == 0)
        #expect(summaryGroup.processedRuns == 1)
        #expect(summaryGroup.messageCreatedRuns == 0)
        #expect(summaryGroup.messageCreatedRunEventCount == 0)
        #expect(summaryGroup.averageMessageCreatedRunEventCount == 0)
        #expect(summaryGroup.maxMessageCreatedRunEventCount == 0)
        #expect(summaryGroup.queueCurrentDepth == 2)
        #expect(summaryGroup.queueMaxDepth == 2)
        #expect(summaryGroup.queueDepthRevision == 1)
        #expect(summaryGroup.queueProducerWaits == 0)
        #expect(summaryGroup.processingBatches == 1)
        #expect(summaryGroup.processingBatchEventCount == 2)
        #expect(summaryGroup.averageProcessingBatchEventCount == 2)
        #expect(summaryGroup.maxProcessingBatchEventCount == 2)
        #expect(summaryGroup.batchFillWaits == 0)
        #expect(summaryGroup.batchFillWaitMillis == 0)
        #expect(summaryGroup.averageBatchFillWaitMillis == 0)
        #expect(summaryGroup.batchFillEventCount == 0)
        #expect(summaryGroup.batchFillSkippedBatches == 1)
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
        setenv("DATABASE_PRIMARY_PASSWORD", "database-0123456789abcdef", 1)
        try IMProductionRuntimeValidationSupport.validatePrimaryDatabaseConfiguration()
    }

    @Test("Production rejects weak primary database password")
    func productionRejectsWeakPrimaryDatabasePassword() throws {
        let keys = [
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

        setenv("DATABASE_PRIMARY_HOST", "db.internal", 1)
        setenv("DATABASE_PRIMARY_NAME", "imserver", 1)
        setenv("DATABASE_PRIMARY_USERNAME", "imserver", 1)
        setenv("DATABASE_PRIMARY_PASSWORD", "password1234", 1)

        do {
            try IMProductionRuntimeValidationSupport.validatePrimaryDatabaseConfiguration()
            Issue.record("Expected weak production database password to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("DATABASE_PRIMARY_PASSWORD"))
        } catch {
            Issue.record("Unexpected database secret validation error: \(error)")
        }
    }

    @Test("Production rejects development seed user configuration")
    func productionRejectsDevelopmentSeedUserConfiguration() throws {
        let keys = [
            "SEED_USER_EMAIL",
            "SEED_USER_EMAILS",
            "SEED_USER_PASSWORD"
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

        try IMProductionRuntimeValidationSupport.validateDevelopmentSeedConfigurationDisabled()

        setenv("SEED_USER_EMAIL", "demo@example.com", 1)
        do {
            try IMProductionRuntimeValidationSupport.validateDevelopmentSeedConfigurationDisabled()
            Issue.record("Expected production seed user configuration to fail")
        } catch let abort as any AbortError {
            #expect(abort.status == .internalServerError)
            #expect(abort.reason.contains("development seed user configuration"))
            #expect(abort.reason.contains("SEED_USER_EMAIL"))
        } catch {
            Issue.record("Unexpected seed user configuration error: \(error)")
        }
    }

    @Test("Production runtime rejects placeholder shared secrets")
    func productionRuntimeRejectsPlaceholderSharedSecrets() async throws {
        try await withProductionRuntimeEnvironment {
            setenv("JWT_SECRETS", "active:0123456789abcdef0123456789abcdef", 1)
            setenv("IM_INTERNAL_SHARED_SECRET", "change_me", 1)

            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime to reject placeholder secrets")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(
                    abort.reason.contains("JWT_SECRETS")
                    || abort.reason.contains("IM_INTERNAL_SHARED_SECRET")
                )
            } catch {
                Issue.record("Unexpected production secret validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
    }

    @Test("Production runtime requires public HTTPS base URL")
    func productionRuntimeRequiresPublicHTTPSBaseURL() async throws {
        try await withProductionRuntimeEnvironment {
            unsetenv("PUBLIC_BASE_URL")
            unsetenv("IM_PUBLIC_BASE_URL")

            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime to reject missing public base URL")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("PUBLIC_BASE_URL"))
            } catch {
                Issue.record("Unexpected public base URL validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }

        try await withProductionRuntimeEnvironment {
            setenv("PUBLIC_BASE_URL", "http://chat.myim-prod.com", 1)

            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime to reject insecure public base URL")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("https"))
            } catch {
                Issue.record("Unexpected public base URL validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }

        try await withProductionRuntimeEnvironment {
            setenv("PUBLIC_BASE_URL", "https://127.0.0.1", 1)

            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime to reject local public base URL")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("real public DNS"))
            } catch {
                Issue.record("Unexpected public base URL validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }

        try await withProductionRuntimeEnvironment {
            setenv("PUBLIC_BASE_URL", "https://chat.yourdomain.com", 1)

            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime to reject placeholder public base URL")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("placeholder domain"))
            } catch {
                Issue.record("Unexpected public base URL validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }

        try await withProductionRuntimeEnvironment {
            setenv("PUBLIC_BASE_URL", "https://chat.myim-prod.com:8443", 1)

            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime to reject non-default public base URL port")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("443"))
            } catch {
                Issue.record("Unexpected public base URL validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }

        try await withProductionRuntimeEnvironment {
            setenv("PUBLIC_BASE_URL", "https://chat.myim-prod.com", 1)
            setenv("IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL", "true", 1)

            let app = try await productionRuntimeValidationApp(role: .queryAPI)
            do {
                try IMProductionRuntimeValidator.validate(app: app)
                Issue.record("Expected production runtime to reject insecure public base URL override")
            } catch let abort as any AbortError {
                #expect(abort.status == .internalServerError)
                #expect(abort.reason.contains("IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL"))
            } catch {
                Issue.record("Unexpected public base URL validation error: \(error)")
            }
            try? await app.asyncShutdown()
        }
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

    @Test("Gateway command bridge forwards command receipt negotiation")
    func gatewayCommandBridgeForwardsCommandReceiptAcceptHeader() async throws {
        try await withApp(configure: configure) { app in
            let request = Request(application: app, on: app.eventLoopGroup.next())
            request.headers.replaceOrAdd(
                name: .accept,
                value: IMConversationController.commandReceiptMediaType
            )

            let forwarded = GatewayCommandBridgeController.forwardedHeaders(
                from: request,
                sharedSecret: "bridge-test-secret"
            )

            #expect(forwarded.first(name: .accept) == IMConversationController.commandReceiptMediaType)
            #expect(forwarded.first(name: "X-IM-Internal-Secret") == "bridge-test-secret")
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

    @Test("TCP configuration loads realtime drop-on-backpressure setting")
    func tcpConfigurationLoadsRealtimeDropOnBackpressureSetting() {
        let key = "IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE"
        let originalValue = Environment.get(key)
        defer {
            restoreEnvironment(key, to: originalValue)
        }

        setenv(key, "false", 1)
        var configuration = IMTCPConfiguration.load(from: .production)
        #expect(configuration.dropsRealtimeWhenNotWritable == false)

        setenv(key, "true", 1)
        configuration = IMTCPConfiguration.load(from: .production)
        #expect(configuration.dropsRealtimeWhenNotWritable == true)
    }

    @Test("TCP configuration bounds Gateway shutdown drain grace")
    func tcpConfigurationBoundsShutdownDrainGrace() {
        let key = "IM_TCP_SHUTDOWN_DRAIN_GRACE_SECONDS"
        let originalValue = Environment.get(key)
        defer {
            restoreEnvironment(key, to: originalValue)
        }

        setenv(key, "3.5", 1)
        #expect(IMTCPConfiguration.load(from: .production).shutdownDrainGraceSeconds == 3.5)

        setenv(key, "99", 1)
        #expect(IMTCPConfiguration.load(from: .production).shutdownDrainGraceSeconds == 15)
    }

    @Test("TCP lifecycle drains admission before closing its listener")
    func tcpLifecycleDrainsAdmissionBeforeClosingListener() async throws {
        let values = [
            "IM_TCP_ENABLED": "true",
            "IM_TCP_HOST": "127.0.0.1",
            "IM_TCP_PORT": "0",
            "IM_TCP_SHUTDOWN_DRAIN_GRACE_SECONDS": "0"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }
        for (key, value) in values {
            setenv(key, value, 1)
        }

        let app = try await Application.make(.testing)
        app.imTCPConfiguration = IMTCPConfiguration.load(from: .testing)
        let lifecycle = IMTCPServerLifecycle()
        do {
            try await lifecycle.didBootAsync(app)
            #expect(!app.imTCPAdmissionController.status().isDraining)

            await lifecycle.shutdownAsync(app)

            #expect(app.imTCPAdmissionController.status().isDraining)
            let decision = app.imTCPAdmissionController.acquire()
            #expect(decision.isAccepted == false)
            #expect(decision.rejectionReason == .gatewayDraining)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test("Maintenance configuration is explicit and disabled by default")
    func maintenanceConfigurationIsExplicitAndDisabledByDefault() {
        let key = "IM_MAINTENANCE_ENABLED"
        let originalValue = Environment.get(key)
        defer {
            restoreEnvironment(key, to: originalValue)
        }

        unsetenv(key)
        #expect(IMMaintenanceConfiguration.load().enabled == false)

        setenv(key, "true", 1)
        #expect(IMMaintenanceConfiguration.load().enabled == true)
    }

    @Test("TCP configuration and admission controller enforce a bounded Gateway connection budget")
    func tcpConfigurationAndAdmissionControllerEnforceConnectionBudget() {
        let values = [
            "IM_TCP_MAX_CONNECTIONS": "2",
            "IM_TCP_MAX_NEW_CONNECTIONS_PER_SECOND": "3"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        for (key, value) in values {
            setenv(key, value, 1)
        }
        let configuration = IMTCPConfiguration.load(from: .production)
        #expect(configuration.maximumConnectionCount == 2)
        #expect(configuration.maximumNewConnectionsPerSecond == 3)

        let controller = IMTCPAdmissionController(maximumConnectionCount: 2)
        #expect(controller.acquire() == .init(isAccepted: true, activeConnectionCount: 1, maximumConnectionCount: 2, rejectionReason: nil))
        #expect(controller.acquire() == .init(isAccepted: true, activeConnectionCount: 2, maximumConnectionCount: 2, rejectionReason: nil))
        #expect(controller.acquire() == .init(isAccepted: false, activeConnectionCount: 2, maximumConnectionCount: 2, rejectionReason: .connectionLimit))
        #expect(controller.release() == 1)
        #expect(controller.acquire() == .init(isAccepted: true, activeConnectionCount: 2, maximumConnectionCount: 2, rejectionReason: nil))

        let rateLimited = IMTCPAdmissionController(
            maximumConnectionCount: 0,
            maximumNewConnectionsPerSecond: 2
        )
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(rateLimited.acquire(now: start).isAccepted)
        #expect(rateLimited.acquire(now: start.addingTimeInterval(0.5)).isAccepted)
        #expect(
            rateLimited.acquire(now: start.addingTimeInterval(0.9))
                == .init(
                    isAccepted: false,
                    activeConnectionCount: 2,
                    maximumConnectionCount: 0,
                    rejectionReason: .connectionRateLimit
                )
        )
        #expect(rateLimited.acquire(now: start.addingTimeInterval(1)).isAccepted)

        let draining = IMTCPAdmissionController(maximumConnectionCount: 2)
        #expect(draining.acquire().isAccepted)
        #expect(
            draining.setDraining(true)
                == .init(isDraining: true, activeConnectionCount: 1, maximumConnectionCount: 2)
        )
        #expect(
            draining.acquire().rejectionReason == .gatewayDraining
        )
        #expect(draining.setDraining(false).isDraining == false)
        #expect(draining.acquire().isAccepted)
    }

    @Test("Gateway relay configuration loads body limits")
    func gatewayRelayConfigurationLoadsBodyLimits() {
        let values = [
            "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_MAX_BODY_BYTES": "131072",
            "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES": "262144",
            "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKETS_MAX_BODY_BYTES": "65536"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: values.keys.map { ($0, Environment.get($0)) })
        defer {
            for (key, value) in originalValues {
                restoreEnvironment(key, to: value)
            }
        }

        for (key, value) in values {
            setenv(key, value, 1)
        }

        let configuration = IMGatewayRelayConfiguration.load(from: .production)
        #expect(configuration.domainEventPacketMaxBodyBytes == 131_072)
        #expect(configuration.domainEventPacketBinaryMaxBodyBytes == 262_144)
        #expect(configuration.domainEventPacketsMaxBodyBytes == 65_536)
        #expect(configuration.domainEventPacketMaxBodySize.value == 131_072)
        #expect(configuration.domainEventPacketBinaryMaxBodySize.value == 262_144)
        #expect(configuration.domainEventPacketsMaxBodySize.value == 65_536)
    }


}

private func withProductionRuntimeEnvironment(_ body: () async throws -> Void) async throws {
    let values = [
        "IM_NODE_ID": "node-a",
        "IM_REALTIME_CELL_ID": "cell-a",
        "PUBLIC_BASE_URL": "https://chat.myim-prod.com",
        "IM_PUBLIC_BASE_URL": "",
        "IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL": "",
        "JWT_SECRET": "",
        "JWT_SECRETS": "active:0123456789abcdef0123456789abcdef",
        "JWT_ACTIVE_KID": "active",
        "IM_ROUTING_MODE": "redis",
        "REDIS_URL": "redis://redis.internal:6379",
        "IM_REDIS_MAX_CONNECTIONS": "16",
        "IM_ALLOW_BEST_EFFORT_NODE_DISPATCH": "true",
        "IM_COMMAND_API_INTERNAL_BASE_URL": "http://command.internal",
        "IM_GATEWAY_RELAY_MODE": "http",
        "IM_GATEWAY_INTERNAL_BASE_URL": "http://gateway.internal",
        "IM_INTERNAL_SHARED_SECRET": "fedcba9876543210fedcba9876543210",
        "IM_GATEWAY_RELAY_DOMAIN_EVENT_PACKET_BIN_MAX_BODY_BYTES": "262144",
        "IM_TCP_REQUIRES_TLS_TERMINATION": "true",
        "IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE": "true",
        "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED": "true",
        "IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD": "500",
        "IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD": "500",
        "IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS": "500",
        "IM_DOMAIN_DELIVERY_SKIP_MESSAGE_CREATED_OWNER_DELIVERY": "false",
        "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE": "timeline-pull",
        "IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD": "500",
        "IM_NOTIFICATION_SKIP_MESSAGE_CREATED_OWNER_NOTIFICATIONS": "false",
        "IM_NOTIFICATION_MESSAGE_CREATED_OWNER_NOTIFICATION_SKIP_RECIPIENT_THRESHOLD": "500",
        "IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED": "true",
        "IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD": "500",
        "IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED": "false",
        "IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS": "1000",
        "IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS": "1000",
        "IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS": "25",
        "IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS": "120",
        "IM_STREAM_CONSUMER_REQUIRE_MESSAGE_CREATED_RECIPIENT_SNAPSHOT": "true",
        "IM_EVENT_STREAM_DRIVER": "kafka",
        "IM_KAFKA_BROKERS": "kafka-a:9092",
        "IM_KAFKA_TOPIC": "conversation-domain-events",
        "IM_KAFKA_DEAD_LETTER_TOPIC": "conversation-domain-events-dead-letter",
        "IM_KAFKA_CLIENT_ID": "imserver-test",
        "IM_KAFKA_REQUIRED_ACKS": "all",
        "IM_KAFKA_AUTO_CREATE_TOPICS": "false",
        "IM_KAFKA_SECURITY_PROTOCOL": "sasl_tls",
        "IM_KAFKA_SASL_MECHANISM": "scram-sha-512",
        "IM_KAFKA_SASL_USERNAME": "im-user",
        "IM_KAFKA_SASL_PASSWORD": "kafka-0123456789abcdef",
        "IM_KAFKA_TLS_CA_FILE": "/tmp/im-ca.pem",
        "IM_SUMMARY_PROJECTION_WRITE_MODE": "sharded",
        "IM_SUMMARY_QUERY_READ_SOURCE": "sharded",
        "IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT": "500",
        "IM_SEARCH_DRIVER": "opensearch",
        "IM_OPENSEARCH_ENDPOINT": "https://opensearch.internal",
        "IM_STREAM_CONSUMER_GROUPS": "summary-projection-consumer",
        "IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS": "10",
        "IM_HOT_CONVERSATION_MSG_PER_SECOND_LIMIT": "100",
        "IM_SEQUENCE_ALLOCATION_MODE": "block",
        "IM_SEQUENCE_BLOCK_SIZE": "256",
        "IM_GROUP_MEMBER_LIMIT": "1000",
        "IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS": "5000",
        "IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_PAGES": "50",
        "IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS": "250",
        "IM_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES": "4096",
        "IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS": "2000",
        "IM_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS": "1024",
        "IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION": "512",
        "IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS": "5",
        "IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE": "redis",
        "IM_MESSAGE_WRITE_BATCH_ENABLED": "true",
        "IM_MESSAGE_WRITE_BATCH_MAX_SIZE": "32",
        "IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD": "500",
        "IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD": "500",
        "IM_MESSAGE_WRITE_BATCH_MAX_DELAY_MS": "10",
        "IM_COMMAND_NODE_ID": "command-a",
        "IM_COMMAND_NODE_URLS": "command-a=http://command-a.internal,command-b=http://command-b.internal",
        "MEDIA_STORAGE_PROVIDER": "s3compatible",
        "MEDIA_STORAGE_S3_ENDPOINT": "https://s3.internal",
        "MEDIA_STORAGE_S3_BUCKET": "im-media",
        "MEDIA_STORAGE_S3_ACCESS_KEY_ID": "AKIA0123456789ABCDEF",
        "MEDIA_STORAGE_S3_SECRET_ACCESS_KEY": "s3-0123456789abcdef0123456789abcdef",
        "MEDIA_STORAGE_S3_REGION": "cn-shenzhen",
        "MEDIA_STORAGE_S3_FORCE_PATH_STYLE": "true",
        "IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT": "",
        "DATABASE_PRIMARY_HOST": "primary-db",
        "DATABASE_PRIMARY_NAME": "imserver",
        "DATABASE_PRIMARY_USERNAME": "imserver",
        "DATABASE_PRIMARY_PASSWORD": "database-0123456789abcdef",
        "IM_SUMMARY_SHARD_IDS": "summary-0",
        "DATABASE_SUMMARY_SUMMARY_0_HOST": "summary-db",
        "DATABASE_SUMMARY_SUMMARY_0_NAME": "imserver_summary",
        "DATABASE_SUMMARY_SUMMARY_0_USERNAME": "imserver",
        "DATABASE_SUMMARY_SUMMARY_0_PASSWORD": "database-0123456789abcdef"
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

private actor ActiveConversationRouteLoadCounter {
    private(set) var startCount = 0
    private(set) var loadedUserIDs: [UUID] = []

    func recordStart(missingUserIDs: [UUID]) {
        startCount += 1
        loadedUserIDs = missingUserIDs
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
    app.gatewayLocalFanoutConfiguration = IMGatewayLocalFanoutConfiguration.load()
    IMDatabaseConfigurator.configureDatabases(app)
    return app
}

private struct FixedSummaryShardRouter: SummaryShardRouter {
    let shardID: String
    let fixedDatabase: any Database

    var routerName: String { "fixed-summary-shard-test" }
    var shardIDs: [String] { [shardID] }

    func shardID(forOwnerUserID userID: UUID) -> String {
        shardID
    }

    func database(forShardID shardID: String) -> any Database {
        fixedDatabase
    }

    func database(forOwnerUserID userID: UUID) -> any Database {
        fixedDatabase
    }
}

private func prepareSummaryReadModelSchema(on database: any Database) async throws {
    try await CreateConversationUserSummary().prepare(on: database)
    try await AddConversationUserSummaryGroupLifecycleState().prepare(on: database)
    try await AddConversationUserSummaryMembershipRevision().prepare(on: database)
    try await AddConversationUserSummaryDirectPeerProfileFields().prepare(on: database)
    try await AddConversationUserSummaryIndexes().prepare(on: database)
    try await AddConversationUserSummaryListOrderIndex().prepare(on: database)
    try await CreateConversationSummaryReadModelTables().prepare(on: database)
    try await AddConversationSummaryReadModelIndexes().prepare(on: database)
    try await CreateConversationActivitySummaryReadModel().prepare(on: database)
    try await AddLargeGroupSummaryReadPathIndexes().prepare(on: database)
}
