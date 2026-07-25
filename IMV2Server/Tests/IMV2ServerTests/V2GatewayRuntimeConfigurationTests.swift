import Foundation
@testable import IMV2Server
import Testing

struct V2GatewayRuntimeConfigurationTests {
    @Test("runtime has no secret or capacity defaults")
    func rejectsMissingConfiguration() {
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_DATABASE_URL")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment([:]))
        }
    }

    @Test("runtime requires an explicit protobuf nesting limit")
    func rejectsMissingProtobufNestingLimit() {
        var values = runtimeValues
        values.removeValue(forKey: "IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("runtime parses a complete explicit deployment configuration")
    func parsesCompleteConfiguration() throws {
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(runtimeValues))
        #expect(configuration.tls.port == 7443)
        #expect(configuration.frameLimits.maximumPayloadBytes == 65_536)
        #expect(configuration.maximumProtobufMessageDepth == 32)
        #expect(configuration.capacityProfile.id == "standard")
        #expect(configuration.capacityProfile.limits.maxEligibleMembers == 100_000)
        #expect(configuration.workerBatchSize == 256)
        #expect(configuration.workerPollIntervalMilliseconds == 100)
        #expect(configuration.durableRetryPolicy.initialDelay == 1)
        #expect(configuration.durableRetryPolicy.maximumDelay == 60)
        #expect(configuration.durableRetryPolicy.maximumAttempts == 10)
        #expect(configuration.durableRetryPolicy.jitterFraction == 0.2)
        #expect(configuration.maintenancePollIntervalMilliseconds == 60_000)
        #expect(configuration.mediaWithdrawnRetentionSeconds == 2_592_000)
        let expectedMetrics = try V2MetricsListenerConfiguration(host: "127.0.0.1", port: 9464)
        #expect(configuration.metrics == expectedMetrics)
        #expect(configuration.idleTimeoutMilliseconds == 60_000)
        #expect(configuration.gatewayNodeID == "gateway-a")
        #expect(configuration.userShardRoute.bucket == "users-primary")
        #expect(configuration.userShardRoute.observedRouterEpoch == 7)
        #expect(configuration.userShardStorage == [try .init(bucket: "users-primary", databaseURL: "postgres://v2:password@db/im_v2")])
        #expect(configuration.directRoomShardID == "rooms-primary")
        #expect(configuration.groupRoomShardID == "rooms-primary")
        #expect(configuration.strangerMessagePolicy.maximumMessagesPerWindow == 3)
        #expect(configuration.strangerMessagePolicy.window == 86_400)
        guard case .durablePollingOnly = configuration.fanoutHint else {
            Issue.record("Expected durable polling without NATS configuration")
            return
        }
    }

    @Test("NATS hint requires both endpoint and subject")
    func parsesAndValidatesNATSHintConfiguration() throws {
        var values = runtimeValues
        values["IM_V2_NATS_URL"] = "nats://nats.internal:4222"
        values["IM_V2_NATS_SUBJECT"] = "imv2.fanout.wake"
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        guard case .nats(let nats) = configuration.fanoutHint else {
            Issue.record("Expected NATS hint")
            return
        }
        #expect(nats.subject == "imv2.fanout.wake")
        values.removeValue(forKey: "IM_V2_NATS_SUBJECT")
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_NATS_URL/IM_V2_NATS_SUBJECT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("runtime requires an explicit versioned user-shard route")
    func rejectsMissingOrNegativeUserShardRoute() {
        var missingBucket = runtimeValues
        missingBucket.removeValue(forKey: "IM_V2_USER_SHARD_BUCKET")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_USER_SHARD_BUCKET")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missingBucket))
        }
        var negativeEpoch = runtimeValues
        negativeEpoch["IM_V2_USER_SHARD_ROUTER_EPOCH"] = "-1"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_ROUTER_EPOCH")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(negativeEpoch))
        }
    }

    @Test("runtime bounds the durable gateway node identifier")
    func rejectsInvalidGatewayNodeID() {
        var invalidCharacter = runtimeValues
        invalidCharacter["IM_V2_GATEWAY_NODE_ID"] = "gateway/a"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GATEWAY_NODE_ID")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidCharacter))
        }

        var overlong = runtimeValues
        overlong["IM_V2_GATEWAY_NODE_ID"] = String(repeating: "a", count: 129)
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GATEWAY_NODE_ID")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(overlong))
        }
    }

    @Test("runtime validates an explicit logical-bucket storage registry")
    func parsesAndRejectsInvalidUserShardStorageRegistry() throws {
        var values = runtimeValues
        values["IM_V2_USER_SHARD_STORES_JSON"] = """
        [{"bucket":"users-primary","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"},
         {"bucket":"users-next","database_url":"postgres://v2:password@db-next/im_v2","schema":"im_v2"}]
        """
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        #expect(configuration.userShardStorage.map(\.bucket) == ["users-primary", "users-next"])

        values["IM_V2_USER_SHARD_STORES_JSON"] = "[{\"bucket\":\"users-next\",\"database_url\":\"postgres://v2:password@db-next/im_v2\",\"schema\":\"im_v2\"}]"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }

        values["IM_V2_USER_SHARD_STORES_JSON"] = "[{\"bucket\":\"users-primary\",\"database_url\":\"postgres://v2:password@db/im_v2\",\"schema\":\"im_v2\"},{\"bucket\":\"users-next\",\"database_url\":\"postgres://v2:password@db/im_v2\",\"schema\":\"im_v2\"}]"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("APNs mode requires explicit provider and endpoint secrets")
    func rejectsIncompleteAPNSConfiguration() {
        var values = runtimeValues
        values["IM_V2_PUSH_PROVIDER"] = "apns"
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    @Test("APNs mode parses explicit provider configuration")
    func parsesAPNSConfiguration() throws {
        var values = runtimeValues
        values["IM_V2_PUSH_PROVIDER"] = "apns"
        values["IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64"] = Data(repeating: 1, count: 32).base64EncodedString()
        values["IM_V2_APNS_TEAM_ID"] = "TEAM123"
        values["IM_V2_APNS_KEY_ID"] = "KEY123"
        values["IM_V2_APNS_PRIVATE_KEY_RAW_BASE64"] = Data(repeating: 2, count: 32).base64EncodedString()
        values["IM_V2_APNS_TOPIC"] = "com.example.im"
        let configuration = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        guard case .apns(let apns) = configuration.push else {
            Issue.record("Expected APNs configuration")
            return
        }
        #expect(apns.topic == "com.example.im")
    }

    @Test("metrics listener requires an explicit loopback-only address")
    func rejectsPublicMetricsAddress() {
        var publicAddress = runtimeValues
        publicAddress["IM_V2_METRICS_HOST"] = "0.0.0.0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_METRICS_HOST/IM_V2_METRICS_PORT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(publicAddress))
        }
    }

    @Test("runtime rejects an invalid durable retry budget")
    func rejectsInvalidDurableRetryBudget() {
        var values = runtimeValues
        values["IM_V2_DURABLE_RETRY_MAX_DELAY_MS"] = "999"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DURABLE_RETRY_MAX_DELAY_MS")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }

        values = runtimeValues
        values["IM_V2_DURABLE_RETRY_JITTER_PERCENT"] = "101"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DURABLE_RETRY_JITTER_PERCENT")) {
            _ = try V2GatewayRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        }
    }

    private var runtimeValues: [String: String] {
        [
            "IM_V2_DATABASE_URL": "postgres://v2:password@db/im_v2",
            "IM_V2_TLS_HOST": "0.0.0.0",
            "IM_V2_TLS_PORT": "7443",
            "IM_V2_TLS_CERTIFICATE_CHAIN_PATH": "/run/secrets/tls-chain.pem",
            "IM_V2_TLS_PRIVATE_KEY_PATH": "/run/secrets/tls-key.pem",
            "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64": Data(repeating: 3, count: 32).base64EncodedString(),
            "IM_V2_CAPABILITY_PROFILE": "base",
            "IM_V2_MAX_MESSAGE_UTF8_BYTES": "4096",
            "IM_V2_MAX_FRAME_BYTES": "65536",
            "IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH": "32",
            "IM_V2_MAX_IN_FLIGHT_REQUESTS": "32",
            "IM_V2_MAX_QUEUED_INBOUND_BYTES": "262144",
            "IM_V2_IDLE_TIMEOUT_MS": "60000",
            "IM_V2_WORKER_BATCH_SIZE": "256",
            "IM_V2_WORKER_POLL_INTERVAL_MS": "100",
            "IM_V2_DURABLE_RETRY_INITIAL_DELAY_MS": "1000",
            "IM_V2_DURABLE_RETRY_MAX_DELAY_MS": "60000",
            "IM_V2_DURABLE_RETRY_MAX_ATTEMPTS": "10",
            "IM_V2_DURABLE_RETRY_JITTER_PERCENT": "20",
            "IM_V2_MAINTENANCE_POLL_INTERVAL_MS": "60000",
            "IM_V2_MEDIA_WITHDRAWN_RETENTION_SECONDS": "2592000",
            "IM_V2_METRICS_HOST": "127.0.0.1",
            "IM_V2_METRICS_PORT": "9464",
            "IM_V2_GATEWAY_NODE_ID": "gateway-a",
            "IM_V2_USER_SHARD_BUCKET": "users-primary",
            "IM_V2_USER_SHARD_ROUTER_EPOCH": "7",
            "IM_V2_DIRECT_ROOM_SHARD_ID": "rooms-primary",
            "IM_V2_GROUP_ROOM_SHARD_ID": "rooms-primary",
            "IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW": "3",
            "IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS": "86400",
            "IM_V2_CAPACITY_PROFILE_ID": "standard",
            "IM_V2_MAX_ELIGIBLE_MEMBERS": "100000",
            "IM_V2_MAX_COMMANDS_PER_WINDOW": "1000",
            "IM_V2_MAX_FANOUT_UNITS_PER_WINDOW": "100000",
            "IM_V2_MAX_OUTSTANDING_FANOUT_UNITS": "1000000",
            "IM_V2_MAX_OUTSTANDING_PLANS": "10000",
            "IM_V2_MAX_ENUMERATION_PAGE_SIZE": "1000",
            "IM_V2_MAX_PLANNER_CONCURRENCY": "8",
            "IM_V2_MAX_DELIVERY_CONCURRENCY": "16",
            "IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS": "3",
        ]
    }
}
