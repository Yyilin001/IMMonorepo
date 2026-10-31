import Foundation
import IMV2Core
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

@Suite(.serialized)
struct V2PublicProfileSnapshotCacheTests {
    @Test("concurrent viewers share one immutable content load; new revision reads independently")
    func coalescingAndVersions() async throws {
        let loader = SnapshotLoader(), key = V2PublicProfileSnapshotKey(userID: UUID(), revision: 1)
        let cache = V2PublicProfileSnapshotCache(load: loader.load)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let values = try await cache.read([key], deadline: .now + .seconds(5))
                    #expect(values[key]?.displayName == "Version 1")
                }
            }
            try await group.waitForAll()
        }
        #expect(await loader.calls == 1)
        _ = try await cache.read([key], deadline: .now + .seconds(5))
        #expect(await loader.calls == 1)
        let newer = V2PublicProfileSnapshotKey(userID: key.userID, revision: 2)
        let values = try await cache.read([newer], deadline: .now + .seconds(5))
        #expect(values[newer]?.displayName == "Version 2")
        #expect(await loader.calls == 2)
        await cache.close()
    }

    @Test("a loader cannot poison another author's cache entry")
    func rejectsWrongIdentity() async throws {
        let key = V2PublicProfileSnapshotKey(userID: UUID(), revision: 1)
        let cache = V2PublicProfileSnapshotCache { _, _ in
            [key: try .init(userID: .init(uuid: UUID()), handle: .init("author"), displayName: "Wrong", accountKind: .regular)]
        }
        await #expect(throws: V2ProfileControlBatchError.corruptResult) { _ = try await cache.read([key], deadline: .now + .seconds(5)) }
        #expect(await cache.originBatches == 1)
        await cache.close()
    }
}

private actor SnapshotLoader {
    var calls = 0
    func load(_ keys: [V2PublicProfileSnapshotKey], deadline: ContinuousClock.Instant) async throws -> [V2PublicProfileSnapshotKey: V2PublicIdentity] {
        calls += 1
        try await Task.sleep(for: .milliseconds(10))
        return try Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, try V2PublicIdentity(userID: .init(uuid: key.userID), handle: .init("author"), displayName: "Version \(key.revision)", accountKind: .regular))
        })
    }
}
