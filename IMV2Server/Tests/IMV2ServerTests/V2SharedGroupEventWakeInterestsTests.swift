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
        let foreground = shared.manager(for: .foreground), account = shared.manager(for: .accountCoverage)
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

    @Test("failed activation releases its own demand and can be retried")
    func failure() async throws {
        let broker = InterestBrokerProbe(), room = RoomID(uuid: UUID())
        let shared = V2SharedGroupEventWakeInterests(underlying: broker)
        let account = shared.manager(for: .accountCoverage)
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
        let account = shared.manager(for: .accountCoverage)
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
    private var shouldFail = false
    private var shouldPause = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    func failNext() { shouldFail = true }
    func pauseNext() { shouldPause = true }
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
        active.insert(roomID)
    }
    func deactivate(roomID: RoomID) async {
        active.remove(roomID)
        deactivations += 1
    }
}
