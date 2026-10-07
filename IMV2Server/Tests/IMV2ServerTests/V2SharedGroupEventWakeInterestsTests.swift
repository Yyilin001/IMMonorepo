@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Shared broker room interests")
struct V2SharedGroupEventWakeInterestsTests {
    @Test("closing a detailed subscription preserves account coverage")
    func sharedDemand() async throws {
        let broker = InterestBrokerProbe(), room = RoomID(uuid: UUID())
        let shared = V2SharedGroupEventWakeInterests(underlying: broker)
        let foreground = shared.manager(for: .foreground), account = shared.manager(for: .account(UUID()))
        try await foreground.activate(roomID: room)
        try await account.activate(roomID: room)
        await foreground.deactivate(roomID: room)
        #expect(await broker.active.contains(room))
        #expect(await broker.deactivations == 0)
        await account.deactivate(roomID: room)
        #expect(await broker.active.isEmpty)
        #expect(await broker.deactivations == 1)
        await shared.shutdown()
    }

    @Test("confirmed demand is shared across owners and reconciles acquisition during last release")
    func confirmedDemandAndConcurrentReplacement() async throws {
        let broker = InterestBrokerProbe(), room = RoomID(uuid: UUID())
        let shared = V2SharedGroupEventWakeInterests(underlying: broker)
        let first = shared.manager(for: .account(UUID()))
        let second = shared.manager(for: .account(UUID()))
        let replacementScope = V2SharedGroupEventWakeInterests.Scope.account(UUID())
        let replacement = shared.manager(for: replacementScope)
        try await first.activate(roomID: room)
        try await second.activate(roomID: room)
        #expect(await broker.activations == 1)
        await first.deactivate(roomID: room)
        #expect(await broker.activations == 1)
        #expect(await broker.deactivations == 0)
        await broker.pauseNextRemoval()
        let release = Task { await second.deactivate(roomID: room) }
        await broker.waitUntilPaused()
        let acquire = Task { try await replacement.activate(roomID: room) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await shared.interestedScopes(roomID: room).contains(replacementScope)) {
            guard ContinuousClock.now < deadline else { throw InterestProbeFailure() }
            await Task.yield()
        }
        // A new owner joins the actual removal; it cannot start competing I/O.
        #expect(await broker.activations == 1)
        await broker.resume()
        await release.value
        try await acquire.value
        #expect(await broker.active.contains(room))
        #expect(await broker.activations == 2)
        #expect(await broker.deactivations == 1)
        await replacement.deactivate(roomID: room)
        #expect(await broker.active.isEmpty)
        #expect(await broker.deactivations == 2)
        await shared.shutdown()
    }

    @Test("failed activation releases its own demand and can be retried")
    func failure() async throws {
        let broker = InterestBrokerProbe(), room = RoomID(uuid: UUID())
        let shared = V2SharedGroupEventWakeInterests(underlying: broker)
        let account = shared.manager(for: .account(UUID()))
        await broker.failNext()
        await #expect(throws: InterestProbeFailure.self) { try await account.activate(roomID: room) }
        #expect(await shared.interestedScopes(roomID: room).isEmpty)
        try await account.activate(roomID: room)
        #expect(await broker.active.contains(room))
        await shared.shutdown()
        #expect(await broker.active.isEmpty)
        await #expect(throws: V2SharedGroupEventWakeInterests.Failure.closed) {
            try await account.activate(roomID: room)
        }
    }

    @Test("deactivation during broker activation settles to no subscription", arguments: [false, true])
    func concurrentRemoval(failActivation: Bool) async throws {
        let broker = InterestBrokerProbe(), room = RoomID(uuid: UUID())
        let shared = V2SharedGroupEventWakeInterests(underlying: broker)
        let account = shared.manager(for: .account(UUID()))
        await broker.pauseNext()
        let activation = Task { try await account.activate(roomID: room) }
        await broker.waitUntilPaused()
        let removal = Task { await account.deactivate(roomID: room) }
        // Yield only until the actor has observed removal; the broker remains
        // deterministically suspended throughout this ordering assertion.
        var observed = false
        for _ in 0..<10_000 {
            if await shared.interestedScopes(roomID: room).isEmpty { observed = true; break }
            await Task.yield()
        }
        if failActivation { await broker.failNext() }
        await broker.resume()
        if failActivation {
            await #expect(throws: InterestProbeFailure.self) { try await activation.value }
        } else { try await activation.value }
        await removal.value
        #expect(observed)
        #expect(await broker.active.isEmpty)
        #expect(await broker.deactivations > 0)
        await shared.shutdown()
    }
}

private struct InterestProbeFailure: Error {}

private actor InterestBrokerProbe: V2GroupEventWakeInterestManaging {
    private(set) var active: Set<RoomID> = []
    private(set) var deactivations = 0
    private(set) var activations = 0
    private var shouldFail = false
    private var shouldPause = false
    private var shouldPauseRemoval = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    func failNext() { shouldFail = true }
    func pauseNext() { shouldPause = true }
    func pauseNextRemoval() { shouldPauseRemoval = true }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resume() { paused?.resume(); paused = nil }
    func activate(roomID: RoomID) async throws {
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { continuation in
                paused = continuation
                pauseWaiter?.resume()
                pauseWaiter = nil
            }
        }
        if shouldFail { shouldFail = false; throw InterestProbeFailure() }
        activations += 1
        active.insert(roomID)
    }
    func deactivate(roomID: RoomID) async {
        if shouldPauseRemoval {
            shouldPauseRemoval = false
            await withCheckedContinuation { continuation in
                paused = continuation
                pauseWaiter?.resume()
                pauseWaiter = nil
            }
        }
        active.remove(roomID)
        deactivations += 1
    }
}
