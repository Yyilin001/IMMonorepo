import Foundation

/// The replay service is deliberately loopback-only. A deployment may expose
/// it only through a separately approved operator access path (for example a
/// bastion or mTLS proxy); it must never share the public TLS gateway port.
public struct V2OperatorReplayListenerConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) throws {
        guard host == "127.0.0.1" || host == "::1", (1...65_535).contains(port) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_LISTEN_HOST/IM_V2_OPERATOR_REPLAY_LISTEN_PORT")
        }
        self.host = host
        self.port = port
    }
}

public struct V2OperatorReplayRuntimeConfiguration: Sendable {
    public let databaseURL: String
    public let databasePolicy: V2PostgresRuntimePolicy
    public let listener: V2OperatorReplayListenerConfiguration
    public let authenticator: V2OperatorReplayBearerAuthenticator
    public let operatorPrincipal: String
    public let accountDisableAuthenticator: V2OperatorReplayBearerAuthenticator
    public let accountDisableOperatorPrincipal: String
    public let userShardStorage: [V2UserShardStorageConfiguration]
    public let roomShardStorage: [V2RoomShardStorageConfiguration]
    public let capabilityProfile: String

    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try Self.required("IM_V2_DATABASE_URL", environment: environment)
        databasePolicy = try .init(environment: environment)
        listener = try .init(
            host: Self.required("IM_V2_OPERATOR_REPLAY_LISTEN_HOST", environment: environment),
            port: Self.integer("IM_V2_OPERATOR_REPLAY_LISTEN_PORT", environment: environment)
        )
        let token = try Self.required("IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64", environment: environment)
        do {
            authenticator = try .init(base64EncodedBearerToken: token)
        } catch {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64")
        }
        let principal = try Self.required("IM_V2_OPERATOR_REPLAY_PRINCIPAL", environment: environment)
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(principal) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_PRINCIPAL")
        }
        operatorPrincipal = principal
        let accountDisableToken = try Self.required("IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64", environment: environment)
        do {
            accountDisableAuthenticator = try .init(base64EncodedBearerToken: accountDisableToken)
        } catch {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64")
        }
        let accountDisablePrincipal = try Self.required("IM_V2_OPERATOR_ACCOUNT_DISABLE_PRINCIPAL", environment: environment)
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(accountDisablePrincipal) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_ACCOUNT_DISABLE_PRINCIPAL")
        }
        accountDisableOperatorPrincipal = accountDisablePrincipal
        capabilityProfile = try Self.required("IM_V2_CAPABILITY_PROFILE", environment: environment)
        userShardStorage = try V2UserShardStorageConfiguration.parseRegistryJSON(
            Self.required("IM_V2_USER_SHARD_STORES_JSON", environment: environment)
        )
        // Existing operators may omit this registry; forward replay then has
        // no configured owner and never falls back to the control database.
        if let raw = environment.value(for: "IM_V2_ROOM_SHARD_STORES_JSON") {
            roomShardStorage = try V2RoomShardStorageConfiguration.parseRegistryJSON(raw)
        } else { roomShardStorage = [] }
        try databasePolicy.validate(
            primaryDatabaseURL: databaseURL,
            userShardStorage: userShardStorage
        )
        try databasePolicy.validate(databaseURLs: [databaseURL] + userShardStorage.map(\.databaseURL) + roomShardStorage.map(\.databaseURL))
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
