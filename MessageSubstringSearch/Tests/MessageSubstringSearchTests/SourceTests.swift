import Foundation
import Testing
@testable import MessageSubstringSearch

private struct NonAdvancingSource: SearchChangeSource {
    func readChanges(after cursor: String, limit: Int) async throws -> SourceChangeBatch {
        SourceChangeBatch(epoch: "1", changes: [change(document("1", "bad cursor"))], nextCursor: cursor, reachedHead: true)
    }
}

@Test func nonEmptySourcePageMustAdvanceEvenAtHead() async throws {
    try await withIndex { index in
        await #expect(throws: SearchIndexError.self) {
            try await SourceSynchronizer(index: index, source: NonAdvancingSource()).synchronize()
        }
        let status = try await index.status()
        #expect(status.acceptedSequence == 0); #expect(!status.sourceAndIndexCaughtUp)
    }
}

private actor ReplaySource: SearchChangeSource {
    let epoch: String
    let events: [IndexChange]
    var failAt: Int?
    init(epoch: String = "1", events: [IndexChange], failAt: Int? = nil) { self.epoch = epoch; self.events = events; self.failAt = failAt }
    func resume() { failAt = nil }
    func readChanges(after cursor: String, limit: Int) async throws -> SourceChangeBatch {
        let start = Int(cursor) ?? 0
        if let failAt, start >= failAt { throw InjectedFailure.failure }
        let end = min(events.count, start + limit)
        return SourceChangeBatch(epoch: epoch, changes: Array(events[start..<end]), nextCursor: String(end), reachedHead: end == events.count)
    }
}

@Test func sourceFailureLeavesCoverageIncompleteAndResumesAtDurableCursor() async throws {
    try await withIndex { index in
        let source = ReplaySource(events: (0..<5).map { change(document(String($0), "历史消息")) }, failAt: 2)
        let sync = SourceSynchronizer(index: index, source: source)
        await #expect(throws: InjectedFailure.self) { try await sync.synchronize(pageSize: 2) }
        let partial = try await index.status()
        #expect(partial.documentCount == 2); #expect(partial.acceptedSourceCheckpoint == "2")
        #expect(!partial.sourceAndIndexCaughtUp)
        await source.resume(); try await sync.synchronize(pageSize: 2)
        let completed = try await index.status()
        #expect(completed.documentCount == 5); #expect(completed.sourceAndIndexCaughtUp)
        _ = try await index.enqueue([change(document("6", "实时消息"))], checkpoint: SourceCheckpoint(expected: "5", next: "6"))
        #expect(try await index.status().sourceAndIndexCaughtUp == false)
        await #expect(throws: SearchIndexError.checkpointConflict) { try await index.setSourceCoverage(.caughtUp(through: "6")) }
    }
}

@Test func sourceEpochMismatchCannotOverwriteExistingHistory() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "keep")])
        let source = ReplaySource(epoch: "reset", events: [change(document("1", "replace", version: 2))])
        await #expect(throws: SearchIndexError.incompatibleIndex) { try await SourceSynchronizer(index: index, source: source).synchronize() }
        #expect(try await ids(index, "keep") == ["1"])
    }
}

private actor SQLCancellationProbe {
    nonisolated let executor = DatabaseExecutor("search.tests.cancel")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    func run(control: OperationControl, started: AsyncStream<Void>.Continuation) throws {
        let db = try SQLiteConnection(path: ":memory:")
        do {
            _ = try db.controlled(control) {
                started.yield()
                return try db.integer("WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) FROM n")
            }
            Issue.record("SQL completed without observing cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(try db.integer("SELECT 42") == 42)
        try db.close()
    }
}

@Test func progressHandlerInterruptsActiveSQLAndResetsBeforeReuse() async throws {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let control = OperationControl(), probe = SQLCancellationProbe()
    let operation = Task { try await probe.run(control: control, started: continuation) }
    for await _ in stream { break }
    control.cancel()
    try await operation.value
    continuation.finish()
}
