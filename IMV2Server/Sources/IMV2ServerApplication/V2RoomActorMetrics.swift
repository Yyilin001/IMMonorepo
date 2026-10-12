import IMV2ActorContracts
import IMV2ServerContracts

/// 固定的进程内测量值。执行中和结果不明的工作仍持有命令许可，
/// 因此未完成数量有意包含等待队列以外的工作。
func v2RoomActorMetricLines(_ snapshot: V2RoomRuntimeMetricsSnapshot) -> [String] {
    var values: [(String, Int, String)] = [
        ("cached_locations", snapshot.cachedLocations, "Cached logical room locations."),
        ("pending_resolutions", snapshot.pendingResolutions, "Pending logical room resolutions."),
        ("active_resolutions", snapshot.activeResolutions, "Currently executing logical room resolutions."),
        ("resolution_waiters", snapshot.resolutionWaiters, "Callers waiting for logical room resolution."),
    ]
    if let host = snapshot.host {
        values += [
            ("active_rooms", host.activeRooms, "Locally ready rooms with native execution authority."),
            ("pending_rooms", host.pendingRooms, "Rooms awaiting activation completion."),
            ("restoring_rooms", host.restoringRooms, "Concurrent room restoration operations."),
            ("retiring_rooms", host.retiringRooms, "Rooms draining or awaiting uncertain-result cleanup."),
            ("activation_waiters", host.activationWaiters, "Callers awaiting a local room activation."),
        ]
    }
    if let commands = snapshot.commands {
        values += [
            ("outstanding_commands", commands.commandCount, "Commands charged while waiting, executing or reconciling."),
            ("outstanding_bytes", commands.byteCount, "Encoded request bytes charged to outstanding command permits."),
            ("peak_outstanding_commands", commands.peakCommandCount, "Maximum outstanding command count since this process started."),
            ("peak_outstanding_bytes", commands.peakByteCount, "Maximum charged request bytes since this process started."),
            ("reservations", commands.reservationCount, "Outstanding two-room reservation permits."),
            ("command_rooms", commands.roomCount, "Rooms currently owning command permits."),
        ]
    }
    var lines = values.flatMap { suffix, value, help in
        let name = "im_v2_room_actor_" + suffix
        return ["# HELP \(name) \(help)", "# TYPE \(name) gauge", "\(name) \(value)"]
    }
    if let host = snapshot.host {
        lines += ["# HELP im_v2_room_actor_completed_idle_retirements_total Rooms fully drained and closed after idle passivation since process startup.",
                  "# TYPE im_v2_room_actor_completed_idle_retirements_total counter",
                  "im_v2_room_actor_completed_idle_retirements_total \(host.completedIdleRetirements)"]
    }
    let directory = snapshot.directoryCalls
    let transport = snapshot.transportCalls
    lines.append("# TYPE im_v2_room_actor_renewal_actual_calls gauge")
    lines.append("im_v2_room_actor_renewal_actual_calls \(transport.renewalActualCalls)")
    for stage in V2RoomRenewalFailureStage.allCases {
        let name = "im_v2_room_actor_renewal_failure_" + stage.rawValue + "_total"
        lines.append("# TYPE \(name) counter")
        lines.append("\(name) \(transport.renewalFailures[stage, default: 0])")
    }
    let counters: [(String, UInt64)] = [
        ("cached_call_attempts", directory.cachedCalls),
        ("cached_call_responses", directory.cachedResponses),
        ("cached_call_misses", directory.cacheMisses),
        ("location_invalidations", directory.locationInvalidations),
        ("recovery_attempts", directory.recoveryAttempts),
        ("recovery_waits", directory.recoveryWaits),
        ("recovery_warm_items", directory.recoveryWarmItems),
        ("recovery_cold_items", directory.recoveryColdItems),
        ("recovery_host_cohorts", directory.recoveryHostCohorts),
        ("recovery_host_items", directory.recoveryHostItems),
        ("recovery_batch_caller_timeouts", transport.batchCallerTimeouts),
        ("recovery_batch_caller_cancellations", transport.batchCallerCancellations),
        ("recovery_batch_rejected_global", transport.batchRejectedGlobal),
        ("recovery_batch_rejected_peer", transport.batchRejectedPeer),
        ("cached_local_calls", transport.cachedLocalCalls),
        ("cached_remote_calls", transport.cachedRemoteCalls),
        ("physical_lookups", transport.roomLookups),
        ("business_invocations", transport.roomInvocations),
        ("reference_misses", transport.referenceMisses),
        ("host_recovery_probes", transport.hostRecoveryProbes),
        ("host_recovery_waits", transport.hostRecoveryWaits),
    ]
    for (suffix, value) in counters {
        let name = "im_v2_room_actor_" + suffix + "_total"
        lines += ["# HELP \(name) Process-local \(suffix) since startup.",
                  "# TYPE \(name) counter", "\(name) \(value)"]
    }
    for (suffix, value) in [("recovering_rooms", directory.recoveringRooms),
                            ("active_host_recoveries", transport.activeHostRecoveries)] {
        let name = "im_v2_room_actor_" + suffix
        lines += ["# HELP \(name) Current bounded recovery work.",
                  "# TYPE \(name) gauge", "\(name) \(value)"]
    }
    lines += v2RoomRecoveryStageMetricLines(snapshot)
    return lines
}
