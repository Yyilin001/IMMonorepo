import Foundation

/// One authenticated publisher shard, multiple independent room fences.
/// Every fence's transport receipts increase; data gaps use durable recovery.
public struct V2RoomSubscriptionDeliveryBatch: Equatable, Codable, Sendable {
    public let deliveries: [V2RoomSubscriptionDelivery]
    public init(deliveries: [V2RoomSubscriptionDelivery]) { self.deliveries = deliveries }
    package struct Builder {
        private var bytes = 64
        package private(set) var deliveries: [V2RoomSubscriptionDelivery] = []
        package init() {}
        package var count: Int { deliveries.count }
        package mutating func append(_ delivery: V2RoomSubscriptionDelivery, maximumBytes: Int) throws -> Bool {
            let cost = V2ActorPayloadBudget.retainedBytes(of: delivery)
            guard bytes <= maximumBytes, cost <= maximumBytes - bytes else { return false }
            bytes += cost; deliveries.append(delivery); return true
        }
        package consuming func finish() -> V2RoomSubscriptionDeliveryBatch { .init(deliveries: deliveries) }
    }

    public func validate(maximumItems: Int = 64, maximumBytes: Int = 262_144) throws {
        _ = try validated(maximumItems: maximumItems, maximumBytes: maximumBytes)
    }

    /// Immutable structural proof and room partition, produced only by validation.
    /// Live authorization and generation checks remain the handler's responsibility.
    public func validated(maximumItems: Int = 64, maximumBytes: Int = 262_144) throws -> V2ValidatedRoomSubscriptionBatch {
        guard !deliveries.isEmpty, deliveries.count <= maximumItems else {
            throw V2ActorContractError.invalidConfiguration("room subscription batch items")
        }
        var groups: [V2ValidatedRoomSubscriptionBatch.Room] = []
        var byRoom: [String: Int] = [:]
        for (index, delivery) in deliveries.enumerated() {
            try delivery.validate(maximumPayloadBytes: maximumBytes)
            if let position = byRoom[delivery.fence.roomID.rawValue] {
                let prior = groups[position]
                guard prior.fence == delivery.fence else {
                    throw V2ActorContractError.invalidConfiguration("room subscription mixed room fences")
                }
                guard prior.lastSequence < UInt64.max, delivery.deliverySequence > prior.lastSequence else {
                    throw V2ActorContractError.invalidConfiguration("room subscription batch order")
                }
                groups[position].indices.append(index)
                groups[position].lastSequence = delivery.deliverySequence
            } else {
                byRoom[delivery.fence.roomID.rawValue] = groups.count
                groups.append(.init(fence: delivery.fence, indices: [index], lastSequence: delivery.deliverySequence))
            }
        }
        guard V2ActorPayloadBudget.retainedBytes(of: self) <= maximumBytes else {
            throw V2ActorContractError.invalidConfiguration("room subscription batch bytes")
        }
        return .init(batch: self, rooms: groups, byRoom: byRoom)
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

/// Not Codable: an untrusted packet cannot manufacture a validation proof.
public struct V2ValidatedRoomSubscriptionBatch: Sendable {
    public struct Room: Sendable {
        public let fence: V2RoomSubscriptionFence
        public fileprivate(set) var indices: [Int]
        public fileprivate(set) var lastSequence: UInt64
    }
    public let batch: V2RoomSubscriptionDeliveryBatch
    public let rooms: [Room]
    private let byRoom: [String: Int]
    fileprivate init(batch: V2RoomSubscriptionDeliveryBatch, rooms: [Room], byRoom: [String: Int]) {
        self.batch = batch; self.rooms = rooms; self.byRoom = byRoom
    }
    public func accepts(_ result: V2RoomSubscriptionBatchResult) -> Bool {
        guard result.receipts.count == rooms.count else { return false }
        var seen: UInt64 = 0
        // Validation limits batches to at most 64 deliveries on this path.
        if rooms.count > 64 { return acceptsLarge(result) }
        for receipt in result.receipts {
            guard let index = byRoom[receipt.fence.roomID.rawValue], rooms[index].fence == receipt.fence else { return false }
            let bit = UInt64(1) << index
            guard seen & bit == 0 else { return false }; seen |= bit
            if case .appliedThrough(let sequence) = receipt.result, sequence != rooms[index].lastSequence { return false }
        }
        return true
    }
    private func acceptsLarge(_ result: V2RoomSubscriptionBatchResult) -> Bool {
        var seen: Set<Int> = []
        for receipt in result.receipts {
            guard let index = byRoom[receipt.fence.roomID.rawValue], rooms[index].fence == receipt.fence,
                  seen.insert(index).inserted else { return false }
            if case .appliedThrough(let sequence) = receipt.result, sequence != rooms[index].lastSequence { return false }
        }
        return true
    }
}
