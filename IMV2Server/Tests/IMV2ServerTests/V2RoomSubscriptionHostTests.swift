import Foundation
import Testing
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
@testable import IMV2Server

struct V2RoomSubscriptionHostTests {
    @Test(arguments: [false, true]) func shutdownSharesOneReceiptDeadlineAcrossRooms(alreadyExpired: Bool) async throws {
        try await withNativeSubscriptionTestHost { activations in
            let user = try UserID("user"), host = V2RoomSubscriptionHost()
            activations.own(host)
            let baselines = Mutex(0)
            let progress = Mutex((issued: [RoomID: UInt64](), invalidated: Set<RoomID>()))
            try await host.configure(sendBatch: { batch, _, _ in
                if batch.deliveries.contains(where: { $0.payload == .authorizationInvalidated }) {
                    // A stopped peer rejects every terminal. Each room must
                    // retain responsibility, but must not restart the budget.
                    return .init(receipts: batch.deliveries.map { .init(fence: $0.fence, result: .stale) })
                }
                baselines.withLock { $0 += batch.deliveries.count }
                return .init(receipts: batch.deliveries.map {
                    .init(fence: $0.fence, result: .appliedThrough($0.deliverySequence))
                })
            }, maximumCalls: 1)
            let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
            let pump = try #require(await host.currentPump())
            for index in 0..<8 {
                let room = try RoomID("shutdown-room-\(index)")
                let (token, lifetime) = try await activations.activate(room)
                let source = HostCheckSource(room: room, owner: token.owner, user: user)
                let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room, owner: token.owner,
                    activation: token, deadline: .now + .seconds(3), trackedUserIDs: [],
                    observeAuthorization: { update, _ in
                        progress.withLock { state in
                            state.issued[room] = update.issued
                            if update.invalidated { state.invalidated.insert(room) }
                        }
                    })
                try await host.register(owner, token: token, lifetime: lifetime)
                let grant = try await owner.subscribe(gateway: gateway, userID: user, token: token, deadline: .now + .seconds(3))
                try #require(try await owner.activate(to: pump, descriptor: .init(identity: gateway,
                    endpointReference: Data([1]), address: "127.0.0.1", port: 8443), userID: user,
                    fence: grant.fence, token: token, deadline: .now + .seconds(3)))
            }
            let ready = ContinuousClock.now + .seconds(3)
            while baselines.withLock({ $0 }) < 8 {
                try #require(.now < ready); try await Task.sleep(for: .milliseconds(1))
            }
            let issued = progress.withLock { $0.issued }
            let started = ContinuousClock.now
            await host.close(deadline: alreadyExpired ? started : started + .milliseconds(100))
            if alreadyExpired {
                let final = progress.withLock { $0 }
                #expect(issued.count == 8)
                #expect(final.invalidated == Set(issued.keys))
                #expect(final.issued == issued)
            }
            #expect(started.duration(to: .now) < .seconds(1))
            #expect(await host.currentPump() == nil)
            #expect(await pump.snapshot().actualCalls == 0)
        }
    }

    @Test func oneCompletedRoomCanDeliverWhileAnotherRoomReadIsHeld() async throws {
        try await withNativeSubscriptionTestHost { activations in
            let host = V2RoomSubscriptionHost()
            activations.own(host)
            let gate = HostReadOrder()
            let bodies = Mutex<Set<RoomID>>([])
            let authorizedRooms = Mutex<Set<RoomID>>([])
            try await host.configure(sendBatch: { batch, _, _ in
                var receipts: [V2RoomSubscriptionFence: UInt64] = [:]
                for delivery in batch.deliveries {
                    if delivery.payload.isAuthorizationControl {
                        _ = authorizedRooms.withLock { $0.insert(delivery.fence.roomID) }
                    }
                    if case .broadcast = delivery.payload {
                        _ = bodies.withLock { $0.insert(delivery.fence.roomID) }
                    }
                    receipts[delivery.fence] = delivery.deliverySequence
                }
                return .init(receipts: receipts.map { .init(fence: $0.key, result: .appliedThrough($0.value)) })
            }, maximumCalls: 2)
            let pump = try #require(await host.currentPump())
            let user = try UserID("user")
            let identity = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "realtime", incarnationID: UUID())
            let descriptor = V2GatewayRealtimeDescriptor(identity: identity, endpointReference: Data([1]),
                                                         address: "127.0.0.1", port: 8443)
            var sources: [HostCheckSource] = []
            do {
                for index in 0..<3 {
                    let room = try RoomID("room-wake-\(index)")
                    let (token, lifetime) = try await activations.activate(room)
                    let source = HostCheckSource(room: room, owner: token.owner, user: user)
                    let owner = try await V2RoomSubscriptionOwner.restore(source: source, roomID: room,
                        owner: token.owner, activation: token, deadline: .now + .seconds(10), trackedUserIDs: [],
                        notifyChanged: { host.signal(gateway: .init(roomID: room, gateway: $0)) })
                    try await host.register(owner, token: token, lifetime: lifetime)
                    if index > 0 {
                        let grant = try await owner.subscribe(gateway: identity, userID: user, token: token,
                                                              deadline: .now + .seconds(10))
                        try #require(try await owner.activate(to: pump, descriptor: descriptor, userID: user,
                            fence: grant.fence, token: token, deadline: .now + .seconds(10)))
                    }
                    sources.append(source)
                }
                let deadline = ContinuousClock.now + .seconds(5)
                while true {
                    let state = await pump.snapshot()
                    if authorizedRooms.withLock({ $0.count }) == 2, state.actualCalls == 0,
                       state.activeRoomPrefixes == 0, state.queuedRooms == 0 { break }
                    try #require(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(1))
                }
                for source in sources { await source.holdReads(with: gate); await source.setHead(1) }
                // The first reader has no subscription. Holding it places the
                // next two rooms in the same captured Host batch in either order.
                host.signal(room: sources[0].room)
                while await gate.rooms.count != 1 {
                    try #require(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(1))
                }
                host.signal(room: sources[1].room); host.signal(room: sources[2].room)
                await gate.releaseOne()
                while await gate.rooms.count < 3 {
                    try #require(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(1))
                }
                let readyRoom = await gate.rooms[1]
                while !bodies.withLock({ $0.contains(readyRoom) }) {
                    try #require(ContinuousClock.now < deadline, "ready room waited behind an independent held database read")
                    try await Task.sleep(for: .milliseconds(1))
                }
                let blockedRoom = await gate.rooms[2]
                #expect(!bodies.withLock { $0.contains(blockedRoom) })
                await gate.finish(); await host.close()
            } catch {
                await gate.finish(); await host.close()
                throw error
            }
        }
    }

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

private actor HostReadOrder {
    private(set) var rooms: [RoomID] = []
    private var held: CheckedContinuation<Void, Never>?
    private var closed = false
    func enter(_ room: RoomID) async {
        rooms.append(room)
        if !closed && (rooms.count == 1 || rooms.count == 3) {
            await withCheckedContinuation { held = $0 }
        }
    }
    func releaseOne() { held?.resume(); held = nil }
    func finish() { closed = true; releaseOne() }
}

private actor HostCheckSource: V2RoomSubscriptionSource {
    private enum Transient: Error { case unavailable }
    let room: RoomID; let owner: V2RoomDataOwner; let user: UserID
    private var head: UInt64 = 0
    private var readGate: HostReadOrder?
    func holdReads(with order: HostReadOrder) { readGate = order }
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
        if let readGate { await readGate.enter(roomID) }
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
