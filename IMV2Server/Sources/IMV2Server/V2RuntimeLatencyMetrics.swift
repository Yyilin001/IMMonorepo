import Foundation
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// Fixed latency buckets shared by process-local runtime diagnostics.
///
/// The bounds are deliberately static and contain no room, user, request or
/// database identifiers. They can therefore be rendered as Prometheus
/// histograms without creating an unbounded label set.
public enum V2RuntimeLatencyBucket: Int, CaseIterable, Sendable {
    case milliseconds1 = 1
    case milliseconds2 = 2
    case milliseconds4 = 4
    case milliseconds8 = 8
    case milliseconds16 = 16
    case milliseconds32 = 32
    case milliseconds64 = 64
    case milliseconds128 = 128
    case milliseconds256 = 256
    case milliseconds512 = 512
    case milliseconds1_000 = 1_000
    case milliseconds2_000 = 2_000
    case milliseconds5_000 = 5_000
}

public struct V2RuntimeLatencyHistogramSnapshot: Equatable, Sendable {
    public let samples: UInt64
    public let sumMilliseconds: UInt64
    public let maximumMilliseconds: UInt64
    private let cumulativeBuckets: [V2RuntimeLatencyBucket: UInt64]

    public init(
        samples: UInt64,
        sumMilliseconds: UInt64,
        maximumMilliseconds: UInt64,
        cumulativeBuckets: [V2RuntimeLatencyBucket: UInt64]
    ) {
        self.samples = samples
        self.sumMilliseconds = sumMilliseconds
        self.maximumMilliseconds = maximumMilliseconds
        self.cumulativeBuckets = cumulativeBuckets
    }

    public func count(atOrBelow bucket: V2RuntimeLatencyBucket) -> UInt64 {
        cumulativeBuckets[bucket, default: 0]
    }

    public static let empty = Self(
        samples: 0,
        sumMilliseconds: 0,
        maximumMilliseconds: 0,
        cumulativeBuckets: [:]
    )
}

private struct V2RuntimeLatencyAccumulator: Sendable {
    var samples: UInt64 = 0
    var sumMilliseconds: UInt64 = 0
    var maximumMilliseconds: UInt64 = 0
    var buckets: [V2RuntimeLatencyBucket: UInt64] = [:]

    mutating func record(milliseconds: UInt64) {
        samples = saturatingIncrement(samples)
        sumMilliseconds = saturatingAdd(sumMilliseconds, milliseconds)
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        for bucket in V2RuntimeLatencyBucket.allCases where milliseconds <= bucket.rawValue {
            buckets[bucket] = saturatingIncrement(buckets[bucket, default: 0])
        }
    }

    var snapshot: V2RuntimeLatencyHistogramSnapshot {
        .init(
            samples: samples,
            sumMilliseconds: sumMilliseconds,
            maximumMilliseconds: maximumMilliseconds,
            cumulativeBuckets: buckets
        )
    }
}

/// Stable stages in the shard-only direct-message batch transaction.
///
/// These values are operational schema. Keep them low-cardinality and do not
/// add dynamic relation, shard, room or request values.
public enum V2DirectRoomLogAppendStage: String, CaseIterable, Sendable {
    case fastPathProbe = "fast_path_probe"
    case acceleratedTotal = "accelerated_total"
    case standardTotal = "standard_total"
    case cacheLookup = "cache_lookup"
    case transaction = "transaction"
    case operationLocks = "operation_locks"
    case authorizationPreflight = "authorization_preflight"
    case preparation
    case policyMutations = "policy_mutations"
    case messagePersistence = "message_persistence"
    case projectionPersistence = "projection_persistence"
    case shardReservation = "shard_reservation"
    case cacheFinalization = "cache_finalization"
    case projectionShadowFinalization = "projection_shadow_finalization"
    case cacheAndShadowFinalization = "cache_and_shadow_finalization"
}

public struct V2DirectRoomLogAppendStageMetricsSnapshot: Equatable, Sendable {
    private let histograms: [V2DirectRoomLogAppendStage: V2RuntimeLatencyHistogramSnapshot]

    public init(
        histograms: [V2DirectRoomLogAppendStage: V2RuntimeLatencyHistogramSnapshot]
    ) {
        self.histograms = histograms
    }

    public func value(
        for stage: V2DirectRoomLogAppendStage
    ) -> V2RuntimeLatencyHistogramSnapshot {
        histograms[stage] ?? .empty
    }
}

/// Synchronous recorder used inside PostgreSQL transactions.
///
/// Recording never suspends, acquires another database connection or enters
/// an actor while a transaction is open. One small mutex update per SQL stage
/// preserves the repository's no-nested-pool invariant.
public final class V2DirectRoomLogAppendStageMetrics: Sendable {
    private let state = Mutex([V2DirectRoomLogAppendStage: V2RuntimeLatencyAccumulator]())

    public init() {}

    public func record(
        _ stage: V2DirectRoomLogAppendStage,
        duration: Duration
    ) {
        record(stage, milliseconds: runtimeMilliseconds(duration))
    }

    public func record(
        _ stage: V2DirectRoomLogAppendStage,
        milliseconds: UInt64
    ) {
        state.withLock { state in
            state[stage, default: .init()].record(milliseconds: milliseconds)
        }
    }

    public func snapshot() -> V2DirectRoomLogAppendStageMetricsSnapshot {
        state.withLock { state in
            .init(histograms: state.mapValues(\.snapshot))
        }
    }
}

/// Low-frequency scheduler probe for a group of SwiftNIO EventLoops.
///
/// A recursively scheduled 100 ms task measures how late each loop executes
/// known work. This avoids enabling NIO's per-tick delegate, which would add
/// timestamp and callback overhead to every loop tick at high connection
/// counts. Delayed callbacks never catch up in a tight loop: the next sample
/// is scheduled relative to the actual callback time.
public final class V2EventLoopLagMetrics: Sendable {
    private struct State: Sendable {
        var isRunning = false
        var generation: UInt64 = 0
        var latency = V2RuntimeLatencyAccumulator()
    }

    private let intervalNanoseconds: UInt64
    private let state = Mutex(State())

    public init(intervalMilliseconds: Int = 100) {
        precondition((10 ... 1_000).contains(intervalMilliseconds))
        intervalNanoseconds = UInt64(intervalMilliseconds) * 1_000_000
    }

    public func start(on group: MultiThreadedEventLoopGroup) {
        let generation = state.withLock { state -> UInt64 in
            precondition(!state.isRunning, "event-loop lag metrics started more than once")
            state.isRunning = true
            state.generation &+= 1
            precondition(state.generation != 0, "event-loop lag metrics generation exhausted")
            return state.generation
        }
        for eventLoop in Array(group.makeIterator()) {
            schedule(
                on: eventLoop,
                expected: .now() + .nanoseconds(Int64(intervalNanoseconds)),
                generation: generation
            )
        }
    }

    public func stop() {
        state.withLock { state in
            state.isRunning = false
            state.generation &+= 1
        }
    }

    public func snapshot() -> V2RuntimeLatencyHistogramSnapshot {
        state.withLock { $0.latency.snapshot }
    }

    /// Test seam and adapter for runtimes that already own a scheduler probe.
    public func recordLag(milliseconds: UInt64) {
        state.withLock { $0.latency.record(milliseconds: milliseconds) }
    }

    private func schedule(
        on eventLoop: any EventLoop,
        expected: NIODeadline,
        generation: UInt64
    ) {
        eventLoop.scheduleTask(deadline: expected) { [weak self] in
            self?.sample(on: eventLoop, expected: expected, generation: generation)
        }
    }

    private func sample(
        on eventLoop: any EventLoop,
        expected: NIODeadline,
        generation: UInt64
    ) {
        let now = NIODeadline.now()
        let shouldContinue = state.withLock { state -> Bool in
            guard state.isRunning, state.generation == generation else { return false }
            let lagNanoseconds = now.uptimeNanoseconds > expected.uptimeNanoseconds
                ? now.uptimeNanoseconds - expected.uptimeNanoseconds
                : 0
            state.latency.record(milliseconds: lagNanoseconds / 1_000_000)
            return true
        }
        guard shouldContinue else { return }
        schedule(
            on: eventLoop,
            expected: now + .nanoseconds(Int64(intervalNanoseconds)),
            generation: generation
        )
    }
}

private func runtimeMilliseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
    let seconds = UInt64(components.seconds)
    let secondsMilliseconds = seconds.multipliedReportingOverflow(by: 1_000)
    guard !secondsMilliseconds.overflow else { return .max }
    let fractionalMilliseconds = UInt64(components.attoseconds / 1_000_000_000_000_000)
    return saturatingAdd(secondsMilliseconds.partialValue, fractionalMilliseconds)
}

private func saturatingIncrement(_ value: UInt64) -> UInt64 {
    value == .max ? .max : value + 1
}

private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let sum = lhs.addingReportingOverflow(rhs)
    return sum.overflow ? .max : sum.partialValue
}
