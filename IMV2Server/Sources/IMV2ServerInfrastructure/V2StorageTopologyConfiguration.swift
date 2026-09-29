import IMV2ServerContracts
import Foundation

/// 仅用于部署的「逻辑桶到物理数据库」映射。
///
/// 它在启动时解析，绝不写入业务记录、日志或 API 响应。
/// 省略该 JSON 会让单桶部署保持显式。
public struct V2UserShardStorageConfiguration: Codable, Equatable, Sendable {
    public let bucket: String
    public let databaseURL: String
    public let schema: String

    public init(bucket: String, databaseURL: String, schema: String = "im_v2") throws {
        let normalizedBucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBucket.isEmpty, !normalizedURL.isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON") }
        self.bucket = normalizedBucket
        self.databaseURL = normalizedURL
        self.schema = schema
    }

    enum CodingKeys: String, CodingKey { case bucket; case databaseURL = "database_url"; case schema }

    /// 解码网关与运维进程共享的、仅用于部署的注册表。
    ///
    /// 调用方仍需自行负责要求与其角色相符的本地桶。
    ///
    /// - Parameter rawValue: 注册表 JSON 文本。
    /// - Returns: 解码出的存储配置列表。
    /// - Throws: JSON 非法、为空或存在重复桶/地址时抛出。
    public static func parseRegistryJSON(_ rawValue: String) throws -> [Self] {
        guard let data = rawValue.data(using: .utf8) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON")
        }
        let decoded: [Self]
        do { decoded = try JSONDecoder().decode([Self].self, from: data) }
        catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON") }
        guard !decoded.isEmpty,
              Set(decoded.map(\.bucket)).count == decoded.count,
              Set(decoded.map { "\($0.databaseURL)|\($0.schema)" }).count == decoded.count
        else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_USER_SHARD_STORES_JSON") }
        return decoded
    }
}

/// 仅用于部署的房间写入物理归属注册表。
///
/// 一行的持久 `room_shard_id` 会选中其中一项；
/// 该注册表必须覆盖本网关能够创建或服务的每个分片。
/// 在分阶段灰度期间，多个逻辑分片可以刻意共享同一个数据库，
/// 因此重复的地址是合法的，而重复的分片 ID 不是。
public struct V2RoomShardStorageConfiguration: Codable, Equatable, Sendable {
    public let shardID: String
    public let databaseURL: String
    public let schema: String

    public init(shardID: String, databaseURL: String, schema: String = "im_v2") throws {
        let normalizedShard = shardID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedShard.isEmpty, !normalizedURL.isEmpty,
              // 房间归属存储目前将所有规范表限定在 `im_v2.*`。
              // 若接受其他 Schema，就绪性检查虽会通过，热路径 SQL 却会悄然访问错误位置。
              // 在这些存储获得与用户分片相同的 Schema 感知 SQL 边界前，
              // 必须保持拓扑配置与实际访问位置一致。
              schema == "im_v2"
        else { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON") }
        self.shardID = normalizedShard
        self.databaseURL = normalizedURL
        self.schema = schema
    }

    enum CodingKeys: String, CodingKey {
        case shardID = "shard_id"
        case databaseURL = "database_url"
        case schema
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            shardID: container.decode(String.self, forKey: .shardID),
            databaseURL: container.decode(String.self, forKey: .databaseURL),
            schema: container.decodeIfPresent(String.self, forKey: .schema) ?? "im_v2"
        )
    }

    public static func parseRegistryJSON(_ rawValue: String) throws -> [Self] {
        guard let data = rawValue.data(using: .utf8) else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON")
        }
        let decoded: [Self]
        do { decoded = try JSONDecoder().decode([Self].self, from: data) }
        catch { throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON") }
        guard !decoded.isEmpty, Set(decoded.map(\.shardID)).count == decoded.count else {
            throw V2GatewayRuntimeConfigurationError.invalid("IM_V2_ROOM_SHARD_STORES_JSON")
        }
        return decoded
    }
}
