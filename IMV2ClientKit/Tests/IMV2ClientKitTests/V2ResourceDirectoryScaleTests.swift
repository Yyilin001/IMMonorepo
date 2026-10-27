import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

/// Opt-in scale verification. Host timings are diagnostics, never proof of the
/// Release iPhone latency/memory gate. Run on the target device separately.
@Suite("Resource directory at 10000 indexed attachments", .timeLimit(.minutes(3)))
struct V2ResourceDirectoryScaleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_SCALE_VERIFICATION"] == "1"))
    func firstSnapshotAndCompleteKeysetWalk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-scale-\(UUID())")
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let scope = V2AccountStorageScope(incarnation: UUID(), accountID: user, directory: directory, cacheDirectory: directory.appending(path: "cache-scope"))
        let center = try await V2ResourceCenter.make(scope: scope, store: store)
        do {
            // Same timestamp stresses every tie-break column. This uses the real
            // indexing domain transaction, not a reduced standalone SQL schema.
            try await store.databasePool.write { db in
                for index in 0..<10_000 {
                    let descriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())),
                        revision: 1, displayName: .init("scale-\(index).png"), contentType: "image/png", byteCount: 32,
                        checksum: .init(value: String(repeating: "a", count: 64)), state: .ready, pixelWidth: 320, pixelHeight: 200)
                    try GRDBV2LocalSyncStore.indexResource(descriptor,
                        reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0),
                        businessRevision: 1, now: Date(timeIntervalSince1970: 100), db: db)
                }
            }
            let start = ContinuousClock.now
            var iterator = try await center.snapshots(for: .init(limit: 50)).makeAsyncIterator()
            guard case .available(let first) = await iterator.next() else { throw ScaleFailure.missingSnapshot }
            let firstMilliseconds = milliseconds(start.duration(to: .now))
            #expect(first.entries.count == 50 && first.nextCursor != nil)
            #expect(first.entries.allSatisfy { $0.descriptor.pixelWidth == 320 && $0.referenceCount == 1 })
            var samples: [Double] = []
            for _ in 0..<30 {
                let sampleStart = ContinuousClock.now
                let page = try await store.resourceDirectory(roomID: room, limit: 50)
                samples.append(milliseconds(sampleStart.duration(to: .now)))
                #expect(page.entries.map(\.descriptor.key) == first.entries.map(\.descriptor.key))
            }
            var keys = Set(first.entries.map(\.descriptor.key)), cursor = first.nextCursor, pages = 1
            while let before = cursor {
                try Task.checkCancellation()
                let page = try await store.resourceDirectory(roomID: room, before: before, limit: 50)
                #expect(page.entries.count == 50)
                for entry in page.entries { #expect(keys.insert(entry.descriptor.key).inserted) }
                pages += 1; cursor = page.nextCursor
            }
            #expect(keys.count == 10_000 && pages == 200)
            let p95 = samples.sorted()[28]
            print("RESOURCE_SCALE records=10000 pageSize=50 pages=\(pages) firstSnapshotMs=\(firstMilliseconds) warmQueryP95Ms=\(p95) os=\(ProcessInfo.processInfo.operatingSystemVersionString) processors=\(ProcessInfo.processInfo.processorCount)")
            await center.close(); try await store.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            await center.close(); try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
    private enum ScaleFailure: Error { case missingSnapshot }
}
