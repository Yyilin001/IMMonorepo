import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorContracts
import IMV2Core

/// 控制目录只解析已有身份。未知房间不会落入创建路径，
/// 也不会被分配给重新计算哈希所得的所有者。
public struct V2RoomServerOwnerResolver: V2RoomDataOwnerResolving {
    private let router: any V2RoomShardRouting

    public init(router: any V2RoomShardRouting) { self.router = router }

    public func owner(for roomID: RoomID) async throws -> V2RoomDataOwner {
        do {
            let route = try await router.route(for: roomID)
            return try .init(shardID: route.shardID, epoch: route.epoch)
        } catch V2RoomShardRouteError.roomNotFound {
            throw V2RoomActivationLeaseError.roomNotFound
        }
    }
}

/// 仅选择本地配置的数据库句柄。完整的所有者与激活校验
/// 仍在选定的物理数据库事务中进行。
public struct V2RoomServerLeaseStore: V2RoomActivationLeaseStore {
    private let stores: [String: PostgresV2RoomActivationStore]

    public init(databases: [String: any Database], timeouts: V2RoomActivationSQLTimeouts = .default) throws {
        guard !databases.isEmpty else { throw V2ActorContractError.invalidConfiguration("room lease databases") }
        for key in databases.keys { _ = try V2RoomDataOwner(shardID: key, epoch: 0) }
        self.stores = databases.mapValues { .init(database: $0, timeouts: timeouts) }
    }

    public func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
        try await store(owner).locate(roomID: roomID, owner: owner)
    }

    public func acquire(roomID: RoomID, owner: V2RoomDataOwner, host: V2ActorHostIdentity,
                        duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
        try await store(owner).acquire(roomID: roomID, owner: owner, host: host, duration: duration)
    }

    public func renew(token: V2RoomActivationToken, duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
        try await store(token.owner).renew(token: token, duration: duration)
    }

    public func release(token: V2RoomActivationToken) async throws -> Bool {
        try await store(token.owner).release(token: token)
    }

    private func store(_ owner: V2RoomDataOwner) throws -> PostgresV2RoomActivationStore {
        guard let store = stores[owner.shardID] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return store
    }
}
