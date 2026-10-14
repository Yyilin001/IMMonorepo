import Foundation
import Testing
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerGateway
@testable import IMV2ServerApp

@Suite("Shared Journal recovery owner", .timeLimit(.minutes(1)))
struct GatewayJournalRecoveryCoordinatorTests {
    @Test("late higher versions require another pass while equal local and remote requests share one")
    func strongerArrival() async throws {
        let harness = RecoveryHarness(), user = UserID(uuid: UUID())
        let owner = GatewayJournalRecoveryCoordinator(isCurrent: { _, _ in true }, execute: { try await harness.execute($0) })
        let firstWork = work(user: user, version: 1)
        var upgraded = firstWork; upgraded.minimumCut = 2; upgraded.controls.versions[user] = 2
        let stronger = upgraded
        let first = Task { try await owner.run(firstWork) }
        try await wait { await harness.count == 1 }
        let same = Task { try await owner.run(firstWork) }
        let late = Task { try await owner.run(stronger) }
        try await wait { await owner.snapshot().waiting == 3 }
        await harness.release()
        #expect(try await first.value.cut == 1)
        #expect(try await same.value.versions[user] == 1)
        try await wait { await harness.count == 2 }
        #expect(await owner.snapshot().waiting == 1)
        await harness.release()
        #expect(try await late.value.versions[user] == 2)
        #expect(await harness.count == 2)
        let cached = try await owner.run(stronger)
        #expect(cached.cut == 2 && cached.versions[user] == 2)
        #expect(await harness.count == 2)
        await owner.close()
    }

    @Test("a changed connection lifecycle or expired binding cannot reuse a completed result")
    func invalidCache() async throws {
        let calls = Mutex(0), valid = Mutex(true)
        let owner = GatewayJournalRecoveryCoordinator(isCurrent: { _, _ in valid.withLock { $0 } }, execute: { work in
            calls.withLock { $0 += 1 }
            return .init(cut: work.minimumCut, interestRevision: work.interestRevision,
                         versions: work.controls.versions, controls: work.controls)
        })
        var request = work(user: UserID(uuid: UUID()), version: 1)
        _ = try await owner.run(request); _ = try await owner.run(request)
        #expect(calls.withLock { $0 } == 1)
        request.interestRevision = 2
        _ = try await owner.run(request)
        #expect(calls.withLock { $0 } == 2)
        valid.withLock { $0 = false }
        _ = try await owner.run(request)
        #expect(calls.withLock { $0 } == 3)
        await owner.close()
    }

    @Test("cancelling a joined caller leaves the actual shared recovery owned and shutdown joins it")
    func cancellationAndClose() async throws {
        let harness = RecoveryHarness()
        let owner = GatewayJournalRecoveryCoordinator(isCurrent: { _, _ in true }, execute: { try await harness.execute($0) })
        let request = work(user: UserID(uuid: UUID()), version: 1)
        let first = Task { try await owner.run(request) }
        try await wait { await harness.count == 1 }
        let joined = Task { try await owner.run(request) }
        try await wait { await owner.snapshot().waiting == 2 }
        joined.cancel()
        do { _ = try await joined.value; Issue.record("cancelled caller succeeded") } catch is CancellationError {} catch { throw error }
        #expect(await owner.snapshot().actual == 1)
        let closed = Mutex(false)
        let shutdown = Task { await owner.close(); closed.withLock { $0 = true } }
        try await wait { await owner.snapshot().closed }
        #expect(!closed.withLock { $0 })
        await harness.release()
        await shutdown.value
        do { _ = try await first.value; Issue.record("shutdown caller succeeded") } catch is CancellationError {} catch { throw error }
        #expect(await owner.snapshot().actual == 0)
        #expect(await owner.snapshot().waiting == 0)
        #expect(await owner.snapshot().cached == 0)
    }

    @Test("an independent source progresses while another recovery is suspended")
    func independentSources() async throws {
        let harness = RecoveryHarness()
        let blocked = work(user: UserID(uuid: UUID()), version: 1)
        let owner = GatewayJournalRecoveryCoordinator(isCurrent: { _, _ in true }, execute: { work in
            if work.key == blocked.key { return try await harness.execute(work) }
            return .init(cut: work.minimumCut, interestRevision: work.interestRevision,
                         versions: work.controls.versions, controls: work.controls)
        })
        let held = Task { try await owner.run(blocked) }
        try await wait { await harness.count == 1 }
        let other = try await owner.run(work(user: UserID(uuid: UUID()), version: 4))
        #expect(other.cut == 4)
        await harness.release(); _ = try await held.value
        await owner.close()
    }

    @Test("a cancelled queued version does not survive into a replacement request or start twice")
    func queuedReplacement() async throws {
        let harness = RecoveryHarness()
        let owner = GatewayJournalRecoveryCoordinator(isCurrent: { _, _ in true }, execute: { try await harness.execute($0) })
        let heldWork = (0..<4).map { _ in work(user: UserID(uuid: UUID()), version: 1) }
        let held = heldWork.map { value in Task { try await owner.run(value) } }
        try await wait { await harness.count == 4 }
        let old = work(user: UserID(uuid: UUID()), version: 100)
        let queued = Task { try await owner.run(old) }
        try await wait { await owner.snapshot().waiting == 5 }
        queued.cancel()
        do { _ = try await queued.value; Issue.record("cancelled queue succeeded") } catch is CancellationError {} catch { throw error }
        var changed = old; changed.minimumCut = 1
        changed.controls.versions = old.controls.versions.mapValues { _ in 1 }
        let replacementWork = changed
        let replacement = Task { try await owner.run(replacementWork) }
        try await wait { await owner.snapshot().waiting == 5 }
        await harness.release()
        try await wait { await harness.count == 5 }
        #expect(await harness.minimumCuts.last == 1)
        await harness.releaseAll()
        for task in held { _ = try await task.value }
        #expect(try await replacement.value.cut == 1)
        #expect(await harness.count == 5)
        await owner.close()
    }

    private func work(user: UserID, version: UInt64) -> GatewayJournalRecoveryCoordinator.Work {
        let source = V2RealtimeJournalSource(sourceID: "source", incarnationID: UUID(), partitionID: 1)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: .distantFuture, routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        var controls = V2GatewayJournalRecoveryControls(); controls.versions[user] = version
        return .init(batch: .init(source: source, fence: fence, payload: .baseline(minimumCut: Int64(version))),
            service: "host", minimumCut: Int64(version), interestRevision: 1, controls: controls)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw RecoveryTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
private enum RecoveryTestError: Error { case timeout }
private actor RecoveryHarness {
    private(set) var count = 0
    private(set) var minimumCuts: [Int64] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    func execute(_ work: GatewayJournalRecoveryCoordinator.Work) async throws -> GatewayJournalRecoveryCoordinator.Proof {
        count += 1
        minimumCuts.append(work.minimumCut)
        await withCheckedContinuation { gates.append($0) }
        return .init(cut: work.minimumCut, interestRevision: work.interestRevision,
            versions: work.controls.versions, controls: work.controls)
    }
    func release() { if !gates.isEmpty { gates.removeFirst().resume() } }
    func releaseAll() { let values = gates; gates.removeAll(); for value in values { value.resume() } }
}
