import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerGateway

@Suite("Room relay to Gateway subscription authority")
struct V2RoomSubscriptionIntegrationTests {
    @Test("one room event reaches devices on two Gateways without foreground interests")
    func onlineDevicesAcrossGateways() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let relay = try V2RoomSubscriptionRelay(activation: try activation(room, shardID: "rooms", ownerEpoch: 1),
            baselineSequence: 0, members: [.init(userID: user, memberRevision: 1)])
        let gateways = (0..<2).map { V2GatewayRealtimeIdentity(nodeID: "gateway-\($0)",
            serviceID: "gateway-\($0)", incarnationID: UUID()) }
        var authorities: [V2GatewayRoomSubscriptionAuthority] = []
        var expected: Set<UUID> = []
        for (index, gateway) in gateways.enumerated() {
            let authority = V2GatewayRoomSubscriptionAuthority()
            for _ in 0..<(index + 1) {
                let connection = UUID(); expected.insert(connection)
                #expect(authority.registerConnection(connection, userID: user, lifecycle: UUID()))
            }
            try await relay.offer(.init(ownerEpoch: 1, inputSequence: UInt64(index + 1),
                operation: .subscribe(gateway: gateway, userID: user, memberRevision: 1,
                    subscriptionID: UUID(), generation: 1)))
            let baseline = try #require(await relay.pending(for: gateway).first)
            #expect(await authority.install(fence: baseline.fence, serviceID: "owner", deadline: .now + .seconds(30)))
            for delivery in await relay.pending(for: gateway) {
                #expect(await authority.apply(delivery, authenticatedServiceID: "owner") == .applied(permits: []))
            }
            authorities.append(authority)
        }
        let event = V2RealtimeRoomEvent(roomID: room, highWatermark: 1, sourceEventID: .init(uuid: UUID()),
            roomSequence: 1, projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 1)
        try await relay.offer(.init(ownerEpoch: 1, inputSequence: 3, operation: .event(event)))
        var recipients: Set<UUID> = []
        for (index, gateway) in gateways.enumerated() {
            for delivery in await relay.pending(for: gateway) {
                guard case .applied(let permits) = await authorities[index].apply(delivery, authenticatedServiceID: "owner") else {
                    Issue.record("Gateway rejected an authorized delivery"); continue
                }
                recipients.formUnion(permits.map(\.connectionID))
                for permit in permits {
                    let accepted = authorities[index].enqueueIfCurrent(permit, enqueue: {})
                    #expect(accepted)
                }
            }
        }
        #expect(recipients == expected)
    }

    @Test func shardMigrationRequiresHigherOwnerAndFreshBaseline() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let authority = V2GatewayRoomSubscriptionAuthority()
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let first = V2RoomSubscriptionFence(activation: try activation(room, shardID: "old-shard", ownerEpoch: 0),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        #expect(await ingress.install(fence: first, sourceShardID: "old-shard", serviceID: "owner", deadline: .now + .seconds(30)))
        let member = V2RoomSubscriptionMember(userID: user, memberRevision: 0)
        let baseline = V2RoomSubscriptionDelivery(fence: first, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [member]))
        #expect(await ingress.applyRoomSubscription(baseline, authenticatedServiceID: "owner", sourceShardID: "old-shard") == .appliedThrough(1))
        let sameOwner = V2RoomSubscriptionFence(activation: try activation(room, shardID: "new-shard", ownerEpoch: 0),
            subscriptionID: UUID(), generation: 2, baselineSequence: 0)
        #expect(!(await ingress.install(fence: sameOwner, sourceShardID: "new-shard", serviceID: "owner", deadline: .now + .seconds(30))))
        let migrated = V2RoomSubscriptionFence(activation: try activation(room, shardID: "new-shard", ownerEpoch: 1),
            subscriptionID: UUID(), generation: 1, baselineSequence: 1)
        #expect(await ingress.install(fence: migrated, sourceShardID: "new-shard", serviceID: "owner", deadline: .now + .seconds(30)))
        #expect(await ingress.applyRoomSubscription(baseline, authenticatedServiceID: "owner", sourceShardID: "old-shard") == .stale)
        let fresh = V2RoomSubscriptionDelivery(fence: migrated, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [member]))
        #expect(await ingress.applyRoomSubscription(fresh, authenticatedServiceID: "owner", sourceShardID: "new-shard") == .appliedThrough(1))
    }

    @Test func actorIngressRequiresInstalledShardAndDoesNotRepeatBodyOnRetry() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let authority = V2GatewayRoomSubscriptionAuthority()
        let bodies = Mutex(0)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority,
            offerEvent: { _, _ in bodies.withLock { $0 += 1 } }, offerHead: { _, _ in })
        let fence = V2RoomSubscriptionFence(activation: try activation(room, shardID: "room-shard", ownerEpoch: 1),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        let installed = await ingress.install(fence: fence, sourceShardID: "room-shard", serviceID: "owner", deadline: .now + .seconds(30))
        #expect(installed)
        let connection = UUID(), lifecycle = UUID()
        authority.registerConnection(connection, userID: user, lifecycle: lifecycle)
        #expect(await authority.registerRoomInterest(connectionID: connection, lifecycle: lifecycle, roomID: room, scopeGeneration: 1))
        let member = V2RoomSubscriptionMember(userID: user, memberRevision: 1)
        let baseline = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [member]))
        #expect(await ingress.applyRoomSubscription(baseline, authenticatedServiceID: "owner", sourceShardID: "other") == .stale)
        #expect(await ingress.applyRoomSubscription(baseline, authenticatedServiceID: "owner", sourceShardID: "room-shard") == .appliedThrough(1))
        let event = V2RealtimeRoomEvent(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 1, projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 1)
        let delivery = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 2, authorizationSequence: 1, payload: .event(event, members: [member]))
        #expect(await ingress.applyRoomSubscription(delivery, authenticatedServiceID: "imposter", sourceShardID: "room-shard") == .stale)
        #expect(await ingress.applyRoomSubscription(delivery, authenticatedServiceID: "owner", sourceShardID: "room-shard") == .appliedThrough(2))
        #expect(await ingress.applyRoomSubscription(delivery, authenticatedServiceID: "owner", sourceShardID: "room-shard") == .appliedThrough(2))
        #expect(bodies.withLock { $0 } == 1)
    }

    @Test func sharedDevicesLocalRevocationAndLostAcknowledgement() async throws {
        let room = RoomID(uuid: UUID()), alice = UserID(uuid: UUID()), bob = UserID(uuid: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())
        let relay = try V2RoomSubscriptionRelay(activation: try activation(room, shardID: "rooms", ownerEpoch: 1), baselineSequence: 0,
            members: [.init(userID: alice, memberRevision: 1), .init(userID: bob, memberRevision: 1)])
        let local = V2GatewayRoomSubscriptionAuthority()
        let first = UUID(), second = UUID(), other = UUID(), subscription = UUID()
        for (connection, user) in [(first, alice), (second, alice), (other, bob)] {
            let lifecycle = UUID()
            local.registerConnection(connection, userID: user, lifecycle: lifecycle)
        }
        try await relay.offer(.init(ownerEpoch: 1, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: alice, memberRevision: 1, subscriptionID: subscription, generation: 1)))
        try await relay.offer(.init(ownerEpoch: 1, inputSequence: 2,
            operation: .subscribe(gateway: gateway, userID: bob, memberRevision: 1, subscriptionID: subscription, generation: 1)))
        let baseline = try #require(await relay.pending(for: gateway).first)
        let installed = await local.install(fence: baseline.fence, serviceID: "owner", deadline: .now + .seconds(30))
        #expect(installed)
        for delivery in await relay.pending(for: gateway) {
            #expect(await local.apply(delivery, authenticatedServiceID: "owner") == .applied(permits: []))
        }
        try await relay.acknowledgeAll(gateway: gateway, fence: baseline.fence, through: 2)
        let event = V2RealtimeRoomEvent(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 1, projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 1)
        try await relay.offer(.init(ownerEpoch: 1, inputSequence: 3, operation: .event(event)))
        let delivery = try #require(await relay.pending(for: gateway).first)
        guard case .applied(let permits) = await local.apply(delivery, authenticatedServiceID: "owner") else {
            Issue.record("Relay event was not admitted"); return
        }
        #expect(Set(permits.map(\.connectionID)) == [first, second, other])
        // The RPC acknowledgement is lost: replay must acknowledge without
        // producing another device fanout or invalidating the original permits.
        #expect(await local.apply(delivery, authenticatedServiceID: "owner") == .applied(permits: []))
        try await relay.acknowledgeAll(gateway: gateway, fence: baseline.fence, through: 3)
        try await relay.offer(.init(ownerEpoch: 1, inputSequence: 4,
            operation: .membership(userID: alice, revision: 2, authorized: false)))
        let revoke = try #require(await relay.pending(for: gateway).first)
        #expect(await local.apply(revoke, authenticatedServiceID: "owner") == .applied(permits: []))
        for permit in permits {
            let accepted = local.enqueueIfCurrent(permit, enqueue: {})
            #expect(accepted == (permit.userID == bob))
        }
    }

    @Test func ingressRequiresTheInstalledActivationShard() async throws {
        let room = RoomID(uuid: UUID()), authority = V2GatewayRoomSubscriptionAuthority()
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let first = V2RoomSubscriptionFence(activation: try activation(room, shardID: "actual-shard", ownerEpoch: 0),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        #expect(!(await ingress.install(fence: first, sourceShardID: "wrong-shard", serviceID: "owner", deadline: .now + .seconds(30))))
        #expect(await ingress.install(fence: first, sourceShardID: "actual-shard", serviceID: "owner", deadline: .now + .seconds(30)))
        let baseline = V2RoomSubscriptionDelivery(fence: first, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: []))
        #expect(await ingress.applyRoomSubscription(baseline, authenticatedServiceID: "owner", sourceShardID: "wrong-shard") == .stale)
        #expect(await ingress.applyRoomSubscription(baseline, authenticatedServiceID: "owner", sourceShardID: "actual-shard") == .appliedThrough(1))
    }

    @Test func everyDeliveryValidatesItsActivationFenceBeforeInstallingAuthority() async throws {
        let room = RoomID(uuid: UUID())
        let token = try activation(room, shardID: String(repeating: "r", count: 129), ownerEpoch: 0)
        let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        let delivery = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: []))
        #expect(throws: V2ActorContractError.invalidConfiguration("room subscription activation fence")) {
            try delivery.validate()
        }
        let authority = V2GatewayRoomSubscriptionAuthority()
        #expect(!(await authority.install(fence: fence, serviceID: "owner", deadline: .now + .seconds(30))))
        #expect(fence.roomID == token.roomID)
        #expect(fence.ownerEpoch == token.owner.epoch)
    }

    private func activation(_ room: RoomID, shardID: String, ownerEpoch: Int64) throws -> V2RoomActivationToken {
        .init(roomID: room, owner: try .init(shardID: shardID, epoch: ownerEpoch), activationEpoch: try .init(1),
            host: .init(hostID: try .init("integration-test-owner"),
                incarnationID: UUID(uuidString: "00000000-0000-0000-0000-00000000ac01")!))
    }

}
