import Crypto
import Foundation
import IMV2ActorContracts

/// Process-local replay receipts only; this digest is neither persisted nor sent.
/// Explicit tags, lengths and optional markers prevent ambiguous concatenation.
/// Keep every delivery/event field here when extending the wire contract.
struct V2RoomSubscriptionDeliveryFingerprint {
    private var hash = SHA256()

    static func digest(_ delivery: V2RoomSubscriptionDelivery) -> Data {
        var value = Self()
        value.string("imv2.room-subscription.receipt.v1")
        let fence = delivery.fence, token = fence.activation
        value.string(token.roomID.rawValue); value.string(token.owner.shardID)
        value.integer(UInt64(bitPattern: token.owner.epoch))
        value.integer(UInt64(bitPattern: token.activationEpoch.rawValue))
        value.string(token.host.hostID.rawValue); value.uuid(token.host.incarnationID)
        value.uuid(fence.subscriptionID); value.integer(fence.generation); value.integer(fence.baselineSequence)
        value.integer(delivery.deliverySequence); value.integer(delivery.authorizationSequence)
        switch delivery.payload {
        case .baseline(let members):
            value.tag(0); value.members(members)
        case .baselinePage(let index, let total, let members):
            value.tag(1); value.integer(UInt64(truncatingIfNeeded: index))
            value.integer(UInt64(truncatingIfNeeded: total)); value.members(members)
        case .grant(let member, let sequence):
            value.tag(2); value.integer(1); value.member(member); value.integer(sequence)
        case .broadcast(let event):
            value.tag(3); value.event(event)
        case .event(let event, let members):
            value.tag(4); value.event(event); value.members(members)
        case .head(let watermark):
            value.tag(5); value.integer(watermark)
        case .authorizationInvalidated:
            value.tag(6)
        case .revoke(let userID, let revision):
            value.tag(7); value.string(userID.rawValue); value.integer(revision)
        }
        return Data(value.hash.finalize())
    }

    private mutating func tag(_ value: UInt8) {
        var byte = value; withUnsafeBytes(of: &byte) { hash.update(bufferPointer: $0) }
    }
    private mutating func integer(_ value: UInt64) {
        var bytes = value.bigEndian; withUnsafeBytes(of: &bytes) { hash.update(bufferPointer: $0) }
    }
    private mutating func uuid(_ value: UUID) {
        var bytes = value.uuid; withUnsafeBytes(of: &bytes) { hash.update(bufferPointer: $0) }
    }
    private mutating func string(_ value: String) {
        integer(UInt64(value.utf8.count))
        // Borrow contiguous UTF-8; only unusual storage needs a materialized fallback.
        let updated = value.utf8.withContiguousStorageIfAvailable { bytes in
            hash.update(bufferPointer: UnsafeRawBufferPointer(bytes))
            return true
        } ?? false
        if !updated { hash.update(data: Data(value.utf8)) }
    }
    private mutating func bytes(_ value: Data) {
        integer(UInt64(value.count)); hash.update(data: value)
    }
    private mutating func optional(_ value: UInt64?) {
        if let value { tag(1); integer(value) } else { tag(0) }
    }
    private mutating func optional(_ value: UUID?) {
        if let value { tag(1); uuid(value) } else { tag(0) }
    }
    private mutating func members(_ value: [V2RoomSubscriptionMember]) {
        integer(UInt64(value.count))
        for member in value { self.member(member) }
    }
    private mutating func member(_ value: V2RoomSubscriptionMember) {
        string(value.userID.rawValue); integer(value.memberRevision)
    }
    private mutating func event(_ value: V2RealtimeRoomEvent) {
        string(value.roomID.rawValue); integer(value.highWatermark); string(value.sourceEventID.rawValue)
        integer(value.roomSequence); string(value.projectionKind); bytes(value.payload)
        let recipients = value.recipientUserIDs.sorted { $0.rawValue < $1.rawValue }
        integer(UInt64(recipients.count))
        for user in recipients { string(user.rawValue) }
        optional(value.groupMembershipRevision); optional(value.acceptedMembershipRevision)
        optional(value.excludedConnectionID)
    }
}
