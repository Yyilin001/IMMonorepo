import Foundation
import NIOCore
import Synchronization

/// Opt-in diagnostics only. Sample all heartbeats on a stable 1/64 of connections;
/// no connection/user identifiers are exported and no extra task is created.
enum V2GatewayHeartbeatDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["IM_V2_GATEWAY_HEARTBEAT_DIAGNOSTICS"] == "true"
    @TaskLocal static var current: V2GatewayHeartbeatProbe?
    static let metrics = Metrics()
    static func selects(_ connectionID: UUID) -> Bool {
        // Local UUIDs have a process-constant prefix. Hash all bytes once, using
        // Swift's process-randomized Hasher, rather than sampling a prefix byte.
        connectionID.hashValue & 63 == 0
    }

    enum Point: Int, CaseIterable, Sendable {
        case chunkReceived, dispatched, taskEntered, streamEntered
        case sessionSubmitted, sessionEntered, progressSubmitted, progressEntered
        case progressCompleted, progressReturned, sessionCompleted, sessionReturned
        case registrySubmitted, registryEntered, leaseSubmitted, leaseEntered
        case leaseCompleted, leaseReturned, registryCompleted, registryReturned
        case writeSubmitted, writeEntered, writeCompleted
    }
    enum Stage: String, CaseIterable, Sendable {
        case chunkToDispatch = "chunk_to_dispatch"
        case taskEntry = "task_entry"
        case streamEntry = "stream_entry"
        case beforeSession = "before_session"
        case sessionEntry = "session_entry"
        case beforeProgress = "before_progress"
        case progressEntry = "progress_entry"
        case progressBody = "progress_body"
        case progressReturn = "progress_return"
        case afterProgress = "after_progress"
        case sessionReturn = "session_return"
        case beforeRegistry = "before_registry"
        case registryEntry = "registry_entry"
        case beforeLease = "before_lease"
        case leaseEntry = "lease_entry"
        case leaseBody = "lease_body"
        case leaseReturn = "lease_return"
        case registryBodyAfterLease = "registry_body_after_lease"
        case registryReturn = "registry_return"
        case beforeWrite = "before_write"
        case writeEntry = "write_entry"
        case writeCompletion = "write_completion"
        case serverTotal = "server_total"
    }
    struct Histogram: Sendable {
        var count: UInt64 = 0
        var sumNanoseconds: Double = 0
        var maximumNanoseconds: UInt64 = 0
        var buckets = [UInt64](repeating: 0, count: bounds.count)
        static let bounds: [UInt64] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]
        mutating func record(_ ns: UInt64) {
            count += 1; sumNanoseconds += Double(ns)
            maximumNanoseconds = max(maximumNanoseconds, ns)
            for index in Self.bounds.indices where ns <= Self.bounds[index] * 1_000_000 { buckets[index] += 1 }
        }
    }
    struct Snapshot: Sendable {
        var completed: UInt64 = 0
        var failed: UInt64 = 0
        var all: [Stage: Histogram] = [:]
        var slow: [Stage: Histogram] = [:]
        var slowExamples: [SlowExample] = []
    }
    struct SlowExample: Sendable {
        let completedAtUnixSeconds: Double
        let stages: [Stage: UInt64]
    }
    final class Metrics: Sendable {
        private let state = Mutex(Snapshot())
        func record(_ stages: [Stage: UInt64]?, completedAtUnixSeconds: Double = Date().timeIntervalSince1970) {
            state.withLock { state in
                guard let stages else { state.failed += 1; return }
                state.completed += 1
                let slow = stages[.serverTotal, default: 0] >= 25_000_000
                for (stage, duration) in stages {
                    state.all[stage, default: .init()].record(duration)
                    if slow { state.slow[stage, default: .init()].record(duration) }
                }
                if slow {
                    state.slowExamples.removeAll { $0.completedAtUnixSeconds < completedAtUnixSeconds - 30 }
                }
                if slow, state.slowExamples.count < 16
                    || stages[.serverTotal, default: 0] > (state.slowExamples.last?.stages[.serverTotal] ?? 0) {
                    state.slowExamples.append(.init(completedAtUnixSeconds: completedAtUnixSeconds, stages: stages))
                    state.slowExamples.sort { $0.stages[.serverTotal, default: 0] > $1.stages[.serverTotal, default: 0] }
                    if state.slowExamples.count > 16 { state.slowExamples.removeLast() }
                }
            }
        }
        func snapshot() -> Snapshot { state.withLock { $0 } }
    }
    static func render(_ snapshot: Snapshot) -> String {
        var lines = ["# HELP im_v2_heartbeat_sample_total Stable 1/64 connection sample; success means local ACK write completion, not client receipt.",
                     "# TYPE im_v2_heartbeat_sample_total counter",
                     "im_v2_heartbeat_sample_total{result=\"completed\"} \(snapshot.completed)",
                     "im_v2_heartbeat_sample_total{result=\"failed\"} \(snapshot.failed)",
                     "# HELP im_v2_heartbeat_stage_milliseconds Server stages of completed sampled heartbeats. slow is the same-request cohort with server_total >= 25ms. Entry spans include runtime scheduling. chunk starts at the last input callback used for the decode batch; kernel/TLS/client are excluded.",
                     "# TYPE im_v2_heartbeat_stage_milliseconds histogram"]
        for (cohort, values) in [("all", snapshot.all), ("slow", snapshot.slow)] {
            for stage in Stage.allCases {
                let h = values[stage, default: .init()]
                let labels = "stage=\"\(stage.rawValue)\",cohort=\"\(cohort)\""
                lines.append("im_v2_heartbeat_stage_milliseconds_count{\(labels)} \(h.count)")
                lines.append("im_v2_heartbeat_stage_milliseconds_sum{\(labels)} \(h.sumNanoseconds / 1_000_000)")
                for i in Histogram.bounds.indices {
                    lines.append("im_v2_heartbeat_stage_milliseconds_bucket{\(labels),le=\"\(Histogram.bounds[i])\"} \(h.buckets[i])")
                }
                lines.append("im_v2_heartbeat_stage_milliseconds_bucket{\(labels),le=\"+Inf\"} \(h.count)")
            }
        }
        // Bounded diagnostic examples are comments, not high-cardinality labels.
        for example in snapshot.slowExamples {
            let values = Dictionary(uniqueKeysWithValues: example.stages.map { ($0.key.rawValue, Double($0.value) / 1_000_000) })
            if let data = try? JSONSerialization.data(withJSONObject: ["completedAtUnixSeconds": example.completedAtUnixSeconds, "stages": values], options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { lines.append("# im_v2_heartbeat_slow_example \(json)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public func v2RenderPrometheusGatewayHeartbeatDiagnostics() -> String {
    V2GatewayHeartbeatDiagnostics.enabled
        ? V2GatewayHeartbeatDiagnostics.render(V2GatewayHeartbeatDiagnostics.metrics.snapshot()) : ""
}

final class V2GatewayHeartbeatProbe: Sendable {
    private struct State: Sendable {
        var points = [UInt64?](repeating: nil, count: V2GatewayHeartbeatDiagnostics.Point.allCases.count)
        var finished = false
    }
    private let state = Mutex(State())
    private let metrics: V2GatewayHeartbeatDiagnostics.Metrics
    init(chunkReceivedAt: UInt64, metrics: V2GatewayHeartbeatDiagnostics.Metrics = V2GatewayHeartbeatDiagnostics.metrics) {
        self.metrics = metrics
        mark(.chunkReceived, at: chunkReceivedAt)
    }
    func mark(_ point: V2GatewayHeartbeatDiagnostics.Point, at: UInt64 = NIODeadline.now().uptimeNanoseconds) {
        state.withLock { state in
            guard !state.finished else { return }
            state.points[point.rawValue] = at
        }
    }
    func finish(success: Bool) {
        let result: [V2GatewayHeartbeatDiagnostics.Stage: UInt64]?? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            guard success else { return .some(nil) }
            let p = state.points
            let stages = V2GatewayHeartbeatDiagnostics.Stage.allCases
            var values: [V2GatewayHeartbeatDiagnostics.Stage: UInt64] = [:]
            for index in 0..<(p.count - 1) {
                if let begin = p[index], let end = p[index + 1], end >= begin { values[stages[index]] = end - begin }
            }
            if let begin = p.first!, let end = p.last!, end >= begin { values[.serverTotal] = end - begin }
            return .some(values)
        }
        if let result { metrics.record(result) }
    }
}
