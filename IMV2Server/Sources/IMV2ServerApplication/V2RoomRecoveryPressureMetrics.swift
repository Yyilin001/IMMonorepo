import IMV2ActorContracts
import IMV2ServerContracts

/// Stages overlap: caller waits and actual work are not additive. Completed
/// durations exclude active work; oldest exposes the work still holding capacity.
func v2RoomRecoveryStageMetricLines(_ snapshot: V2RoomRuntimeMetricsSnapshot) -> [String] {
    var lines: [String] = []
    for stage in V2RoomDirectoryRecoveryStage.allCases {
        let value = snapshot.directoryCalls.recoveryStages[stage, default: .init()]
        lines += v2RecoveryMetricFamily("im_v2_room_directory_recovery", label: "stage", value: stage.rawValue,
            samples: [("active", "gauge", String(value.active)),
                      ("oldest_milliseconds", "gauge", String(value.oldestMilliseconds)),
                      ("started_total", "counter", String(value.started)),
                      ("completed_total", "counter", String(value.completed)),
                      ("items_started_total", "counter", String(value.itemsStarted)),
                      ("duration_milliseconds_sum", "counter", String(value.totalMilliseconds)),
                      ("duration_milliseconds_max", "gauge", String(value.maxMilliseconds))],
            includeDeclarations: stage == V2RoomDirectoryRecoveryStage.allCases.first)
    }
    for stage in V2RoomTransportRecoveryStage.allCases {
        let value = snapshot.transportCalls.recoveryStages[stage, default: .init()]
        lines += v2RecoveryMetricFamily("im_v2_room_transport_recovery", label: "stage", value: stage.rawValue,
            samples: [("active", "gauge", String(value.active)),
                      ("oldest_milliseconds", "gauge", String(value.oldestMilliseconds)),
                      ("started_total", "counter", String(value.started)),
                      ("completed_total", "counter", String(value.completed)),
                      ("items_started_total", "counter", String(value.itemsStarted)),
                      ("duration_milliseconds_sum", "counter", String(value.totalMilliseconds)),
                      ("duration_milliseconds_max", "gauge", String(value.maxMilliseconds))],
            includeDeclarations: stage == V2RoomTransportRecoveryStage.allCases.first)
    }
    return lines
}

func v2RoomRecoveryBatchMetricLines(_ snapshot: V2RoomRecoveryBatchPressureSnapshot) -> [String] {
    var lines = V2RoomRecoveryBatchPurpose.allCases.flatMap { purpose in
        let value = snapshot.purposes[purpose, default: .init()]
        return v2RecoveryMetricFamily("im_v2_room_recovery_batch", label: "purpose", value: purpose.rawValue,
            samples: [("in_flight", "gauge", String(value.inFlight)),
                      ("items", "gauge", String(value.items)),
                      ("oldest_milliseconds", "gauge", String(value.oldestMilliseconds)),
                      ("started_total", "counter", String(value.started)),
                      ("completed_total", "counter", String(value.completed)),
                      ("busy_before_acquire_total", "counter", String(value.busyBeforeAcquire)),
                      ("duration_milliseconds_sum", "counter", String(value.durationMillisecondsSum)),
                      ("duration_milliseconds_max", "gauge", String(value.durationMillisecondsMax))],
            includeDeclarations: purpose == V2RoomRecoveryBatchPurpose.allCases.first)
    }
    let samples: [(String, String, String)] = [
        ("pending_items", "gauge", String(snapshot.pendingItems)),
        ("retained_items", "gauge", String(snapshot.retainedItems)),
        ("retained_bytes", "gauge", String(snapshot.retainedBytes)),
        ("ordinary_retained_items", "gauge", String(snapshot.ordinaryRetainedItems)),
        ("actual_batches", "gauge", String(snapshot.actualBatches)),
        ("oldest_queued_milliseconds", "gauge", String(snapshot.oldestQueuedMilliseconds)),
        ("oldest_actual_milliseconds", "gauge", String(snapshot.oldestActualMilliseconds)),
        ("batches_started_total", "counter", String(snapshot.batchesStarted)),
        ("items_selected_total", "counter", String(snapshot.itemsSelected)),
        ("items_settled_total", "counter", String(snapshot.itemsSettled))]
    for (suffix, type, value) in samples {
        let name = "im_v2_room_read_collector_" + suffix
        lines += ["# HELP \(name) Shared physical-owner read collector \(suffix); retained includes queued and actual unsettled inputs.",
                  "# TYPE \(name) \(type)", "\(name) \(value)"]
    }
    return lines
}

private func v2RecoveryMetricFamily(
    _ prefix: String, label: String, value: String,
    samples: [(String, String, String)], includeDeclarations: Bool
) -> [String] {
    samples.flatMap { suffix, type, sample in
        let name = prefix + "_" + suffix
        let declarations = includeDeclarations
            ? ["# HELP \(name) Process-local recovery \(suffix); durations cover completed work and max is since startup.",
               "# TYPE \(name) \(type)"] : []
        return declarations + ["\(name){\(label)=\"\(value)\"} \(sample)"]
    }
}
