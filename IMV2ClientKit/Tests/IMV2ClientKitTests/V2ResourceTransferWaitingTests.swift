import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Resource waiting observations follow actual admission", .timeLimit(.minutes(1)))
struct V2ResourceTransferWaitingTests {
    @Test func waitingCannotOverrideControlsTerminalFactsOrActualByteProgress() {
        let id = V2ManagedResourceTransferID.download(UUID())
        for phase in [V2ManagedResourceTransferPhase.paused, .pausing, .verifying, .cancelling, .completed, .cancelled, .requiresAttention(.space), .failed(.network)] {
            let item = entry(id, phase: phase)
            let updated = V2ResourceTransferSnapshot.available(.init(entries: [item], nextCursor: nil)).applyingTransferWaiting([id: .transferSlot])
            guard case .available(let page) = updated else { Issue.record("Missing snapshot"); return }
            #expect(page.entries.first?.waitingReason == nil && page.entries.first?.phase == phase)
        }
        var active = entry(id, phase: .transferring)
        active.attemptProgress = .init(attemptID: UUID(), transferredBytes: 2, expectedBytes: 4)
        let updated = V2ResourceTransferSnapshot.available(.init(entries: [active], nextCursor: nil)).applyingTransferWaiting([id: .requestSlot])
        guard case .available(let page) = updated else { Issue.record("Missing snapshot"); return }
        #expect(page.entries.first?.waitingReason == nil && page.entries.first?.attemptProgress == active.attemptProgress)
        active.attemptProgress = .init(attemptID: UUID(), transferredBytes: 0, expectedBytes: 4)
        let notStarted = V2ResourceTransferSnapshot.available(.init(entries: [active], nextCursor: nil)).applyingTransferWaiting([id: .transferSlot])
        guard case .available(let queued) = notStarted else { Issue.record("Missing queued attempt"); return }
        #expect(queued.entries.first?.waitingReason == .transferSlot && queued.entries.first?.attemptProgress == nil)
        let copying = entry(.serverImport(UUID()), phase: .transferring, purpose: .serverImport)
        let copyPage = V2ResourceTransferSnapshot.available(.init(entries: [copying], nextCursor: nil)).applyingTransferWaiting([copying.id: .requestSlot])
        guard case .available(let imports) = copyPage else { Issue.record("Missing import"); return }
        #expect(imports.entries.first?.waitingReason == nil)
    }
    @Test(arguments: [V2NetworkWorkKind.ordinary, .byteTransfer(.download)])
    func schedulerReportsSlotThenCooldownAndClearsOnlyWhenGranted(kind: V2NetworkWorkKind) async throws {
        let clock = MutexClock(), scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1, serviceLimit: 1, byteTransferLimit: 1), monotonicNow: { clock.now })
        let context = V2NetworkWorkContext(service: "resources", kind: kind), hub = V2ResourceTransferProgressHub(), job = V2ManagedResourceTransferID.download(UUID())
        let occupied = try await scheduler.acquire(context)
        let waiting = Task {
            try await V2ResourceTransferWaitScope.$context.withValue(.init(transfer: job, hub: hub)) { try await scheduler.acquire(context) }
        }
        try await until { await scheduler.snapshot().waiting == 1 }
        #expect(hub.waitingSnapshot()[job] == (kind == .ordinary ? .requestSlot : .transferSlot))
        await scheduler.coolDown(service: "resources", for: 30)
        #expect(hub.waitingSnapshot()[job] == .serviceCooldown)
        clock.advance(40)
        _ = await scheduler.release(occupied)
        let granted = try await waiting.value
        #expect(hub.waitingSnapshot().isEmpty)
        #expect(await scheduler.snapshot().active == 1)
        _ = await scheduler.release(granted); await scheduler.closeAndDrain(); hub.close()
    }

    @Test func cancellingQueuedRequestClearsItsObservationWithoutReleasingActiveIO() async throws {
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1)), hub = V2ResourceTransferProgressHub()
        let context = V2NetworkWorkContext(service: "resources"), job = V2ManagedResourceTransferID.upload(UUID())
        let occupied = try await scheduler.acquire(context)
        let waiting = Task { try await V2ResourceTransferWaitScope.$context.withValue(.init(transfer: job, hub: hub)) { try await scheduler.acquire(context) } }
        try await until { await scheduler.snapshot().waiting == 1 }
        waiting.cancel(); await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(hub.waitingSnapshot().isEmpty)
        #expect(await scheduler.snapshot().active == 1)
        _ = await scheduler.release(occupied); await scheduler.closeAndDrain(); hub.close()
    }

    @Test func oldTokensCannotClearNewWaitsAndTheHubBoundsAndClosesObservations() throws {
        let hub = V2ResourceTransferProgressHub(), job = V2ManagedResourceTransferID.download(UUID())
        let old = try #require(hub.beginWait(transfer: job, reason: .requestSlot)); old.end()
        let next = try #require(hub.beginWait(transfer: job, reason: .transferSlot))
        old.update(.serviceCooldown); old.end()
        #expect(hub.waitingSnapshot()[job] == .transferSlot)
        let other = try #require(hub.beginWait(transfer: job, reason: .serviceCooldown))
        #expect(hub.waitingSnapshot()[job] == .serviceCooldown)
        other.end(); #expect(hub.waitingSnapshot()[job] == .transferSlot)
        var retained = [next]
        for _ in 0..<63 { retained.append(try #require(hub.beginWait(transfer: .upload(UUID()), reason: .requestSlot))) }
        #expect(hub.beginWait(transfer: .upload(UUID()), reason: .requestSlot) == nil)
        hub.close(); next.update(.network); next.end()
        #expect(hub.waitingSnapshot().isEmpty && hub.beginWait(transfer: job, reason: .network) == nil)
    }

    private func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) { try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(5)) }
    }
    private func entry(_ id: V2ManagedResourceTransferID, phase: V2ManagedResourceTransferPhase, purpose: V2ResourceTransferPurpose = .download) -> V2ManagedResourceTransfer {
        .init(id: id, displayName: nil, purpose: purpose, mediaID: .init(uuid: UUID()), resource: nil, createdAt: Date(), group: .active,
            phase: phase, totalBytes: 4, confirmedBytes: nil, actions: [], cancellableMessageCount: nil, hasBusinessOwners: false)
    }
}

import Synchronization
private final class MutexClock: Sendable {
    private let value = Mutex<TimeInterval>(0)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}
