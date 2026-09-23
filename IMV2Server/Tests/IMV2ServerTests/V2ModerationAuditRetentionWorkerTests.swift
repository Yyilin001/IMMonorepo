import Foundation
@testable import IMV2Server
import Testing
import Synchronization

@Suite("V2 moderation audit retention")
struct V2ModerationAuditRetentionWorkerTests {
    @Test("monotonic maintenance remains due across wall-clock corrections while retention receives wall time")
    func maintenanceClockCorrections() async throws {
        let store = RecordingModerationRetentionStore(deleted: 0)
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let wallClock = Mutex(base)
        let worker = V2ModerationAuditRetentionWorker(store: store, now: { wallClock.withLock { $0 } })
        let cadence = try V2MaintenanceCadence(intervalMilliseconds: 60_000)
        let start = ContinuousClock.now
        var deadline: ContinuousClock.Instant?
        // A day forward at 59 seconds must not trigger early cleanup. A day
        // backward at 60 seconds must not suppress the scheduled pass.
        for (elapsed, wallOffset) in [(0, 0), (59, 86_400), (60, -86_400), (119, 172_800), (120, 86_400)] {
            wallClock.withLock { $0 = base.addingTimeInterval(Double(wallOffset)) }
            let instant = start.advanced(by: .seconds(elapsed))
            if cadence.isDue(now: instant, nextScheduledAt: deadline) {
                _ = try await worker.runOnce(limit: 3)
                deadline = cadence.nextScheduledAt(after: instant)
            }
        }
        #expect(await store.requests() == [
            .init(now: base, limit: 3),
            .init(now: base.addingTimeInterval(-86_400), limit: 3),
            .init(now: base.addingTimeInterval(86_400), limit: 3)
        ])
    }

    @Test("Invalid batch limits throw without invoking retention", arguments: [Int.min, -1, 0])
    func invalidLimits(limit: Int) async throws {
        let store = RecordingModerationRetentionStore(deleted: 0)
        let worker = V2ModerationAuditRetentionWorker(store: store)
        await #expect(throws: V2ModerationStoreError.corruptPersistenceState) { _ = try await worker.runOnce(limit: limit) }
        #expect(await store.requests().isEmpty)
    }

    @Test("worker uses its configured bounded batch size")
    func workerDelegatesBoundedRetention() async throws {
        let store = RecordingModerationRetentionStore(deleted: 2)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let worker = V2ModerationAuditRetentionWorker(store: store, now: { now })

        #expect(try await worker.runOnce(limit: 3) == 2)
        #expect(await store.requests() == [.init(now: now, limit: 3)])
    }

    @Test("physical owners share a row budget and rotate past a busy owner")
    func ownerBudgetAndRotation() async throws {
        let first = RecordingModerationRetentionStore(deleted: 2)
        let second = RecordingModerationRetentionStore(deleted: 1)
        let store = V2OwnerModerationAuditRetentionStore(owners: [first, second])
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(try await store.deleteExpiredAuditEntries(now: now, limit: 2) == 2)
        #expect(await second.requests().isEmpty)
        #expect(try await store.deleteExpiredAuditEntries(now: now, limit: 3) == 3)
        #expect(await first.requests().map(\.limit) == [2, 2])
        #expect(await second.requests().map(\.limit) == [3])
    }

    @Test("a failed owner's next pass begins at a healthy physical database")
    func failingOwnerDoesNotStarveNextPass() async throws {
        let healthy = RecordingModerationRetentionStore(deleted: 1)
        let store = V2OwnerModerationAuditRetentionStore(owners: [FailingModerationRetentionStore(), healthy])
        await #expect(throws: V2ModerationStoreError.corruptPersistenceState) {
            try await store.deleteExpiredAuditEntries(now: Date(), limit: 1)
        }
        #expect(try await store.deleteExpiredAuditEntries(now: Date(), limit: 1) == 1)
        #expect(await healthy.requests().count == 1)
    }
}

private struct FailingModerationRetentionStore: V2ModerationAuditRetentionStore {
    func deleteExpiredAuditEntries(now: Date, limit: Int) async throws -> Int {
        throw V2ModerationStoreError.corruptPersistenceState
    }
}

private actor RecordingModerationRetentionStore: V2ModerationAuditRetentionStore {
    struct Request: Equatable, Sendable { let now: Date; let limit: Int }
    private let deleted: Int
    private var values: [Request] = []

    init(deleted: Int) { self.deleted = deleted }

    func deleteExpiredAuditEntries(now: Date, limit: Int) -> Int {
        values.append(.init(now: now, limit: limit))
        return deleted
    }

    func requests() -> [Request] { values }
}
