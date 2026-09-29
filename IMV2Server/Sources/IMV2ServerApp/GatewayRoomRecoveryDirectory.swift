import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Server
import IMV2ServerInfrastructure

/// 按物理存储分组构造房间恢复目录；不启动后台任务或持有额外连接池。
/// 目录按房间归属读取，客户端仍按有效活动事实自行排序。
enum GatewayRoomRecoveryDirectory {
    static func build(
        configuration: V2GatewayRuntimeConfiguration,
        topology: GatewayDatabaseTopology
    ) throws -> V2UserRoomDirectoryService {
        // 恢复扫描使用不经缓存的控制面路由，避免过期归属缓存参与校验。
        let recoveryRouter = V2PostgresRoomShardRouter(database: topology.syncControlDatabase)
        let storageGroups = Dictionary(grouping: configuration.roomShardStorage) {
            $0.databaseURL + "\u{0}" + $0.schema
        }
        var stores: [any V2UserRoomDirectoryReading] = []
        var storageIdentities: [String] = []
        for key in storageGroups.keys.sorted() {
            guard let group = storageGroups[key], let first = group.first,
                  let owner = topology.databaseForRole(for: .sync, url: first.databaseURL) else {
                throw V2RoomRecoveryReadError.corruptPersistence
            }
            let shardIDs = Set(group.map(\.shardID))
            let store = try PostgresV2RoomRecoveryStore(database: owner, schema: first.schema)
            stores.append(try V2OwnerValidatedRoomDirectoryStore(
                underlying: store, router: recoveryRouter, physicalStoreShardIDs: shardIDs))
            // 部署指纹同时包含别名与物理身份；连接材料只参与哈希，不对外返回。
            storageIdentities.append(try JSONEncoder().encode([key] + shardIDs.sorted()).base64EncodedString())
            // 逐个校验分片位置格式；目录只需要存储句柄，不需要保存位置对象。
            for shardID in shardIDs.sorted() {
                _ = try V2RoomShardStorageLocation(shardID: shardID, database: owner, schema: first.schema)
            }
        }
        let recoveryTopology = try PostgresV2RoomRecoveryTopology(
            database: topology.syncControlDatabase,
            stores: stores,
            orderedStoreIdentities: storageIdentities
        )
        return V2UserRoomDirectoryService(
            topologySource: recoveryTopology,
            cursorCodec: try .init(key: Data(configuration.accessTokenKey
                .digest("im-v2-room-recovery-cursor-root-v1").utf8))
        )
    }
}
