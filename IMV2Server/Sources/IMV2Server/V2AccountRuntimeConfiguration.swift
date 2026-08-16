import Foundation

public struct V2AccountListenerConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int

    /// The account process is deliberately an internal HTTP listener. A TLS
    /// terminating edge must be the only public caller; binding it to a public
    /// interface would expose password/passkey endpoints without an approved
    /// TLS/rate-limit policy.
    public init(host: String, port: Int) throws {
        guard host == "127.0.0.1" || host == "::1", (1 ... 65_535).contains(port) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_LISTEN_HOST/IM_V2_ACCOUNT_LISTEN_PORT")
        }
        self.host = host
        self.port = port
    }
}

/// Secret shared only by the HTTPS edge and the loopback account process.
/// It prevents a local caller from bypassing the approved edge and supplying
/// its own forwarding-context headers directly to account routes.
public struct V2AccountEdgeAuthorizationSecret: Sendable {
    private let bytes: Data

    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64")
        }
        self.bytes = bytes
    }

    public func matches(base64EncodedCandidate value: String) -> Bool {
        guard let candidate = Data(base64Encoded: value), candidate.count == bytes.count else { return false }
        var difference: UInt8 = 0
        for (candidateByte, expectedByte) in zip(candidate, bytes) {
            difference |= candidateByte ^ expectedByte
        }
        return difference == 0
    }
}

/// Runtime-only configuration for the isolated account/device credential
/// service. It is intentionally separate from the TLS gateway so credential
/// replay and assertion signing secrets never enter that gateway process.
public struct V2AccountRuntimeConfiguration: Sendable {
    public let databaseURL: String
    public let databasePolicy: V2PostgresRuntimePolicy
    public let listener: V2AccountListenerConfiguration
    public let accessTokenKey: V2AccessTokenHMACKey
    public let replayEnvelopeKey: V2CredentialReplayEnvelopeKey
    public let pushEndpointEnvelopeKey: V2PushEndpointEnvelopeKey
    public let edgeAuthorizationSecret: V2AccountEdgeAuthorizationSecret
    public let edgeClientRateLimitKey: V2AccountEdgeClientRateLimitKey
    public let accountAssertionKey: Data
    public let dummyPasswordHash: String
    public let passwordLoginRateLimit: V2PasswordLoginRateLimitPolicy
    public let edgeClientRateLimit: V2AccountEdgeClientRateLimitPolicy
    public let publicIdentityLookupRateLimit: V2PublicIdentityLookupRateLimitPolicy
    public let deviceRegistrationPolicy: V2DeviceRegistrationPolicy

    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try Self.required("IM_V2_DATABASE_URL", environment: environment)
        databasePolicy = try .init(environment: environment)
        try databasePolicy.validate(databaseURLs: [databaseURL])
        listener = try .init(
            host: Self.required("IM_V2_ACCOUNT_LISTEN_HOST", environment: environment),
            port: Self.integer("IM_V2_ACCOUNT_LISTEN_PORT", environment: environment)
        )
        accessTokenKey = try .init(base64Encoded: Self.required("IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64", environment: environment))
        replayEnvelopeKey = try .init(base64Encoded: Self.required("IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64", environment: environment))
        pushEndpointEnvelopeKey = try .init(base64Encoded: Self.required("IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64", environment: environment))
        edgeAuthorizationSecret = try .init(base64Encoded: Self.required("IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64", environment: environment))
        do {
            edgeClientRateLimitKey = try .init(base64Encoded: Self.required("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64", environment: environment))
        } catch V2AccountEdgeClientRateLimitError.invalidKeyMaterial {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64")
        }
        let rawAccountAssertionKey = try Self.required("IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64", environment: environment)
        guard let accountAssertionKey = Data(base64Encoded: rawAccountAssertionKey), accountAssertionKey.count >= 32 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_ASSERTION_HMAC_KEY_BASE64")
        }
        self.accountAssertionKey = accountAssertionKey
        let dummy = try Self.required("IM_V2_PASSWORD_DUMMY_BCRYPT_HASH", environment: environment)
        guard dummy.utf8.count <= 255, dummy.hasPrefix("$2") else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_PASSWORD_DUMMY_BCRYPT_HASH")
        }
        dummyPasswordHash = dummy
        let maximumFailures = try Self.integer("IM_V2_PASSWORD_LOGIN_MAX_FAILURES", environment: environment)
        let windowSeconds = try Self.integer("IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS", environment: environment)
        let lockoutSeconds = try Self.integer("IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS", environment: environment)
        do {
            passwordLoginRateLimit = try .init(
                maximumFailures: maximumFailures,
                window: TimeInterval(windowSeconds),
                lockout: TimeInterval(lockoutSeconds)
            )
        } catch V2PasswordLoginRateLimitError.invalidPolicy {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_PASSWORD_LOGIN_MAX_FAILURES/IM_V2_PASSWORD_LOGIN_WINDOW_SECONDS/IM_V2_PASSWORD_LOGIN_LOCKOUT_SECONDS")
        }
        let edgeClientMaximumRequests = try Self.integer("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS", environment: environment)
        let edgeClientWindowSeconds = try Self.integer("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_WINDOW_SECONDS", environment: environment)
        do {
            edgeClientRateLimit = try .init(maximumRequests: edgeClientMaximumRequests, window: TimeInterval(edgeClientWindowSeconds))
        } catch V2AccountEdgeClientRateLimitError.invalidPolicy {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_MAX_REQUESTS/IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_WINDOW_SECONDS")
        }
        let publicIdentityMaximumQueries = try Self.integer("IM_V2_PUBLIC_IDENTITY_LOOKUP_MAX_QUERIES", environment: environment)
        let publicIdentityWindowSeconds = try Self.integer("IM_V2_PUBLIC_IDENTITY_LOOKUP_WINDOW_SECONDS", environment: environment)
        do {
            publicIdentityLookupRateLimit = try .init(maximumQueries: publicIdentityMaximumQueries, window: TimeInterval(publicIdentityWindowSeconds))
        } catch V2PublicIdentityLookupRateLimitError.invalidPolicy {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_PUBLIC_IDENTITY_LOOKUP_MAX_QUERIES/IM_V2_PUBLIC_IDENTITY_LOOKUP_WINDOW_SECONDS")
        }
        do {
            deviceRegistrationPolicy = try .init(
                maximumActiveDevices: Self.integer("IM_V2_MAX_ACTIVE_DEVICES_PER_ACCOUNT", environment: environment),
                maximumNewDevicesPerWindow: Self.integer("IM_V2_MAX_NEW_DEVICES_PER_WINDOW", environment: environment),
                window: TimeInterval(Self.integer("IM_V2_DEVICE_REGISTRATION_WINDOW_SECONDS", environment: environment))
            )
        } catch V2DeviceCredentialServiceError.invalidConfiguration {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_MAX_ACTIVE_DEVICES_PER_ACCOUNT/IM_V2_MAX_NEW_DEVICES_PER_WINDOW/IM_V2_DEVICE_REGISTRATION_WINDOW_SECONDS")
        }
    }

    private static func required(_ key: String, environment: any V2RuntimeEnvironment) throws -> String {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw V2GatewayRuntimeConfigurationError.missing(key)
        }
        return value
    }

    private static func integer(_ key: String, environment: any V2RuntimeEnvironment) throws -> Int {
        let value = try required(key, environment: environment)
        guard let result = Int(value) else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
        return result
    }
}
