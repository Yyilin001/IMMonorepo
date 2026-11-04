import Foundation
import Testing
@testable import MessageSubstringSearch

func document(_ id: String, _ text: String, group: String = "room", version: Int64 = 1,
              time: Int64 = 1, coverage: ContentCoverage = .fullText) -> SearchDocument {
    SearchDocument(id: id, groupID: group, version: version, timestamp: time, coverage: coverage, fields: [SearchField(text: text)])
}
func change(_ doc: SearchDocument, eventID: String? = nil) -> IndexChange {
    IndexChange(eventID: eventID ?? "\(doc.id)-\(doc.version)", operation: .upsert(doc))
}
func directory() throws -> URL {
    let result = FileManager.default.temporaryDirectory.appendingPathComponent("substring-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    return result
}
func withIndex(configure: (inout SearchConfiguration) -> Void = { _ in },
               _ body: (SearchIndex) async throws -> Void) async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    var configuration = SearchConfiguration(path: dir.appendingPathComponent("search.sqlite").path, scopeID: "account", sourceEpoch: "1")
    configuration.automaticallyProcess = false; configuration.queryTimeoutSeconds = 10
    configure(&configuration)
    let index = try await SearchIndex.open(configuration)
    do { try await body(index); try await index.close() }
    catch { try? await index.close(); throw error }
}
func insert(_ index: SearchIndex, _ documents: [SearchDocument]) async throws {
    _ = try await index.enqueue(documents.map { change($0) }); _ = try await index.processPending()
}
func ids(_ index: SearchIndex, _ text: String, group: String? = nil) async throws -> [String] {
    try await index.search(SearchRequest(text, groupID: group, pageSize: 200)).hits.map { $0.document.id }
}

@Test func literalSubstringSemanticsAndOperators() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "北京欢迎你 helloWorld 13812345678 foo-bar \"OR\"* x\0y"),
                                 document("2", "北京很欢迎你 hello World foo bar")])
        for query in ["京欢", "loWo", "3456", "o-b", "\"OR\"*", "x\0y", "\0"] { #expect(try await ids(index, query) == ["1"]) }
        for query in ["北你", "欢迎北京", "lo*Wo", "foobar"] { #expect(try await ids(index, query).isEmpty) }
        #expect(try await ids(index, "京").count == 2)
        await #expect(throws: SearchIndexError.emptyQuery) { try await index.search(SearchRequest("")) }
    }
}

@Test func unicodeAndOriginalHighlightRanges() async throws {
    try await withIndex { index in
        let original = "Cafe\u{301} HELLO Straße 👨‍👩‍👧‍👦 👋🏽 🇨🇳"
        try await insert(index, [document("1", original)])
        let page = try await index.search(SearchRequest("fé"))
        let hit = try #require(page.hits.first)
        #expect(hit.document.fields[0].text == original)
        #expect(hit.ranges == [TextRange(location: 2, length: 3)])
        for query in ["ELL", "👨‍👩‍👧‍👦", "👋🏽", "🇨🇳"] { #expect(try await ids(index, query) == ["1"]) }
        for query in ["STRASSE", "👨", "👋", "🏽", "🇨", "cafe", "ＨＥＬＬＯ"] { #expect(try await ids(index, query).isEmpty) }
    }
    try await withIndex(configure: { $0.mode = .literal }) { index in
        try await insert(index, [document("1", "Hello")])
        #expect(try await ids(index, "ELL").isEmpty); #expect(try await ids(index, "ell") == ["1"])
    }
}

@Test func allChunkBoundariesAndFieldsAreIndependent() async throws {
    try await withIndex(configure: { $0.chunkCharacters = 16; $0.maximumQueryCharacters = 8 }) { index in
        let text = "abcdefghijklmnop北京欢迎你0123456789uvwxyz"
        let doc = SearchDocument(id: "1", groupID: "a", version: 1, timestamp: 1,
            fields: [SearchField(id: "body", text: text), SearchField(id: "title", text: "单独字段")])
        try await insert(index, [doc])
        let characters = Array(text)
        for size in 1...8 {
            for start in 0...(characters.count - size) {
                #expect(try await ids(index, String(characters[start..<start + size])) == ["1"])
            }
        }
        #expect(try await ids(index, "z单").isEmpty); #expect(try await ids(index, "独字") == ["1"])
        try await index.integrityCheck()
    }
}

@Test func duplicateOutOfOrderAndDeletionVersions() async throws {
    try await withIndex { index in
        let initial = change(document("1", "old", version: 10))
        _ = try await index.enqueue([initial, initial]); _ = try await index.processPending()
        #expect(try await index.status().acceptedSequence == 1)
        _ = try await index.enqueue([change(document("1", "stale", version: 9))]); _ = try await index.processPending()
        #expect(try await ids(index, "old") == ["1"])
        _ = try await index.enqueue([IndexChange(eventID: "delete", operation: .delete(documentID: "1", version: 11)),
                                     change(document("1", "old", version: 10), eventID: "late")])
        _ = try await index.processPending()
        #expect(try await ids(index, "old").isEmpty)
        try await insert(index, [document("1", "new", version: 12)])
        #expect(try await ids(index, "new") == ["1"])
        await #expect(throws: SearchIndexError.conflictingEvent(initial.eventID)) {
            try await index.enqueue([change(document("2", "oops"), eventID: initial.eventID)])
        }
        try await index.integrityCheck()
    }
}

@Test func updateRemovesOldIndexAndSameContentSkipsReindex() async throws {
    try await withIndex { index in
        try await insert(index, [document("1", "old")])
        try await insert(index, [document("1", "new", version: 2), document("1", "new", version: 3)])
        #expect(try await ids(index, "old").isEmpty); #expect(try await ids(index, "new") == ["1"])
        let metrics = await index.diagnostics(); #expect(metrics.index.unchangedContents == 1)
        try await index.integrityCheck()
    }
}

@Test func groupClearRejectsLateEventsButKeepsNewerMessages() async throws {
    try await withIndex { index in
        try await insert(index, [document("old", "match", version: 1), document("new", "match", version: 9),
                                 document("other", "match", group: "other", version: 1)])
        _ = try await index.enqueue([IndexChange(eventID: "clear", operation: .clearGroup(groupID: "room", version: 5)),
                                    change(document("late", "match", version: 3)),
                                    change(document("old", "match", version: 2), eventID: "late-old")])
        _ = try await index.processPending()
        #expect(Set(try await ids(index, "match")) == ["new", "other"])
        try await index.integrityCheck()
    }
}

@Test func snapshotsSurviveWritesAndSkipChangedRecords() async throws {
    try await withIndex { index in
        try await insert(index, (1...7).map { document(String($0), "match", time: Int64($0 / 2)) })
        let request = SearchRequest("at", pageSize: 3)
        let first = try await index.search(request)
        #expect(first.hits.map { $0.document.id } == ["7", "6", "5"])
        try await insert(index, [document("8", "match", time: 8), document("4", "different", version: 2)])
        let second = try await index.search(request, after: first.nextCursor)
        #expect(second.hits.map { $0.document.id } == ["3", "2", "1"]); #expect(second.nextCursor == nil)
        await #expect(throws: SearchIndexError.staleCursor) { try await index.search(SearchRequest("ma"), after: first.nextCursor) }
    }
}

@Test func truncationFilteringAndPreviewCoverageAreExplicit() async throws {
    try await withIndex(configure: { $0.maximumResults = 3 }) { index in
        try await insert(index, (1...6).map { document(String($0), "match", group: $0 < 4 ? "a" : "b", time: Int64($0), coverage: .previewOnly) })
        let page = try await index.search(SearchRequest("match", pageSize: 2))
        #expect(page.resultsTruncated); #expect(page.hits.map { $0.document.id } == ["6", "5"])
        #expect(page.status.previewOnlyCount == 6)
        #expect(try await ids(index, "match", group: "a") == ["3", "2", "1"])
        let filtered = try await index.search(SearchRequest("match", fromTimestamp: 2, throughTimestamp: 3))
        #expect(filtered.hits.map { $0.document.id } == ["3", "2"])
    }
}

@Test func fixedSeedMatchesIndependentCharacterWindowOracle() async throws {
    try await withIndex(configure: { $0.mode = .literal; $0.chunkCharacters = 16; $0.maximumQueryCharacters = 8 }) { index in
        let alphabet = Array("北京欢迎abAB12 .%\n") + [Character("👋🏽"), Character("é"), Character("🇨🇳")]
        var seed: UInt64 = 42
        func random(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(count)) }
        let docs = (0..<100).map { document(String($0), String((0..<50).map { _ in alphabet[random(alphabet.count)] })) }
        try await insert(index, docs)
        for _ in 0..<150 {
            let characters = Array(docs[random(docs.count)].fields[0].text)
            let size = 1 + random(8), start = random(characters.count - size + 1)
            let query = Array(characters[start..<start + size])
            let expected = Set(docs.filter {
                let chars = Array($0.fields[0].text)
                return (0...(chars.count - query.count)).contains { Array(chars[$0..<$0 + query.count]) == query }
            }.map(\.id))
            #expect(Set(try await ids(index, String(query))) == expected)
        }
    }
}

@Test func compatibilityExpansionsAtChunkBoundaries() async throws {
    try await withIndex(configure: {
        $0.mode = .compatibilityCaseInsensitive
        $0.chunkCharacters = 3
        $0.maximumQueryCharacters = 3
    }) { index in
        let original = "👩🏽‍💻ＡﬃＢ㍻Ｃㅂㅏ"
        try await insert(index, [document("1", original)])
        for (query, expected) in [("af", "Ａﬃ"), ("ffi", "ﬃ"), ("ib平", "ﬃＢ㍻"), ("成c", "㍻Ｃ"), ("바", "ㅂㅏ")] {
            let page = try await index.search(.init(query))
            let hit = try #require(page.hits.first)
            let range = (original as NSString).range(of: expected)
            #expect(hit.ranges == [.init(location: range.location, length: range.length)])
        }
        try await index.integrityCheck()
        try await insert(index, [document("1", "新正文", version: 2)])
        #expect(try await ids(index, "ffi").isEmpty)
        try await index.integrityCheck()
    }
}

@Test func embeddedMatcherPreservesCRLF() throws {
    let newline = try SubstringSearchText("\n")
    #expect(try newline.matchingRanges(in: "a\r\nb").isEmpty)
    let pair = try SubstringSearchText("\r\n")
    #expect(try pair.matchingRanges(in: "a\r\nb") == [.init(location: 1, length: 2)])
}

@Test func previewMatchesTheVisiblePartOfFullUnicodeResults() throws {
    let complex = "👩🏽‍💻㍻Ｆｆﬃㅂㅏ\r\n"
    for prefix in [0, 157, 158, 159, 160, 161, 318, 319] {
        let text = String(repeating: "x", count: prefix) + String(repeating: complex, count: 90)
        for needle in ["f", "ff", "ffi", "바", "平成", "👩🏽‍💻", "\r\n", "x👩🏽‍💻", "x" + complex, String(repeating: "x", count: 200)] {
            let pattern = try SubstringSearchText(needle)
            let full = try pattern.matchingRanges(in: text)
            for width in [1, 8, 120] {
                let expected = full.prefix { range in
                    guard let first = full.first else { return false }
                    let start = String.Index(utf16Offset: first.location, in: text)
                    let end = text.index(start, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
                    return range.location < end.utf16Offset(in: text)
                }
                #expect(try pattern.previewRanges(in: text, characterCount: width) == Array(expected))
            }
        }
    }
}

@Test func lazyPagesKeepOriginalCapAcrossEditsAndBackdatedInsertions() async throws {
    try await withIndex(configure: { $0.maximumResults = 6 }) { index in
        try await insert(index, (1...9).map { document(String($0), "match", time: Int64($0 / 2)) })
        let request = SearchRequest("match", pageSize: 2)
        let first = try await index.search(request)
        #expect(first.hits.map { $0.document.id } == ["9", "8"])
        #expect(first.resultsTruncated)
        let cursor = try #require(first.nextCursor)
        try await insert(index, [document("new", "match", time: 2), document("7", "match", version: 2, time: 2)])
        _ = try await index.enqueue([.init(eventID: "remove", operation: .delete(documentID: "5", version: 2))])
        _ = try await index.processPending()
        let next = try await index.search(request, after: cursor)
        #expect(next.hits.map { $0.document.id } == ["6", "4"])
        #expect(next.nextCursor == nil)
        #expect(next.resultsTruncated)
        #expect(try await index.search(request, after: cursor).hits.map { $0.document.id } == ["6", "4"])
    }
}

@Test func firstSearchOnEmptyStoreHasNoContinuation() async throws {
    try await withIndex { index in
        let page = try await index.search(.init("词"))
        #expect(page.hits.isEmpty)
        #expect(page.nextCursor == nil)
        #expect(!page.resultsTruncated)
    }
}

@Test func idleSnapshotReleasesWALWithoutAnotherSearch() async throws {
    try await withIndex(configure: { $0.snapshotLifetimeSeconds = 0.1 }) { index in
        try await insert(index, (1...8).map { document(String($0), "match") })
        let request = SearchRequest("match", pageSize: 1)
        let first = try await index.search(request)
        let cursor = try #require(first.nextCursor)
        try await insert(index, [document("new", "match")])
        let checker = try SQLiteConnection(path: index.configuration.path)
        defer { try? checker.close() }
        let deadline = ContinuousClock.now + .seconds(3)
        var busy = try checker.integer("PRAGMA wal_checkpoint(TRUNCATE)")
        while busy != 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            busy = try checker.integer("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        #expect(busy == 0)
        await #expect(throws: SearchIndexError.staleCursor) { try await index.search(request, after: cursor) }
    }
}

@Test func embeddedIndexEncodingPreservesPersistedTokens() throws {
    let fixtures = [
        ("", ""),
        ("Ａﬃß", "x61 x66 x66 x69 xc39f"),
        ("\r\n\0", "x0d0a x00"),
        ("e\u{301}㍻", "xc3a9 xe5b9b3 xe68890"),
        ("ㅂㅏ", "xebb094"),
        ("🇨🇳", "xf09f87a8f09f87b3")
    ]
    for (source, expected) in fixtures {
        #expect(try SubstringSearchText.encodeForIndex(source) == expected)
    }

    // 拼接原字符后再分词，覆盖兼容展开、跨字符合成及 Unicode 边界的相互作用。
    let pieces = ["Ａ", "ﬃ", "ㅂ", "ㅏ", "\u{301}", "\r", "\n", " ", "\0", "🇨", "🇳", "👩", "🏽", "\u{200D}", "💻", "1️⃣"]
    for first in pieces {
        for second in pieces {
            let text = first + second + first
            #expect(try SubstringSearchText.encodeForIndex(text) == SubstringSearchText(text).encodedPhrase)
        }
    }
}

@Test func tailPreviewPreservesOriginalRangesAcrossMultipleSlices() throws {
    let prefix = String(repeating: "👩🏽‍💻㍻", count: 1_000)
    for boundary in 0..<4 {
        let text = prefix + String(repeating: "x", count: boundary) + "ㅂㅏﬃＢ\r\nＡﬃ" + prefix
        let query = try SubstringSearchText("fi")
        let expected = try query.matchingRanges(in: text)
        #expect(expected.count == 2)
        #expect(try query.previewRanges(in: text, characterCount: 120) == expected)
    }
}

@Test func embeddedWriteHonorsCancellation() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(throws: CancellationError.self) { try SubstringSearchText.encodeForIndex("取消索引") }
    }
    await task.value
}
