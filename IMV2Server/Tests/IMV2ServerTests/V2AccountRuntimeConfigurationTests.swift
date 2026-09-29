@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2AccountRuntimeConfigurationTests {
    @Test("account database budget reserves separate direct-route and social connections")
    func validatesDirectRouteConnectionBudget() throws {
        var configured = values
        configured["IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = "1"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(configured))
        }
        configured["IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = "2"
        let configuration = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(configured))
        #expect(configuration.databasePolicy.maximumConnectionsPerEventLoop == 2)
    }

    @Test("runtime rejects unencodable account rate-limit settings", arguments: [
        "IM_V2_PASSWORD_LOGIN_MAX_FAILURES", "IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS",
        "IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS", "IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_WINDOW_SECONDS",
        "IM_V2_PUBLIC_IDENTITY_LOOKUP_WINDOW_SECONDS"
    ])
    func rejectsUnencodableRateLimitSetting(key: String) {
        var invalid = values
        invalid[key] = String(Int.max)
        #expect(throws: V2GatewayRuntimeConfigurationError.self) {
            try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalid))
        }
    }

    @Test("account invitations require an explicit owner registry even without local media")
    func requiresInvitationOwners() {
        var missing = values
        missing.removeValue(forKey: "IM_V2_ROOM_SHARD_STORES_JSON")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_ROOM_SHARD_STORES_JSON")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missing))
        }
    }

    @Test("account service accepts only an internal listener with explicit secrets")
    func parsesStrictConfiguration() throws {
        let configuration = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(values))
        let expectedListener = try V2AccountListenerConfiguration(host: "127.0.0.1", port: 8444)
        let expectedRateLimit = try V2PasswordLoginRateLimitPolicy(maximumFailures: 5, window: 900, lockout: 900)
        let expectedIdentityRateLimit = try V2PublicIdentityLookupRateLimitPolicy(maximumQueries: 30, window: 60)
        let expectedEdgeClientRateLimit = try V2AccountEdgeClientRateLimitPolicy(maximumRequests: 60, window: 60)
        let expectedDeviceRegistrationPolicy = try V2DeviceRegistrationPolicy(
            maximumActiveDevices: 8,
            maximumNewDevicesPerWindow: 16,
            window: 2_592_000
        )
        #expect(configuration.listener == expectedListener)
        #expect(configuration.accountAssertionKey.count == 32)
        #expect(configuration.groupInviteTokenHMACKey.count == 32)
        #expect(configuration.capacityProfile.id == "standard")
        #expect(configuration.passwordLoginRateLimit == expectedRateLimit)
        #expect(configuration.publicIdentityLookupRateLimit == expectedIdentityRateLimit)
        #expect(configuration.edgeClientRateLimit == expectedEdgeClientRateLimit)
        #expect(configuration.deviceRegistrationPolicy == expectedDeviceRegistrationPolicy)
    }

    @Test("media owner routing requires user storage and counts every database pool")
    func validatesMediaOwnerRegistry() throws {
        var configured = values
        configured.removeValue(forKey: "IM_V2_USER_SHARD_STORES_JSON")
        configured["IM_V2_ROOM_SHARD_STORES_JSON"] = #"[{"shard_id":"room-b","database_url":"postgres://v2:password@db/room_b","schema":"im_v2"}]"#
        configured["IM_V2_DIRECT_ROOM_SHARD_ID"] = "room-b"
        configured["IM_V2_GROUP_ROOM_SHARD_ID"] = "room-b"
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_USER_SHARD_STORES_JSON")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(configured))
        }
        configured["IM_V2_USER_SHARD_STORES_JSON"] = #"[{"bucket":"users-primary","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"}]"#
        let valid = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(configured))
        #expect(valid.roomShardStorage.count == 1)
        #expect(valid.userShardStorage.count == 1)
        configured["IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS"] = "4"
        #expect(throws: (any Error).self) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(configured))
        }
    }

    @Test("account service rejects public binding")
    func rejectsPublicListener() {
        var publicValues = values
        publicValues["IM_V2_ACCOUNT_LISTEN_HOST"] = "0.0.0.0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_LISTEN_HOST/IM_V2_ACCOUNT_LISTEN_PORT")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(publicValues))
        }
    }

    @Test("account service rejects a non-positive password login rate-limit policy")
    func rejectsInvalidPasswordLoginRateLimit() {
        var invalidValues = values
        invalidValues["IM_V2_PASSWORD_LOGIN_MAX_FAILURES"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_PASSWORD_LOGIN_MAX_FAILURES/IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS/IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidValues))
        }
    }

    @Test("account service rejects a missing or undersized edge authorization secret")
    func rejectsInvalidEdgeAuthorizationSecret() {
        var missingValues = values
        missingValues.removeValue(forKey: "IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missingValues))
        }

        var undersizedValues = values
        undersizedValues["IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64"] = Data(repeating: 5, count: 31).base64EncodedString()
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(undersizedValues))
        }
    }

    @Test("account service fails closed without an independent group-invite key")
    func rejectsInvalidGroupInviteKey() {
        var missingValues = values
        missingValues.removeValue(forKey: "IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missingValues))
        }

        var undersizedValues = values
        undersizedValues["IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64"] = Data(repeating: 5, count: 31).base64EncodedString()
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(undersizedValues))
        }
    }

    @Test("account service requires a distinct valid edge-client rate-limit key and policy")
    func rejectsInvalidEdgeClientRateLimitConfiguration() {
        var missingKey = values
        missingKey.removeValue(forKey: "IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64")
        #expect(throws: V2GatewayRuntimeConfigurationError.missing("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(missingKey))
        }

        var invalidKey = values
        invalidKey["IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64"] = Data(repeating: 7, count: 31).base64EncodedString()
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidKey))
        }

        var invalidPolicy = values
        invalidPolicy["IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS/IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_WINDOW_SECONDS")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidPolicy))
        }
    }

    @Test("database-backed request counters reserve a safe saturation value")
    func rejectsCounterOverflowPolicies() {
        #expect(throws: V2AccountEdgeClientRateLimitError.invalidPolicy) {
            _ = try V2AccountEdgeClientRateLimitPolicy(
                maximumRequests: Int(Int32.max),
                window: 60
            )
        }
        #expect(throws: V2PublicIdentityLookupRateLimitError.invalidPolicy) {
            _ = try V2PublicIdentityLookupRateLimitPolicy(
                maximumQueries: Int(Int32.max),
                window: 60
            )
        }
    }

    @Test("account service rejects an invalid device registration budget")
    func rejectsInvalidDeviceRegistrationPolicy() {
        var invalidValues = values
        invalidValues["IM_V2_MAX_ACTIVE_DEVICES_PER_ACCOUNT"] = "0"
        #expect(throws: V2GatewayRuntimeConfigurationError.invalid("IM_V2_MAX_ACTIVE_DEVICES_PER_ACCOUNT/IM_V2_MAX_NEW_DEVICES_PER_WINDOW/IM_V2_DEVICE_REGISTRATION_WINDOW_SECONDS")) {
            _ = try V2AccountRuntimeConfiguration(environment: V2DictionaryRuntimeEnvironment(invalidValues))
        }
    }

    private var values: [String: String] {
        [
            "IM_V2_DATABASE_URL": "postgres://v2:password@db/im_v2",
            "IM_V2_DIRECT_ROOM_SHARD_ID": "room-a",
            "IM_V2_GROUP_ROOM_SHARD_ID": "room-a",
            "IM_V2_ROOM_SHARD_STORES_JSON": #"[{"shard_id":"room-a","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"}]"#,
            "IM_V2_USER_SHARD_STORES_JSON": #"[{"bucket":"users-primary","database_url":"postgres://v2:password@db/im_v2","schema":"im_v2"}]"#,
            "IM_V2_DATABASE_EVENT_LOOP_THREADS": "2",
            "IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP": "4",
            "IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS": "16",
            "IM_V2_MAX_USER_SHARD_STORES": "1",
            "IM_V2_DATABASE_CONNECT_TIMEOUT_MS": "5000",
            "IM_V2_DATABASE_POOL_TIMEOUT_MS": "3000",
            "IM_V2_DATABASE_STATEMENT_TIMEOUT_MS": "5000",
            "IM_V2_DATABASE_LOCK_TIMEOUT_MS": "2000",
            "IM_V2_DATABASE_IDLE_TRANSACTION_TIMEOUT_MS": "10000",
            "IM_V2_ACCOUNT_LISTEN_HOST": "127.0.0.1",
            "IM_V2_ACCOUNT_LISTEN_PORT": "8444",
            "IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64": Data(repeating: 1, count: 32).base64EncodedString(),
            "IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64": Data(repeating: 2, count: 32).base64EncodedString(),
            "IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64": Data(repeating: 4, count: 32).base64EncodedString(),
            "IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64": Data(repeating: 5, count: 32).base64EncodedString(),
            "IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64": Data(repeating: 6, count: 32).base64EncodedString(),
            "IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64": Data(repeating: 3, count: 32).base64EncodedString(),
            "IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64": Data(repeating: 8, count: 32).base64EncodedString(),
            "IM_V2_CAPACITY_PROFILE_ID": "standard",
            "IM_V2_MAX_ELIGIBLE_MEMBERS": "100000",
            "IM_V2_MAX_COMMANDS_PER_WINDOW": "1000",
            "IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS": "3",
            "IM_V2_PASSWORD_LOGIN_MAX_FAILURES": "5",
            "IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS": "900",
            "IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS": "900",
            "IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS": "60",
            "IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_WINDOW_SECONDS": "60",
            "IM_V2_MAX_ACTIVE_DEVICES_PER_ACCOUNT": "8",
            "IM_V2_MAX_NEW_DEVICES_PER_WINDOW": "16",
            "IM_V2_DEVICE_REGISTRATION_WINDOW_SECONDS": "2592000",
            "IM_V2_PUBLIC_IDENTITY_LOOKUP_MAX_QUERIES": "30",
            "IM_V2_PUBLIC_IDENTITY_LOOKUP_WINDOW_SECONDS": "60",
        ]
    }
}
