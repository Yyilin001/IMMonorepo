import FluentKit
import IMV2ActorContracts
import IMV2Core

/// The control directory resolves existing identities only. An unknown room
/// never falls through to a creation path or a newly hashed owner.
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

/// Selects only locally configured database handles. Full owner/activation
/// verification still happens in the chosen physical database transaction.
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
