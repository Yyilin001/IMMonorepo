import Foundation
import IMV2ServerContracts
import IMV2ServerInfrastructure

public struct V2AdminRuntimeConfiguration: Sendable {
    public let databaseURL: String
    public let databasePolicy: V2PostgresRuntimePolicy
    public let port: Int
    public let origin: String
    public let accountProbeOrigin: String
    public let gatewayProbeHost: String
    public let gatewayProbePort: Int
    public let accountsFile: String
    public let roomShardStorage: [V2RoomShardStorageConfiguration]
    public init(environment: any V2RuntimeEnvironment) throws {
        databaseURL = try v2RequiredEnvironmentValue("IM_V2_DATABASE_URL", environment: environment)
        databasePolicy = try .init(environment: environment)
        port = try v2RequiredEnvironmentInteger("IM_V2_ADMIN_PORT", environment: environment)
        guard (1...65_535).contains(port) else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ADMIN_PORT") }
        origin = try v2RequiredEnvironmentValue("IM_V2_ADMIN_ORIGIN", environment: environment)
        let account = try v2RequiredEnvironmentValue("IM_V2_ADMIN_ACCOUNT_ORIGIN", environment: environment)
        guard let url = URLComponents(string: account), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty,
              (1...65_535).contains(url.port ?? 443) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ADMIN_ACCOUNT_ORIGIN")
        }
        accountProbeOrigin = account
        gatewayProbeHost = try v2RequiredEnvironmentValue("IM_V2_ADMIN_GATEWAY_HOST", environment: environment)
        gatewayProbePort = try v2RequiredEnvironmentInteger("IM_V2_ADMIN_GATEWAY_PORT", environment: environment)
        guard (1...65_535).contains(gatewayProbePort) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ADMIN_GATEWAY_PORT")
        }
        accountsFile = try v2RequiredEnvironmentValue("IM_V2_ADMIN_ACCOUNTS_FILE", environment: environment)
        roomShardStorage = try V2RoomShardStorageConfiguration.parseRegistryJSON(
            v2RequiredEnvironmentValue("IM_V2_ROOM_SHARD_STORES_JSON", environment: environment))
        try databasePolicy.validate(databaseURLs: [databaseURL] + roomShardStorage.map(\.databaseURL),
            connectionsPerEventLoopPerPhysicalStore: databasePolicy.maximumConnectionsPerEventLoop)
    }
}
