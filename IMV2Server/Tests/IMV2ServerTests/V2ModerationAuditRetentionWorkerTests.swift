import Foundation
@testable import IMV2Server
import Testing

@Suite("V2 moderation audit retention")
struct V2ModerationAuditRetentionWorkerTests {
    @Test("worker uses its configured bounded batch size")
    func workerDelegatesBoundedRetention() async throws {
        let store = RecordingModerationRetentionStore(deleted: 2)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let worker = V2ModerationAuditRetentionWorker(store: store, now: { now })

        #expect(try await worker.runOnce(limit: 3) == 2)
        #expect(await store.requests() == [.init(now: now, limit: 3)])
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
