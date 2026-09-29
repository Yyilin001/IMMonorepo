@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 cached room shard router")
struct V2CachedRoomShardRouterTests {
    @Test("an expired entry retains its epoch while a newer refresh is waiting")
    func refreshInFlightPreservesEpoch() async throws {
        let base = ContinuousClock.now
        let clock = Mutex(base)
        let room = RoomID(uuid: UUID())
        let old = try V2RoomShardRoute(shardID: "rooms-old", epoch: 1)
        let newer = try V2RoomShardRoute(shardID: "rooms-new", epoch: 2)
        let source = LateCachedRouterSource(path: "scalar", old: old, latest: newer, pauseRefresh: true)
        let router = V2CachedRoomShardRouter(source: source, capacity: 1, lifetime: .seconds(2), now: { clock.withLock { $0 } })
        let oldRead = Task { try await router.route(for: room) }
        await source.waitForOldRead()
        clock.withLock { $0 = base + .seconds(1) }
        #expect(try await router.route(for: room) == newer)
        clock.withLock { $0 = base + .seconds(4) }
        let refresh = Task { try await router.route(for: room) }
        await source.waitForRefresh()
        // The expired-cache miss must not erase the known epoch before
        // either of these two outstanding reads has finished.
        await source.releaseOldRead()
        #expect(try await oldRead.value == newer)
        await source.releaseRefresh()
        #expect(try await refresh.value == newer)
        #expect(try await router.route(for: room) == newer)
        #expect(await source.scalarCalls() == 3)
    }

    @Test("late directory results retain the newer cached epoch without extending its deadline", arguments: ["scalar", "batch", "direct"], [false, true])
    func lateResultKeepsNewerRoute(path: String, expired: Bool) async throws {
        let base = ContinuousClock.now
        let clock = Mutex(base)
        let room = RoomID(uuid: UUID())
        let old = try V2RoomShardRoute(shardID: "rooms-old", epoch: Int64.max - 1)
        let newer = try V2RoomShardRoute(shardID: "rooms-new", epoch: Int64.max)
        let source = LateCachedRouterSource(path: path, old: old, latest: newer)
        let router = V2CachedRoomShardRouter(source: source, capacity: 1, lifetime: .seconds(2), now: { clock.withLock { $0 } })
        let pending = Task { () async throws -> V2RoomShardRoute? in
            switch path {
            case "scalar": return try await router.route(for: room)
            case "batch": return try await router.routes(for: [room, room])[room]
            default:
                let result: String = try await router.withDirectPairRoute(actorUserID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()), proposedShardID: old.shardID) { route in
                    #expect(route == old)
                    return ("owner committed", room)
                }
                #expect(result == "owner committed")
                return nil
            }
        }
        await source.waitForOldRead()
        clock.withLock { $0 = base + .seconds(1) }
        // The old read has observed its result but is still waiting to return.
        #expect(try await router.route(for: room) == newer)
        clock.withLock { $0 = base + .seconds(expired ? 4 : 2) }
        await source.releaseOldRead()
        let completed = try await pending.value
        #expect(completed == (path == "direct" ? nil : newer))
        #expect(await source.scalarCalls() == (path == "scalar" ? 2 : 1))
        // An expired newer entry must still trigger a refresh; the late
        // older result cannot revive itself with a fresh two-second TTL.
        #expect(try await router.route(for: room) == newer)
        let calls = await source.scalarCalls()
        #expect(calls == (path == "scalar" ? 2 : 1) + (expired ? 1 : 0))
        let deadline = base + .seconds(expired ? 6 : 3)
        clock.withLock { $0 = deadline - .nanoseconds(1) }
        #expect(try await router.route(for: room) == newer)
        #expect(await source.scalarCalls() == calls)
        clock.withLock { $0 = deadline }
        #expect(try await router.route(for: room) == newer)
        #expect(await source.scalarCalls() == calls + 1)
    }

    @Test("cache capacity arithmetic accepts Int boundaries without eager entry allocation", arguments: [Int.min, 0, 1, Int.max], [1, 2, 64])
    func capacityArithmeticBounds(capacity: Int, bucketCount: Int) async throws {
        let first = RoomID(uuid: UUID()), second = RoomID(uuid: UUID())
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 1)
        let expected = [first: route, second: route]
        let source = CachedRouterSource(routes: expected)
        let router = V2CachedRoomShardRouter(source: source, capacity: capacity, bucketCount: bucketCount)
        #expect(try await router.route(for: first) == route)
        #expect(try await router.route(for: second) == route)
        #expect(try await router.routes(for: [first, second, first]) == expected)
        let batches = await source.batchRequests()
        #expect(batches.count == (capacity == Int.max ? 0 : 1))
        if capacity != Int.max { #expect(batches.first?.count == 1) }
    }

    @Test("bucket allocation cannot exceed the normalized entry budget", arguments: [Int.min, 0, Int.max])
    func bucketCountBounds(bucketCount: Int) async throws {
        let room = RoomID(uuid: UUID())
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 1)
        let source = CachedRouterSource(routes: [room: route])
        let router = V2CachedRoomShardRouter(source: source, capacity: 1, bucketCount: bucketCount)
        #expect(try await router.route(for: room) == route)
        #expect(try await router.route(for: room) == route)
        #expect(await source.scalarCalls() == 1)
    }

    @Test("uneven bucket budgets never cache more than the configured capacity", arguments: [1, 5, 17])
    func exactCapacityBudget(capacity: Int) async throws {
        let rooms = (0..<192).map { _ in RoomID(uuid: UUID()) }
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 1)
        let expected = Dictionary(uniqueKeysWithValues: rooms.map { ($0, route) })
        let source = CachedRouterSource(routes: expected)
        let router = V2CachedRoomShardRouter(source: source, capacity: capacity, bucketCount: capacity == 5 ? 2 : 64)
        for room in rooms { #expect(try await router.route(for: room) == route) }
        #expect(await source.scalarCalls() == rooms.count)
        #expect(try await router.routes(for: rooms) == expected)
        let misses = try #require(await source.batchRequests().first)
        let cachedCount = rooms.count - misses.count
        #expect(cachedCount > 0)
        #expect(cachedCount <= capacity)
    }

    @Test("a same-sized batch with wrong room IDs cannot return or seed partial routes", arguments: [false, true])
    func mismatchedBatchIsAtomic(warm: Bool) async throws {
        let first = RoomID(uuid: UUID()), second = RoomID(uuid: UUID()), unexpected = RoomID(uuid: UUID())
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 1)
        let wrong = try V2RoomShardRoute(shardID: "rooms-wrong", epoch: 99)
        let returned = warm ? [unexpected: wrong] : [first: route, unexpected: wrong]
        let source = CachedRouterSource(routes: [first: route, second: route, unexpected: route], batchOverride: returned)
        let router = V2CachedRoomShardRouter(source: source, capacity: 16, bucketCount: 1)
        if warm { #expect(try await router.route(for: first) == route) }
        await #expect(throws: V2RoomShardRouteError.roomNotFound) { try await router.routes(for: [first, second, first]) }
        #expect(try await router.route(for: unexpected) == route)
        #expect(try await router.route(for: first) == route)
        #expect(try await router.route(for: second) == route)
        #expect(await source.scalarCalls() == 3)
    }

    @Test("cache expires at its monotonic deadline and hits do not extend its lifetime", arguments: [Duration.zero, .seconds(-1), .seconds(Int64.min), .seconds(2)])
    func expirationBoundary(lifetime: Duration) async throws {
        let base = ContinuousClock.now
        let clock = Mutex(base)
        let room = RoomID(uuid: UUID())
        let first = try V2RoomShardRoute(shardID: "rooms-a", epoch: 1)
        let second = try V2RoomShardRoute(shardID: "rooms-b", epoch: 2)
        let third = try V2RoomShardRoute(shardID: "rooms-c", epoch: 3)
        let source = CachedRouterSource(routes: [room: first])
        let router = V2CachedRoomShardRouter(source: source, capacity: 1, lifetime: lifetime, now: { clock.withLock { $0 } })
        #expect(try await router.route(for: room) == first)
        await source.setRoute(second, for: room)
        let interval: Duration = lifetime == .seconds(2) ? .seconds(2) : .seconds(1)
        clock.withLock { $0 = base + interval - .nanoseconds(1) }
        #expect(try await router.route(for: room) == first)
        #expect(await source.scalarCalls() == 1)
        clock.withLock { $0 = base + interval }
        #expect(try await router.route(for: room) == second)
        await source.setRoute(third, for: room)
        clock.withLock { $0 = base + interval + .milliseconds(500) }
        #expect(try await router.route(for: room) == second)
        clock.withLock { $0 = base + interval + interval }
        #expect(try await router.route(for: room) == third)
        #expect(await source.scalarCalls() == 3)
    }

    @Test("the largest seconds lifetime remains usable without a wall-clock conversion")
    func largeLifetime() async throws {
        let base = ContinuousClock.now
        let clock = Mutex(base)
        let room = RoomID(uuid: UUID())
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 1)
        let source = CachedRouterSource(routes: [room: route])
        let router = V2CachedRoomShardRouter(source: source, lifetime: .seconds(Int64.max), now: { clock.withLock { $0 } })
        #expect(try await router.route(for: room) == route)
        clock.withLock { $0 = base + .seconds(3_600) }
        #expect(try await router.route(for: room) == route)
        #expect(await source.scalarCalls() == 1)
    }

    @Test("a directory failure after owner success cannot publish the proposed route")
    func failedDirectoryCommitDoesNotSeedCache() async throws {
        let room = RoomID(uuid: UUID())
        let route = try V2RoomShardRoute(shardID: "rooms-a", epoch: 1)
        let source = CachedRouterSource(routes: [room: route], failAfterCallback: true)
        let router = V2CachedRoomShardRouter(source: source, capacity: 16, bucketCount: 2)
        await #expect(throws: V2RoomShardRouteError.corruptPersistenceState) {
            let _: String = try await router.withDirectPairRoute(actorUserID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()), proposedShardID: route.shardID) { _ in
                ("owner committed", room)
            }
        }
        #expect(try await router.route(for: room) == route)
        #expect(await source.scalarCalls() == 1)
    }

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

private actor LateCachedRouterSource: V2DirectRoomShardRouting {
    let path: String
    let old: V2RoomShardRoute
    private let latest: V2RoomShardRoute
    private var scalarCount = 0
    private var started = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?
    private let pauseRefresh: Bool
    private var refreshStarted = false
    private var refreshObservers: [CheckedContinuation<Void, Never>] = []
    private var refreshPending: CheckedContinuation<Void, Never>?

    init(path: String, old: V2RoomShardRoute, latest: V2RoomShardRoute, pauseRefresh: Bool = false) {
        self.path = path; self.old = old; self.latest = latest; self.pauseRefresh = pauseRefresh
    }

    private func pauseOldRead() async {
        started = true
        let waiting = observers
        observers.removeAll()
        for observer in waiting { observer.resume() }
        await withCheckedContinuation { pending = $0 }
    }

    func waitForOldRead() async {
        if !started { await withCheckedContinuation { observers.append($0) } }
    }

    func releaseOldRead() { pending?.resume(); pending = nil }
    func scalarCalls() -> Int { scalarCount }

    func waitForRefresh() async {
        if !refreshStarted { await withCheckedContinuation { refreshObservers.append($0) } }
    }

    func releaseRefresh() { refreshPending?.resume(); refreshPending = nil }

    func route(for roomID: RoomID) async -> V2RoomShardRoute {
        scalarCount += 1
        if path == "scalar", !started {
            await pauseOldRead()
            return old
        }
        if pauseRefresh, scalarCount == 3 {
            refreshStarted = true
            let waiting = refreshObservers
            refreshObservers.removeAll()
            for observer in waiting { observer.resume() }
            await withCheckedContinuation { refreshPending = $0 }
        }
        return latest
    }

    func routes(for roomIDs: [RoomID]) async -> [RoomID: V2RoomShardRoute] {
        if path == "batch", !started {
            await pauseOldRead()
            return Dictionary(uniqueKeysWithValues: Set(roomIDs).map { ($0, old) })
        }
        return Dictionary(uniqueKeysWithValues: Set(roomIDs).map { ($0, latest) })
    }

    func withDirectPairRoute<Result: Sendable>(actorUserID: UserID, targetUserID: UserID, proposedShardID: String, deadline: ContinuousClock.Instant?,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (result: Result, roomID: RoomID?)) async throws -> Result {
        let completion = try await operation(old)
        await pauseOldRead()
        return completion.result
    }
}

private actor CachedRouterSource: V2DirectRoomShardRouting {
    private var routeMap: [RoomID: V2RoomShardRoute]
    private let batchOverride: [RoomID: V2RoomShardRoute]?
    private var scalarCount = 0
    private var batchRoomRequests: [[RoomID]] = []

    private let failAfterCallback: Bool
    init(routes: [RoomID: V2RoomShardRoute], failAfterCallback: Bool = false, batchOverride: [RoomID: V2RoomShardRoute]? = nil) {
        routeMap = routes; self.failAfterCallback = failAfterCallback; self.batchOverride = batchOverride
    }

    func setRoute(_ route: V2RoomShardRoute, for room: RoomID) { routeMap[room] = route }

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
        if let batchOverride { return batchOverride }
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
        deadline _: ContinuousClock.Instant?,
        _ operation: @escaping @Sendable (V2RoomShardRoute) async throws -> (
            result: Result, roomID: RoomID?
        )
    ) async throws -> Result {
        guard let route = routeMap.values.first else {
            throw V2RoomShardRouteError.roomNotFound
        }
        let completion = try await operation(route)
        if failAfterCallback { throw V2RoomShardRouteError.corruptPersistenceState }
        return completion.result
    }

    func scalarCalls() -> Int { scalarCount }
    func batchRequests() -> [[RoomID]] { batchRoomRequests }
}
