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

/// Runtime-only configuration for the isolated account/device credential
/// service. It is intentionally separate from the TLS gateway so credential
/// replay and assertion signing secrets never enter that gateway process.
public struct V2AccountRuntimeConfiguration: Sendable {
    public let databaseURL: String
    public let listener: V2AccountListenerConfiguration
    public let accessTokenKey: V2AccessTokenHMACKey
    public let replayEnvelopeKey: V2CredentialReplayEnvelopeKey
    public let pushEndpointEnvelopeKey: V2PushEndpointEnvelopeKey
    public let accountAssertionKey: Data
    public let dummyPasswordHash: String

    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try Self.required("IM_V2_DATABASE_URL", environment: environment)
        listener = try .init(
            host: Self.required("IM_V2_ACCOUNT_LISTEN_HOST", environment: environment),
            port: Self.integer("IM_V2_ACCOUNT_LISTEN_PORT", environment: environment)
        )
        accessTokenKey = try .init(base64Encoded: Self.required("IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64", environment: environment))
        replayEnvelopeKey = try .init(base64Encoded: Self.required("IM_V2_CREDENTIAL_REPLAY_ENVELOPE_KEY_BASE64", environment: environment))
        pushEndpointEnvelopeKey = try .init(base64Encoded: Self.required("IM_V2_PUSH_ENDPOINT_ENVELOPE_KEY_BASE64", environment: environment))
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
