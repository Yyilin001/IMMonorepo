import Foundation
import Testing
@testable import MessageSubstringSearch

@Test func acknowledgedButUnreturnedReceiptCanBeReplayed() async throws {
    try await withIndex { index in
        let event = change(document("1", "once"))
        await index.setFault { if $0 == .afterAccept { throw InjectedFailure.failure } }
        await #expect(throws: InjectedFailure.self) { try await index.enqueue([event]) }
        #expect(try await index.status().pendingCount == 1)
        await index.setFault(nil)
        let receipt = try await index.enqueue([event])
        _ = try await index.processPending(); try await index.waitUntilIndexed(receipt)
        #expect(try await index.status().acceptedSequence == 1)
        #expect(try await ids(index, "once") == ["1"])
    }
}

@Test func groupClearAffectsExistingSnapshotAndMaintenance() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "match"), document("2", "match"), document("3", "match")])
        let request = SearchRequest("match", pageSize: 1)
        let page = try await index.search(request)
        _ = try await index.enqueue([IndexChange(eventID: "clear", operation: .clearGroup(groupID: "room", version: 5))])
        _ = try await index.processPending()
        let next = try await index.search(request, after: page.nextCursor)
        #expect(next.hits.isEmpty); #expect(next.status.documentCount == 0)
        try await index.maintain()
        try await insert(index, [document("1", "resurrect", group: "moved", version: 2)])
        #expect(try await ids(index, "resurrect").isEmpty)
        try await index.integrityCheck()
    }
}

@Test func rebuildProgressPersistsAcrossReopen() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    var config = SearchConfiguration(path: dir.appendingPathComponent("index.sqlite").path, scopeID: "a", sourceEpoch: "1")
    config.automaticallyProcess = false
    let first = try await SearchIndex.open(config)
    try await insert(first, (0..<20).map { document(String($0), "original") })
    try await first.beginRebuildForTesting(); _ = try await first.rebuildStepForTesting(count: 5)
    try await first.close()
    let reopened = try await SearchIndex.open(config)
    #expect(try await reopened.status().rebuilding)
    try await reopened.rebuild(batchSize: 4)
    #expect(try await ids(reopened, "original").count == 20)
    #expect(try await reopened.status().generation == 2)
    try await reopened.integrityCheck(); try await reopened.close()
}

@Test func cancelledSQLStopsAndDoesNotCancelNextRequest() async throws {
    try await withIndex { index in
        for batch in 0..<20 {
            try await insert(index, (0..<100).map { document("\(batch)-\($0)", String(repeating: "常见字", count: 100)) })
        }
        let task = Task { try await index.search(SearchRequest("常")) }
        try await Task.sleep(for: .milliseconds(1))
        task.cancel()
        do { _ = try await task.value } catch { #expect(error is CancellationError) }
        // 即使旧请求在 cancel 前完成，也必须证明连接可复用且后续结果正确。
        let page = try await index.search(SearchRequest("常"))
        #expect(page.hits.count == 50)
        try await index.integrityCheck()
    }
}

@Test func automaticPumpDrainsConcurrentProducers() async throws {
    try await withIndex(configure: { $0.automaticallyProcess = true }) { index in
        try await withThrowingTaskGroup(of: Void.self) { group in
            for producer in 0..<8 {
                group.addTask {
                    for i in 0..<20 {
                        let receipt = try await index.enqueue([change(document("\(producer)-\(i)", "流量"))])
                        try await index.waitUntilIndexed(receipt)
                    }
                }
            }
            try await group.waitForAll()
        }
        let status = try await index.status()
        #expect(status.documentCount == 160); #expect(status.acceptedEventsIndexed)
        try await index.integrityCheck()
    }
}

@Test func purgeRequiresOwnershipAndDoesNotDeleteReopenedStore() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let config = SearchConfiguration(path: dir.appendingPathComponent("index.sqlite").path, scopeID: "a", sourceEpoch: "1")
    let first = try await SearchIndex.open(config)
    try await first.close()
    let second = try await SearchIndex.open(config)
    await #expect(throws: SearchIndexError.closed) { try await first.purge() }
    #expect(FileManager.default.fileExists(atPath: config.path))
    try await second.purge()
    #expect(!FileManager.default.fileExists(atPath: config.path))
}

@Test func rejectsForeignDatabaseAndChangedRules() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let foreign = dir.appendingPathComponent("foreign.sqlite").path
    let database = try SQLiteConnection(path: foreign)
    try database.execute("CREATE TABLE messages(id TEXT)"); try database.close()
    await #expect(throws: SearchIndexError.incompatibleIndex) {
        try await SearchIndex.open(SearchConfiguration(path: foreign, scopeID: "a", sourceEpoch: "1"))
    }
    var config = SearchConfiguration(path: dir.appendingPathComponent("index.sqlite").path, scopeID: "a", sourceEpoch: "1")
    let index = try await SearchIndex.open(config); try await index.close()
    config.mode = .literal
    await #expect(throws: SearchIndexError.incompatibleIndex) { try await SearchIndex.open(config) }
}
