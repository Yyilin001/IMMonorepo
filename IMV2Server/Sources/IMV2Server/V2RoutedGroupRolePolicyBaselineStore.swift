import FluentKit
import Foundation
import IMV2Core

/// 按房间归属路由到对应分片存储的角色策略基线读取器。
public struct V2RoutedGroupRolePolicyBaselineStore: V2GroupRolePolicyBaselineReading {
    private let router: any V2RoomShardRouting
    private let stores: [String: any V2GroupRolePolicyBaselineReading]

    /// 以控制面数据库构造读取器。
    ///
    /// 恢复基线必须使用实时的控制面读取：读取后的代次复核不能用缓存路由提示替代，
    /// 否则迁移期间可能返回旧归属的基线。
    ///
    /// - Parameters:
    ///   - controlDatabase: 提供房间归属目录的数据库。
    ///   - stores: 逻辑分片标识到基线读取实现的映射。
    /// - Throws: 映射为空或含纯空白逻辑标识时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    public init(controlDatabase: any Database, stores: [String: any V2GroupRolePolicyBaselineReading]) throws {
        try self.init(router: V2PostgresRoomShardRouter(database: controlDatabase), stores: stores)
    }

    // Internal injection supports deterministic route-transition tests while
    // the public constructor always selects the uncached PostgreSQL directory.
    /// 注入路由实现构造读取器，供路由切换测试使用。
    ///
    /// - Parameters:
    ///   - router: 房间归属来源，测试可注入确定性实现。
    ///   - stores: 逻辑分片标识到基线读取实现的映射。
    /// - Throws: 映射为空或含纯空白逻辑标识时抛出
    ///   ``V2RoomShardStorageRegistryError/invalidLocation``。
    init(router: any V2RoomShardRouting, stores: [String: any V2GroupRolePolicyBaselineReading]) throws {
        guard !stores.isEmpty, stores.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        self.router = router
        self.stores = stores
    }

    /// 读取房间角色策略基线，并在返回前复核归属未发生迁移。
    ///
    /// 读取结果必须与请求房间一致；读取后归属若已变化，说明基线来自旧归属，
    /// 此时直接报错而不是静默回退到其他归属或代次。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起读取的用户。
    /// - Returns: 与请求房间一致且归属未变化的策略基线。
    /// - Throws: 未配置对应分片存储时抛出
    ///   ``V2RoomShardStorageRegistryError/unknownShardID``；返回房间不符时抛出
    ///   ``V2GroupRolePolicyBaselineError/corruptPersistenceState``；读取期间归属变化时抛出
    ///   ``V2RoomShardRouteError/routeConflict``。
    public func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupRolePolicyBaseline {
        let route = try await router.route(for: roomID)
        guard let store = stores[route.shardID] else { throw V2RoomShardStorageRegistryError.unknownShardID }
        let value = try await store.readRolePolicyBaseline(roomID: roomID, actorUserID: actorUserID)
        guard value.roomID == roomID else { throw V2GroupRolePolicyBaselineError.corruptPersistenceState }
        // A late read from the prior owner must not become a recovery baseline.
        // Surface the change; do not silently try a fallback owner or epoch.
        guard try await router.route(for: roomID) == route else { throw V2RoomShardRouteError.routeConflict }
        return value
    }
}
