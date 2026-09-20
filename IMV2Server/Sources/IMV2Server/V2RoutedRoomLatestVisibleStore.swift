import Foundation
import IMV2Core

/// Requires an authoritative (uncached) router. Revalidating after each owner
/// read prevents a migration copy from being returned after ownership moved.
public struct V2RoutedRoomLatestVisibleStore: V2RoomLatestVisibleReading {
    private let router: any V2RoomShardRouting
    private let read: @Sendable (String, [RoomID], UserID) async throws -> [RoomID: V2RoomLatestVisibleResult]

    public init(router: any V2RoomShardRouting, registry: any V2RoomShardStorageResolving) {
        self.router = router
        self.read = { shard, rooms, user in
            let location = try registry.location(for: shard)
            return try await PostgresV2RoomLatestVisibleStore(database: location.database, schema: location.schema)
                .latestVisible(roomIDs: rooms, actorUserID: user)
        }
    }

    init(router: any V2RoomShardRouting,
         read: @escaping @Sendable (String, [RoomID], UserID) async throws -> [RoomID: V2RoomLatestVisibleResult]) {
        self.router = router; self.read = read
    }

    public func latestVisible(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomLatestVisibleResult] {
        guard !roomIDs.isEmpty, roomIDs.count <= 100, actorUserID.uuidValue != nil,
              roomIDs.allSatisfy({ $0.uuidValue != nil }) else { throw V2RoomRecoveryReadError.invalidRequest }
        try Task.checkCancellation()
        let ids = Array(Set(roomIDs)).sorted { $0.rawValue < $1.rawValue }
        var result = Dictionary(uniqueKeysWithValues: ids.map { ($0, V2RoomLatestVisibleResult.retry) })
        var routes: [RoomID: V2RoomShardRoute]
        do { routes = try await router.routes(for: ids) }
        catch V2RoomShardRouteError.roomNotFound {
            routes = [:]
            for id in ids {
                try Task.checkCancellation()
                do { routes[id] = try await router.route(for: id) }
                catch V2RoomShardRouteError.roomNotFound { result[id] = .unavailable }
                catch is CancellationError { throw CancellationError() }
                catch { }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return result }
        // Ignore unsolicited routing entries, but keep missing requested entries retryable.
        let groups = Dictionary(grouping: ids.filter { routes[$0] != nil }, by: { routes[$0]!.shardID })
        for shard in groups.keys.sorted() {
            try Task.checkCancellation()
            guard let group = groups[shard] else { continue }
            do {
                let observations = try await read(shard, group, actorUserID)
                try Task.checkCancellation()
                let current = try await router.routes(for: group)
                try Task.checkCancellation()
                for room in group {
                    guard let original = routes[room], current[room] == original,
                          let observation = observations[room] else { continue }
                    if case .snapshot(let snapshot) = observation {
                        guard snapshot.roomID == room, original.epoch >= 0,
                              snapshot.ownerEpoch == UInt64(original.epoch) else { continue }
                    }
                    result[room] = observation
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Failed owner groups retain explicit retry results. */ }
        }
        return result
    }
}
