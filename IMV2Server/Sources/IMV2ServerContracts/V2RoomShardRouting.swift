import Foundation
import IMV2Core

/// 房间持久化归属的逻辑分片标识及路由代次。
///
/// 不携带主机名或数据库连接信息，实际存储由部署配置单独解析。
/// 路由仅决定访问位置，不代表调用方具有房间访问权限。
public struct V2RoomShardRoute: Equatable, Sendable {
    /// 去除首尾空白后的非空逻辑分片标识。
    public let shardID: String
    /// 非负路由代次；新用户对提议路由使用零。
    public let epoch: Int64

    /// 规范化并验证路由值。
    ///
    /// - Parameters:
    ///   - shardID: 逻辑分片标识，首尾空白与换行会被移除。
    ///   - epoch: 非负路由代次。
    /// - Throws: 规范化后的标识为空或代次为负时抛出 ``V2RoomShardRouteError/invalidRoute``。
    public init(shardID: String, epoch: Int64) throws {
        let normalized = shardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, epoch >= 0 else {
            throw V2RoomShardRouteError.invalidRoute
        }
        self.shardID = normalized
        self.epoch = epoch
    }
}

/// 房间归属查询与目录登记使用的领域错误。
public enum V2RoomShardRouteError: Error, Equatable, Sendable {
    /// 分片标识为空或路由代次为负。
    case invalidRoute
    /// 显式归属目录和历史房间记录均不能提供完整的请求路由。
    case roomNotFound
    /// 已有房间或用户对的持久化归属与本次登记结果不一致。
    case routeConflict
    /// 标识、数据库适配能力或待持久化时间不满足路由存储要求。
    case corruptPersistenceState
}

/// 解析已存在房间的持久化归属，供调用方选择归属存储。
///
/// 目录属于控制面，不保存第二份权威消息状态；实现可通过缓存提示加速查询。
public protocol V2RoomShardRouting: Sendable {
    /// 解析单个房间归属。
    ///
    /// - Parameter roomID: 已存在房间的标识。
    /// - Returns: 分片标识与路由代次。
    /// - Throws: 房间不存在、路由无效或底层目录查询错误。
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute
    /// 批量解析房间归属，默认实现逐个查询去重后的房间。
    ///
    /// - Parameter roomIDs: 待解析标识，可含重复项；调用方负责限制批次规模。
    /// - Returns: 不同房间到路由的映射，空输入返回空字典。
    /// - Throws: 任一房间解析失败时抛错，不返回部分结果。
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute]
}

public extension V2RoomShardRouting {
    /// 为不支持集合查询的路由器提供顺序批量适配。
    ///
    /// - Parameter roomIDs: 原始请求标识，重复项在首次查询成功后跳过。
    /// - Returns: 每个不同房间对应的路由；不会并行发起查询。
    /// - Throws: 第一个失败的单房间查询错误，其前面已经发生的读取不会回滚。
    func routes(for roomIDs: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        var routes: [RoomID: V2RoomShardRoute] = [:]
        routes.reserveCapacity(roomIDs.count)
        for roomID in roomIDs {
            if routes[roomID] == nil {
                routes[roomID] = try await route(for: roomID)
            }
        }
        return routes
    }
}

/// 在尚无房间标识的私聊创建阶段，为用户对选择稳定归属并保护目录登记。
///
/// PostgreSQL 实现以控制面事务级建议锁串行化同一用户对的创建。
/// 回调可执行一次有界的归属存储创建或重放事务；它与控制面事务不是同一个原子提交。
public protocol V2DirectRoomShardRouting: V2RoomShardRouting {
    /// 在用户对归属保护范围内执行业务操作。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起用户。
    ///   - targetUserID: 目标用户，反向用户对也应映射到同一归属。
    ///   - proposedShardID: 用户对尚无显式记录时提议的分片。
    ///   - operation: 使用选定路由执行创建或重放，返回业务结果及可选房间标识。
    /// - Returns: 回调的业务结果；外层目录操作成功后才返回。
    /// - Throws: 路由选择、回调或目录登记失败。回调已提交的归属存储事务不由目录回滚撤销。
    func withDirectPairRoute<Result: Sendable>(
        actorUserID: UserID,
        targetUserID: UserID,
        proposedShardID: String,
        deadline: ContinuousClock.Instant?,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (result: Result, roomID: RoomID?)
    ) async throws -> Result
}
