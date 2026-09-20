import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Personal stream completion boundary")
struct V2PersonalSyncCompletionTests {
    @Test func resetAndAdditionalPagesCannotReportCompletion() async throws {
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 7, expiresAt: .distantFuture)
        let driver = CompletionDriver(results: [.resetPending(reset), .synchronized(appliedThrough: 8, hasMore: true), .synchronized(appliedThrough: 9, hasMore: false)])
        #expect(try await driver.synchronizeIncludingResets() == 9)
        #expect(await driver.operations == ["pull", "reset", "pull", "pull"])
    }

    @Test func cancellationAfterAPullCannotReturnCaughtUp() async throws {
        let driver = CompletionDriver(results: [.synchronized(appliedThrough: 8, hasMore: false)], cancelOnPull: true)
        let operation = Task { try await driver.synchronizeIncludingResets() }
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
}

private actor CompletionDriver: V2SyncDriving {
    var results: [V2SyncCycleResult]
    let cancelOnPull: Bool
    private(set) var operations: [String] = []
    init(results: [V2SyncCycleResult], cancelOnPull: Bool = false) {
        self.results = results; self.cancelOnPull = cancelOnPull
    }
    func synchronizeUntilCaughtUp() throws -> V2SyncCycleResult {
        operations.append("pull")
        if cancelOnPull { withUnsafeCurrentTask { $0?.cancel() } }
        guard !results.isEmpty else { throw V2RealtimeTransportError.unexpectedResponse }
        return results.removeFirst()
    }
    func completePendingReset() { operations.append("reset") }
}
