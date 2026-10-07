import Foundation

/// One authenticated publisher shard, multiple independent room fences.
/// Every fence's transport receipts increase; data gaps use durable recovery.
public struct V2RoomSubscriptionDeliveryBatch: Equatable, Codable, Sendable {
    public let deliveries: [V2RoomSubscriptionDelivery]
    public init(deliveries: [V2RoomSubscriptionDelivery]) { self.deliveries = deliveries }

    public func validate(maximumItems: Int = 64, maximumBytes: Int = 262_144) throws {
        guard !deliveries.isEmpty, deliveries.count <= maximumItems else {
            throw V2ActorContractError.invalidConfiguration("room subscription batch items")
        }
        var previous: [V2RoomSubscriptionFence: UInt64] = [:]
        var roomFences: [String: V2RoomSubscriptionFence] = [:]
        for delivery in deliveries {
            try delivery.validate(maximumPayloadBytes: maximumBytes)
            if let prior = previous[delivery.fence] {
                guard prior < UInt64.max, delivery.deliverySequence > prior else {
                    throw V2ActorContractError.invalidConfiguration("room subscription batch order")
                }
            }
            if let fence = roomFences[delivery.fence.roomID.rawValue], fence != delivery.fence {
                throw V2ActorContractError.invalidConfiguration("room subscription mixed room fences")
            }
            roomFences[delivery.fence.roomID.rawValue] = delivery.fence
            previous[delivery.fence] = delivery.deliverySequence
        }
        guard try JSONEncoder().encode(self).count <= maximumBytes else {
            throw V2ActorContractError.invalidConfiguration("room subscription batch bytes")
        }
    }
}

/// One cumulative authority receipt for each exact fence present in the batch.
/// No per-event transport ACKs are required. Failures preserve durable recovery.
public struct V2RoomSubscriptionBatchReceipt: Equatable, Codable, Sendable {
    public let fence: V2RoomSubscriptionFence
    public let result: V2RoomSubscriptionDeliveryResult
    public init(fence: V2RoomSubscriptionFence, result: V2RoomSubscriptionDeliveryResult) {
        self.fence = fence; self.result = result
    }
}

public struct V2RoomSubscriptionBatchResult: Equatable, Codable, Sendable {
    public let receipts: [V2RoomSubscriptionBatchReceipt]
    public init(receipts: [V2RoomSubscriptionBatchReceipt]) { self.receipts = receipts }
}
