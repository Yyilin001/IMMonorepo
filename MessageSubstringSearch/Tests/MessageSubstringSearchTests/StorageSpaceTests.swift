import Foundation
import Testing
@testable import MessageSubstringSearch

@Test func compactStorageKeepsLedgerButReleasesPayloadAtomically() async throws {
    try await withIndex { index in
        let db = try SQLiteConnection(path: index.configuration.path, readOnly: true)
        let event = change(document("1", "北京 ABC 👨‍👩‍👧‍👦"))
        let receipt = try await index.enqueue([event])
        #expect(try db.integer("SELECT count(*) FROM event_payloads") == 1)
        #expect(try db.integer("SELECT length(hash) FROM events") == 32)
        #expect(try db.string("SELECT typeof(hash) FROM events") == "blob")
        await index.setFault { if $0 == .beforeCommit { throw InjectedFailure.failure } }
        await #expect(throws: SearchIndexError.self) { try await index.processPending() }
        #expect(try db.integer("SELECT count(*) FROM event_payloads") == 1)
        await index.setFault(nil); try await index.retryFailed(); _ = try await index.processPending()
        try await index.waitUntilIndexed(receipt)
        #expect(try db.integer("SELECT count(*) FROM event_payloads") == 0)
        #expect(try db.integer("SELECT count(*) FROM events") == 1)
        #expect(try db.integer("SELECT length(hash) FROM documents") == 32)
        #expect(try db.integer("SELECT count(*) FROM pragma_table_info('chunks') WHERE name='tokens'") == 0)
        #expect(try db.integer("SELECT count(*) FROM sqlite_master WHERE name='chunk_fts_docsize'") == 0)
        let hash = try await index.search(SearchRequest("北京")).hits.first?.contentHash
        #expect(hash?.count == 64)
        #expect(hash == (try db.string("SELECT lower(hex(hash)) FROM documents")))
        #expect(try await index.enqueue([event]).sequence == receipt.sequence)
        await #expect(throws: SearchIndexError.conflictingEvent(event.eventID)) {
            try await index.enqueue([change(document("1", "different"), eventID: event.eventID)])
        }
        try await index.integrityCheck(); try db.close()
    }
}

@Test func regeneratedTokensPreserveUnicodeBoundariesAndRetiredModes() async throws {
    try await withIndex(configure: { $0.chunkCharacters = 16; $0.maximumQueryCharacters = 8 }) { index in
        let text = String(repeating: "Ae\u{301}\0🇨🇳👨‍👩‍👧‍👦北", count: 30)
        try await insert(index, [document("1", text)])
        try await index.integrityCheck()
        #expect(try await ids(index, "aé\0") == ["1"])
        try await index.rebuild(mode: .literal)
        // 旧代编码模式独立保存；切换之后清理旧代仍必须删除正确的 token。
        try await index.integrityCheck(); try await index.maintain(); try await index.integrityCheck()
        #expect(try await ids(index, "aé\0").isEmpty)
        #expect(try await ids(index, "Aé\0") == ["1"])
        try await insert(index, [document("1", "replacement", version: 2)])
        try await index.integrityCheck()
        #expect(try await ids(index, "Aé\0").isEmpty)
        _ = try await index.enqueue([IndexChange(eventID: "delete", operation: .delete(documentID: "1", version: 3))])
        _ = try await index.processPending(); try await index.integrityCheck()
        #expect(try await ids(index, "replace").isEmpty)
    }
}

@Test func tokenViewRejectsInvalidByteRangesAndBlobBindingsAreExact() throws {
    let db = try SQLiteConnection(path: ":memory:")
    #expect(try db.string("SELECT search_tokens(?,0,3,'literal')", [.text("北")]) == "xe58c97")
    for (start, count) in [(-1, 3), (0, 4), (1, 1), (Int64.max, 1)] {
        #expect(throws: SearchIndexError.self) {
            try db.string("SELECT search_tokens(?,?,?,'literal')", [.text("北"), .integer(Int64(start)), .integer(Int64(count))])
        }
    }
    for data in [Data(), Data([0, 255, 128, 0]), Data(repeating: 42, count: 32)] {
        #expect(try db.blob("SELECT ?", [.blob(data)]) == data)
        #expect(try db.string("SELECT typeof(?)", [.blob(data)]) == "blob")
    }
    try db.close()
}

@Test func legacySchemaIsRejectedWithoutChangingItsData() async throws {
    let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("legacy.sqlite").path
    let db = try SQLiteConnection(path: path)
    try db.execute("CREATE TABLE preserved(value TEXT); INSERT INTO preserved VALUES('pending payload'); PRAGMA user_version=3")
    await #expect(throws: SearchIndexError.incompatibleIndex) {
        try await SearchIndex.open(SearchConfiguration(path: path, scopeID: "a", sourceEpoch: "1"))
    }
    #expect(try db.integer("PRAGMA user_version") == 3)
    #expect(try db.string("SELECT value FROM preserved") == "pending payload")
    try db.close()
}

@Test func tokenRegenerationChecksDeadlineInsideTheSQLCallback() throws {
    let db = try SQLiteConnection(path: ":memory:")
    let text = String(repeating: "北", count: 200_000)
    // 一个标量函数内部的长计算不会触发 VM 的每千指令 progress 回调，必须自行检查期限。
    #expect(throws: SearchIndexError.timeout) {
        try db.controlled(OperationControl(timeout: 0.005)) {
            try db.string("SELECT search_tokens(?,0,?,'literal')", [.text(text), .integer(Int64(text.utf8.count))])
        }
    }
    #expect(try db.string("SELECT search_tokens('abc',0,3,'literal')") == "x61 x62 x63")
    try db.close()
}
