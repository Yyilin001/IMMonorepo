import Foundation
import Synchronization
import IMV2ServerGateway

/// Opt-in control spans share the heartbeat diagnostic switch. No identities,
/// new tasks or SQL; bounded examples describe wall time, not CPU occupancy.
enum GatewayJournalDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["IM_V2_GATEWAY_HEARTBEAT_DIAGNOSTICS"] == "true"
    enum Stage: String, CaseIterable, Sendable {
        case reconcile, batchProof, reconcileSource, bindingCheck, recovery, proof, selection, snapshot, applyUsers, install
    }
    enum Fallback: String, CaseIterable, Sendable {
        case noBaseline, interestChanged, missingUser, floorsUnavailable, replayInvalid
    }
    struct Span: Sendable {
        let started: ContinuousClock.Instant
        let startedAtUnixSeconds: Double
    }
    private struct Duration: Sendable {
        var count: UInt64 = 0
        var milliseconds: Double = 0
    }
    private struct Example: Sendable {
        let stage: Stage
        let start: Double
        let end: Double
        let milliseconds: Double
    }
    private struct State: Sendable {
        var durations: [Stage: Duration] = [:]
        var failures: [V2GatewayJournalProjectionReceiver.RecoveryCheckpointFailure: UInt64] = [:]
        var fallbacks: [Fallback: UInt64] = [:]
        var examples: [Example] = []
    }
    private static let state = Mutex(State())
    static func begin() -> Span? {
        guard enabled else { return nil }
        return .init(started: .now, startedAtUnixSeconds: Date().timeIntervalSince1970)
    }
    static func end(_ span: Span?, stage: Stage) {
        guard let span else { return }
        let elapsed = span.started.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let endedAt = Date().timeIntervalSince1970
        state.withLock { value in
            value.durations[stage, default: .init()].count += 1
            value.durations[stage, default: .init()].milliseconds += ms
            if ms >= 5 {
                value.examples.removeAll { $0.end < endedAt - 30 }
                value.examples.append(.init(stage: stage, start: span.startedAtUnixSeconds, end: endedAt, milliseconds: ms))
                value.examples.sort { $0.milliseconds > $1.milliseconds }
                if value.examples.count > 64 { value.examples.removeLast(value.examples.count - 64) }
            }
        }
    }
    static func failure(_ reason: V2GatewayJournalProjectionReceiver.RecoveryCheckpointFailure) {
        guard enabled else { return }
        state.withLock { $0.failures[reason, default: 0] += 1 }
    }
    static func fallback(_ reason: Fallback) {
        guard enabled else { return }
        state.withLock { $0.fallbacks[reason, default: 0] += 1 }
    }
    static func prometheus() -> String {
        guard enabled else { return "" }
        let snapshot = state.withLock { $0 }
        var lines = ["# HELP im_v2_gateway_journal_diagnostic_stage_milliseconds Opt-in completed control wall spans, includes awaits and scheduling; nested spans overlap.",
            "# TYPE im_v2_gateway_journal_diagnostic_stage_milliseconds summary",
            "# TYPE im_v2_gateway_journal_checkpoint_failure_total counter",
            "# TYPE im_v2_gateway_journal_snapshot_fallback_total counter"]
        for stage in Stage.allCases {
            let value = snapshot.durations[stage, default: .init()]
            lines.append("im_v2_gateway_journal_diagnostic_stage_milliseconds_count{stage=\"\(stage.rawValue)\"} \(value.count)")
            lines.append("im_v2_gateway_journal_diagnostic_stage_milliseconds_sum{stage=\"\(stage.rawValue)\"} \(value.milliseconds)")
        }
        for reason in V2GatewayJournalProjectionReceiver.RecoveryCheckpointFailure.allCases {
            lines.append("im_v2_gateway_journal_checkpoint_failure_total{reason=\"\(reason.rawValue)\"} \(snapshot.failures[reason, default: 0])")
        }
        for reason in Fallback.allCases {
            lines.append("im_v2_gateway_journal_snapshot_fallback_total{reason=\"\(reason.rawValue)\"} \(snapshot.fallbacks[reason, default: 0])")
        }
        for example in snapshot.examples {
            // Fixed stage and finite internally measured numbers, no payload.
            lines.append("# im_v2_gateway_journal_slow_example {\"stage\":\"\(example.stage.rawValue)\",\"startedAtUnixSeconds\":\(example.start),\"endedAtUnixSeconds\":\(example.end),\"milliseconds\":\(example.milliseconds)}")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
