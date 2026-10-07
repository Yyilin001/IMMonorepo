import IMV2ServerContracts
import FluentKit
import Foundation

/// 部署配置中的房间存储位置；只验证格式，不建立连接或检查 schema 可用性。
public struct V2RoomShardStorageLocation: Sendable {
    public let shardID: String
    public let database: any Database
    public let schema: String

    /// 保留原始逻辑标识，验证其非空和 schema 的标识符格式。
    public init(shardID: String, database: any Database, schema: String) throws {
        guard !shardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        else { throw V2RoomShardStorageRegistryError.invalidLocation }
        self.shardID = shardID
        self.database = database
        self.schema = schema
    }
}
