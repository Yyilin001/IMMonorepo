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

    /// Physical identity comes from composition, never from database existential identity.
    /// Keys may contain private connection information and are never included in errors.
    public init(databases: [String: any Database], timeouts: V2RoomActivationSQLTimeouts = .default,
                physicalRegistrationKeys: [String: String]? = nil,
                sqlContinuationMetricsByOwner: [String: V2SendOperationBatchMetrics] = [:]) throws {
        guard !databases.isEmpty else { throw V2ActorContractError.invalidConfiguration("room lease databases") }
        for key in databases.keys { _ = try V2RoomDataOwner(shardID: key, epoch: 0) }
        guard let physicalRegistrationKeys else {
            self.stores = Dictionary(uniqueKeysWithValues: databases.map { owner, database in
                (owner, Self.makeStore(database: database, timeouts: timeouts,
                    sqlContinuationMetrics: sqlContinuationMetricsByOwner[owner]))
            })
            return
        }
        guard Set(physicalRegistrationKeys.keys) == Set(databases.keys),
              physicalRegistrationKeys.values.allSatisfy({ key in
                  !key.isEmpty && key.contains(where: { !$0.isWhitespace })
              }) else {
            throw V2ActorContractError.invalidConfiguration("room lease physical registration keys")
        }
        var physicalStores: [String: PostgresV2RoomActivationStore] = [:]
        var aliases: [String: PostgresV2RoomActivationStore] = [:]
        for ownerID in databases.keys.sorted() {
            let physicalKey = physicalRegistrationKeys[ownerID]!
            if let store = physicalStores[physicalKey] {
                aliases[ownerID] = store
            } else {
                let store = Self.makeStore(database: databases[ownerID]!, timeouts: timeouts,
                    sqlContinuationMetrics: sqlContinuationMetricsByOwner[ownerID])
                physicalStores[physicalKey] = store
                aliases[ownerID] = store
            }
        }
        self.stores = aliases
    }

    private static func makeStore(database: any Database, timeouts: V2RoomActivationSQLTimeouts, sqlContinuationMetrics: V2SendOperationBatchMetrics?) -> PostgresV2RoomActivationStore {
        // The Store derives its activation facade once from this physical
        // database; renewal uses the reserved facade of the same gate. Physical
        // aliases copy the exact Store, including both lifecycle facades.
        let renewalDatabase = (database as? V2EventLoopBalancedDatabase)?.usingLoanClass(.renewal)
        return .init(database: database, timeouts: timeouts, renewalDatabase: renewalDatabase, sqlContinuationMetrics: sqlContinuationMetrics)
    }

    /// Internal identity evidence for composition tests; no physical keys or credentials escape.
    var renewalBatcherIdentities: [String: ObjectIdentifier] {
        stores.mapValues(\.renewalBatcherIdentity)
    }

    var lifecycleBatcherIdentities: [String: ObjectIdentifier] {
        stores.mapValues(\.lifecycleBatcherIdentity)
    }

    /// The factory's restore validator must share the exact physical Store,
    /// including per-room exclusion, deadlines and actual transaction drain.
    public func validate(token: V2RoomActivationToken) async throws {
        try await store(token.owner).validate(token: token)
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

    public func shutdownRenewals() async {
        var drained: Set<ObjectIdentifier> = []
        for store in stores.values where drained.insert(store.renewalBatcherIdentity).inserted {
            await store.shutdownRenewals()
        }
    }

    /// Only the application owning these physical stores may close lifecycle
    /// admission, after its Hosts have finished their release operations.
    public func shutdownLifecycle() async {
        var drained: Set<ObjectIdentifier> = []
        for store in stores.values where drained.insert(store.lifecycleBatcherIdentity).inserted {
            await store.shutdownLifecycle()
        }
    }

    private func store(_ owner: V2RoomDataOwner) throws -> PostgresV2RoomActivationStore {
        guard let store = stores[owner.shardID] else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return store
    }
}
