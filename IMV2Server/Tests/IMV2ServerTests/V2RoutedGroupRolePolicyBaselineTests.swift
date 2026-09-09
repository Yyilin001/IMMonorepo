import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 routed role policy baseline")
struct V2RoutedGroupRolePolicyBaselineTests {
    let room = try! RoomID("00000000-0000-0000-0000-000000000A01")
    let actor = try! UserID("00000000-0000-0000-0000-000000000A02")

    @Test("baseline uses the selected owner and preserves actor and explicit empty policy")
    func selectedOwner() async throws {
        let router = try BaselineRouter(epochs: [7, 7])
        let owner = BaselineRecorder()
        let fallback = BaselineRecorder()
        let store = try V2RoutedGroupRolePolicyBaselineStore(router: router, stores: ["current": owner, "fallback": fallback])
        let baseline = try await store.readRolePolicyBaseline(roomID: room, actorUserID: actor)
        #expect(baseline.memberPermissions.isEmpty)
        #expect(await owner.requests() == [.init(room: room, actor: actor)])
        #expect(await fallback.requests().isEmpty)
        #expect(await router.readCount() == 2)
    }

    @Test("a baseline from a changed owner epoch is rejected")
    func epochFence() async throws {
        let store = try V2RoutedGroupRolePolicyBaselineStore(router: BaselineRouter(epochs: [7, 8]), stores: ["current": BaselineRecorder()])
        await #expect(throws: V2RoomShardRouteError.routeConflict) { try await store.readRolePolicyBaseline(roomID: room, actorUserID: actor) }
    }

    @Test("owner authorization errors cannot fall back to another store")
    func noFallback() async throws {
        let fallback = BaselineRecorder()
        let store = try V2RoutedGroupRolePolicyBaselineStore(router: BaselineRouter(epochs: [7]), stores: ["current": BaselineRecorder(denied: true), "fallback": fallback])
        await #expect(throws: V2GroupRolePolicyBaselineError.actorNotMember) { try await store.readRolePolicyBaseline(roomID: room, actorUserID: actor) }
        #expect(await fallback.requests().isEmpty)
        let missing = try V2RoutedGroupRolePolicyBaselineStore(router: BaselineRouter(epochs: [7]), stores: ["fallback": fallback])
        await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) { try await missing.readRolePolicyBaseline(roomID: room, actorUserID: actor) }
    }
}

private actor BaselineRouter: V2RoomShardRouting {
    let routes: [V2RoomShardRoute]
    private var count = 0
    init(epochs: [Int64]) throws { routes = try epochs.map { try .init(shardID: "current", epoch: $0) } }
    func route(for _: RoomID) -> V2RoomShardRoute {
        let route = routes[min(count, routes.count - 1)]
        count += 1
        return route
    }
    func readCount() -> Int { count }
}

private actor BaselineRecorder: V2GroupRolePolicyBaselineReading {
    struct Request: Equatable { let room: RoomID; let actor: UserID }
    let denied: Bool
    private var values: [Request] = []
    init(denied: Bool = false) { self.denied = denied }
    func readRolePolicyBaseline(roomID: RoomID, actorUserID: UserID) throws -> V2GroupRolePolicyBaseline {
        values.append(.init(room: roomID, actor: actorUserID))
        if denied { throw V2GroupRolePolicyBaselineError.actorNotMember }
        return try .init(roomID: roomID, permissionRevision: 4, membershipRevision: 2, roomSequence: 9, adminPermissions: [.inviteMembers], memberPermissions: [])
    }
    func requests() -> [Request] { values }
}
