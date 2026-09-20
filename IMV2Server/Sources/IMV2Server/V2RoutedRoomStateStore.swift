import Foundation
import IMV2Core

/// Group requested identities by owner; a missing room cannot hide other results.
/// Requires an authoritative router and revalidates ownership after each read.
public struct V2RoutedRoomStateStore: V2RoomStateReading {
    private let router: any V2RoomShardRouting
    private let read: @Sendable (String, [RoomID], UserID) async throws -> [RoomID: V2RoomStateReadResult]

    public init(router: any V2RoomShardRouting, registry: any V2RoomShardStorageResolving) {
        self.router = router
        self.read = { shard, rooms, user in
            let location = try registry.location(for: shard)
            return try await PostgresV2RoomRecoveryStore(database: location.database, schema: location.schema)
                .states(roomIDs: rooms, actorUserID: user)
        }
    }

    init(router: any V2RoomShardRouting,
         read: @escaping @Sendable (String, [RoomID], UserID) async throws -> [RoomID: V2RoomStateReadResult]) {
        self.router = router; self.read = read
    }

    public func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        guard !roomIDs.isEmpty, roomIDs.count <= 100, actorUserID.uuidValue != nil,
              roomIDs.allSatisfy({ $0.uuidValue != nil }) else { throw V2RoomRecoveryReadError.invalidRequest }
        let ids = Array(Set(roomIDs)).sorted { $0.rawValue < $1.rawValue }
        var result = Dictionary(uniqueKeysWithValues: ids.map { ($0, V2RoomStateReadResult.retry) })
        let routes: [RoomID: V2RoomShardRoute]
        do {
            routes = try await router.routes(for: ids)
        } catch V2RoomShardRouteError.roomNotFound {
            // The existing router's batch contract is all-or-nothing. Resolve the
            // bounded exceptional batch individually without exposing existence.
            var partial: [RoomID: V2RoomShardRoute] = [:]
            for id in ids {
                try Task.checkCancellation()
                do { partial[id] = try await router.route(for: id) }
                catch V2RoomShardRouteError.roomNotFound { result[id] = .unavailable }
                catch is CancellationError { throw CancellationError() }
                catch { result[id] = .retry }
            }
            routes = partial
        } catch is CancellationError { throw CancellationError() }
        catch { return result }
        let grouped = Dictionary(grouping: ids.filter { routes[$0] != nil }, by: { routes[$0]!.shardID })
        // Serial owner groups keep request concurrency bounded without launching
        // one task/connection per room. Each owner uses one array lookup.
        for shard in grouped.keys.sorted() {
            try Task.checkCancellation()
            let group = grouped[shard]!
            do {
                let observations = try await read(shard, group, actorUserID)
                try Task.checkCancellation()
                let current = try await router.routes(for: group)
                try Task.checkCancellation()
                for id in group {
                    // Even absence belongs to an owner: a migration copy cannot
                    // revoke local data after that owner has changed.
                    guard current[id] == routes[id] else { continue }
                    guard let observation = observations[id] else { throw V2RoomRecoveryReadError.corruptPersistence }
                    if case .state(let state) = observation,
                       (state.ownerEpoch != UInt64(routes[id]!.epoch) || state.roomID != id) {
                        result[id] = .retry
                    } else { result[id] = observation }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { for id in group { result[id] = .retry } }
        }
        return result
    }
}
