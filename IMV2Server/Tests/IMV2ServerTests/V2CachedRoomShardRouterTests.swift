import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 cached room shard router")
struct V2CachedRoomShardRouterTests {
    @Test("repeated scalar route is resolved once from durable directory")
    func cachesScalarRoute() async throws {
        let room = try RoomID("00000000-0000-0000-0000-00000000f101")
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 2)
        let source = CachedRouterSource(routes: [room: route])
        let router = V2CachedRoomShardRouter(
            source: source, capacity: 16, bucketCount: 2
        )

        #expect(try await router.route(for: room) == route)
        #expect(try await router.route(for: room) == route)
        #expect(await source.scalarCalls() == 1)
    }

    @Test("batch lookup asks durable directory only for cache misses")
    func resolvesOnlyBatchMisses() async throws {
        let first = try RoomID("00000000-0000-0000-0000-00000000f111")
        let second = try RoomID("00000000-0000-0000-0000-00000000f112")
        let routes = try [
            first: V2RoomShardRoute(shardID: "rooms-a", epoch: 0),
            second: V2RoomShardRoute(shardID: "rooms-b", epoch: 1),
        ]
        let source = CachedRouterSource(routes: routes)
        let router = V2CachedRoomShardRouter(
            source: source, capacity: 16, bucketCount: 2
        )

        _ = try await router.route(for: first)
        #expect(try await router.routes(for: [first, second]) == routes)
        #expect(await source.batchRequests() == [[second]])
    }

    @Test("successful direct creation seeds its room route")
    func directCreationSeedsCache() async throws {
        let room = try RoomID("00000000-0000-0000-0000-00000000f121")
        let actor = try UserID("00000000-0000-0000-0000-00000000f122")
        let target = try UserID("00000000-0000-0000-0000-00000000f123")
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 4)
        let source = CachedRouterSource(routes: [room: route])
        let router = V2CachedRoomShardRouter(
            source: source, capacity: 16, bucketCount: 2
        )

        let result: String = try await router.withDirectPairRoute(
            actorUserID: actor,
            targetUserID: target,
            proposedShardID: route.shardID
        ) { selected in
            #expect(selected == route)
            return ("opened", room)
        }

        #expect(result == "opened")
        #expect(try await router.route(for: room) == route)
        #expect(await source.scalarCalls() == 0)
    }
}

private actor CachedRouterSource: V2DirectRoomShardRouting {
    let routeMap: [RoomID: V2RoomShardRoute]
    private var scalarCount = 0
    private var batchRoomRequests: [[RoomID]] = []

    init(routes: [RoomID: V2RoomShardRoute]) { routeMap = routes }

    func route(for roomID: RoomID) throws -> V2RoomShardRoute {
        scalarCount += 1
        guard let route = routeMap[roomID] else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return route
    }

    func routes(
        for roomIDs: [RoomID]
    ) throws -> [RoomID: V2RoomShardRoute] {
        batchRoomRequests.append(roomIDs)
        return try Dictionary(uniqueKeysWithValues: roomIDs.map { roomID in
            guard let route = routeMap[roomID] else {
                throw V2RoomShardRouteError.roomNotFound
            }
            return (roomID, route)
        })
    }

    func withDirectPairRoute<Result: Sendable>(
        actorUserID _: UserID,
        targetUserID _: UserID,
        proposedShardID _: String,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (
            result: Result, roomID: RoomID?
        )
    ) async throws -> Result {
        guard let route = routeMap.values.first else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return try await operation(route).result
    }

    func scalarCalls() -> Int { scalarCount }
    func batchRequests() -> [[RoomID]] { batchRoomRequests }
}
