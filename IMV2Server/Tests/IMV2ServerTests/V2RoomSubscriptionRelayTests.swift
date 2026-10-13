import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerGateway
import IMV2ServerContracts
@testable import IMV2ServerApplication
import Testing

struct V2RoomSubscriptionRelayTests {
    @Test func pendingSnapshotKeepsFenceAndLanePrefixAcrossReset() async throws {
        let room = try RoomID("snapshot-room"), user = try UserID("snapshot-user")
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0),
            baselineSequence: 0, members: [.init(userID: user, memberRevision: 1)])
        #expect(await relay.pendingSnapshot(for: gateway, lane: .message) == nil)
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: user, memberRevision: 1,
                subscriptionID: UUID(), generation: 1)))
        let controls = try #require(await relay.pendingSnapshot(for: gateway, lane: .authorization))
        #expect(controls.pending.count == 1)
        #expect(controls.pending.allSatisfy { $0.fence == controls.status.fence })
        try await relay.acknowledge(gateway: gateway, fence: controls.status.fence,
            through: controls.pending[0].deliverySequence, lane: .authorization)
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2, operation: .event(try event(room, sequence: 1))))
        let messages = try #require(await relay.pendingSnapshot(for: gateway, lane: .message))
        #expect(messages.pending.count == 1 && messages.status.latestHighWatermark == 1)
        #expect(messages.status.fence == controls.status.fence)
        #expect(await relay.pendingSnapshot(for: gateway, lane: .authorization)?.pending.isEmpty == true)
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 3,
            operation: .reset(gateway: gateway, subscriptionID: UUID(), generation: 2)))
        let replacement = try #require(await relay.pendingSnapshot(for: gateway, lane: .authorization))
        #expect(replacement.status.fence != messages.status.fence)
        #expect(messages.pending[0].fence == messages.status.fence)
        #expect(replacement.pending.allSatisfy { $0.fence == replacement.status.fence })
    }

    @Test func resetSplitsLargeAuthorizationBaseline() async throws {
        let room = RoomID(uuid: UUID()), id = UUID()
        let members = (0..<1_025).map { _ in V2RoomSubscriptionMember(userID: .init(uuid: UUID()), memberRevision: 1) }
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0),
            baselineSequence: 0, members: members)
        for (index, member) in members.enumerated() {
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: UInt64(index + 1),
                operation: .subscribe(gateway: gateway, userID: member.userID, memberRevision: 1,
                    subscriptionID: id, generation: 1)))
            let fence = try #require(await relay.status(for: gateway)).fence
            try await relay.acknowledgeAll(gateway: gateway, fence: fence, through: UInt64(index + 1))
        }
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: UInt64(members.count + 1),
            operation: .reset(gateway: gateway, subscriptionID: UUID(), generation: 2)))
        let pages = await relay.pending(for: gateway)
        #expect(pages.count == 3)
        var restored: Set<UserID> = []
        for (index, page) in pages.enumerated() {
            try page.validate()
            guard case .baselinePage(let number, let total, let chunk) = page.payload else {
                Issue.record("expected segmented baseline"); return
            }
            #expect(number == index && total == members.count)
            #expect(page.deliverySequence == UInt64(index + 1))
            restored.formUnion(chunk.map(\.userID))
        }
        #expect(restored == Set(members.map(\.userID)))
        #expect(await relay.status(for: gateway)?.needsBaseline == false)
    }
    private let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
    private func event(_ room: RoomID, sequence: UInt64) throws -> V2RealtimeRoomEvent {
        .init(roomID: room, highWatermark: sequence, sourceEventID: try EventID("event-\(sequence)"),
              roomSequence: sequence, projectionKind: "message", payload: Data([1]),
              recipientUserIDs: [], groupMembershipRevision: 1)
    }



    @Test func reorderingDuplicateAndSharedUserRevocation() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob"), id = UUID()
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 3), baselineSequence: 0,
            members: [.init(userID: alice, memberRevision: 1), .init(userID: bob, memberRevision: 1)])
        let first = V2RoomSubscriptionInput(ownerEpoch: 3, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: alice, memberRevision: 1, subscriptionID: id, generation: 7))
        let second = V2RoomSubscriptionInput(ownerEpoch: 3, inputSequence: 2, operation: .event(try event(room, sequence: 1)))
        #expect(try await relay.offer(second) == 0)
        #expect(await relay.pending(for: gateway).isEmpty)
        #expect(try await relay.offer(first) == 2)
        #expect(try await relay.offer(second) == 2)
        try await relay.offer(.init(ownerEpoch: 3, inputSequence: 3,
            operation: .subscribe(gateway: gateway, userID: bob, memberRevision: 1, subscriptionID: id, generation: 7)))
        try await relay.offer(.init(ownerEpoch: 3, inputSequence: 4,
            operation: .membership(userID: alice, revision: 2, authorized: false)))
        try await relay.offer(.init(ownerEpoch: 3, inputSequence: 5, operation: .event(try event(room, sequence: 2))))
        let deliveries = await relay.pending(for: gateway)
        #expect(deliveries.map(\.deliverySequence) == [1, 2, 3, 4, 5])
        #expect(Set(deliveries.map(\.fence)).count == 1)
        #expect(deliveries[2].payload == .grant(member: .init(userID: bob, memberRevision: 1), baselineSequence: 1))
        #expect(deliveries[3].payload == .revoke(userID: alice, memberRevision: 2))
        #expect(deliveries[4].payload == .broadcast(try event(room, sequence: 2)))
    }

    @Test func slowGatewayDoesNotBlockFastGatewayAndRetainsLatestHead() async throws {
        let room = try RoomID("room"), user = try UserID("user"), id = UUID()
        let fast = V2GatewayRealtimeIdentity(nodeID: "fast", serviceID: "realtime", incarnationID: UUID())
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 2), baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 1)], maximumPendingDeliveries: 1)
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: user, memberRevision: 1, subscriptionID: id, generation: 1)))
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 2,
            operation: .subscribe(gateway: fast, userID: user, memberRevision: 1, subscriptionID: UUID(), generation: 1)))
        let baseline = try #require(await relay.pending(for: gateway).first)
        let fastBaseline = try #require(await relay.pending(for: fast).first)
        try await relay.acknowledgeAll(gateway: fast, fence: fastBaseline.fence, through: 1)
        #expect(try await relay.offer(.init(ownerEpoch: 2, inputSequence: 3,
            operation: .event(try event(room, sequence: 1)))) == 3)
        let first = try #require(await relay.pending(for: fast).first)
        #expect(first.deliverySequence == 2)
        try await relay.acknowledgeAll(gateway: fast, fence: first.fence, through: 2)
        #expect(try await relay.offer(.init(ownerEpoch: 2, inputSequence: 4,
            operation: .event(try event(room, sequence: 2)))) == 4)
        let slowStatus = try #require(await relay.status(for: gateway))
        #expect(!slowStatus.needsBaseline)
        #expect(slowStatus.latestHighWatermark == 2)
        #expect(await relay.pending(for: gateway).count == 2)
        let fastEvent = try #require(await relay.pending(for: fast).first)
        #expect(fastEvent.deliverySequence == 3)
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 5,
            operation: .reset(gateway: gateway, subscriptionID: UUID(), generation: 2)))
        let newBaseline = try #require(await relay.pending(for: gateway).first)
        #expect(newBaseline.fence.baselineSequence == 2)
        #expect(newBaseline.deliverySequence == 1)
        #expect(await relay.status(for: gateway)?.needsBaseline == false)
        await #expect(throws: V2RoomSubscriptionRelayError.stale) {
            try await relay.acknowledgeAll(gateway: gateway, fence: baseline.fence, through: 1)
        }
    }

    @Test func newBodyBecomesHeadAndPublishedUnacknowledgedBodyIsImmutable() async throws {
        let room = try RoomID("room"), user = try UserID("user")
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 2), baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 1)], maximumPendingBodyBytes: 1)
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: user, memberRevision: 1,
                subscriptionID: UUID(), generation: 1)))
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 2, operation: .event(try event(room, sequence: 1))))
        // Transport has taken the first body and can have applied it remotely;
        // deliberately leave it unacknowledged to model a lost ACK.
        let published = await relay.pending(for: gateway)
        let admittedBody = published[1]
        let authority = V2GatewayRoomSubscriptionAuthority()
        #expect(await authority.installTestSession(fence: admittedBody.fence, serviceID: "owner"))
        #expect(await authority.apply(published[0], authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(admittedBody, authenticatedServiceID: "owner") == .applied(permits: []))
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 3, operation: .event(try event(room, sequence: 2))))
        let deliveries = await relay.pending(for: gateway)
        #expect(deliveries.map(\.deliverySequence) == [1, 2, 3])
        #expect(deliveries[1] == admittedBody)
        #expect(deliveries[1].payload == .broadcast(try event(room, sequence: 1)))
        #expect(deliveries[2].payload == .head(highWatermark: 2))
        #expect(await authority.apply(deliveries[1], authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await authority.apply(deliveries[2], authenticatedServiceID: "owner") == .applied(permits: []))
        #expect(await relay.status(for: gateway)?.needsBaseline == false)
        #expect(await relay.status(for: gateway)?.latestHighWatermark == 2)
        try await relay.acknowledgeAll(gateway: gateway, fence: admittedBody.fence, through: 2)
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 4, operation: .event(try event(room, sequence: 3))))
        let afterAck = await relay.pending(for: gateway)
        #expect(afterAck[0].payload == .head(highWatermark: 2))
        #expect(afterAck[1].payload == .broadcast(try event(room, sequence: 3)))
    }

    @Test func controlOverflowRequiresBaselineAndCannotRestoreRevokedMember() async throws {
        let room = try RoomID("room"), user = try UserID("user")
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 2), baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 1)], maximumPendingDeliveries: 1)
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: user, memberRevision: 1,
                subscriptionID: UUID(), generation: 1)))
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 2,
            operation: .membership(userID: user, revision: 2, authorized: false)))
        #expect(await relay.controlInvalidationPending(gateway: gateway))
        let terminal = try #require(await relay.pending(for: gateway, lane: .authorization).last)
        #expect(terminal.payload == .authorizationInvalidated)
        try await relay.acknowledge(gateway: gateway, fence: terminal.fence,
            through: terminal.deliverySequence, lane: .authorization)
        #expect(await relay.status(for: gateway)?.needsBaseline == true)
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 3,
            operation: .reset(gateway: gateway, subscriptionID: UUID(), generation: 2)))
        let baseline = try #require(await relay.pending(for: gateway).first)
        #expect(baseline.payload == .baseline(members: []))
        #expect(await relay.status(for: gateway)?.needsBaseline == false)
    }

    @Test func localUnsubscribeAllowsSameMembershipRevisionGrant() async throws {
        let room = try RoomID("room"), user = try UserID("user"), id = UUID()
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 2), baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 1)])
        let subscribe = V2RoomSubscriptionInput.Operation.subscribe(gateway: gateway, userID: user,
            memberRevision: 1, subscriptionID: id, generation: 1)
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 1, operation: subscribe))
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 2,
            operation: .unsubscribe(gateway: gateway, userID: user, memberRevision: 1)))
        try await relay.offer(.init(ownerEpoch: 2, inputSequence: 3, operation: subscribe))
        let deliveries = await relay.pending(for: gateway)
        #expect(deliveries[1].payload == .revoke(userID: user, memberRevision: 1))
        #expect(deliveries[2].payload == .grant(member: .init(userID: user, memberRevision: 1), baselineSequence: 0))
    }

    @Test func rejectsUnauthorizedEpochConflictAndBoundedReorder() async throws {
        let room = try RoomID("room"), user = try UserID("user")
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 2), baselineSequence: 0,
            maximumBufferedInputs: 2)
        await #expect(throws: V2RoomSubscriptionRelayError.stale) {
            try await relay.offer(.init(ownerEpoch: 1, inputSequence: 1,
                operation: .membership(userID: user, revision: 1, authorized: true)))
        }
        await #expect(throws: V2RoomSubscriptionRelayError.overloaded) {
            try await relay.offer(.init(ownerEpoch: 2, inputSequence: 3,
                operation: .membership(userID: user, revision: 1, authorized: true)))
        }
        let input = V2RoomSubscriptionInput(ownerEpoch: 2, inputSequence: 2,
            operation: .membership(userID: user, revision: 1, authorized: true))
        try await relay.offer(input)
        await #expect(throws: V2RoomSubscriptionRelayError.conflict) {
            try await relay.offer(.init(ownerEpoch: 2, inputSequence: 2,
                operation: .membership(userID: user, revision: 2, authorized: true)))
        }
        await #expect(throws: V2RoomSubscriptionRelayError.unauthorized) {
            try await relay.offer(.init(ownerEpoch: 2, inputSequence: 1,
                operation: .subscribe(gateway: gateway, userID: user, memberRevision: 1,
                    subscriptionID: UUID(), generation: 1)))
        }
        #expect(await relay.pending(for: gateway).isEmpty)
    }

    @Test func bufferedInputByteBudgetRejectsWithoutLosingRetryAndGapFillerProgresses() async throws {
        let room = try RoomID("room"), user = try UserID("user")
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 1), baselineSequence: 0,
            maximumBufferedInputs: 8, maximumBufferedInputBytes: 1025)
        let second = V2RoomSubscriptionInput(ownerEpoch: 1, inputSequence: 2,
            operation: .event(try event(room, sequence: 1)))
        let third = V2RoomSubscriptionInput(ownerEpoch: 1, inputSequence: 3,
            operation: .event(try event(room, sequence: 2)))
        #expect(try await relay.offer(second) == 0)
        await #expect(throws: V2RoomSubscriptionRelayError.overloaded) { try await relay.offer(third) }
        // The unretained gap-filler applies despite the full reorder budget,
        // releasing the buffered body's bytes so the rejected input can retry.
        #expect(try await relay.offer(.init(ownerEpoch: 1, inputSequence: 1,
            operation: .membership(userID: user, revision: 1, authorized: true))) == 2)
        #expect(try await relay.offer(third) == 3)
        #expect(try await relay.offer(second) == 3)
        let conflictEvent = V2RealtimeRoomEvent(roomID: room, highWatermark: 1,
            sourceEventID: try EventID("event-1"), roomSequence: 1, projectionKind: "message",
            payload: Data([9]), recipientUserIDs: [], groupMembershipRevision: 1)
        await #expect(throws: V2RoomSubscriptionRelayError.conflict) {
            try await relay.offer(.init(ownerEpoch: 1, inputSequence: 2, operation: .event(conflictEvent)))
        }
    }

    @Test func zeroOwnerEpochAndMembershipRevisionAreValidDomainValues() async throws {
        let room = try RoomID("room"), user = try UserID("user")
        let relay = try V2RoomSubscriptionRelay(activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0), baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)])
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0,
                subscriptionID: UUID(), generation: 1)))
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2, operation: .event(try event(room, sequence: 1))))
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 3,
            operation: .unsubscribe(gateway: gateway, userID: user, memberRevision: 0)))
        let deliveries = await relay.pending(for: gateway)
        for delivery in deliveries { try delivery.validate() }
        #expect(deliveries[0].payload == .baseline(members: [.init(userID: user, memberRevision: 0)]))
        #expect(deliveries[1].payload == .broadcast(try event(room, sequence: 1)))
        #expect(deliveries[2].payload == .revoke(userID: user, memberRevision: 0))
        let authority = V2GatewayRoomSubscriptionAuthority()
        #expect(await authority.installTestSession(fence: deliveries[0].fence, serviceID: "owner"))
        for delivery in deliveries {
            #expect(await authority.apply(delivery, authenticatedServiceID: "owner") == .applied(permits: []))
        }
    }

    @Test func attachmentSeedsAtConsumedCutAndEmptyEligibleDoesNotBroadcast() async throws {
        let room = try RoomID("room"), alice = try UserID("alice"), bob = try UserID("bob")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0), subscriptionID = UUID()
        let oldState = V2RoomSubscriptionSourceMember(userID: alice, memberRevision: 0, authorized: true)
        let relay = try V2RoomSubscriptionRelay.restored(from: .init(roomID: room, owner: owner,
            highWatermark: 0, members: [oldState]), activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0))
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: alice, memberRevision: 0,
                subscriptionID: subscriptionID, generation: 1)))
        let baseline = try #require(await relay.pending(for: gateway).first)
        let newState = V2RoomSubscriptionSourceMember(userID: bob, memberRevision: 1, authorized: true)
        let attachment = V2RoomSubscriptionSourceSnapshot(roomID: room, owner: owner, highWatermark: 1, membershipRevision: 1, members: [newState])
        await #expect(throws: V2RoomSubscriptionRelayError.stale) { try await relay.seedAuthorizations(from: attachment) }
        try await relay.ingest(.init(roomID: room, owner: owner, afterRoomSequence: 0,
            highWatermark: 1, records: [.init(event: try event(room, sequence: 1), hasOnlineBody: false,
                membershipControl: .init(revisionBefore: 0, revisionAfter: 1, members: [oldState]), recipientPolicy: .explicit([]))]))
        #expect(await relay.committedSequence() == 1)
        #expect(await relay.pending(for: gateway) == [baseline])
        try await relay.seedAuthorizations(from: attachment)
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2,
            operation: .subscribe(gateway: gateway, userID: bob, memberRevision: 1,
                subscriptionID: subscriptionID, generation: 1)))
        let deliveries = await relay.pending(for: gateway)
        #expect(deliveries.count == 2 && deliveries[0] == baseline)
        #expect(deliveries[1].fence == baseline.fence)
        #expect(deliveries[1].payload == .grant(member: .init(userID: bob, memberRevision: 1), baselineSequence: 1))
    }

    @Test func ordinaryMessageWithUnseenMembershipRevisionFailsBeforeMutation() async throws {
        let room = try RoomID("room"), user = try UserID("user")
        let owner = try V2RoomDataOwner(shardID: "source", epoch: 0)
        let relay = try V2RoomSubscriptionRelay.restored(from: .init(roomID: room, owner: owner,
            highWatermark: 0, membershipRevision: 0,
            members: [.init(userID: user, memberRevision: 0, authorized: true)]), activation: roomSubscriptionFixtureActivation(roomID: room, ownerEpoch: 0))
        // The committed message claims revision 1 but no membership control
        // has consumed it. A current SQL roster must not patch over the gap.
        await #expect(throws: V2RoomSubscriptionSourceError.snapshotRequired) {
            try await relay.ingest(.init(roomID: room, owner: owner, afterRoomSequence: 0, highWatermark: 1,
                records: [.init(event: try event(room, sequence: 1), hasOnlineBody: true)]))
        }
        #expect(await relay.committedSequence() == 0)
    }
}

func roomSubscriptionFixtureActivation(roomID: RoomID, ownerEpoch: Int64, shardID: String = "source",
                                       activationEpoch: Int64 = 1) throws -> V2RoomActivationToken {
    .init(roomID: roomID, owner: try .init(shardID: shardID, epoch: ownerEpoch),
          activationEpoch: try .init(activationEpoch),
          host: .init(hostID: try V2ActorHostID("fixture-owner"), incarnationID: UUID()))
}

// Simulate reception of both lanes for relay-only tests. Production receipts
// acknowledge exactly one lane and can never retire another lane's payloads.
extension V2RoomSubscriptionRelay {
    func acknowledgeAll(gateway: V2GatewayRealtimeIdentity, fence: V2RoomSubscriptionFence, through sequence: UInt64) async throws {
        try acknowledge(gateway: gateway, fence: fence, through: sequence, lane: .authorization)
        try acknowledge(gateway: gateway, fence: fence, through: sequence, lane: .message)
    }
}
