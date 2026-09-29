import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation

/// 将房间逻辑分片映射到部署配置的数据库与 schema 的运行时位置。
///
/// 房间行只存储 `room_shard_id`，连接细节留在部署配置中，
/// 因此绝不会进入事件、投递记录、日志行或客户端响应。
/// 只保存存储访问能力，不计算归属、不建立新连接，也不检查数据库或 schema 是否实际可用。
/// 逻辑标识仅验证去除首尾空白后非空，保存时保留原值，注册表查询按原字符串精确匹配。
public struct V2RoomShardStorageLocation: Sendable {
    /// 房间逻辑分片标识，保留初始化输入的原始字符串。
    public let shardID: String
    /// 部署配置提供的 Fluent 数据库访问能力。
    public let database: any Database
    /// 通过标识符格式校验的 schema 名称；未验证其存在性或访问权限。
    public let schema: String

    /// 校验逻辑标识与 schema 的格式后保存位置。
    ///
    /// - Parameters:
    ///   - shardID: 非纯空白逻辑标识，不自动去除保存值的空白。
    ///   - database: 供后续存储操作使用的数据库。
    ///   - schema: 以 ASCII 字母或下划线开头，后续仅含 ASCII 字母、数字、下划线的名称。
    /// - Throws: 标识为空白或 schema 不满足正则格式时抛出 `invalidLocation`。
    public init(shardID: String, database: any Database, schema: String) throws {
        guard !shardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.shardID = shardID
        self.database = database
        self.schema = schema
    }
}


/// 根据已选定的房间逻辑分片解析部署位置，不接受客户端提供的连接地址。
public protocol V2RoomShardStorageResolving: Sendable {
    /// 查询已配置的存储位置。
    ///
    /// - Parameter shardID: 归属路由选定的逻辑标识。
    /// - Returns: 对应数据库与 schema。
    /// - Throws: 配置缺失或实现特有的解析错误。
    func location(for shardID: String) throws -> V2RoomShardStorageLocation
}

/// 初始化后不可变的房间分片位置注册表，允许空配置但不提供默认位置。
public struct V2StaticRoomShardStorageRegistry: V2RoomShardStorageResolving, Sendable {
    private let locations: [String: V2RoomShardStorageLocation]

    /// 建立按原始逻辑标识索引的位置映射。
    ///
    /// - Parameter locations: 部署提供的位置列表，允许为空。
    /// - Throws: 逻辑标识重复时抛出 `duplicateShardID`，不会让后面的配置覆盖前面的配置。
    public init(locations: [V2RoomShardStorageLocation]) throws {
        var result: [String: V2RoomShardStorageLocation] = [:]
        for location in locations {
            guard result[location.shardID] == nil else {
                throw V2RoomShardStorageRegistryError.duplicateShardID
            }
            result[location.shardID] = location
        }
        self.locations = result
    }

    /// 按原字符串精确查找，不修剪空白、不重新计算分片，也不回退到其他位置。
    ///
    /// - Parameter shardID: 需要解析的逻辑标识。
    /// - Returns: 初始化时保存的位置。
    /// - Throws: 未配置时抛出 `unknownShardID`。
    public func location(for shardID: String) throws -> V2RoomShardStorageLocation {
        guard let location = locations[shardID] else {
            throw V2RoomShardStorageRegistryError.unknownShardID
        }
        return location
    }
}
