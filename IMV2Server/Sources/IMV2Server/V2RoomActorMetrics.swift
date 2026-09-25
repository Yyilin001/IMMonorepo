import IMV2ActorRuntime

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
            ("active_rooms", host.activeRooms, "Locally ready rooms with a safe lease."),
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
    return values.flatMap { suffix, value, help in
        let name = "im_v2_room_actor_" + suffix
        return ["# HELP \(name) \(help)", "# TYPE \(name) gauge", "\(name) \(value)"]
    }
}
