import Foundation

/// 账号服务的监听配置。
public struct V2AccountListenerConfiguration: Equatable, Sendable {
    /// 监听主机，仅允许回环地址。
    public let host: String
    /// 监听端口。
    public let port: Int

    /// 校验并保存监听配置。
    ///
    /// 账号进程刻意只作为内网 HTTP 监听者，TLS 终结边缘必须是唯一的公网调用方：
    /// 直接绑定公网接口会在缺少已批准的 TLS 与限流策略时暴露密码与通行密钥接口。
    ///
    /// - Parameters:
    ///   - host: 监听主机，仅接受 `127.0.0.1` 或 `::1`。
    ///   - port: 监听端口，需落在 `1...65535`。
    /// - Throws: 主机或端口不满足约束时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(host: String, port: Int) throws {
        guard host == "127.0.0.1" || host == "::1", (1 ... 65_535).contains(port) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_LISTEN_HOST/IM_V2_ACCOUNT_LISTEN_PORT")
        }
        self.host = host
        self.port = port
    }
}

/// 仅由 HTTPS 边缘与回环账号进程共享的密钥。
///
/// 它用于阻止本地调用方绕过已批准的边缘，直接把自造的转发上下文头交给账号路由。
public struct V2AccountEdgeAuthorizationSecret: Sendable {
    private let bytes: Data

    /// 从 Base64 编码的密钥材料构造。
    ///
    /// - Parameter value: Base64 编码的密钥，至少 32 字节。
    /// - Throws: 无法解码或字节数不足时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(base64Encoded value: String) throws {
        guard let bytes = Data(base64Encoded: value), bytes.count >= 32 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64")
        }
        self.bytes = bytes
    }

    /// 以恒定时间比较候选密钥。
    ///
    /// - Parameter value: 候选密钥的 Base64 编码。
    /// - Returns: 长度与内容都一致时为 `true`。
    public func matches(base64EncodedCandidate value: String) -> Bool {
        guard let candidate = Data(base64Encoded: value), candidate.count == bytes.count else { return false }
        var difference: UInt8 = 0
        for (candidateByte, expectedByte) in zip(candidate, bytes) {
            difference |= candidateByte ^ expectedByte
        }
        return difference == 0
    }
}

/// 隔离的账号与设备凭据服务运行时配置。
///
/// 它与 TLS 网关刻意分离，使凭据重放密钥与断言签名密钥永远不进入网关进程。
public struct V2AccountRuntimeConfiguration: Sendable {
    /// 控制库连接地址。
    public let databaseURL: String
    /// PostgreSQL 会话与连接策略。
    public let databasePolicy: V2PostgresRuntimePolicy
    /// 账号服务监听配置。
    public let listener: V2AccountListenerConfiguration
    /// 访问令牌 HMAC 密钥。
    public let accessTokenKey: V2AccessTokenHMACKey
    /// 凭据重放信封密钥。
    public let replayEnvelopeKey: V2CredentialReplayEnvelopeKey
    /// 推送端点信封密钥。
    public let pushEndpointEnvelopeKey: V2PushEndpointEnvelopeKey
    /// 边缘授权共享密钥。
    public let edgeAuthorizationSecret: V2AccountEdgeAuthorizationSecret
    /// 边缘客户端限流假名化密钥。
    public let edgeClientRateLimitKey: V2AccountEdgeClientRateLimitKey
    /// 账号断言 HMAC 密钥材料。
    public let accountAssertionKey: Data
    /// 群邀请令牌 HMAC 密钥材料。
    public let groupInviteTokenHMACKey: Data
    /// 本进程使用的容量档位。
    public let capacityProfile: V2CapacityProfile
    /// 密码登录失败限流策略。
    public let passwordLoginRateLimit: V2PasswordLoginRateLimitPolicy
    /// 边缘客户端限流预算。
    public let edgeClientRateLimit: V2AccountEdgeClientRateLimitPolicy
    /// 公开身份查询限流预算。
    public let publicIdentityLookupRateLimit: V2PublicIdentityLookupRateLimitPolicy
    /// 设备注册策略。
    public let deviceRegistrationPolicy: V2DeviceRegistrationPolicy
    /// 房间分片存储配置。
    public let roomShardStorage: [V2RoomShardStorageConfiguration]
    /// 用户分片存储配置；未配置时为空。
    public let userShardStorage: [V2UserShardStorageConfiguration]

    /// 从运行环境解析并校验全部配置。
    ///
    /// 房间分片注册表是必需项；用户分片注册表可省略，但一旦配置了房间分片就必须同时提供用户分片。
    /// 数据库策略会先按主库与用户分片校验，再对全部数据库地址做一次整体校验；
    /// 各项限流与注册策略在构造时即完成取值范围校验。
    ///
    /// - Parameter environment: 读取环境变量的运行时视图。
    /// - Throws: 必需变量缺失时抛出
    ///   ``V2GatewayRuntimeConfigurationError/missing(_:)``；
    ///   密钥材料、监听配置、数据库策略、容量档位或任一限流策略非法时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try Self.required("IM_V2_DATABASE_URL", environment: environment)
        databasePolicy = try .init(environment: environment)
        if let raw = environment.value(for: "IM_V2_ROOM_SHARD_STORES_JSON") {
            roomShardStorage = try V2RoomShardStorageConfiguration.parseRegistryJSON(raw)
        } else { throw V2GatewayRuntimeConfigurationError.missing("IM_V2_ROOM_SHARD_STORES_JSON") }
        if let raw = environment.value(for: "IM_V2_USER_SHARD_STORES_JSON") {
            userShardStorage = try V2UserShardStorageConfiguration.parseRegistryJSON(raw)
        } else { userShardStorage = [] }
        guard roomShardStorage.isEmpty || !userShardStorage.isEmpty else {
            throw V2GatewayRuntimeConfigurationError.missing("IM_V2_USER_SHARD_STORES_JSON")
        }
        try databasePolicy.validate(primaryDatabaseURL: databaseURL, userShardStorage: userShardStorage)
        try databasePolicy.validate(databaseURLs: [databaseURL] + roomShardStorage.map(\.databaseURL) + userShardStorage.map(\.databaseURL))
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
        let rawGroupInviteKey = try Self.required("IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64", environment: environment)
        guard let groupInviteTokenHMACKey = Data(base64Encoded: rawGroupInviteKey), groupInviteTokenHMACKey.count >= 32 else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64")
        }
        self.groupInviteTokenHMACKey = groupInviteTokenHMACKey
        capacityProfile = try .init(
            id: Self.required("IM_V2_CAPACITY_PROFILE_ID", environment: environment),
            limits: .init(
                maxEligibleMembers: Self.integer("IM_V2_MAX_ELIGIBLE_MEMBERS", environment: environment),
                maxCommandsPerWindow: Self.integer("IM_V2_MAX_COMMANDS_PER_WINDOW", environment: environment),

                retryAfterSeconds: Self.integer("IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS", environment: environment)
            )
        )
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

    /// 读取必需的环境变量并去除首尾空白。
    ///
    /// - Parameters:
    ///   - key: 环境变量名。
    ///   - environment: 运行时环境视图。
    /// - Returns: 非空的变量取值。
    /// - Throws: 变量缺失或去除空白后为空时抛出
    ///   ``V2GatewayRuntimeConfigurationError/missing(_:)``。
    private static func required(_ key: String, environment: any V2RuntimeEnvironment) throws -> String {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw V2GatewayRuntimeConfigurationError.missing(key)
        }
        return value
    }

    /// 读取必需的整数环境变量。
    ///
    /// - Parameters:
    ///   - key: 环境变量名。
    ///   - environment: 运行时环境视图。
    /// - Returns: 解析后的整数。
    /// - Throws: 变量缺失时抛出 ``V2GatewayRuntimeConfigurationError/missing(_:)``；
    ///   无法解析为整数时抛出 ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    private static func integer(_ key: String, environment: any V2RuntimeEnvironment) throws -> Int {
        let value = try required(key, environment: environment)
        guard let result = Int(value) else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
        return result
    }
}
