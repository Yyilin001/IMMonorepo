import IMV2ServerInfrastructure
import IMV2ServerApplication
import IMV2ServerContracts
import Foundation

/// 运维重放服务的监听配置。
///
/// 该服务只允许回环可达；部署方若要对外提供，只能通过单独审批的运维通道
/// （例如堡垒机或 mTLS 代理），绝不与公网 TLS 网关共用端口。
public struct V2OperatorReplayListenerConfiguration: Equatable, Sendable {
    /// 监听主机，仅允许回环地址。
    public let host: String
    /// 监听端口。
    public let port: Int

    /// 校验并保存监听配置。
    ///
    /// - Parameters:
    ///   - host: 监听主机，仅接受 `127.0.0.1` 或 `::1`。
    ///   - port: 监听端口，需落在 `1...65535`。
    /// - Throws: 主机或端口不满足约束时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(host: String, port: Int) throws {
        guard host == "127.0.0.1" || host == "::1", (1...65_535).contains(port) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_LISTEN_HOST/IM_V2_OPERATOR_REPLAY_LISTEN_PORT")
        }
        self.host = host
        self.port = port
    }
}

/// 运维重放进程的运行时配置。
///
/// 所有字段都来自环境变量，且校验集中在初始化阶段完成：
/// 数据库地址与策略、回环监听配置、重放与停用账号两套独立的 Bearer 凭据与运维主体、
/// 用户分片与房间分片存储列表以及能力档位。
public struct V2OperatorReplayRuntimeConfiguration: Sendable {
    /// 控制库连接地址。
    public let databaseURL: String
    /// PostgreSQL 会话与连接策略。
    public let databasePolicy: V2PostgresRuntimePolicy
    /// 重放服务的回环监听配置。
    public let listener: V2OperatorReplayListenerConfiguration
    /// 重放请求的 Bearer 认证器。
    public let authenticator: V2OperatorReplayBearerAuthenticator
    /// 重放请求的运维主体标识。
    public let operatorPrincipal: String
    /// 账号停用请求的 Bearer 认证器。
    public let accountDisableAuthenticator: V2OperatorReplayBearerAuthenticator
    /// 账号停用请求的运维主体标识。
    public let accountDisableOperatorPrincipal: String
    /// 用户分片存储配置。
    public let userShardStorage: [V2UserShardStorageConfiguration]
    /// 房间分片存储配置；未配置时为空列表。
    public let roomShardStorage: [V2RoomShardStorageConfiguration]
    /// 能力档位标识。
    public let capabilityProfile: String

    /// 从运行环境解析并校验全部配置。
    ///
    /// 房间分片注册表可以缺省：此时转发重放没有可用的归属，也不会回退到控制库。
    /// 数据库策略会分别针对主库与用户分片、再针对全部数据库地址做一次整体校验。
    ///
    /// - Parameter environment: 读取环境变量的运行时视图。
    /// - Throws: 任一必需变量缺失时抛出
    ///   ``V2GatewayRuntimeConfigurationError/missing(_:)``；取值非法（监听主机、端口、
    ///   Bearer 密钥、运维主体、分片注册表 JSON 或数据库策略）时抛出
    ///   ``V2GatewayRuntimeConfigurationError/invalid(_:)``。
    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try v2RequiredEnvironmentValue("IM_V2_DATABASE_URL", environment: environment)
        databasePolicy = try .init(environment: environment)
        listener = try .init(
            host: v2RequiredEnvironmentValue("IM_V2_OPERATOR_REPLAY_LISTEN_HOST", environment: environment),
            port: v2RequiredEnvironmentInteger("IM_V2_OPERATOR_REPLAY_LISTEN_PORT", environment: environment)
        )
        let token = try v2RequiredEnvironmentValue("IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64", environment: environment)
        do {
            authenticator = try .init(base64EncodedBearerToken: token)
        } catch {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64")
        }
        let principal = try v2RequiredEnvironmentValue("IM_V2_OPERATOR_REPLAY_PRINCIPAL", environment: environment)
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(principal) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_REPLAY_PRINCIPAL")
        }
        operatorPrincipal = principal
        let accountDisableToken = try v2RequiredEnvironmentValue("IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64", environment: environment)
        do {
            accountDisableAuthenticator = try .init(base64EncodedBearerToken: accountDisableToken)
        } catch {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_ACCOUNT_DISABLE_BEARER_TOKEN_BASE64")
        }
        let accountDisablePrincipal = try v2RequiredEnvironmentValue("IM_V2_OPERATOR_ACCOUNT_DISABLE_PRINCIPAL", environment: environment)
        guard V2DurableWorkOperatorReplayService.isValidPrincipal(accountDisablePrincipal) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_OPERATOR_ACCOUNT_DISABLE_PRINCIPAL")
        }
        accountDisableOperatorPrincipal = accountDisablePrincipal
        capabilityProfile = try v2RequiredEnvironmentValue("IM_V2_CAPABILITY_PROFILE", environment: environment)
        userShardStorage = try V2UserShardStorageConfiguration.parseRegistryJSON(
            v2RequiredEnvironmentValue("IM_V2_USER_SHARD_STORES_JSON", environment: environment)
        )
        // 没有房间注册表时，个人事件和转发重放都没有已配置的来源所有者，
        // 也绝不回退到控制数据库。
        if let raw = environment.value(for: "IM_V2_ROOM_SHARD_STORES_JSON") {
            roomShardStorage = try V2RoomShardStorageConfiguration.parseRegistryJSON(raw)
        } else { roomShardStorage = [] }
        try databasePolicy.validate(
            primaryDatabaseURL: databaseURL,
            userShardStorage: userShardStorage
        )
        try databasePolicy.validate(databaseURLs: [databaseURL] + userShardStorage.map(\.databaseURL) + roomShardStorage.map(\.databaseURL),
            connectionsPerEventLoopPerPhysicalStore: databasePolicy.maximumConnectionsPerEventLoop)
    }

}
