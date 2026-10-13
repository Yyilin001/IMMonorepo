/// Reports the actual room-local room subscription authority commit.
public enum V2RoomSubscriptionDeliveryResult: Equatable, Codable, Sendable {
    case appliedThrough(UInt64)
    case snapshotRequired
    case stale
}

/// Installed by trusted gateway composition. RPC publishers cannot install
/// session authority, room ownership, subscription generations or member grants.
public protocol V2RoomSubscriptionHandler: Sendable {
    func applyDeliverySession(_ pulse: V2RoomDeliverySessionPulse,
                              authenticatedServiceID: String) async -> V2RoomDeliverySessionResult
    func applyRoomSubscription(_ delivery: V2RoomSubscriptionDelivery,
                               authenticatedServiceID: String,
                               sourceShardID: String) async -> V2RoomSubscriptionDeliveryResult
    func applyRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch,
                                    authenticatedServiceID: String,
                                    sourceShardID: String) async -> V2RoomSubscriptionBatchResult
    func applyRoomSubscriptionBatch(_ batch: V2ValidatedRoomSubscriptionBatch,
                                    authenticatedServiceID: String,
                                    sourceShardID: String) async -> V2RoomSubscriptionBatchResult
}

extension V2RoomSubscriptionHandler {
    public func applyDeliverySession(_ pulse: V2RoomDeliverySessionPulse,
        authenticatedServiceID: String) async -> V2RoomDeliverySessionResult { .stale }
    public func applyRoomSubscriptionBatch(_ batch: V2ValidatedRoomSubscriptionBatch,
        authenticatedServiceID: String, sourceShardID: String) async -> V2RoomSubscriptionBatchResult {
        await applyRoomSubscriptionBatch(batch.batch, authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID)
    }
}
