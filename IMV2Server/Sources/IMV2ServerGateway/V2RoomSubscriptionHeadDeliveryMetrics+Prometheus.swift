import IMV2ServerContracts

public func v2RenderPrometheusRoomSubscriptionHeadDeliveryMetrics(
    _ snapshot: V2RoomSubscriptionHeadDeliveryMetrics.Snapshot
) -> String {
    var lines = [
        "# HELP im_v2_room_subscription_head_delivery_total Completed local delivery checks by fixed stage. head stages cover room subscription H; socket stages cover all scoped notifications. Acceptance is local enqueue admission, not client receipt. Repeated offers and retries count separately.",
        "# TYPE im_v2_room_subscription_head_delivery_total counter"
    ]
    for stage in V2RoomSubscriptionHeadDeliveryMetrics.Stage.allCases {
        lines.append("im_v2_room_subscription_head_delivery_total{stage=\"\(stage.rawValue)\"} \(snapshot[stage])")
    }
    lines += [
        "# HELP im_v2_room_subscription_acquisition_active In-flight stages; queue and slot include their nested stages and must not be added together.",
        "# TYPE im_v2_room_subscription_acquisition_active gauge",
        "# HELP im_v2_room_subscription_acquisition_seconds Completed stage duration including suspension, measured with a monotonic clock.",
        "# TYPE im_v2_room_subscription_acquisition_seconds summary",
        "# HELP im_v2_room_subscription_acquisition_max_seconds Maximum completed stage duration since process start.",
        "# TYPE im_v2_room_subscription_acquisition_max_seconds gauge",
        "# HELP im_v2_room_subscription_acquisition_outcomes_total Completed stages by fixed terminal outcome; retries count separately.",
        "# TYPE im_v2_room_subscription_acquisition_outcomes_total counter"
    ]
    for kind in V2RoomSubscriptionHeadDeliveryMetrics.Kind.allCases {
        for phase in V2RoomSubscriptionHeadDeliveryMetrics.Phase.allCases {
            let value = snapshot.phases[kind]?[phase] ?? .init()
            let label = "kind=\"\(kind.rawValue)\",phase=\"\(phase.rawValue)\""
            lines.append("im_v2_room_subscription_acquisition_active{\(label)} \(value.active)")
            lines.append("im_v2_room_subscription_acquisition_seconds_count{\(label)} \(value.completed)")
            lines.append("im_v2_room_subscription_acquisition_seconds_sum{\(label)} \(value.seconds)")
            lines.append("im_v2_room_subscription_acquisition_max_seconds{\(label)} \(value.maximumSeconds)")
            for outcome in V2RoomSubscriptionHeadDeliveryMetrics.Outcome.allCases {
                lines.append("im_v2_room_subscription_acquisition_outcomes_total{\(label),outcome=\"\(outcome.rawValue)\"} \(value.outcomes[outcome, default: 0])")
            }
        }
    }
    let ownerFailures = V2RoomSubscriptionOwnerFailureMetrics.shared.snapshot()
    lines.append("# HELP im_v2_room_subscription_owner_failures_total Fixed Owner reasons before wire error mapping.")
    lines.append("# TYPE im_v2_room_subscription_owner_failures_total counter")
    for reason in V2RoomSubscriptionOwnerFailureMetrics.Reason.allCases {
        lines.append("im_v2_room_subscription_owner_failures_total{reason=\"\(reason.rawValue)\"} \(ownerFailures[reason, default: 0])")
    }
    return lines.joined(separator: "\n") + "\n"
}
