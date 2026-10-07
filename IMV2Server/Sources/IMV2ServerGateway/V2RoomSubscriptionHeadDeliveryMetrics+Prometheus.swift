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
    let ownerFailures = V2RoomSubscriptionOwnerFailureMetrics.shared.snapshot()
    lines.append("# HELP im_v2_room_subscription_owner_failures_total Fixed Owner reasons before wire error mapping.")
    lines.append("# TYPE im_v2_room_subscription_owner_failures_total counter")
    for reason in V2RoomSubscriptionOwnerFailureMetrics.Reason.allCases {
        lines.append("im_v2_room_subscription_owner_failures_total{reason=\"\(reason.rawValue)\"} \(ownerFailures[reason, default: 0])")
    }
    return lines.joined(separator: "\n") + "\n"
}
