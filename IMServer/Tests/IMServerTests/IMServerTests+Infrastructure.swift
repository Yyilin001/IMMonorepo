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

    @Test("Testing environment uses local routing by default")
    func testingUsesLocalRoutingBackendByDefault() async throws {
        try await withApp(configure: configure) { app in
            #expect(app.connectionRoutingService.routeBackendName == "local")
        }
    }

    @Test("Testing environment falls back to local routing when Redis backend is unavailable")
    func testingFallsBackToLocalRoutingWhenRedisBackendUnavailable() async throws {
        try await withApp(configure: { app in
            app.imRedisRoutingConfigurationOverride = IMRedisRoutingConfiguration(
                url: "://bad-redis-url",
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

    @Test("Production summary read model store resolves to owner-sharded store")
    func productionSummaryReadModelStoreUsesShardedStore() async throws {
        let app = try await Application.make(.production)

        app.summaryReadModelConfiguration = IMSummaryReadModelConfiguration(
            projectionWriteMode: .legacy,
            queryReadSource: .legacy
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

        if let adapter = app.conversationSearchAdapter as? OpenSearchConversationSearchAdapter {
            #expect(adapter.fallback == nil)
        } else {
            Issue.record("Expected production search adapter to resolve to OpenSearchConversationSearchAdapter")
        }
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

    @Test("Internal metrics endpoint returns Prometheus text only when enabled")
    func internalMetricsEndpointHonorsConfiguration() async throws {
        try await withApp(configure: configure) { app in
            app.metricsConfiguration = IMMetricsConfiguration(isEnabled: true)
            try await app.testing().test(.GET, "internal/metrics", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.type == "text")
                #expect(res.body.string.contains("im_tcp_connections"))
                #expect(res.body.string.contains("im_outbox_backlog_events"))
            })

            app.metricsConfiguration = IMMetricsConfiguration(isEnabled: false)
            try await app.testing().test(.GET, "internal/metrics", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
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
