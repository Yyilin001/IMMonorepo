import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
@testable import IMV2Server

struct V2RoomSubscriptionHostTests {
    @Test func stationaryRoomsReadOnlyWhenExplicitlySignalled() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let user = try UserID("user")
            let host = V2RoomSubscriptionHost()
            activations.own(host)
            try await host.configure(sendBatch: { _, _, _ in .init(receipts: []) }, maximumCalls: 1)
            var sources: [HostCheckSource] = []
            var owners: [V2RoomSubscriptionOwner] = []
            for index in 0..<32 {
                let room = try RoomID("room-\(index)")
                let (token, lifetime) = try await activations.activate(room)
                let source = HostCheckSource(room: room, owner: token.owner, user: user)
                let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                    activation: token, deadline: .now + .seconds(30), trackedUserIDs: [])
                try await host.register(owner, token: token, lifetime: lifetime)
                sources.append(source); owners.append(owner)
            }
            for source in sources {
                #expect(await source.readCount == 0)
                #expect(await source.snapshotCount == 1)
            }
            await sources[0].setHead(1)
            host.signal(room: sources[0].room)
            let deadline = ContinuousClock.now + .seconds(3)
            while await owners[0].consumedSequence() < 1 {
                try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await sources[0].readCount == 1)
            #expect(await sources[0].snapshotCount == 1)
            for source in sources.dropFirst() { #expect(await source.readCount == 0) }
            await host.close()
            host.signal(room: sources[0].room)
            #expect(await host.currentPump() == nil)
            #expect(await sources[0].readCount == 1)
        }
    }

    @Test(arguments: [false, true])
    func explicitRecoveryRetainsTransientReadResponsibility(failFirstRead: Bool) async throws {
        try await withNativeSubscriptionTestHost { activations in
            let room = try RoomID("room"), user = try UserID("user")
            let (token, lifetime) = try await activations.activate(room)
            let source = HostCheckSource(room: room, owner: token.owner, user: user)
            let host = V2RoomSubscriptionHost()
            let deliveries = AsyncStream<V2RoomSubscriptionDelivery>.makeStream(bufferingPolicy: .bufferingNewest(8))
            activations.own(host)
            try await host.configure(sendBatch: { batch, _, _ in
                for delivery in batch.deliveries { deliveries.continuation.yield(delivery) }
                return .init(receipts: [.init(fence: batch.deliveries[0].fence,
                    result: .appliedThrough(batch.deliveries.last!.deliverySequence))])
            }, maximumCalls: 1)
            let service = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                activation: token, deadline: .now + .seconds(30), trackedUserIDs: [],
                notifyChanged: { host.signal(gateway: .init(roomID: room, gateway: $0)) })
            try await host.register(service, token: token, lifetime: lifetime)
            let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
            let grant = try await service.subscribe(gateway: gateway, userID: user, token: token, deadline: .now + .seconds(30))
            let pump = try #require(await host.currentPump())
            #expect(try await service.activate(to: pump, descriptor: .init(identity: gateway, endpointReference: Data([1]),
                address: "127.0.0.1", port: 8443), userID: user, fence: grant.fence, token: token, deadline: .now + .seconds(30)))
            _ = try await nextHostDelivery(deliveries.stream)
            await source.commit(failFirstRead: failFirstRead)
            host.signal(room: room)
            let body = try #require(try await nextHostDelivery(deliveries.stream))
            if case .broadcast(let event) = body.payload {
                #expect(event.roomSequence == 1)
            } else { Issue.record("expected committed body after explicit recovery") }
            #expect(await source.failures == (failFirstRead ? 1 : 0))
            #expect(await service.consumedSequence() == 1)
            #expect(await source.readCount == (failFirstRead ? 2 : 1))
            await host.close()
            #expect(await host.currentPump() == nil)
            deliveries.continuation.finish()
        }
    }
}

private actor HostCheckSource: V2RoomSubscriptionSource {
    private enum Transient: Error { case unavailable }
    let room: RoomID; let owner: V2RoomDataOwner; let user: UserID
    private var head: UInt64 = 0
    private var failNext = false
    private(set) var failures = 0
    private(set) var readCount = 0
    private(set) var snapshotCount = 0
    init(room: RoomID, owner: V2RoomDataOwner, user: UserID) { self.room = room; self.owner = owner; self.user = user }
    func setHead(_ value: UInt64) { head = value }
    func commit(failFirstRead: Bool) { head = 1; failNext = failFirstRead }
    func snapshot(roomID: RoomID, owner: V2RoomDataOwner, trackedUserIDs: Set<UserID>) async throws -> V2RoomSubscriptionSourceSnapshot {
        snapshotCount += 1
        return .init(roomID: room, owner: self.owner, highWatermark: head,
            members: trackedUserIDs.map { .init(userID: $0, memberRevision: 0, authorized: true) })
    }
    func read(roomID: RoomID, owner: V2RoomDataOwner, afterRoomSequence: UInt64, trackedUserIDs: Set<UserID>, limit: Int) async throws -> V2RoomSubscriptionSourcePage {
        readCount += 1
        if failNext { failNext = false; failures += 1; throw Transient.unavailable }
        let records: [V2RoomSubscriptionSourceRecord] = afterRoomSequence == 0 && head == 1 ? [
            .init(event: .init(roomID: room, highWatermark: 1, sourceEventID: try EventID("event"), roomSequence: 1,
                projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 0),
                hasOnlineBody: true, membershipControl: nil, recipientPolicy: .currentAuthorized)
        ] : []
        return .init(roomID: room, owner: self.owner, afterRoomSequence: afterRoomSequence, highWatermark: head, records: records)
    }
}

private func nextHostDelivery(_ stream: AsyncStream<V2RoomSubscriptionDelivery>) async throws -> V2RoomSubscriptionDelivery? {
    try await withThrowingTaskGroup(of: V2RoomSubscriptionDelivery?.self) { group in
        group.addTask { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw HostDeliveryTimeout.expired
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}
private enum HostDeliveryTimeout: Error { case expired }
