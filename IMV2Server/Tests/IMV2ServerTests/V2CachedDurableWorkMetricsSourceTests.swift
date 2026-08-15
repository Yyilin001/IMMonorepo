import Foundation
import IMV2Server
import Synchronization
import Testing

@Suite("Cached durable-work metrics")
struct V2CachedDurableWorkMetricsSourceTests {
    @Test("coalesces concurrent scrapes and refreshes only after the interval")
    func coalescesAndExpires() async {
        let clock = MetricsTestClock(Date(timeIntervalSince1970: 1_750_000_000))
        let upstream = CountingMetricsSource()
        let cached = V2CachedDurableWorkMetricsSource(
            source: upstream,
            minimumRefreshInterval: 5,
            now: { clock.now() }
        )

        await withTaskGroup(of: V2DurableWorkMetricsSnapshot.self) { group in
            for _ in 0..<20 {
                group.addTask { await cached.durableWorkMetricsSnapshot() }
            }
            for await snapshot in group { #expect(snapshot.isAvailable) }
        }
        #expect(await upstream.loadCount() == 1)

        clock.advance(by: 4)
        _ = await cached.durableWorkMetricsSnapshot()
        #expect(await upstream.loadCount() == 1)

        clock.advance(by: 1)
        _ = await cached.durableWorkMetricsSnapshot()
        #expect(await upstream.loadCount() == 2)

        // A wall-clock correction must not extend one exact aggregate cache
        // indefinitely. Treat a negative age as stale and refresh once.
        clock.advance(by: -10)
        _ = await cached.durableWorkMetricsSnapshot()
        #expect(await upstream.loadCount() == 3)
    }

    @Test("a timed-out refresh returns last-known-good data and future refreshes recover")
    func timesOutWithoutPoisoningTheCache() async {
        let clock = MetricsTestClock(Date(timeIntervalSince1970: 1_750_000_000))
        let upstream = FirstThenSuspendingMetricsSource()
        let cached = V2CachedDurableWorkMetricsSource(
            source: upstream,
            minimumRefreshInterval: 1,
            maximumRefreshDuration: 0.02,
            now: { clock.now() }
        )

        let first = await cached.durableWorkMetricsSnapshot()
        #expect(first.isAvailable)
        #expect(first.readyRoomOutboxRows == 42)

        clock.advance(by: 1)
        await withTaskGroup(of: V2DurableWorkMetricsSnapshot.self) { group in
            for _ in 0..<20 {
                group.addTask { await cached.durableWorkMetricsSnapshot() }
            }
            for await snapshot in group {
                #expect(!snapshot.isAvailable)
                #expect(snapshot.servedFromLastKnownGood)
                #expect(snapshot.lastSuccessfulRefreshAgeSeconds == 1)
                #expect(snapshot.readyRoomOutboxRows == 42)
            }
        }
        #expect(await upstream.loadCount() == 2)

        clock.advance(by: 1)
        let recovered = await cached.durableWorkMetricsSnapshot()
        #expect(recovered.isAvailable)
        #expect(!recovered.servedFromLastKnownGood)
        #expect(recovered.readyRoomOutboxRows == 99)
        #expect(await upstream.loadCount() == 3)
    }

    @Test("aggregates shard totals and maxima and fails closed on partial availability")
    func aggregatesShardMetrics() async {
        let control = FixedMetricsSource(.init(
            isAvailable: true,
            readyRoomOutboxRows: 2,
            pendingDeviceRevocationEvents: 3,
            pendingRevokedDeviceProjectionCleanupEvents: 4
        ))
        let firstShard = FixedMetricsSource(.init(
            isAvailable: true,
            userSyncLogEstimatedRows: 5,
            userSyncLogRelationBytes: 100,
            userProjectionEffectsEstimatedRows: 7,
            userProjectionEffectsRelationBytes: 80,
            maximumUserProjectionLag: 9,
            oldestBuildingSnapshotAgeSeconds: 11,
            pendingSyncRecordsAcrossDevices: 4
        ))
        let secondShard = FixedMetricsSource(.init(
            isAvailable: true,
            userSyncLogEstimatedRows: 6,
            userSyncLogRelationBytes: 200,
            userProjectionEffectsEstimatedRows: 8,
            userProjectionEffectsRelationBytes: 90,
            maximumUserProjectionLag: 3,
            oldestBuildingSnapshotAgeSeconds: 13,
            pendingSyncRecordsAcrossDevices: 5
        ))
        let aggregate = await V2AggregateDurableWorkMetricsSource(
            sources: [control, firstShard, secondShard]
        ).durableWorkMetricsSnapshot()
        #expect(aggregate.isAvailable)
        #expect(aggregate.readyRoomOutboxRows == 2)
        #expect(aggregate.pendingDeviceRevocationEvents == 3)
        #expect(aggregate.pendingRevokedDeviceProjectionCleanupEvents == 4)
        #expect(aggregate.userSyncLogEstimatedRows == 11)
        #expect(aggregate.userSyncLogRelationBytes == 300)
        #expect(aggregate.userProjectionEffectsEstimatedRows == 15)
        #expect(aggregate.userProjectionEffectsRelationBytes == 170)
        #expect(aggregate.maximumUserProjectionLag == 9)
        #expect(aggregate.oldestBuildingSnapshotAgeSeconds == 13)
        #expect(aggregate.pendingSyncRecordsAcrossDevices == 9)

        let partial = await V2AggregateDurableWorkMetricsSource(
            sources: [control, FixedMetricsSource(.unavailable)]
        ).durableWorkMetricsSnapshot()
        #expect(!partial.isAvailable)
        #expect(partial.readyRoomOutboxRows == 0)
        #expect(partial.userSyncLogRelationBytes == 0)
    }
}

private struct FixedMetricsSource: V2DurableWorkMetricsSource {
    let snapshot: V2DurableWorkMetricsSnapshot
    init(_ snapshot: V2DurableWorkMetricsSnapshot) { self.snapshot = snapshot }
    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot { snapshot }
}

private actor CountingMetricsSource: V2DurableWorkMetricsSource {
    private var count = 0

    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        count += 1
        await Task.yield()
        return .init(isAvailable: true, readyRoomOutboxRows: count)
    }

    func loadCount() -> Int { count }
}

private actor FirstThenSuspendingMetricsSource: V2DurableWorkMetricsSource {
    private var count = 0

    func durableWorkMetricsSnapshot() async -> V2DurableWorkMetricsSnapshot {
        count += 1
        switch count {
        case 1:
            return .init(isAvailable: true, readyRoomOutboxRows: 42)
        case 2:
            do {
                try await Task.sleep(for: .seconds(60))
                return .init(isAvailable: true, readyRoomOutboxRows: 77)
            } catch {
                return .unavailable
            }
        default:
            return .init(isAvailable: true, readyRoomOutboxRows: 99)
        }
    }

    func loadCount() -> Int { count }
}

private final class MetricsTestClock: Sendable {
    private let value: Mutex<Date>

    init(_ date: Date) { value = Mutex(date) }
    func now() -> Date { value.withLock { $0 } }
    func advance(by interval: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}
