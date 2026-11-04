import Foundation
import Testing
@testable import MessageSubstringSearch

@Test func invalidConfigurationCannotOverflowQueryBudgetOrTruncatePath() async throws {
    var config = SearchConfiguration(path: "invalid\0path", scopeID: "a", sourceEpoch: "1")
    await #expect(throws: SearchIndexError.self) { try await SearchIndex.open(config) }
    config.path = "/tmp/unused-search-index.sqlite"
    config.maximumQueryCharacters = .max; config.chunkCharacters = .max
    await #expect(throws: SearchIndexError.self) { try await SearchIndex.open(config) }
}

@Test func uncertainModeSwitchRecoversActualCommittedMode() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    var config = SearchConfiguration(path: dir.appendingPathComponent("index.sqlite").path, scopeID: "a", sourceEpoch: "1")
    config.automaticallyProcess = false
    let first = try await SearchIndex.open(config)
    try await insert(first, [document("1", "Hello")])
    await first.setFault { if $0 == .beforeGenerationSwitch { throw InjectedFailure.failure } }
    await #expect(throws: InjectedFailure.self) { try await first.rebuild(mode: .literal) }
    try await first.close()
    config.useStoredTextMode = true
    let pending = try await SearchIndex.open(config)
    #expect(try await pending.status().textMode == .asciiCaseInsensitive)
    await pending.setFault { if $0 == .afterGenerationSwitch { throw InjectedFailure.failure } }
    await #expect(throws: InjectedFailure.self) { try await pending.rebuild() }
    try await pending.close()
    let committed = try await SearchIndex.open(config)
    #expect(try await committed.status().textMode == .literal)
    #expect(try await committed.status().rebuilding == false)
    #expect(try await ids(committed, "ELL").isEmpty)
    try await committed.close()
}

@Test func shadowRebuildChangesRulesAtomically() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "Hello")])
        #expect(try await ids(index, "ELL") == ["1"])
        await index.setFault { if $0 == .beforeGenerationSwitch { throw InjectedFailure.failure } }
        await #expect(throws: InjectedFailure.self) { try await index.rebuild(mode: .literal) }
        #expect(try await ids(index, "ELL") == ["1"])
        #expect(try await index.status().textMode == .asciiCaseInsensitive)
        await index.setFault(nil)
        try await index.rebuild(mode: .literal)
        #expect(try await ids(index, "ELL").isEmpty)
        #expect(try await ids(index, "ell") == ["1"])
        try await insert(index, [document("2", "Hello", version: 2)])
        #expect(try await ids(index, "ELL").isEmpty)
        try await index.integrityCheck()
    }
}

@Test func diskFullDuringAdmissionDoesNotAcknowledgeOrModifyData() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "keep")])
        try await index.limitDatabaseGrowthForTesting()
        await #expect(throws: SearchIndexError.self) {
            try await index.enqueue([change(document("2", String(repeating: "a", count: 500_000)))])
        }
        let status = try await index.status()
        #expect(status.acceptedSequence == 1); #expect(status.pendingCount == 0)
        #expect(try await ids(index, "keep") == ["1"])
    }
}

@Test func largeTextHasCompleteTailCoverageAndPreviewCanUpgrade() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "摘要", coverage: .previewOnly)])
        let original = "摘要" + String(repeating: "abcdefgh北京 ", count: 5_000) + "尾部真正全文"
        try await insert(index, [document("1", original, version: 2)])
        #expect(try await ids(index, "真正全文") == ["1"])
        #expect(try await index.status().previewOnlyCount == 0)
        let page = try await index.search(SearchRequest("真正全文"))
        let hit = try #require(page.hits.first)
        #expect(hit.ranges == [TextRange(location: original.utf16.count - 4, length: 4)])
        try await index.integrityCheck()
    }
}

@Test func expiredSnapshotAndInvalidFiltersFailExplicitly() async throws {
    try await withIndex(configure: { $0.snapshotLifetimeSeconds = 1e-20 }) { index in
        try await insert(index, [document("1", "match"), document("2", "match")])
        let request = SearchRequest("match", pageSize: 1)
        let page = try await index.search(request)
        await #expect(throws: SearchIndexError.staleCursor) { try await index.search(request, after: page.nextCursor) }
        await #expect(throws: SearchIndexError.self) { try await index.search(SearchRequest("match", fromTimestamp: 10, throughTimestamp: 1)) }
    }
}
