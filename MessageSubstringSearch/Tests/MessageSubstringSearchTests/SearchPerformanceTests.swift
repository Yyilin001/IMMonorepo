import Foundation
import Testing
import MessageSubstringSearch

/// IM_SEARCH_BENCHMARK=1 swift test -c release --filter searchPerformance
@Test(.enabled(if: ProcessInfo.processInfo.environment["IM_SEARCH_BENCHMARK"] == "1"))
func searchPerformance() async throws {
    let query = try SubstringSearchText("的")
    let sample = "今天讨论ＡＢＣ的安排，稍后同步进度👩🏽‍💻。"
    for length in [32, 256, 2048] {
        let prefix = String(String(repeating: sample, count: length / sample.count + 1).prefix(length - 2))
        let texts = (0..<50).map { prefix + String(format: "%02d", $0) }
        for preview in [false, true] {
            var times: [Double] = []
            for run in 0..<23 {
                var matches = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for text in texts {
                    let ranges = try preview ? query.previewRanges(in: text, characterCount: 120) : query.matchingRanges(in: text)
                    matches += ranges.count
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                try #require(matches >= texts.count)
                if run >= 3 { times.append(elapsed) }
            }
            print("SEARCH_HIGHLIGHT characters=\(length) documents=50 preview=\(preview) p95_ms=\(times.sorted()[18])")
        }
    }

    try await withIndex(configure: { $0.mode = .compatibilityCaseInsensitive }) { index in
        for start in stride(from: 0, to: 10_000, by: 100) {
            try await insert(index, (start..<(start + 100)).map {
                document(String($0), "会议的时间是下午。确认参与人ＡＢＣ 👩🏽‍💻 \($0)", time: Int64($0))
            })
        }
        for (needle, expected) in [("的", 50), ("👩🏽‍💻 7864", 1), ("不存在", 0)] {
            var times: [Double] = []
            for run in 0..<65 {
                let start = DispatchTime.now().uptimeNanoseconds
                let page = try await index.search(.init(needle, groupID: "room", pageSize: 50))
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                try #require(page.hits.count == expected)
                if run >= 5 { times.append(elapsed) }
            }
            print("SEARCH_PAGE documents=10000 hits=\(expected) p95_ms=\(times.sorted()[56])")
        }
    }
}
