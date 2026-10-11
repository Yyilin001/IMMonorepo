/// Reports the actual room-local room subscription authority commit.
public enum V2RoomSubscriptionDeliveryResult: Equatable, Codable, Sendable {
    case appliedThrough(UInt64)
    case snapshotRequired
    case stale
}

/// Installed by trusted gateway composition. RPC publishers cannot install
/// lease deadlines, room ownership, subscription generations or member grants.
public protocol V2RoomSubscriptionHandler: Sendable {
    func applyRoomSubscription(_ delivery: V2RoomSubscriptionDelivery,
                               authenticatedServiceID: String,
                               sourceShardID: String) async -> V2RoomSubscriptionDeliveryResult
    func applyRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch,
                                    authenticatedServiceID: String,
                                    sourceShardID: String) async -> V2RoomSubscriptionBatchResult
}
