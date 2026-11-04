import Foundation
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

extension V2MessageSearchTests {
    /// IM_SEARCH_BENCHMARK=1 swift test -c release --filter localSearchBenchmark
    @Test("消息子串索引端到端基准", .enabled(if: ProcessInfo.processInfo.environment["IM_SEARCH_BENCHMARK"] == "1"))
    func localSearchBenchmark() async throws {
        let total = 10_000, burst = 50, commitsPerRound = 60
        let room = RoomID(uuid: UUID()), sender = UserID(uuid: UUID())
        let clock = ContinuousClock()
        func milliseconds(_ interval: Duration) -> Double {
            let parts = interval.components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        let events = try (1...(total + burst + 4 * commitsPerRound)).map { number in
            let detail = number.isMultiple(of: 100) ? String(repeating: "核对清单和附件。", count: 50) : "请确认时间 👩🏽‍💻"
            let body = number > total ? "增量待查 \(number)" : "项目群的更新 ＡＢＣ-\(number) \(detail)"
            let record = try acceptedRoomEvent(sourceEvent: UUID().uuidString, roomID: room, senderID: sender,
                messageID: MessageID(uuid: UUID()), roomSequence: UInt64(number), text: body,
                createdAtMilliseconds: 1_750_000_000_000 + Int64(number))
            return try V2ClientGroupEvent(sourceEventID: record.sourceEventID, roomSequence: record.sequence,
                                          projectionKind: record.projectionKind, payload: record.payload)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "V2.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()))
        for start in stride(from: 0, to: total, by: 100) {
            let batch = Array(events[start..<(start + 100)])
            _ = try await store.applyGroupEventPage(.init(roomID: room, events: batch, nextRoomSequence: UInt64(start + 100), hasMore: false))
        }
        try await store.messageSearch.prepareMessageSearchIndex()
        let pool = try #require(await store.messageSearchDatabasePool)
        try await pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let bytes = try V2LocalDatabaseArtifacts(primary: url).search.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let size = try #require(bytes)
        var times: [Double] = []
        for iteration in 0..<65 {
            let start = clock.now
            let page = try await store.messageSearch.searchMessages(.init(query: "的", scope: .room(room), previewHighlights: true))
            let elapsed = milliseconds(start.duration(to: clock.now))
            try #require(page.hits.count == 50 && page.hits.first?.roomSequence == UInt64(total))
            if iteration >= 5 { times.append(elapsed) }
        }

        // 以生产索引循环实际休眠/唤醒周期测量端到端延迟；轮询间隔为 20 ms。
        await store.messageSearch.startIndexing()
        let incoming = Array(events[total..<(total + burst)])
        async let written = Self.publishBenchmarkBurst(incoming, room: room, to: store)
        var observed: [UInt64: ContinuousClock.Instant] = [:]
        let deadline = clock.now + .seconds(20)
        while observed.count < burst && clock.now < deadline {
            let page = try await store.messageSearch.searchMessages(.init(query: "增量待查", scope: .room(room), limit: 100, previewHighlights: true))
            let now = clock.now
            for hit in page.hits where observed[hit.roomSequence] == nil { observed[hit.roomSequence] = now }
            try await Task.sleep(for: .milliseconds(20))
        }
        let commits = try await written
        let delays = try commits.map { sequence, instant in
            milliseconds(instant.duration(to: try #require(observed[sequence])))
        }
        // 同一数据库、提交路径和消息大小，以 ABBA 顺序交替只收消息及持续搜索长历史。
        var idle: [Double] = [], loaded: [Double] = [], walPeak: Int64 = 0, searches = 0
        let artifacts = V2LocalDatabaseArtifacts(primary: url)
        for (round, withLoad) in [false, true, true, false].enumerated() {
            let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let load: Task<Int, Error>? = withLoad ? Task {
                defer { signal.finish() }
                var pages = 0
                do {
                    while !Task.isCancelled {
                        let page = try await store.messageSearch.searchMessages(.init(query: "核对", scope: .room(room), previewHighlights: true))
                        try #require(page.hits.count == 50)
                        pages += 1
                        if pages == 1 { signal.yield(()) }
                    }
                } catch is CancellationError {}
                return pages
            } : nil
            defer { load?.cancel() }
            if let load {
                var notices = started.makeAsyncIterator()
                if await notices.next() == nil { _ = try await load.value }
            }
            let offset = total + burst + round * commitsPerRound
            for event in events[offset..<(offset + commitsPerRound)] {
                let start = clock.now
                _ = try await store.applyGroupEventPage(.init(roomID: room, events: [event], nextRoomSequence: event.roomSequence, hasMore: false))
                let ms = milliseconds(start.duration(to: clock.now))
                if withLoad { loaded.append(ms) } else { idle.append(ms) }
                let bytes = [artifacts.primary, artifacts.search].reduce(Int64(0)) { size, url in
                    size + ((try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0)
                }
                walPeak = max(walPeak, bytes)
                try await Task.sleep(for: .milliseconds(8))
            }
            load?.cancel()
            if let load { searches += try await load.value }
        }
        var cancellations: [Double] = []
        for _ in 0..<30 {
            let task = Task { try await store.messageSearch.searchMessages(.init(query: "的", scope: .room(room), limit: 100)) }
            try await Task.sleep(for: .milliseconds(1))
            let start = clock.now
            task.cancel()
            do { _ = try await task.value } catch is CancellationError {
                cancellations.append(milliseconds(start.duration(to: clock.now)))
            }
        }
        try #require(!cancellations.isEmpty && searches > 0)
        print("IM_SYNC_SEARCH idle_apply_p95_ms=\(p95(idle)) loaded_apply_p95_ms=\(p95(loaded)) pages=\(searches) cancellation_p95_ms=\(p95(cancellations)) cancelled=\(cancellations.count) peak_wal_bytes=\(walPeak)")
        await store.messageSearch.stopIndexing()
        try await store.close()
        print("IM_SEARCH_BENCH documents=\(total) db_bytes=\(size) first_page_p95_ms=\(p95(times)) visible_p95_ms=\(p95(delays))")
    }

    private static func publishBenchmarkBurst(_ events: [V2ClientGroupEvent], room: RoomID,
                                               to store: GRDBV2LocalSyncStore) async throws -> [UInt64: ContinuousClock.Instant] {
        var starts: [UInt64: ContinuousClock.Instant] = [:]
        for event in events {
            starts[event.roomSequence] = ContinuousClock.now
            _ = try await store.applyGroupEventPage(.init(roomID: room, events: [event], nextRoomSequence: event.roomSequence, hasMore: false))
            try await Task.sleep(for: .milliseconds(25))
        }
        return starts
    }
}
