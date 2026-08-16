import Foundation
@testable import IMV2Server
import Testing

@Suite("V2 fan-out completion release worker")
struct V2FanoutCompletionReleaseWorkerTests {
    @Test("drains a bounded terminal backlog and counts closed plans")
    func drainsBoundedBacklog() async throws {
        let store = CompletionReleaseStore(reports: [
            .init(releasedCount: 2, closedPlanCount: 1),
            .init(releasedCount: 1, closedPlanCount: 0),
        ])
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let worker = V2FanoutCompletionReleaseWorker(store: store, now: { now })

        #expect(try await worker.runOnce(limit: 2) == .init(
            releasedCount: 2, closedPlanCount: 1
        ))
        #expect(await store.callCount() == 1)
        #expect(await store.observedDates() == [now])
        #expect(await store.observedLimits() == [2])

        #expect(try await worker.runOnce(limit: 4) == .init(
            releasedCount: 1, closedPlanCount: 0
        ))
        #expect(await store.callCount() == 2)
        #expect(await store.observedDates() == [now, now])
        #expect(await store.observedLimits() == [2, 4])
    }
}

private actor CompletionReleaseStore: V2FanoutCompletionReleaseStore {
    private var reports: [V2FanoutCompletionReleaseReport]
    private var dates: [Date] = []
    private var limits: [Int] = []

    init(reports: [V2FanoutCompletionReleaseReport]) {
        self.reports = reports
    }

    func releaseTerminalCompletionUnits(
        now: Date,
        limit: Int
    ) -> V2FanoutCompletionReleaseReport {
        dates.append(now)
        limits.append(limit)
        guard !reports.isEmpty else {
            return .init(releasedCount: 0, closedPlanCount: 0)
        }
        return reports.removeFirst()
    }

    func callCount() -> Int { dates.count }
    func observedDates() -> [Date] { dates }
    func observedLimits() -> [Int] { limits }
}
