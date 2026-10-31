import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts

/// Authenticated Actor ingress for room-local subscriptions. Composition installs
/// source ownership and a delivery session; packets cannot grant either.
/// Control results wait for connection EventLoop projections. Callbacks offer
/// bounded work carrying immutable permits for the final socket-local check.
public final class V2GatewayRoomSubscriptionIngress: V2RoomSubscriptionHandler, Sendable {
    public typealias OfferEvent = @Sendable (V2RealtimeRoomEvent, [V2GatewayRoomSubscriptionAuthority.Permit]) -> Void
    public typealias OfferHead = @Sendable (RoomID, UInt64) -> Void
    public let authority: V2GatewayRoomSubscriptionAuthority
    private let offerEvent: OfferEvent
    private let offerHead: OfferHead
    private let observePresentationEvent: @Sendable (V2RealtimeRoomEvent) -> Void
    private let invalidatePresentations: @Sendable (RoomID) -> Void

    public init(authority: V2GatewayRoomSubscriptionAuthority, maximumRooms: Int = 256,
                offerEvent: @escaping OfferEvent, offerHead: @escaping OfferHead,
                observePresentationEvent: @escaping @Sendable (V2RealtimeRoomEvent) -> Void = { _ in },
                invalidatePresentations: @escaping @Sendable (RoomID) -> Void = { _ in }) {
        precondition(maximumRooms > 0)
        self.authority = authority
        self.offerEvent = offerEvent; self.offerHead = offerHead
        self.observePresentationEvent = observePresentationEvent; self.invalidatePresentations = invalidatePresentations
    }

    @discardableResult
    public func install(fence: V2RoomSubscriptionFence, sourceShardID: String,
                        serviceID: String, session: V2RoomDeliverySession,
                        afterAuthoritativeReset: Bool = false) async -> Bool {
        guard sourceShardID == fence.activation.owner.shardID,
              !sourceShardID.isEmpty, sourceShardID.utf8.count <= 128 else { return false }
        let installed = await authority.install(fence: fence, serviceID: serviceID, session: session,
            afterAuthoritativeReset: afterAuthoritativeReset)
        if installed {
            let obsolete = authority.releaseSupersededHostSessions(confirmed: session, serviceID: serviceID)
            if !obsolete.isEmpty {
                let notify = sessionChanged.withLock { $0 }
                for host in obsolete { await notify?(host) }
            }
        }
        return installed
    }

    @discardableResult
    public func retire(fence: V2RoomSubscriptionFence) async -> Bool { await authority.retire(fence: fence) }

    /// A successful local repair can outlive its original head publication.
    /// This advisory wake grants no authority; the consumer captures fresh gates.
    package func resignalProgress(roomID: RoomID) async {
        if let head = await authority.recoveryHighWatermark(roomID: roomID) { offerHead(roomID, head) }
    }

    private let sessionChanged = Synchronization.Mutex<(@Sendable (V2ActorHostIdentity) async -> Void)?>(nil)
    public func configureSessionChanged(_ notify: @escaping @Sendable (V2ActorHostIdentity) async -> Void) {
        sessionChanged.withLock { precondition($0 == nil); $0 = notify }
    }
    private let baselineRequired = Synchronization.Mutex<(@Sendable (RoomID) async -> Void)?>(nil)
    public func configureBaselineRequired(_ notify: @escaping @Sendable (RoomID) async -> Void) {
        baselineRequired.withLock { precondition($0 == nil); $0 = notify }
    }
    private func requestBaseline(for fence: V2RoomSubscriptionFence) async {
        guard await authority.requiresBaseline(fence: fence) else { return }
        let notify = baselineRequired.withLock { $0 }
        await notify?(fence.roomID)
    }
    public func applyDeliverySession(_ pulse: V2RoomDeliverySessionPulse,
        authenticatedServiceID: String) async -> V2RoomDeliverySessionResult {
        let result = authority.applyDeliverySession(pulse, serviceID: authenticatedServiceID)
        if result != .stale {
            let notify = sessionChanged.withLock { $0 }
            await notify?(pulse.session.host)
        }
        return result
    }
    public func applyRoomSubscription(_ delivery: V2RoomSubscriptionDelivery,
                                      authenticatedServiceID: String, sourceShardID: String) async -> V2RoomSubscriptionDeliveryResult {
        guard sourceShardID == delivery.fence.activation.owner.shardID else { return .stale }
        switch await authority.apply(delivery, authenticatedServiceID: authenticatedServiceID,
            observeAccepted: { [observePresentationEvent, invalidatePresentations] accepted in
                switch accepted.payload {
                case .event(let event, _), .broadcast(let event): observePresentationEvent(event)
                case .baseline, .grant, .revoke, .authorizationInvalidated, .head:
                    invalidatePresentations(accepted.fence.roomID)
                case .baselinePage(let index, let total, _):
                    if (index + 1) * V2RoomSubscriptionPayload.maximumBaselinePageMembers >= total {
                        invalidatePresentations(accepted.fence.roomID)
                    }
                }
            }) {
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
        case .snapshotRequired:
            invalidatePresentations(delivery.fence.roomID)
            await requestBaseline(for: delivery.fence)
            return .snapshotRequired
        case .stale, .invalid:
            await requestBaseline(for: delivery.fence)
            return .stale
        }
    }
    public func applyRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch,
        authenticatedServiceID: String, sourceShardID: String) async -> V2RoomSubscriptionBatchResult {
        do {
            return await applyRoomSubscriptionBatch(try batch.validated(),
                authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID)
        } catch {
            return .init(receipts: Array(Set(batch.deliveries.map(\.fence))).map { .init(fence: $0, result: .stale) })
        }
    }

    public func applyRoomSubscriptionBatch(_ batch: V2ValidatedRoomSubscriptionBatch,
        authenticatedServiceID: String, sourceShardID: String) async -> V2RoomSubscriptionBatchResult {
        // A single room needs no child task; multi-room controls stay concurrent.
        if batch.rooms.count == 1 {
            return .init(receipts: [await applyRoom(batch.rooms[0], in: batch,
                authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID)])
        }
        return await withTaskGroup(of: (Int, V2RoomSubscriptionBatchReceipt).self) { group in
            for (index, room) in batch.rooms.enumerated() {
                group.addTask {
                    (index, await self.applyRoom(room, in: batch,
                        authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID))
                }
            }
            var receipts = [V2RoomSubscriptionBatchReceipt?](repeating: nil, count: batch.rooms.count)
            for await (index, receipt) in group { receipts[index] = receipt }
            return .init(receipts: receipts.map { $0! })
        }
    }

    private func applyRoom(_ room: V2ValidatedRoomSubscriptionBatch.Room, in batch: V2ValidatedRoomSubscriptionBatch,
        authenticatedServiceID: String, sourceShardID: String) async -> V2RoomSubscriptionBatchReceipt {
        var result: V2RoomSubscriptionDeliveryResult = .stale
        for index in room.indices {
            result = await applyRoomSubscription(batch.batch.deliveries[index],
                authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID)
            if case .appliedThrough = result {} else { break }
        }
        return .init(fence: room.fence, result: result)
    }
}
