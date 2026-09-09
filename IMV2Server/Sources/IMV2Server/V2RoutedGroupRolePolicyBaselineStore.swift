import Fluent
import Foundation
import IMV2Core

public struct V2RoutedGroupRolePolicyBaselineStore: V2GroupRolePolicyBaselineReading {
    private let router: any V2RoomShardRouting
    private let stores: [String: any V2GroupRolePolicyBaselineReading]

    /// The recovery baseline must use fresh control-plane reads. A cached
    /// routing hint is insufficient for the post-read epoch check.
    public init(controlDatabase: any Database, stores: [String: any V2GroupRolePolicyBaselineReading]) throws {
        try self.init(router: V2PostgresRoomShardRouter(database: controlDatabase), stores: stores)
    }

    // Internal injection supports deterministic route-transition tests while
    // the public constructor always selects the uncached PostgreSQL directory.
    init(router: any V2RoomShardRouting, stores: [String: any V2GroupRolePolicyBaselineReading]) throws {
        guard !stores.isEmpty, stores.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw V2RoomShardStorageRegistryError.invalidLocation
        }
        self.router = router
        self.stores = stores
    }

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
