import IMV2ServerContracts

/// Standalone rendering uses only a fixed, synchronous telemetry snapshot.
public func v2RenderPrometheusRecoverySchedulingMetrics(_ snapshot: V2RecoverySchedulingSnapshot) -> String {
    var lines: [String] = []
    lines += [
        "# HELP im_v2_gateway_recovery_scheduling_observations_total Completed monotonic spans by fixed phase. Pump pass is synchronous work; short offer is actor roundtrip; interest provider is logical shared-interest acquisition and may cache or join; query provider is room provider API including callbacks, not pure SQL; presence SQL is measured separately; control cohort is the entire control root. These overlap and are not ownership counts.",
        "# TYPE im_v2_gateway_recovery_scheduling_observations_total counter",
        "# HELP im_v2_gateway_recovery_scheduling_duration_milliseconds_total Cumulative completed span durations by fixed phase; not CPU time or current oldest age.",
        "# TYPE im_v2_gateway_recovery_scheduling_duration_milliseconds_total counter",
        "# HELP im_v2_gateway_recovery_scheduling_duration_milliseconds_max Maximum completed span duration since process start; not a current owned task age.",
        "# TYPE im_v2_gateway_recovery_scheduling_duration_milliseconds_max gauge",
        "# HELP im_v2_gateway_recovery_scheduling_scan_entries_total Entries examined during recovery scheduling, including indexed selection; repeated visits count again, not distinct scopes.",
        "# TYPE im_v2_gateway_recovery_scheduling_scan_entries_total counter"
    ]
    for phase in V2RecoverySchedulingPhase.allCases {
        let timing = snapshot.timings[phase] ?? .init()
        let labels = "{phase=\"\(phase.rawValue)\"}"
        lines.append("im_v2_gateway_recovery_scheduling_observations_total\(labels) \(timing.count)")
        lines.append("im_v2_gateway_recovery_scheduling_duration_milliseconds_total\(labels) \(timing.totalMilliseconds)")
        lines.append("im_v2_gateway_recovery_scheduling_duration_milliseconds_max\(labels) \(timing.maxMilliseconds)")
    }
    for source in V2RecoverySchedulingScan.allCases {
        lines.append("im_v2_gateway_recovery_scheduling_scan_entries_total{source=\"\(source.rawValue)\"} \(snapshot.scans[source] ?? 0)")
    }
    lines += [
        "# HELP im_v2_gateway_recovery_ready_rejections_total Failed Ready validation, permit or suppressed transition checks by fixed reason, including retained retries; not distinct failed operations. Repeated checks may count separately. Permission expired means an observed original deadline elapsed; permission missing means no authority witness. Enqueue refused means the actual Ready API returned false while post-validation passed; it may overlap a separately classified permit rejection and does not imply socket capacity exhaustion.",
        "# TYPE im_v2_gateway_recovery_ready_rejections_total counter"
    ]
    for reason in V2RecoveryReadyRejectionReason.allCases {
        lines.append("im_v2_gateway_recovery_ready_rejections_total{reason=\"\(reason.rawValue)\"} \(snapshot.readyRejections[reason] ?? 0)")
    }
    return lines.joined(separator: "\n") + "\n"
}
