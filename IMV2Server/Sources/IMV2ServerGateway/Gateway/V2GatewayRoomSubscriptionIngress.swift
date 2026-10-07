import Foundation
import IMV2Core
import IMV2ActorContracts

/// Authenticated Actor ingress for room-local subscriptions. Composition installs
/// source ownership and a local monotonic deadline; packets cannot grant either.
/// Control results wait for connection EventLoop projections. Callbacks offer
/// bounded work carrying immutable permits for the final socket-local check.
public final class V2GatewayRoomSubscriptionIngress: V2RoomSubscriptionHandler, Sendable {
    public typealias OfferEvent = @Sendable (V2RealtimeRoomEvent, [V2GatewayRoomSubscriptionAuthority.Permit]) -> Void
    public typealias OfferHead = @Sendable (RoomID, UInt64) -> Void
    public let authority: V2GatewayRoomSubscriptionAuthority
    private let offerEvent: OfferEvent
    private let offerHead: OfferHead

    public init(authority: V2GatewayRoomSubscriptionAuthority, maximumRooms: Int = 256,
                offerEvent: @escaping OfferEvent, offerHead: @escaping OfferHead) {
        precondition(maximumRooms > 0)
        self.authority = authority
        self.offerEvent = offerEvent; self.offerHead = offerHead
    }

    @discardableResult
    public func install(fence: V2RoomSubscriptionFence, sourceShardID: String,
                        serviceID: String, deadline: ContinuousClock.Instant,
                        afterAuthoritativeReset: Bool = false) async -> Bool {
        guard sourceShardID == fence.activation.owner.shardID,
              !sourceShardID.isEmpty, sourceShardID.utf8.count <= 128 else { return false }
        return await authority.install(fence: fence, serviceID: serviceID, deadline: deadline,
            afterAuthoritativeReset: afterAuthoritativeReset)
    }

    @discardableResult
    public func retire(fence: V2RoomSubscriptionFence) async -> Bool { await authority.retire(fence: fence) }

    @discardableResult
    public func renew(fence: V2RoomSubscriptionFence, sourceShardID: String, serviceID: String,
        appliedControlSequence: UInt64, deadline: ContinuousClock.Instant) async -> Bool {
        guard sourceShardID == fence.activation.owner.shardID else { return false }
        return await authority.renew(fence: fence, serviceID: serviceID,
            appliedControlSequence: appliedControlSequence, deadline: deadline)
    }

    @discardableResult
    public func refreshProgress(fence: V2RoomSubscriptionFence, sourceShardID: String, serviceID: String,
                                highWatermark: UInt64) async -> Bool {
        guard sourceShardID == fence.activation.owner.shardID else { return false }
        let accepted = await authority.recordCommittedHead(fence: fence, serviceID: serviceID, highWatermark: highWatermark)
        if accepted, let head = await authority.recoveryHighWatermark(roomID: fence.roomID) { offerHead(fence.roomID, head) }
        return accepted
    }

    public func applyRoomSubscription(_ delivery: V2RoomSubscriptionDelivery,
                                      authenticatedServiceID: String, sourceShardID: String) async -> V2RoomSubscriptionDeliveryResult {
        guard sourceShardID == delivery.fence.activation.owner.shardID else { return .stale }
        switch await authority.apply(delivery, authenticatedServiceID: authenticatedServiceID) {
        case .applied(let permits):
            if !permits.isEmpty {
                switch delivery.payload {
                case .event(let event, _), .broadcast(let event): offerEvent(event, permits)
                default: break
                }
            }
            // Terminal controls have already purged every body permit. The
            // retained advisory H only wakes the existing room worker so its
            // trusted coordinator can schedule a new baseline, never reopen it.
            if let highWatermark = await authority.recoveryHighWatermark(roomID: delivery.fence.roomID) {
                offerHead(delivery.fence.roomID, highWatermark)
            }
            return .appliedThrough(delivery.deliverySequence)
        case .snapshotRequired: return .snapshotRequired
        case .stale, .invalid: return .stale
        }
    }
    public func applyRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch,
        authenticatedServiceID: String, sourceShardID: String) async -> V2RoomSubscriptionBatchResult {
        do { try batch.validate() } catch {
            return .init(receipts: Array(Set(batch.deliveries.map(\.fence))).map { .init(fence: $0, result: .stale) })
        }
        var order: [V2RoomSubscriptionFence] = []
        var rooms: [V2RoomSubscriptionFence: [V2RoomSubscriptionDelivery]] = [:]
        for delivery in batch.deliveries {
            if rooms[delivery.fence] == nil { order.append(delivery.fence) }
            rooms[delivery.fence, default: []].append(delivery)
        }
        // Preserve each room's packet order; an unrelated room must not wait
        // for another connection's control projection to be acknowledged.
        let results = await withTaskGroup(of: V2RoomSubscriptionBatchReceipt.self) { group in
            for fence in order {
                let deliveries = rooms[fence]!
                group.addTask {
                    var result: V2RoomSubscriptionDeliveryResult = .stale
                    for delivery in deliveries {
                        result = await self.applyRoomSubscription(delivery,
                            authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID)
                        if case .appliedThrough = result {} else { break }
                    }
                    return .init(fence: fence, result: result)
                }
            }
            var results: [V2RoomSubscriptionFence: V2RoomSubscriptionBatchReceipt] = [:]
            for await receipt in group { results[receipt.fence] = receipt }
            return results
        }
        return .init(receipts: order.map { results[$0]! })
    }

}
