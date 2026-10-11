import Foundation
import IMV2Core
import IMV2ActorContracts
import Testing

@Suite("Room subscription encoded batch")
struct V2RoomSubscriptionBatchEncodingTests {
    private func delivery() throws -> V2RoomSubscriptionDelivery {
        let room = RoomID(uuid: UUID())
        let activation = try V2RoomActivationToken(roomID: room,
            owner: .init(shardID: "rooms", epoch: 0), activationEpoch: .init(1),
            host: .init(hostID: .init("host"), incarnationID: UUID()))
        let fence = V2RoomSubscriptionFence(activation: activation,
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        return .init(fence: fence, deliverySequence: 2, authorizationSequence: 1,
            payload: .broadcast(.init(roomID: room, highWatermark: 1,
                sourceEventID: EventID(uuid: UUID()), roomSequence: 1,
                projectionKind: "中文\"\\/\n", payload: Data(0..<255),
                recipientUserIDs: [], groupMembershipRevision: 1)))
    }
    @Test func validatedPartitionsAndExactReceipts() throws {
        let first = try delivery(), second = try delivery()
        let next = V2RoomSubscriptionDelivery(fence: first.fence, deliverySequence: 3,
            authorizationSequence: first.authorizationSequence, payload: first.payload)
        let validated = try V2RoomSubscriptionDeliveryBatch(deliveries: [first, second, next]).validated()
        #expect(validated.rooms.map(\.indices) == [[0, 2], [1]])
        #expect(validated.rooms.map(\.lastSequence) == [3, 2])
        let a = V2RoomSubscriptionBatchReceipt(fence: first.fence, result: .appliedThrough(3))
        let b = V2RoomSubscriptionBatchReceipt(fence: second.fence, result: .stale)
        #expect(validated.accepts(.init(receipts: [b, a])))
        #expect(!validated.accepts(.init(receipts: [a, a])))
        #expect(!validated.accepts(.init(receipts: [a])))
        #expect(!validated.accepts(.init(receipts: [.init(fence: first.fence, result: .appliedThrough(2)), b])))
        #expect(throws: (any Error).self) {
            try V2RoomSubscriptionDeliveryBatch(deliveries: [next, first]).validated()
        }
        let replacedFence = V2RoomSubscriptionFence(activation: first.fence.activation,
            subscriptionID: UUID(), generation: first.fence.generation, baselineSequence: first.fence.baselineSequence)
        let replaced = V2RoomSubscriptionDelivery(fence: replacedFence, deliverySequence: 3,
            authorizationSequence: first.authorizationSequence, payload: first.payload)
        #expect(throws: (any Error).self) {
            try V2RoomSubscriptionDeliveryBatch(deliveries: [first, replaced]).validated()
        }
    }
    @Test func retainedLimitAndRejectedAppendDoNotChangeBatch() throws {
        let item = try delivery()
        let original = V2RoomSubscriptionDeliveryBatch(deliveries: [item])
        let limit = 64 + V2ActorPayloadBudget.retainedBytes(of: item)
        var builder = V2RoomSubscriptionDeliveryBatch.Builder()
        #expect(try !builder.append(item, maximumBytes: limit - 1))
        #expect(builder.count == 0)
        #expect(try builder.append(item, maximumBytes: limit))
        #expect(try !builder.append(item, maximumBytes: limit))
        let batch = builder.finish()
        let bytes = try V2ActorProtobuf.encode(batch)
        #expect(bytes.count < limit)
        #expect(try V2ActorProtobuf.decode(V2RoomSubscriptionDeliveryBatch.self, from: bytes) == original)
        try batch.validate(maximumBytes: limit)
        #expect(throws: (any Error).self) { try batch.validate(maximumBytes: limit - 1) }
    }
    @Test func multipleItemsRemainCompatibleWithCodable() throws {
        let items = try (0..<5).map { _ in try delivery() }
        var builder = V2RoomSubscriptionDeliveryBatch.Builder()
        for item in items { #expect(try builder.append(item, maximumBytes: 262_144)) }
        let batch = builder.finish()
        let decoded = try V2ActorProtobuf.decode(V2RoomSubscriptionDeliveryBatch.self, from: V2ActorProtobuf.encode(batch))
        #expect(decoded == batch)
        #expect(try V2ActorProtobuf.encode(batch).count == V2ActorProtobuf.encode(batch).count)
        #expect(try V2ActorProtobuf.decode(V2RoomSubscriptionDeliveryBatch.self,
            from: V2ActorProtobuf.encode(batch)) == batch)
    }
    @Test func concurrentBoundaryEncoding() async throws {
        let batch = V2RoomSubscriptionDeliveryBatch(deliveries: [try delivery()])
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<32 { group.addTask { try V2ActorProtobuf.encode(batch) } }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(results.count == 32 && Set(results).count == 1)
        #expect(try V2ActorProtobuf.decode(V2RoomSubscriptionDeliveryBatch.self, from: results[0]) == batch)
    }
}
