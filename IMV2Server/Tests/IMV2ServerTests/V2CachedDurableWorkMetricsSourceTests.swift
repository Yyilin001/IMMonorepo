import Foundation
import IMV2Server
import Synchronization
import Testing

@Suite("Cached durable-work metrics")
struct V2CachedDurableWorkMetricsSourceTests {
    @Test("wall clock jumps preserve the refresh interval and the age of last-known-good metrics",
          arguments: [-3_600.0, 3_600, -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude])
    func monotonicMetricsAgeAcrossWallClockJumps(jump: Double) async {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = MetricsTestClock(start)
        let jumped = start.addingTimeInterval(jump)
        let source = ClockChangingMetricsSource(clock: clock, failureTime: jumped)
        let cached = V2CachedDurableWorkMetricsSource(
            source: source, minimumRefreshInterval: 5,
            now: { clock.now() }, monotonicNow: { clock.monotonicNow() }
        )
        #expect(await cached.durableWorkMetricsSnapshot().readyRoomOutboxRows == 42)
        clock.set(jumped)
        clock.advanceMonotonic(by: .milliseconds(4_500))
        #expect(await cached.durableWorkMetricsSnapshot().isAvailable)
        #expect(await source.loadCount() == 1)
        clock.advanceMonotonic(by: .milliseconds(750))
        let fallback = await cached.durableWorkMetricsSnapshot()
        #expect(!fallback.isAvailable && fallback.servedFromLastKnownGood)
        #expect(fallback.readyRoomOutboxRows == 42)
        #expect(fallback.lastSuccessfulRefreshAgeSeconds == 5)
        #expect(await source.loadCount() == 2)
        // Repairing wall time does not make a cached failure fresh success.
        clock.set(start)
        #expect(await cached.durableWorkMetricsSnapshot() == fallback)
        #expect(await source.loadCount() == 2)
        clock.advanceMonotonic(by: .seconds(5))
        let recovered = await cached.durableWorkMetricsSnapshot()
        #expect(recovered.isAvailable && recovered.readyRoomOutboxRows == 99)
        #expect(!recovered.servedFromLastKnownGood)
        #expect(await source.loadCount() == 3)
    }

    @Test("Non-finite request clocks do not turn metrics scrapes into repeated upstream loads",
          arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteClockAvoidsRefreshStorm(seconds: Double) async {
        let clock = MetricsTestClock(Date(timeIntervalSince1970: seconds))
        let source = CountingMetricsSource()
        let cached = V2CachedDurableWorkMetricsSource(source: source, now: { clock.now() }, monotonicNow: { clock.monotonicNow() })
        for _ in 0..<5 {
            let snapshot = await cached.durableWorkMetricsSnapshot()
            #expect(!snapshot.isAvailable && !snapshot.servedFromLastKnownGood)
        }
        #expect(await source.loadCount() == 0)
        clock.set(Date(timeIntervalSince1970: 1_750_000_000))
        #expect(await cached.durableWorkMetricsSnapshot().isAvailable)
        #expect(await source.loadCount() == 1)
    }

    @Test("Finite wall-clock corrections preserve the elapsed age of last-known-good data",
          arguments: [-1.0, 1.875, Double(Int.max).nextDown, Double(Int.max),
              -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude])
    func finiteFallbackAge(seconds: Double) async {
        let clock = MetricsTestClock(Date(timeIntervalSince1970: 0))
        let source = ClockChangingMetricsSource(clock: clock, failureTime: Date(timeIntervalSince1970: seconds))
        let cached = V2CachedDurableWorkMetricsSource(source: source, minimumRefreshInterval: 1, now: { clock.now() }, monotonicNow: { clock.monotonicNow() })
        _ = await cached.durableWorkMetricsSnapshot()
        clock.advance(by: 2)
        let fallback = await cached.durableWorkMetricsSnapshot()
        #expect(!fallback.isAvailable && fallback.servedFromLastKnownGood)
        #expect(fallback.readyRoomOutboxRows == 42)
        #expect(fallback.lastSuccessfulRefreshAgeSeconds == 2)
    }

    @Test("Invalid fallback age is unavailable and a subsequent healthy refresh recovers",
          arguments: [Double.nan, .infinity, -.infinity])
    func invalidFallbackClock(seconds: Double) async {
        let baseline = Date(timeIntervalSince1970: 0)
        let clock = MetricsTestClock(baseline)
        let upstream = ClockChangingMetricsSource(clock: clock, failureTime: Date(timeIntervalSince1970: seconds))
        let cached = V2CachedDurableWorkMetricsSource(source: upstream, minimumRefreshInterval: 1, now: { clock.now() }, monotonicNow: { clock.monotonicNow() })
        let initial = await cached.durableWorkMetricsSnapshot()
        #expect(initial.isAvailable && initial.readyRoomOutboxRows == 42)
        clock.advance(by: 2)
        let failed = await cached.durableWorkMetricsSnapshot()
        #expect(!failed.isAvailable)
        #expect(!failed.servedFromLastKnownGood)
        #expect(failed.readyRoomOutboxRows == 0)
        // Recover inside the original success's TTL: a failed refresh must
        // not make that older snapshot healthy again merely due to clock repair.
        clock.set(baseline.addingTimeInterval(0.5))
        let recovered = await cached.durableWorkMetricsSnapshot()
        #expect(recovered.isAvailable && recovered.readyRoomOutboxRows == 99)
        #expect(!recovered.servedFromLastKnownGood)
    }

    @Test("coalesces concurrent scrapes and refreshes only after the interval")
    func coalescesAndExpires() async {
        let clock = MetricsTestClock(Date(timeIntervalSince1970: 1_750_000_000))
        let upstream = CountingMetricsSource()
        let cached = V2CachedDurableWorkMetricsSource(
            source: upstream,
            minimumRefreshInterval: 5,
            now: { clock.now() }, monotonicNow: { clock.monotonicNow() }
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

        // A wall-clock correction neither expires the cache early nor extends
        // its monotonic interval. Refresh at the next elapsed deadline.
        clock.set(clock.now().addingTimeInterval(-10))
        _ = await cached.durableWorkMetricsSnapshot()
        #expect(await upstream.loadCount() == 2)
        clock.advanceMonotonic(by: .seconds(5))
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
            now: { clock.now() }, monotonicNow: { clock.monotonicNow() }
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
            terminalFanoutCompletionUnits: 6,
            oldestTerminalFanoutCompletionAgeSeconds: 12,
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
        #expect(aggregate.terminalFanoutCompletionUnits == 6)
        #expect(aggregate.oldestTerminalFanoutCompletionAgeSeconds == 12)
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
    private let instant = Mutex(ContinuousClock.now)

    init(_ date: Date) { value = Mutex(date) }
    func now() -> Date { value.withLock { $0 } }
    func monotonicNow() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advanceMonotonic(by duration: Duration) { instant.withLock { $0 += duration } }
    func set(_ date: Date) { value.withLock { $0 = date } }
    func advance(by interval: TimeInterval) {
        precondition(interval.isFinite && interval >= 0)
        value.withLock { $0 = $0.addingTimeInterval(interval) }
        advanceMonotonic(by: .seconds(interval))
    }
}

private actor ClockChangingMetricsSource: V2DurableWorkMetricsSource {
    let clock: MetricsTestClock
    let failureTime: Date
    var calls = 0
    init(clock: MetricsTestClock, failureTime: Date) { self.clock = clock; self.failureTime = failureTime }
    func loadCount() -> Int { calls }
    func durableWorkMetricsSnapshot() -> V2DurableWorkMetricsSnapshot {
        calls += 1
        if calls == 1 { return .init(isAvailable: true, readyRoomOutboxRows: 42) }
        if calls == 2 { clock.set(failureTime); return .unavailable }
        return .init(isAvailable: true, readyRoomOutboxRows: 99)
    }
}
