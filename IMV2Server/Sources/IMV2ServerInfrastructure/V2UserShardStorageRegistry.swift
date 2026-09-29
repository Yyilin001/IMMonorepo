import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core

/// 将用户逻辑分片映射到部署配置的数据库与 schema 的运行时位置。
///
/// Fluent 的 `Database` 能力本身已是 `Sendable`；
/// 该不可变值刻意不携带任何自己的可变路由或连接池状态。
/// 只保存存储访问能力，不计算归属、不建立新连接，也不检查数据库或 schema 是否实际可用。
/// 逻辑标识仅验证去除首尾空白后非空，保存时保留原值，注册表查询按原字符串精确匹配。
public struct V2UserShardStorageLocation: Sendable {
    /// 用户逻辑分片标识，保留初始化输入的原始字符串。
    public let bucket: String
    /// 部署配置提供的 Fluent 数据库访问能力。
    public let database: any Database
    /// 通过标识符格式校验的 schema 名称；未验证其存在性或访问权限。
    public let schema: String

    /// 校验逻辑标识与 schema 的格式后保存位置。
    ///
    /// - Parameters:
    ///   - bucket: 非纯空白逻辑标识，不自动去除保存值的空白。
    ///   - database: 供后续存储操作使用的数据库。
    ///   - schema: 以 ASCII 字母或下划线开头，后续仅含 ASCII 字母、数字、下划线的名称。
    /// - Throws: 标识为空白或 schema 不满足正则格式时抛出 `invalidLocation`。
    public init(bucket: String, database: any Database, schema: String) throws {
        guard !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2UserShardStorageRegistryError.invalidLocation }
        self.bucket = bucket
        self.database = database
        self.schema = schema
    }
}

/// 用户分片存储配置与查找错误。
public enum V2UserShardStorageRegistryError: Error, Equatable, Sendable {
    /// 逻辑标识或 schema 格式无效。
    case invalidLocation
    /// 初始化注册表时遇到完全相同的逻辑标识。
    case duplicateBucket
    /// 当前注册表中未配置请求的逻辑标识。
    case unknownBucket
}

/// 根据已选定的用户逻辑分片解析部署位置，不接受客户端提供的连接地址。
public protocol V2UserShardStorageResolving: Sendable {
    /// 查询已配置的存储位置。
    ///
    /// - Parameter bucket: 归属路由选定的逻辑标识。
    /// - Returns: 对应数据库与 schema。
    /// - Throws: 配置缺失或实现特有的解析错误。
    func location(for bucket: String) throws -> V2UserShardStorageLocation
}

/// 初始化后不可变的用户分片位置注册表，允许空配置但不提供默认位置。
public struct V2StaticUserShardStorageRegistry: V2UserShardStorageResolving, Sendable {
    private let locations: [String: V2UserShardStorageLocation]

    /// 建立按原始逻辑标识索引的位置映射。
    ///
    /// - Parameter locations: 部署提供的位置列表，允许为空。
    /// - Throws: 逻辑标识重复时抛出 `duplicateBucket`，不会让后面的配置覆盖前面的配置。
    public init(locations: [V2UserShardStorageLocation]) throws {
        var result: [String: V2UserShardStorageLocation] = [:]
        for location in locations {
            guard result[location.bucket] == nil else { throw V2UserShardStorageRegistryError.duplicateBucket }
            result[location.bucket] = location
        }
        self.locations = result
    }

    /// 按原字符串精确查找，不修剪空白、不重新计算分片，也不回退到其他位置。
    ///
    /// - Parameter bucket: 需要解析的逻辑标识。
    /// - Returns: 初始化时保存的位置。
    /// - Throws: 未配置时抛出 `unknownBucket`。
    public func location(for bucket: String) throws -> V2UserShardStorageLocation {
        guard let location = locations[bucket] else { throw V2UserShardStorageRegistryError.unknownBucket }
        return location
    }
}
