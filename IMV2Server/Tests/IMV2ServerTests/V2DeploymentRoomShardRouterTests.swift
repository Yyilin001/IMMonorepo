import Foundation
import Testing
import IMV2Core
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

@Suite("Deployment room routing", .timeLimit(.minutes(1)))
struct V2DeploymentRoomShardRouterTests {
    @Test("snapshot hits never call loader; missing sibling cannot lose a healthy cold route")
    func snapshotAndMissingSibling() async throws {
        let existing = RoomID(uuid: UUID()), healthy = RoomID(uuid: UUID()), missing = RoomID(uuid: UUID())
        let route = try V2RoomShardRoute(shardID: "rooms", epoch: 1)
        let probe = DeploymentRouteProbe(routes: [healthy: route])
        let router = try V2DeploymentRoomShardRouter(snapshot: [existing: route], loadCold: { try await probe.load($0) })
        #expect(try await router.routes(for: [existing, existing]) == [existing: route])
        #expect(await probe.calls == 0)
        await #expect(throws: V2RoomShardRouteError.roomNotFound) { _ = try await router.routes(for: [healthy, missing]) }
        #expect(try await router.route(for: healthy) == route)
        #expect(await probe.calls == 1)
        #expect(await router.invalidate(for: existing, matching: try V2RoomShardRoute(shardID: "different", epoch: 1)) == false)
        #expect(try await router.route(for: existing) == route)
        #expect(await probe.calls == 1)
        await router.shutdown()
    }

    @Test("cold singleflight survives cancelled waiter and actual drain; changed deployment fails closed")
    func cancellationAndDeploymentChange() async throws {
        let room = RoomID(uuid: UUID()), pinned = RoomID(uuid: UUID())
        let route = try V2RoomShardRoute(shardID: "rooms", epoch: 1)
        let probe = DeploymentRouteProbe(routes: [room: route], blocked: true)
        let router = try V2DeploymentRoomShardRouter(snapshot: [:], loadCold: { try await probe.load($0) })
        let first = Task { try await router.route(for: room) }
        await probe.waitForEntry()
        let other = Task { try await router.route(for: room) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await router.pressureSnapshot().waitingCallers < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await router.pressureSnapshot().waitingCallers == 2)
        first.cancel()
        do { _ = try await first.value; Issue.record("cancelled waiter must be removed") } catch { #expect(error is CancellationError) }
        #expect(await probe.calls == 1)
        #expect(await probe.inFlight == 1)
        let stop = Task { await router.shutdown() }
        let repeated = Task { await router.shutdown() }
        for _ in 0..<20 { await Task.yield() }
        #expect(await probe.inFlight == 1)
        await probe.release()
        do { _ = try await other.value; Issue.record("shutdown cannot install the late route") } catch {}
        await stop.value; await repeated.value
        #expect(await probe.inFlight == 0)
        let changed = try V2RoomShardRoute(shardID: "rooms-next", epoch: 2)
        let source = DeploymentRouteProbe(routes: [pinned: changed])
        let fixed = try V2DeploymentRoomShardRouter(snapshot: [pinned: route], loadCold: { try await source.load($0) })
        #expect(await fixed.invalidate(for: pinned, matching: route))
        await #expect(throws: V2DeploymentRoomShardRouter.Failure.deploymentChanged) { _ = try await fixed.route(for: pinned) }
        await #expect(throws: V2DeploymentRoomShardRouter.Failure.deploymentChanged) { _ = try await fixed.route(for: pinned) }
        #expect(await source.calls == 1) // No silent migration or periodic refresh storm.
        await fixed.shutdown()
    }
}
private actor DeploymentRouteProbe {
    var calls = 0; var inFlight = 0
    let routes: [RoomID: V2RoomShardRoute]
    var blocked: Bool
    var entered = false
    var observers: [CheckedContinuation<Void, Never>] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(routes: [RoomID: V2RoomShardRoute], blocked: Bool = false) { self.routes = routes; self.blocked = blocked }
    func load(_ rooms: [RoomID]) async throws -> [RoomID: V2RoomShardRoute] {
        calls += 1; inFlight += 1; entered = true
        let old = observers; observers.removeAll(); for observer in old { observer.resume() }
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        inFlight -= 1
        return routes.filter { rooms.contains($0.key) }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { blocked = false; let old = waiters; waiters.removeAll(); for waiter in old { waiter.resume() } }
}
