import Darwin
import Foundation
import Testing
@testable import MessageSubstringSearch

private let runBenchmarks = ProcessInfo.processInfo.environment["IM_SEARCH_BENCHMARK"] == "1"

/// 单独运行此用例，以免同进程其他测试抬高峰值 RSS。
@Test(.enabled(if: runBenchmarks))
func embeddedFTSWritePerformance() throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try SQLiteConnection(path: dir.appendingPathComponent("fts.sqlite").path)
    defer { try? db.close() }
    try db.execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE VIRTUAL TABLE messages USING fts5(room_scope,sender_scope,tokens,tokenize='ascii',detail=full,columnsize=0);
        """)
    let sample = "今天讨论ＡＢＣ的安排，核对👩🏽‍💻附件ﬃ和e\u{301}。"
    func body(_ length: Int) -> String {
        String(String(repeating: sample, count: length / sample.count + 1).prefix(length))
    }
    let short = body(32), medium = body(256), long = body(2048)
    let count = 10_000, batchSize = 100
    let texts = (0..<count).map { id in
        let prefix = id.isMultiple(of: 100) ? long : (id.isMultiple(of: 10) ? medium : short)
        return prefix + String(id)
    }
    let clock = ContinuousClock()
    let start = clock.now
    for offset in stride(from: 0, to: count, by: batchSize) {
        let encoded = try texts[offset..<(offset + batchSize)].map(SubstringSearchText.encodeForIndex)
        try db.transaction {
            for (i, tokens) in encoded.enumerated() {
                try db.run("INSERT INTO messages(rowid,room_scope,sender_scope,tokens) VALUES(?,?,?,?)",
                           [.integer(Int64(offset + i + 1)), .text("room"), .text("sender"), .text(tokens)])
            }
        }
    }
    let elapsed = start.duration(to: clock.now).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    var usage = rusage()
    try #require(getrusage(RUSAGE_SELF, &usage) == 0)
    let phrase = try SubstringSearchText("abc").encodedPhrase
    #expect(try db.integer("SELECT COUNT(*) FROM messages WHERE messages MATCH ?", [.text("tokens : \"\(phrase)\"")]) == Int64(count))
    print("EMBEDDED_FTS docs_per_second=\(Double(count) / seconds) peak_rss_bytes=\(usage.ru_maxrss)")
}

@Test(.enabled(if: runBenchmarks))
func embeddedTailPreviewPerformance() throws {
    let sample = "今天讨论ＡＢＣ的安排，核对👩🏽‍💻附件ﬃ和e\u{301}。"
    let prefix = String(String(repeating: sample, count: 2048 / sample.count + 1).prefix(2042))
    let texts = (0..<50).map { prefix + "尾部ＡＢ" + String(format: "%02d", $0) }
    let query = try SubstringSearchText("尾部ab")
    var times: [Double] = []
    for run in 0..<24 {
        let start = DispatchTime.now().uptimeNanoseconds
        var hits = 0
        for text in texts {
            hits += try query.previewRanges(in: text, characterCount: 120).count
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        try #require(hits == texts.count)
        if run >= 4 { times.append(ms) }
    }
    print("EMBEDDED_TAIL characters=2048 documents=50 p95_ms=\(times.sorted()[18])")
}
