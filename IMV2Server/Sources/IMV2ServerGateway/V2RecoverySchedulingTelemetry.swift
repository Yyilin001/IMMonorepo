import Synchronization
import IMV2ServerContracts

/// Fixed-cardinality completed observations. Callers own their local monotonic
/// spans; this collector owns no tasks, timestamps, IDs or per-event records.
/// Interest spans measure logical acquisition (including cache/join); room
/// query spans include provider callbacks and do not imply SQL-only duration
/// or physical RPC counts. Presence SQL has separate actual-query metrics.
final class V2RecoverySchedulingTelemetry: Sendable {
    private let state = Mutex(V2RecoverySchedulingSnapshot())

    func record(_ phase: V2RecoverySchedulingPhase, duration: Duration) {
        let value = duration.components
        let milliseconds = max(0, Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15)
        state.withLock { state in
            var timing = state.timings[phase] ?? .init()
            if timing.count < UInt64.max { timing.count += 1 }
            timing.totalMilliseconds += milliseconds
            timing.maxMilliseconds = max(timing.maxMilliseconds, milliseconds)
            state.timings[phase] = timing
        }
    }

    /// Count actual examined entries, including repeated scans. Aggregate at
    /// each caller's scan boundary rather than taking a lock for every entry.
    func recordScan(_ source: V2RecoverySchedulingScan, entries: Int) {
        guard entries > 0 else { return }
        state.withLock { state in
            let result = (state.scans[source] ?? 0).addingReportingOverflow(UInt64(entries))
            state.scans[source] = result.overflow ? UInt64.max : result.partialValue
        }
    }

    // Independent fixed counters: Ready validators may run under ByteStream
    // and Coordinator write fences. These atomics never take the timing mutex
    // or any admission fence and remain live for retained control retries.
    private let permissionExpired = V2RecoveryReadyAtomicCounter()
    private let permissionMissing = V2RecoveryReadyAtomicCounter()
    private let generationInvalid = V2RecoveryReadyAtomicCounter()
    private let headUnsatisfied = V2RecoveryReadyAtomicCounter()
    private let coverageChanged = V2RecoveryReadyAtomicCounter()
    private let closed = V2RecoveryReadyAtomicCounter()
    private let recovering = V2RecoveryReadyAtomicCounter()
    private let enqueueRefused = V2RecoveryReadyAtomicCounter()

    private func counter(_ reason: V2RecoveryReadyRejectionReason) -> V2RecoveryReadyAtomicCounter {
        switch reason {
        case .permissionExpired: permissionExpired
        case .permissionMissing: permissionMissing
        case .generationInvalid: generationInvalid
        case .headUnsatisfied: headUnsatisfied
        case .coverageChanged: coverageChanged
        case .closed: closed
        case .recovering: recovering
        case .enqueueRefused: enqueueRefused
        }
    }

    func recordReadyRejection(_ reason: V2RecoveryReadyRejectionReason) { counter(reason).increment() }

    nonisolated func snapshot() -> V2RecoverySchedulingSnapshot {
        var result = state.withLock { $0 }
        // No cross-reason atomic snapshot is promised. Counters are cumulative;
        // taking this snapshot never reads or acquires an enqueue fence.
        for reason in V2RecoveryReadyRejectionReason.allCases {
            result.readyRejections[reason] = counter(reason).count
        }
        return result
    }
}

private final class V2RecoveryReadyAtomicCounter: Sendable {
    private let value = Atomic<UInt64>(0)
    var count: UInt64 { value.load(ordering: .relaxed) }
    func increment() {
        var observed = value.load(ordering: .relaxed)
        while observed < UInt64.max {
            let result = value.compareExchange(expected: observed, desired: observed + 1, ordering: .relaxed)
            if result.exchanged { return }
            observed = result.original
        }
    }
}
