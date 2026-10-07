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

public extension V2RoomSubscriptionHandler {
    /// Compatibility implementation; production receivers additionally reconcile
    /// already applied prefixes against their current exact-fence checkpoint.
    func applyRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch,
                                    authenticatedServiceID: String,
                                    sourceShardID: String) async -> V2RoomSubscriptionBatchResult {
        var order: [V2RoomSubscriptionFence] = []
        var results: [V2RoomSubscriptionFence: V2RoomSubscriptionDeliveryResult] = [:]
        for delivery in batch.deliveries {
            if results[delivery.fence] == nil { order.append(delivery.fence) }
            if let previous = results[delivery.fence] {
                switch previous { case .snapshotRequired, .stale: continue; case .appliedThrough: break }
            }
            results[delivery.fence] = await applyRoomSubscription(delivery,
                authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID)
        }
        return .init(receipts: order.map { .init(fence: $0, result: results[$0]!) })
    }
}
