import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerApplication

@Suite("Room delivery pump peer isolation")
struct V2RoomSubscriptionDeliveryPumpTests {
    @Test(arguments: ["duplicate", "missing", "foreign"])
    func malformedSharedReceiptsRetainEveryRoom(mode: String) async throws {
        let user = UserID(uuid: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "malformed", serviceID: "gateway", incarnationID: UUID())
        let requested = Mutex<Set<RoomID>>([])
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1,
            sendBatch: { batch, _, _ in
                let first = batch.deliveries[0]
                let receipt = V2RoomSubscriptionBatchReceipt(fence: first.fence,
                    result: .appliedThrough(first.deliverySequence))
                if mode == "missing" { return .init(receipts: [receipt]) }
                let foreign = V2RoomSubscriptionFence(activation: first.fence.activation,
                    subscriptionID: UUID(), generation: first.fence.generation,
                    baselineSequence: first.fence.baselineSequence)
                return .init(receipts: [receipt, .init(fence: mode == "duplicate" ? first.fence : foreign,
                    result: .appliedThrough(first.deliverySequence))])
            }, requestBaseline: { key, _ in requested.withLock { $0.insert(key.roomID) } })
        var relays: [V2RoomSubscriptionRelay] = []
        for _ in 0..<2 {
            let room = RoomID(uuid: UUID())
            let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0),
                activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
            let relay = try V2RoomSubscriptionRelay(activation: activation, baselineSequence: 0,
                members: [.init(userID: user, memberRevision: 0)])
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
                operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0,
                    subscriptionID: UUID(), generation: 1)))
            #expect(await pump.bind(.init(roomID: room, gateway: gateway), relay: relay,
                descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999),
                sourceShardID: "rooms"))
            relays.append(relay)
        }
        await pump.start()
        do { try await waitUntil { requested.withLock { $0.count == 2 } } }
        catch { await pump.close(); throw error }
        for relay in relays { #expect(await relay.pending(for: gateway).count == 1) }
        await pump.close()
    }

    @Test func perBindingRetirementJoinsHeldSharedCallAndPreservesReplacement() async throws {
        let user = UserID(uuid: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "joined", serviceID: "gateway", incarnationID: UUID())
        let descriptor = V2GatewayRealtimeDescriptor(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999)
        let held = HeldSharedBatch()
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1,
            sendBatch: { batch, _, _ in await held.send(batch) }, requestBaseline: { _, _ in })
        var relays: [V2RoomSubscriptionRelay] = [], keys: [V2RoomSubscriptionDeliveryPump.Key] = []
        for _ in 0..<2 {
            let room = RoomID(uuid: UUID())
            let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0),
                activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
            let relay = try V2RoomSubscriptionRelay(activation: activation, baselineSequence: 0,
                members: [.init(userID: user, memberRevision: 0)])
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
                operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0, subscriptionID: UUID(), generation: 1)))
            let key = V2RoomSubscriptionDeliveryPump.Key(roomID: room, gateway: gateway)
            #expect(await pump.bind(key, relay: relay, descriptor: descriptor, sourceShardID: "rooms"))
            relays.append(relay); keys.append(key)
        }
        let oldFence = try #require(await relays[0].status(for: gateway)).fence
        await pump.start()
        try await waitUntil { await held.started }
        #expect(await held.rooms == Set(keys.map(\.roomID)))
        let joined = Mutex(false)
        let firstKey = keys[0]
        let retirement = Task { await pump.unbindAndJoin(firstKey, expectedFence: oldFence); joined.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!joined.withLock { $0 })
        #expect(await pump.snapshot().actualCalls == 1)
        #expect(!(await pump.bind(firstKey, relay: relays[0], descriptor: descriptor, sourceShardID: "rooms")))
        await held.release()
        await retirement.value
        #expect(joined.withLock { $0 })
        #expect(await held.cancelled == false)
        #expect(await relays[1].pending(for: gateway).isEmpty)
        #expect(await relays[0].pending(for: gateway).count == 1)
        try await relays[0].offer(.init(ownerEpoch: 0, inputSequence: 2,
            operation: .reset(gateway: gateway, subscriptionID: UUID(), generation: 2)))
        let replacement = try #require(await relays[0].status(for: gateway)).fence
        #expect(await pump.bind(firstKey, relay: relays[0], descriptor: descriptor, sourceShardID: "rooms"))
        // An old retirement cannot remove this newer exact installation.
        await pump.unbindAndJoin(firstKey, expectedFence: oldFence)
        await pump.signal(firstKey)
        try await waitUntil { await held.fences.contains(replacement) }
        await pump.unbindAndJoin(firstKey, expectedFence: replacement)
        await pump.close()
    }
    private actor HeldSharedBatch {
        var started = false
        var rooms: Set<RoomID> = []
        var fences: Set<V2RoomSubscriptionFence> = []
        var cancelled = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        func send(_ batch: V2RoomSubscriptionDeliveryBatch) async -> V2RoomSubscriptionBatchResult {
            rooms = Set(batch.deliveries.map { $0.fence.roomID }); started = true
            fences.formUnion(batch.deliveries.map(\.fence))
            if !released { await withCheckedContinuation { waiter = $0 } }
            cancelled = Task.isCancelled
            var checkpoints: [V2RoomSubscriptionFence: UInt64] = [:]
            for item in batch.deliveries { checkpoints[item.fence] = item.deliverySequence }
            return .init(receipts: checkpoints.map { .init(fence: $0.key, result: .appliedThrough($0.value)) })
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @Test func failedMultiRoomBatchOwnsOneRetryAndCloseJoinsIt() async throws {
        enum LostReply: Error { case lost }
        let user = UserID(uuid: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "retry", serviceID: "gateway", incarnationID: UUID())
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1,
            sendBatch: { _, _, _ in throw LostReply.lost },
            requestBaseline: { _, _ in Issue.record("Transport loss is not a stale authority") })
        var relays: [V2RoomSubscriptionRelay] = []
        for _ in 0..<32 {
            let room = RoomID(uuid: UUID())
            let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0),
                activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
            let relay = try V2RoomSubscriptionRelay(activation: activation, baselineSequence: 0,
                members: [.init(userID: user, memberRevision: 0)])
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
                operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0,
                    subscriptionID: UUID(), generation: 1)))
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2,
                operation: .event(.init(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()),
                    roomSequence: 1, projectionKind: "message", payload: Data([1]), recipientUserIDs: [user]))))
            let accepted = await pump.bind(.init(roomID: room, gateway: gateway), relay: relay,
                descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999), sourceShardID: "rooms")
            #expect(accepted)
            relays.append(relay)
        }
        await pump.start()
        var failure: (any Error)?
        do { try await waitUntil { let pressure = await pump.snapshot(); return pressure.retryGroups == 2 && pressure.actualCalls == 0 } }
        catch { failure = error }
        let pressure = await pump.snapshot()
        #expect(pressure.retryGroups == 2)
        #expect(pressure.queuedRooms == 64)
        // A retry delays dispatch; it must not reject another room installation.
        let newRoom = RoomID(uuid: UUID())
        let newActivation = try V2RoomActivationToken(roomID: newRoom, owner: .init(shardID: "rooms", epoch: 0),
            activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
        let newRelay = try V2RoomSubscriptionRelay(activation: newActivation, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)])
        try await newRelay.offer(.init(ownerEpoch: 0, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0,
                subscriptionID: UUID(), generation: 1)))
        #expect(await pump.bind(.init(roomID: newRoom, gateway: gateway), relay: newRelay,
            descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999),
            sourceShardID: "rooms"))
        let withNewRoom = await pump.snapshot()
        #expect(withNewRoom.actualCalls == 0 && withNewRoom.retryGroups == 2)
        #expect(withNewRoom.queuedRooms >= 65)
        await pump.close()
        let closed = await pump.snapshot()
        #expect(closed.retryGroups == 0 && closed.actualCalls == 0 && closed.queuedRooms == 0 && closed.activeRoomPrefixes == 0)
        for relay in relays { #expect(await relay.pending(for: gateway).count == 2) }
        if let failure { throw failure }
    }

    @Test func multipleRoomsShareOneCallWithoutMixingSourceShards() async throws {
        let user = UserID(uuid: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "shared", serviceID: "gateway", incarnationID: UUID())
        let transport = MultiRoomTransport()
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 2, maximumBatchItems: 8,
            sendBatch: { batch, shard, _ in await transport.send(batch, shard: shard) },
            requestBaseline: { _, _ in Issue.record("Unexpected baseline request") })
        var relays: [V2RoomSubscriptionRelay] = []
        for index in 0..<4 {
            let room = RoomID(uuid: UUID()), shard = index < 2 ? "a" : "b"
            let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: shard, epoch: 0),
                activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
            let relay = try V2RoomSubscriptionRelay(activation: activation, baselineSequence: 0,
                members: [.init(userID: user, memberRevision: 0)])
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
                operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0,
                    subscriptionID: UUID(), generation: 1)))
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2,
                operation: .event(.init(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()),
                    roomSequence: 1, projectionKind: "message", payload: Data([1]), recipientUserIDs: [user]))))
            let accepted = await pump.bind(.init(roomID: room, gateway: gateway), relay: relay,
                descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999),
                sourceShardID: shard)
            #expect(accepted)
            relays.append(relay)
        }
        await pump.start()
        let ownedRelays = relays
        var failure: (any Error)?
        do {
            try await waitUntil {
                for relay in ownedRelays { if !(await relay.pending(for: gateway)).isEmpty { return false } }
                return true
            }
        } catch { failure = error }
        await pump.close()
        let calls = await transport.calls
        #expect(calls.count == 4)
        #expect(Set(calls.map(\.shard)) == ["a", "b"])
        for call in calls {
            #expect(call.batch.deliveries.count == 2)
            #expect(Set(call.batch.deliveries.map { $0.fence.roomID }).count == 2)
            #expect(call.batch.deliveries.allSatisfy { $0.fence.activation.owner.shardID == call.shard })
        }
        if let failure { throw failure }
    }

    private actor MultiRoomTransport {
        struct Call: Sendable { let batch: V2RoomSubscriptionDeliveryBatch; let shard: String }
        var calls: [Call] = []
        func send(_ batch: V2RoomSubscriptionDeliveryBatch, shard: String) -> V2RoomSubscriptionBatchResult {
            calls.append(.init(batch: batch, shard: shard))
            var checkpoints: [V2RoomSubscriptionFence: UInt64] = [:]
            for delivery in batch.deliveries { checkpoints[delivery.fence] = delivery.deliverySequence }
            return .init(receipts: checkpoints.map { .init(fence: $0.key, result: .appliedThrough($0.value)) })
        }
    }

    @Test func boundedBatchesAcknowledgeContinuousPrefix() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "batch", serviceID: "gateway", incarnationID: UUID())
        let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0),
            activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
        let relay = try V2RoomSubscriptionRelay(activation: activation, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)])
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1,
            operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0,
                subscriptionID: UUID(), generation: 1)))
        for sequence in 1...32 {
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: UInt64(sequence + 1),
                operation: .event(.init(roomID: room, highWatermark: UInt64(sequence), sourceEventID: EventID(uuid: UUID()),
                    roomSequence: UInt64(sequence), projectionKind: "message", payload: Data([1]), recipientUserIDs: [user]))))
        }
        let transport = BatchTransport()
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 2, maximumBatchItems: 8,
            sendBatch: { batch, _, _ in await transport.send(batch) },
            requestBaseline: { _, _ in Issue.record("Unexpected baseline request") })
        let accepted = await pump.bind(.init(roomID: room, gateway: gateway), relay: relay,
            descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999), sourceShardID: "rooms")
        #expect(accepted)
        await pump.start()
        var failure: (any Error)?
        do { try await waitUntil { await relay.pending(for: gateway).isEmpty } }
        catch { failure = error }
        await pump.close()
        let sizes = await transport.sizes
        let controls = await transport.controls
        #expect(sizes.sorted() == [1, 8, 8, 8, 8])
        #expect(controls.sorted() == Array(UInt64(1)...UInt64(33)))
        if let failure { throw failure }
    }

    private actor BatchTransport {
        var sizes: [Int] = []
        var controls: [UInt64] = []
        func send(_ batch: V2RoomSubscriptionDeliveryBatch) -> V2RoomSubscriptionBatchResult {
            sizes.append(batch.deliveries.count)
            controls.append(contentsOf: batch.deliveries.map(\.deliverySequence))
            let last = batch.deliveries.last!
            return .init(receipts: [.init(fence: last.fence, result: .appliedThrough(last.deliverySequence))])
        }
    }

    @Test func slowPeerDoesNotRetainFastPeerWork() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let slow = V2GatewayRealtimeIdentity(nodeID: "slow", serviceID: "gateway", incarnationID: UUID())
        let fast = V2GatewayRealtimeIdentity(nodeID: "fast", serviceID: "gateway", incarnationID: UUID())
        let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0),
            activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
        let relay = try V2RoomSubscriptionRelay(activation: activation, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)])
        for (index, gateway) in [slow, fast].enumerated() {
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: UInt64(index + 1),
                operation: .subscribe(gateway: gateway, userID: user, memberRevision: 0,
                    subscriptionID: UUID(), generation: 1)))
        }
        let transport = HeldTransport()
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 2,
            send: { delivery, _, target in await transport.send(delivery, target: target.identity) },
            requestBaseline: { _, _ in Issue.record("Unexpected baseline request") })
        for gateway in [slow, fast] {
            let accepted = await pump.bind(.init(roomID: room, gateway: gateway), relay: relay,
                descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999),
                sourceShardID: "rooms")
            #expect(accepted)
        }
        await pump.start()
        var failure: (any Error)?
        do {
            try await waitUntil {
                let held = await transport.slowHeld
                let count = await transport.fastCount
                return held && count >= 1
            }
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 3,
                operation: .event(.init(roomID: room, highWatermark: 1, sourceEventID: EventID(uuid: UUID()),
                    roomSequence: 1, projectionKind: "message", payload: Data([1]),
                    recipientUserIDs: [user]))))
            await pump.signal(.init(roomID: room, gateway: fast))
            await pump.signal(.init(roomID: room, gateway: slow))
            try await waitUntil { await transport.fastCount == 2 }
            #expect(await transport.slowHeld)
            try await waitUntil { await relay.pending(for: fast).isEmpty }
            #expect(await relay.pending(for: slow).count == 2)
        } catch { failure = error }
        await transport.release()
        await pump.close()
        #expect(await transport.active == 0)
        if let failure { throw failure }
    }

    @Test func heldMessageDoesNotBlockRevokeOrRetireBodyViaControlReceipt() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "isolated", serviceID: "gateway", incarnationID: UUID())
        let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0),
            activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
        let relay = try V2RoomSubscriptionRelay(activation: activation, baselineSequence: 0,
            members: [.init(userID: user, memberRevision: 0)])
        try await relay.offer(.init(ownerEpoch: 0, inputSequence: 1, operation: .subscribe(gateway: gateway,
            userID: user, memberRevision: 0, subscriptionID: UUID(), generation: 1)))
        let transport = HeldMessageTransport()
        let pump = V2RoomSubscriptionDeliveryPump(maximumCalls: 1,
            send: { delivery, _, _ in await transport.send(delivery) }, requestBaseline: { _, _ in
                Issue.record("Body pressure cannot request an authorization baseline")
            })
        #expect(await pump.bind(.init(roomID: room, gateway: gateway), relay: relay,
            descriptor: .init(identity: gateway, endpointReference: Data([1]), address: "127.0.0.1", port: 9999), sourceShardID: "rooms"))
        await pump.start()
        var failure: (any Error)?
        do {
            try await waitUntil { await relay.pending(for: gateway).isEmpty }
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 2, operation: .event(.init(roomID: room,
                highWatermark: 1, sourceEventID: EventID(uuid: UUID()), roomSequence: 1,
                projectionKind: "message", payload: Data([1]), recipientUserIDs: [user]))))
            await pump.signal(.init(roomID: room, gateway: gateway))
            try await waitUntil { await transport.messageHeld }
            try await relay.offer(.init(ownerEpoch: 0, inputSequence: 3,
                operation: .membership(userID: user, revision: 1, authorized: false)))
            await pump.signal(.init(roomID: room, gateway: gateway))
            try await waitUntil { await transport.revokeReceived }
            try await waitUntil { await relay.pending(for: gateway, lane: .authorization).isEmpty }
            #expect(await transport.messageHeld)
            #expect(await relay.pending(for: gateway, lane: .message).count == 1)
        } catch { failure = error }
        await transport.release()
        await pump.close()
        if let failure { throw failure }
    }
    private actor HeldMessageTransport {
        var messageHeld = false
        var revokeReceived = false
        var waiter: CheckedContinuation<Void, Never>?
        func send(_ delivery: V2RoomSubscriptionDelivery) async -> V2RoomSubscriptionDeliveryResult {
            if !delivery.payload.isAuthorizationControl {
                messageHeld = true
                await withCheckedContinuation { waiter = $0 }
                messageHeld = false
            }
            if case .revoke = delivery.payload { revokeReceived = true }
            return .appliedThrough(delivery.deliverySequence)
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    private enum Timeout: Error { case expired }
    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard .now < deadline else { throw Timeout.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private actor HeldTransport {
        var heldCalls = 0
        var slowHeld: Bool { heldCalls > 0 }
        var fastCount = 0
        var active = 0
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func send(_ delivery: V2RoomSubscriptionDelivery, target: V2GatewayRealtimeIdentity) async -> V2RoomSubscriptionDeliveryResult {
            active += 1
            defer { active -= 1 }
            if target.nodeID == "slow", !released {
                heldCalls += 1
                await withCheckedContinuation { waiters.append($0) }
                heldCalls -= 1
            } else if target.nodeID == "fast" { fastCount += 1 }
            return .appliedThrough(delivery.deliverySequence)
        }
        func release() {
            released = true
            let owned = waiters; waiters.removeAll()
            for waiter in owned { waiter.resume() }
        }
    }
}
