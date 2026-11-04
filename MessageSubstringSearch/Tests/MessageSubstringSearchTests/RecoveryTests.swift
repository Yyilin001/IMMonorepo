import Foundation
import Testing
@testable import MessageSubstringSearch

@Test func inputLimitsAndBackpressureDoNotPartiallyAccept() async throws {
    try await withIndex(configure: { $0.maximumDocumentBytes = 16; $0.maximumInboxCount = 1 }) { index in
        await #expect(throws: SearchIndexError.self) {
            try await index.enqueue([change(document("1", "valid")), change(document("2", String(repeating: "x", count: 17)))])
        }
        #expect(try await index.status().acceptedSequence == 0)
        await #expect(throws: SearchIndexError.backpressure) {
            try await index.enqueue([change(document("1", "one")), change(document("2", "two"))])
        }
        #expect(try await index.status().acceptedSequence == 0)
        _ = try await index.enqueue([change(document("1", "one"))])
        await #expect(throws: SearchIndexError.backpressure) { try await index.enqueue([change(document("2", "two"))]) }
        _ = try await index.processPending()
        #expect(try await ids(index, "one") == ["1"])
        await #expect(throws: SearchIndexError.self) { try await index.search(SearchRequest(String(repeating: "a", count: 129))) }
    }
}

@Test func checkpointCASAndFailedGapCannotBeSkipped() async throws {
    try await withIndex { index in
        let a = try await index.enqueue([change(document("1", "one"))], checkpoint: SourceCheckpoint(expected: "", next: "a"))
        await #expect(throws: SearchIndexError.checkpointConflict) {
            try await index.enqueue([change(document("2", "two"))], checkpoint: SourceCheckpoint(expected: "", next: "b"))
        }
        #expect(try await index.status().indexedSourceCheckpoint == "")
        _ = try await index.processPending(); try await index.waitUntilIndexed(a)
        #expect(try await index.status().indexedSourceCheckpoint == "a")
        let badText = "x" + String(repeating: "\u{0301}", count: 300)
        let receipt = try await index.enqueue([change(document("bad", badText)), change(document("good", "good"))],
                                              checkpoint: SourceCheckpoint(expected: "a", next: "c"))
        await #expect(throws: SearchIndexError.self) { try await index.processPending() }
        _ = try await index.processPending()
        #expect(try await ids(index, "good") == ["good"])
        let status = try await index.status()
        #expect(status.failedCount == 1); #expect(status.indexedSequence == a.sequence)
        #expect(status.indexedSourceCheckpoint == "a")
        await #expect(throws: SearchIndexError.self) { try await index.waitUntilIndexed(receipt) }
    }
}

enum InjectedFailure: Error { case failure }

@Test func corruptPendingPayloadIsVisibleRatherThanSilentlyStalled() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    var config = SearchConfiguration(path: dir.appendingPathComponent("index.sqlite").path, scopeID: "a", sourceEpoch: "1")
    config.automaticallyProcess = false
    let first = try await SearchIndex.open(config)
    let receipt = try await first.enqueue([change(document("1", "original"))])
    try await first.close()
    let db = try SQLiteConnection(path: config.path)
    try db.run("UPDATE event_payloads SET payload=?", [.text("{broken")]); try db.close()
    config.automaticallyProcess = true
    let reopened = try await SearchIndex.open(config)
    await #expect(throws: SearchIndexError.failedEvent(sequence: receipt.sequence, code: "invalidPayload")) {
        try await reopened.waitUntilIndexed(receipt)
    }
    let status = try await reopened.status()
    #expect(status.failedCount == 1); #expect(status.indexedSequence == 0)
    try await reopened.close()
}

@Test func cancelledTransactionRemainsPendingInsteadOfFailed() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "old")])
        let receipt = try await index.enqueue([change(document("1", "new", version: 2))])
        await index.setFault { if $0 == .beforeProgress { throw CancellationError() } }
        await #expect(throws: CancellationError.self) { try await index.processPending() }
        let status = try await index.status()
        #expect(status.pendingCount == 1); #expect(status.failedCount == 0)
        #expect(try await ids(index, "old") == ["1"])
        await index.setFault(nil); _ = try await index.processPending()
        try await index.waitUntilIndexed(receipt)
        #expect(try await ids(index, "new") == ["1"])
    }
}

@Test(arguments: [FaultPoint.afterOldIndexRemoval, .beforeProgress, .beforeCommit])
func transactionFailureRollsBackContentsAndProgress(point: FaultPoint) async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "old")])
        let receipt = try await index.enqueue([change(document("1", "new", version: 2))])
        await index.setFault { if $0 == point { throw InjectedFailure.failure } }
        await #expect(throws: SearchIndexError.self) { try await index.processPending() }
        #expect(try await ids(index, "old") == ["1"]); #expect(try await ids(index, "new").isEmpty)
        #expect(try await index.status().indexedSequence == 1)
        await index.setFault(nil); try await index.retryFailed(); _ = try await index.processPending()
        try await index.waitUntilIndexed(receipt)
        #expect(try await ids(index, "new") == ["1"])
        try await index.integrityCheck()
    }
}

@Test func pendingQueueRecoversOnReopenAndRejectsDifferentAccount() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    var config = SearchConfiguration(path: dir.appendingPathComponent("index.sqlite").path, scopeID: "a", sourceEpoch: "e")
    config.automaticallyProcess = false
    let index = try await SearchIndex.open(config)
    let receipt = try await index.enqueue([change(document("1", "持久化"))])
    await #expect(throws: SearchIndexError.alreadyOpen) { try await SearchIndex.open(config) }
    try await index.close()
    config.automaticallyProcess = true
    let reopened = try await SearchIndex.open(config)
    try await reopened.waitUntilIndexed(receipt)
    #expect(try await ids(reopened, "久") == ["1"])
    try await reopened.close()
    config.scopeID = "other"
    await #expect(throws: SearchIndexError.incompatibleIndex) { try await SearchIndex.open(config) }
    await #expect(throws: SearchIndexError.closed) { try await reopened.search(SearchRequest("久")) }
}

@Test func rebuildResumesAndPreservesConcurrentChanges() async throws {
    try await withIndex { index in
        try await insert(index, (1...6).map { document(String($0), "original") })
        let page = try await index.search(SearchRequest("original", pageSize: 1))
        try await index.beginRebuildForTesting()
        #expect(try await index.rebuildStepForTesting(count: 2) == false)
        try await insert(index, [document("1", "updated", version: 2), document("7", "added")])
        _ = try await index.enqueue([IndexChange(eventID: "delete", operation: .delete(documentID: "3", version: 2))])
        _ = try await index.processPending()
        await index.setFault { if $0 == .beforeGenerationSwitch { throw InjectedFailure.failure } }
        await #expect(throws: InjectedFailure.self) { try await index.rebuild(batchSize: 2) }
        #expect(try await index.status().generation == 1)
        #expect(try await ids(index, "updated") == ["1"])
        await index.setFault(nil); try await index.rebuild(batchSize: 2)
        #expect(try await index.status().generation == 2)
        #expect(try await ids(index, "updated") == ["1"]); #expect(try await ids(index, "added") == ["7"])
        #expect(Set(try await ids(index, "original")) == ["2", "4", "5", "6"])
        await #expect(throws: SearchIndexError.staleCursor) { try await index.search(SearchRequest("original", pageSize: 1), after: page.nextCursor) }
        try await index.maintain(); try await index.integrityCheck()
    }
}

@Test func cancellationAndTimeoutAreNotEmptyResults() async throws {
    try await withIndex { index in
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await index.enqueue([change(document("1", "one"))]) }
            await #expect(throws: CancellationError.self) { try await index.search(SearchRequest("one")) }
        }
        await task.value
        let status = try await index.status()
        #expect(status.acceptedSequence == 0)
    }
    try await withIndex(configure: { $0.queryTimeoutSeconds = 0.000000001 }) { index in
        await #expect(throws: SearchIndexError.timeout) { try await index.search(SearchRequest("x")) }
    }
}
