import Foundation
import SwiftProtobuf

extension V2RoomSubscriptionDelivery: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data { try Im_Actor_V1_HotSubscriptionDelivery(self).serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotSubscriptionDelivery(serializedBytes: bytes).model() }
}
extension V2RoomSubscriptionDeliveryBatch: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data { try Im_Actor_V1_HotDeliveryBatch(self).serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotDeliveryBatch(serializedBytes: bytes).model() }
}
extension V2RoomSubscriptionBatchResult: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data { try Im_Actor_V1_HotDeliveryReceipts(self).serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotDeliveryReceipts(serializedBytes: bytes).model() }
}
extension V2RealtimeBatch: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data { try Im_Actor_V1_HotRealtimeBatch(self).serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotRealtimeBatch(serializedBytes: bytes).model() }
}
extension V2RealtimeJournalProjectionBatch: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data { try Im_Actor_V1_HotJournalBatch(self).serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotJournalBatch(serializedBytes: bytes).model() }
}
extension V2RealtimeJournalProjectionResult: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data { try Im_Actor_V1_HotJournalResult(self).serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotJournalResult(serializedBytes: bytes).model() }
}
