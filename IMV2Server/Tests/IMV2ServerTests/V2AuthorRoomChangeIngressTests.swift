import Foundation
import IMV2Core
import IMV2ActorContracts
import Synchronization
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerGateway

@Suite(.timeLimit(.minutes(1)))
struct V2AuthorRoomChangeIngressTests {
    @Test("only newly accepted room controls, gaps and events notify presentation ingress, even without body recipients")
    func acceptedControls() async throws {
        let f = try RoomChangeFixture()
        try #require(await f.ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
        let baseline = f.delivery(1, 1, .baseline(members: [f.member]))
        #expect(await f.ingress.applyRoomSubscription(baseline, authenticatedServiceID: "foreign", sourceShardID: "rooms") == .stale)
        #expect(f.observations.resets.withLock { $0.isEmpty })
        try await f.apply(baseline)
        try await f.apply(baseline)
        #expect(f.observations.resets.withLock { $0 } == [f.room])
        let head = f.delivery(2, 1, .head(highWatermark: 1))
        try await f.apply(head); try await f.apply(head)
        #expect(f.observations.resets.withLock { $0.count } == 2)
        let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 2, sourceEventID: .init(uuid: UUID()),
            roomSequence: 2, projectionKind: "group_capability",
            payload: Data("{}".utf8), recipientUserIDs: [], groupMembershipRevision: 0)
        let publication = f.delivery(3, 1, .broadcast(event))
        try await f.apply(publication); try await f.apply(publication)
        #expect(f.observations.events.withLock { $0 } == [event])
        #expect(f.observations.bodies.withLock { $0 } == 0)
        let newMember = V2RoomSubscriptionMember(userID: .init(uuid: UUID()), memberRevision: 1)
        for delivery in [f.delivery(4, 2, .grant(member: newMember, baselineSequence: 2)),
                         f.delivery(5, 3, .revoke(userID: newMember.userID, memberRevision: 2)),
                         f.delivery(6, 4, .authorizationInvalidated)] {
            try await f.apply(delivery); try await f.apply(delivery)
        }
        #expect(f.observations.resets.withLock { $0.count } == 5)
        #expect(f.observations.events.withLock { $0.count } == 1)
    }

    @Test("a complete baseline page set and an authorization gap reset presentation hints")
    func baselineAndGap() async throws {
        let f = try RoomChangeFixture()
        try #require(await f.ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
        let members = (0..<513).map { _ in V2RoomSubscriptionMember(userID: .init(uuid: UUID()), memberRevision: 0) }
        try await f.apply(f.delivery(1, 1, .baselinePage(index: 0, totalMembers: 513, members: Array(members.prefix(512)))))
        #expect(f.observations.resets.withLock { $0.isEmpty })
        let last = f.delivery(2, 2, .baselinePage(index: 1, totalMembers: 513, members: [members[512]]))
        try await f.apply(last); try await f.apply(last)
        #expect(f.observations.resets.withLock { $0 } == [f.room])
        let gap = f.delivery(4, 4, .grant(member: f.member, baselineSequence: 0))
        #expect(await f.ingress.applyRoomSubscription(gap, authenticatedServiceID: "owner", sourceShardID: "rooms") == .snapshotRequired)
        #expect(f.observations.resets.withLock { $0.count } == 2)
    }

    @Test("only matching membership and role events request a room permission recheck", arguments: 0...7)
    func permissionEvent(mode: Int) throws {
        let room = RoomID(uuid: UUID())
        let type = ["membership_changed", "group.role_permissions_changed", "group.member_role_changed",
                    "group.announcement_changed", "membership_changed", "membership_changed", "membership_changed", "membership_changed"][mode]
        let payload = try JSONSerialization.data(withJSONObject: ["event_type": type,
            "room_id": (mode == 4 ? RoomID(uuid: UUID()) : room).rawValue, "room_sequence": mode == 5 ? 2 : 1])
        let event = V2DirectRoomLiveEvent(roomID: room, highWatermark: 1, sourceEventID: .init(uuid: UUID()),
            roomSequence: 1, projectionKind: mode == 7 ? "message" : (mode == 1 || mode == 2 || mode == 3 ? "group_capability" : "membership"),
            payload: payload, recipientUserIDs: [], groupMembershipRevision: mode == 6 ? nil : 1)
        #expect(V2AuthorRoomPermissionChange(event: event)?.roomID == (mode < 3 ? room : nil))
    }
}

private final class RoomChangeObservations: Sendable {
    let resets = Mutex<[RoomID]>([]), events = Mutex<[V2RealtimeRoomEvent]>([]), bodies = Mutex(0)
}

private struct RoomChangeFixture {
    let room = RoomID(uuid: UUID())
    let member = V2RoomSubscriptionMember(userID: .init(uuid: UUID()), memberRevision: 0)
    let observations = RoomChangeObservations()
    let fence: V2RoomSubscriptionFence
    let ingress: V2GatewayRoomSubscriptionIngress
    init() throws {
        fence = V2RoomSubscriptionFence(activation: .init(roomID: room,
            owner: try .init(shardID: "rooms", epoch: 0), activationEpoch: try .init(1),
            host: .init(hostID: try .init("presentation-room"), incarnationID: UUID())),
            subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        ingress = .init(authority: .init(), offerEvent: { [observations] _, _ in observations.bodies.withLock { $0 += 1 } }, offerHead: { _, _ in },
            observePresentationEvent: { [observations] event in observations.events.withLock { $0.append(event) } },
            invalidatePresentations: { [observations] room in observations.resets.withLock { $0.append(room) } })
    }
    func delivery(_ sequence: UInt64, _ authorization: UInt64, _ payload: V2RoomSubscriptionPayload) -> V2RoomSubscriptionDelivery {
        .init(fence: fence, deliverySequence: sequence, authorizationSequence: authorization, payload: payload)
    }
    func apply(_ value: V2RoomSubscriptionDelivery) async throws {
        #expect(await ingress.applyRoomSubscription(value, authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(value.deliverySequence))
    }
}
