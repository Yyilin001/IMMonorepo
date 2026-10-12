import Foundation
import Synchronization
import Testing
import NIOCore
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
@testable import IMV2ServerGateway

@Suite("Real Registry room-local subscription sockets", .timeLimit(.minutes(1)))
struct V2GatewayRoomSubscriptionRegistryTests {
    @Test("last-reference retirement frees capacity even after failed activation", arguments: [false, true])
    func retiredRoomDoesNotConsumeActiveCapacity(failFirstActivation: Bool) async throws {
        let f = try RegistryFixture(), nextRoom = RoomID(uuid: UUID())
        let nextToken = V2RoomActivationToken(roomID: nextRoom, owner: f.fence.activation.owner,
            activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host)
        let nextFence = V2RoomSubscriptionFence(activation: nextToken, subscriptionID: UUID(),
            generation: 1, baselineSequence: 10)
        let extraFences = (0..<98).map { _ -> V2RoomSubscriptionFence in
            let room = RoomID(uuid: UUID())
            let token = V2RoomActivationToken(roomID: room, owner: f.fence.activation.owner,
                activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host)
            return .init(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 10)
        }
        let fences = Dictionary(uniqueKeysWithValues: ([f.fence, nextFence] + extraFences).map { ($0.roomID, $0) })
        let resets = Mutex(0)
        let authority = V2GatewayRoomSubscriptionAuthority(maximumRooms: 1)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, maximumRooms: 1,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            .granted(.init(fence: fences[command.roomID]!, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 20_000))
        }, reset: { command, _, _ in
            resets.withLock { $0 += 1 }
            let fresh = V2RoomSubscriptionFence(activation: command.expectedFence.activation,
                subscriptionID: UUID(), generation: command.expectedFence.generation + 1, baselineSequence: 10)
            return .granted(.init(fence: fresh, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 20_000))
        }, renewBatch: { _, _, _ in [] },
        activate: { command, _, _ in
            if failFirstActivation && command.roomID == f.room { return .failure(.unavailable) }
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence,
                deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumRelations: 1, maximumReferences: 1)
        do {
            let first = UUID()
            if failFirstActivation {
                do {
                    _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: first)
                    Issue.record("Failed activation returned a grant")
                } catch V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable) { }
            } else {
                _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: first)
                await coordinator.release(reference: first)
            }
            let second = UUID()
            let grant = try await coordinator.acquire(roomID: nextRoom, userID: f.user, reference: second)
            #expect(grant.fence == nextFence)
            #expect(await authority.renewalCheckpoint(fence: nextFence, serviceID: "owner") == 1)
            await coordinator.release(reference: second)
            for fence in extraFences {
                let reference = UUID()
                let fresh = try await coordinator.acquire(roomID: fence.roomID, userID: f.user, reference: reference)
                #expect(fresh.fence.generation == 2)
                #expect(!(await ingress.install(fence: fence, sourceShardID: "rooms",
                    serviceID: "owner", deadline: .now + .seconds(20))))
                await coordinator.release(reference: reference)
            }
            #expect(resets.withLock { $0 } == 98)
            await coordinator.shutdown()
        } catch { await coordinator.shutdown(); throw error }
    }

    @Test("Owner head including installation baseline reaches unopened member devices", arguments: [UInt64(10), 24])
    func unopenedRoomReceivesOwnerHead(head: UInt64) async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let first = try await f.socket(), second = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        _ = await ingress.applyRoomSubscription(f.delivery(2, .head(highWatermark: head)),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        try await waitUntil { first.writer.hints.contains(head) && second.writer.hints.contains(head) }
        #expect(first.writer.readyHeads.isEmpty && second.writer.readyHeads.isEmpty)
        #expect(first.writer.bodySequences.isEmpty && second.writer.bodySequences.isEmpty)
        try await first.stream.finish(); try await second.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("idle maintenance does not poll and acquiring a room arms its deadline")
    func idleMaintenanceDoesNotPoll() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), renewals = Mutex(0), clockReads = Mutex(0)
        let resets = Mutex(0)
        let replacement = V2RoomSubscriptionFence(activation: f.fence.activation,
            subscriptionID: UUID(), generation: f.fence.generation + 1, baselineSequence: 10)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clockReads.withLock { $0 += 1 }; return clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10, remainingLeaseMilliseconds: 10_000))
        }, reset: { command, _, _ in
            #expect(command.expectedFence == f.fence)
            resets.withLock { $0 += 1 }
            return .granted(.init(fence: replacement, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 10_000))
        },
        renewBatch: { _, requests, deadline in
            renewals.withLock { $0 += 1 }
            clock.withLock { $0 += .seconds(3) }
            #expect(clock.withLock { $0 } < deadline)
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: 11, remainingLeaseMilliseconds: 10_000)))) }
        }, activate: { command, _, _ in
            _ = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            requestTimeout: .seconds(5), now: { clockReads.withLock { $0 += 1 }; return clock.withLock { $0 } })
        await coordinator.start()
        let before = clockReads.withLock { $0 }
        try await Task.sleep(for: .milliseconds(250))
        #expect(clockReads.withLock { $0 } == before)
        let reference = UUID()
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: reference)
        let after = clockReads.withLock { $0 }
        try await Task.sleep(for: .milliseconds(250))
        #expect(clockReads.withLock { $0 } == after)
        #expect(renewals.withLock { $0 } == 0)
        #expect(resets.withLock { $0 } == 0)
        #expect(await authority.renewalCheckpoint(fence: f.fence, serviceID: "owner") == 1)
        await coordinator.release(reference: reference)
        #expect(await authority.renewalCheckpoint(fence: f.fence, serviceID: "owner") == nil)
        #expect(await ingress.applyRoomSubscription(f.delivery(2, .head(highWatermark: 12)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .stale)
        let resumed = UUID()
        let grant = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: resumed)
        #expect(grant.fence == replacement)
        #expect(resets.withLock { $0 } == 1)
        #expect(await authority.renewalCheckpoint(fence: replacement, serviceID: "owner") == 1)
        #expect(await ingress.applyRoomSubscription(f.delivery(3, .head(highWatermark: 99)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .stale)
        #expect(await authority.recoveryHighWatermark(roomID: f.room) == 10)
        await coordinator.release(reference: resumed)
        #expect(await authority.renewalCheckpoint(fence: replacement, serviceID: "owner") == nil)
        await coordinator.shutdown()
    }
    @Test("renewal starts early enough for a three-second response within its five-second budget")
    func renewalLeadCoversResponseBudget() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), renewals = Mutex(0)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10, remainingLeaseMilliseconds: 10_000))
        }, reset: { _, _, _ in Issue.record("An in-budget renewal must not require reset"); return .failure(.unavailable) },
        renewBatch: { _, requests, deadline in
            renewals.withLock { $0 += 1 }
            clock.withLock { $0 += .seconds(3) }
            #expect(clock.withLock { $0 } < deadline)
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: 11, remainingLeaseMilliseconds: 10_000)))) }
        }, activate: { command, _, _ in
            _ = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            requestTimeout: .seconds(5), now: { clock.withLock { $0 } })
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        clock.withLock { $0 += .seconds(5) }
        await coordinator.renewLeases()
        #expect(renewals.withLock { $0 } == 1)
        clock.withLock { $0 += .seconds(3) }
        #expect(await authority.renewalCheckpoint(fence: f.fence, serviceID: "owner") == 1)
        #expect(await authority.recoveryHighWatermark(roomID: f.room) == 11)
        await coordinator.shutdown()
    }
    @Test("a saturated peer defers only a bounded room quantum per admission")
    func saturatedPeerAdmissionHasBoundedWork() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), gate = RegistryRenewalGate()
        let reads = Mutex(0), renewedRooms = Mutex(Set<RoomID>())
        let fences = Dictionary(uniqueKeysWithValues: (0..<400).map { _ -> (RoomID, V2RoomSubscriptionFence) in
            let room = RoomID(uuid: UUID())
            let token = V2RoomActivationToken(roomID: room, owner: f.fence.activation.owner,
                activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host)
            return (room, .init(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 10))
        })
        let authority = V2GatewayRoomSubscriptionAuthority(maximumRooms: 400, now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, maximumRooms: 400, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            .granted(.init(fence: fences[command.roomID]!, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
            await gate.wait()
            renewedRooms.withLock { rooms in
                for request in requests { rooms.insert(request.activation.roomID) }
            }
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: 10, remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { command, _, _ in
            _ = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 4, now: { reads.withLock { $0 += 1 }; return clock.withLock { $0 } })
        for room in fences.keys { _ = try await coordinator.acquire(roomID: room, userID: f.user, reference: UUID()) }
        clock.withLock { $0 += .seconds(2) }
        let held = Task { await coordinator.renewLeases() }
        try await waitUntil { await gate.enteredCount == 2 }
        clock.withLock { $0 += .milliseconds(200) }
        reads.withLock { $0 = 0 }
        await coordinator.renewLeases()
        // With two calls held, one turn may examine at most 2 * 64 rooms.
        // The clock counts observable work without exposing private queues.
        #expect(reads.withLock { $0 } <= 130)
        #expect(await gate.enteredCount == 2)
        await coordinator.start()
        await gate.release()
        await held.value
        // Releasing peer capacity must drain deferred rooms without advancing time.
        try await waitUntil { renewedRooms.withLock { $0.count } == 400 }
        await coordinator.shutdown()
    }
    @Test("a held peer renewal cannot stop maintenance of another peer")
    func heldPeerDoesNotStopMaintenance() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), gate = RegistryRenewalGate()
        let room = RoomID(uuid: UUID())
        let peer = V2ActorHostIdentity(hostID: try .init("second-host"), incarnationID: UUID())
        let token = V2RoomActivationToken(roomID: room, owner: f.fence.activation.owner,
            activationEpoch: f.fence.activation.activationEpoch, host: peer)
        let second = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 10)
        let fences = [f.room: f.fence, room: second]
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let healthyRenewals = Mutex(0)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            .granted(.init(fence: fences[command.roomID]!, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { host, requests, _ in
            if host == f.fence.activation.host { await gate.wait() }
            else { healthyRenewals.withLock { $0 += 1 } }
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: 10, remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { command, _, _ in
            _ = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 4, now: { clock.withLock { $0 } })
        for room in fences.keys { _ = try await coordinator.acquire(roomID: room, userID: f.user, reference: UUID()) }
        clock.withLock { $0 += .seconds(2) }
        await coordinator.start()
        try await waitUntil { await gate.entered && healthyRenewals.withLock { $0 } == 1 }
        clock.withLock { $0 += .seconds(2) }
        // Advancing the injected clock does not advance ContinuousClock sleepers.
        await coordinator.renewLeases()
        for _ in 0..<100 {
            if healthyRenewals.withLock({ $0 >= 2 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(healthyRenewals.withLock { $0 } >= 2)
        #expect(await authority.renewalCheckpoint(fence: second, serviceID: "owner") == 1)
        await gate.release()
        await coordinator.shutdown()
    }
    @Test("a continuous cold queue cannot consume every lease-maintenance slot")
    func coldQueueDoesNotStarveRenewal() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), gate = RegistryRenewalGate()
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let coldFences = Dictionary(uniqueKeysWithValues: (0..<4).map { _ -> (RoomID, V2RoomSubscriptionFence) in
            let room = RoomID(uuid: UUID())
            let token = V2RoomActivationToken(roomID: room, owner: f.fence.activation.owner,
                activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host)
            return (room, .init(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 10))
        })
        let fences = coldFences.merging([f.room: f.fence]) { a, _ in a }
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let renewals = Mutex(0)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            if command.roomID != f.room { await gate.wait() }
            return .granted(.init(fence: fences[command.roomID]!, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
            renewals.withLock { $0 += 1 }
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: 10, remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { command, _, _ in
            _ = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 4, now: { clock.withLock { $0 } })
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        clock.withLock { $0 += .seconds(2) }
        let cold = coldFences.keys.map { room in Task {
            try await coordinator.acquire(roomID: room, userID: f.user, reference: UUID())
        } }
        try await waitUntil { await gate.enteredCount >= 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await gate.enteredCount == 2)
        await coordinator.renewLeases()
        #expect(renewals.withLock { $0 } == 1)
        clock.withLock { $0 += .seconds(2) }
        #expect(await authority.renewalCheckpoint(fence: f.fence, serviceID: "owner") == 1)
        await gate.release()
        for task in cold { _ = try await task.value }
        await coordinator.shutdown()
    }
    @Test("an admitted cold subscription waits behind renewal and retires safely if closed", arguments: [false, true])
    func coldSubscriptionWaitsForMaintenanceCallSlot(closeWhileWaiting: Bool) async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), gate = RegistryRenewalGate()
        let room = RoomID(uuid: UUID())
        let token = V2RoomActivationToken(roomID: room, owner: f.fence.activation.owner,
            activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host)
        let second = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 10)
        let fences = [f.room: f.fence, room: second]
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let settled = Mutex(false), subscribes = Mutex(0)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            subscribes.withLock { $0 += 1 }
            return .granted(.init(fence: fences[command.roomID]!, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
            await gate.wait()
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: 10, remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { command, _, _ in
            _ = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 1, now: { clock.withLock { $0 } })
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        clock.withLock { $0 += .seconds(2) }
        let renewing = Task { await coordinator.renewLeases() }
        try await waitUntil { await gate.entered }
        let cold = Task {
            defer { settled.withLock { $0 = true } }
            return try await coordinator.acquire(roomID: room, userID: f.user, reference: UUID())
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!settled.withLock { $0 })
        let stopping: Task<Void, Never>?
        if closeWhileWaiting {
            stopping = Task { await coordinator.shutdown() }
            try await Task.sleep(for: .milliseconds(10))
        } else { stopping = nil }
        await gate.release(); await renewing.value
        if closeWhileWaiting {
            do { _ = try await cold.value; Issue.record("closed acquisition must be superseded") }
            catch V2GatewayRoomSubscriptionCoordinationError.superseded {}
            catch { Issue.record("unexpected cold acquisition failure: \(error)") }
            await stopping?.value
            #expect(subscribes.withLock { $0 } == 1)
        } else {
            #expect(try await cold.value.fence == second)
            #expect(subscribes.withLock { $0 } == 2)
            await coordinator.shutdown()
        }
    }
    @Test("one peer uses two bounded renewal calls and retains excess rooms for the next pass")
    func samePeerRenewalsUseEveryAvailableCallSlot() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let fences = Dictionary(uniqueKeysWithValues: (0..<129).map { _ -> (RoomID, V2RoomSubscriptionFence) in
            let room = RoomID(uuid: UUID())
            let token = V2RoomActivationToken(roomID: room, owner: f.fence.activation.owner,
                activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host)
            return (room, .init(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 10))
        })
        let batches = Mutex<[Int]>([])
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            .granted(.init(fence: fences[command.roomID]!, memberRevision: 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
            batches.withLock { $0.append(requests.count) }
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: 10, remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { command, _, _ in
            _ = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 3, now: { clock.withLock { $0 } })
        for room in fences.keys { _ = try await coordinator.acquire(roomID: room, userID: f.user, reference: UUID()) }
        clock.withLock { $0 += .seconds(2) }
        await coordinator.renewLeases()
        #expect(batches.withLock { $0.sorted() } == [64, 64])
        clock.withLock { $0 += .milliseconds(100) }
        await coordinator.renewLeases()
        #expect(batches.withLock { $0.sorted() } == [1, 64, 64])
        clock.withLock { $0 += .seconds(2) }
        // All old grants would be expired here if a call slot went unused.
        for fence in fences.values {
            #expect(await authority.renewalCheckpoint(fence: fence, serviceID: "owner") == 1)
        }
        await coordinator.shutdown()
    }
    @Test("normalized SQL topic locates the same local account scope and wire ID")
    func sqlTopicAndLocalCoverageUseSameScopeIdentity() throws {
        let user = try UserID("EED841A8-28BD-5C9D-8BDC-896DAEDCF9A3"), connection = UUID()
        let sql = V2RealtimeTopicKey(kind: .userSync, id: user.rawValue)
        let local = V2RealtimeRecoveryKey(connection: connection, kind: .userSync, id: user.rawValue)
        let incoming = V2RealtimeRecoveryKey(connection: connection, kind: .userSync, id: sql.id)
        #expect(local == incoming && incoming.id == user.rawValue)
        #expect(incoming.wireScope == .account)
    }

    @Test("ordinary broadcast uses controlled membership for all online devices")
    func broadcastUsesControlledMembers() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let requested = try await f.socket(), unrelated = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        #expect(await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        _ = try await f.registry.subscribeForegroundRoom(requested.stream, connectionID: requested.connectionID, roomID: f.room)
        let event = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 11, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 11, projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 0)
        #expect(await ingress.applyRoomSubscription(f.delivery(2, .broadcast(event)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        try await waitUntil { requested.writer.bodySequences == [11] }
        #expect(requested.writer.bodySequences == [11])
        try await waitUntil { unrelated.writer.bodySequences == [11] }
        #expect(unrelated.writer.bodySequences == [11])
        #expect(await ingress.applyRoomSubscription(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 0)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(3))
        let after = V2RealtimeRoomEvent(roomID: f.room, highWatermark: 12, sourceEventID: EventID(uuid: UUID()),
            roomSequence: 12, projectionKind: "message", payload: Data([1]), recipientUserIDs: [], groupMembershipRevision: 1)
        #expect(await ingress.applyRoomSubscription(f.delivery(4, authorization: 2, .broadcast(after)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(4))
        try await waitUntil { requested.writer.bodySequences == [11] }
        #expect(requested.writer.bodySequences == [11])
        try await requested.stream.finish(); try await unrelated.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("production Journal user control receiver does not attach room viewer authority")
    func journalUserControlDoesNotClaimRooms() async throws {
        let f = try RegistryFixture()
        let receiver = V2GatewayJournalProjectionReceiver(projection: .init())
        await f.registry.configureJournalUserControlReceiver(receiver)
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        #expect(await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        _ = try await f.registry.subscribeForegroundRoom(socket.stream, connectionID: socket.connectionID, roomID: f.room)
        try await waitUntil { socket.writer.readyHeads == [10] }
        await f.registry.applySharedRealtimeDelivery(.init(topic: .init(kind: .roomEvents, id: f.room.rawValue,
            owner: f.fence.activation.owner), partitionID: 1, partitionEpoch: 1, sessionID: UUID(),
            interestGeneration: 1, gatewayIncarnation: UUID(), payload: .roomWake(roomID: f.room, highWatermark: 999)),
            isCurrent: { true })
        #expect(await ingress.applyRoomSubscription(f.delivery(2, .event(f.event(11), members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        try await waitUntil { socket.writer.bodySequences == [11] }
        #expect(socket.writer.bodySequences == [11])
        let permit = try #require(await f.authority.capturePermits(roomID: f.room).first)
        socket.stream.invalidateForegroundAuthorization()
        let accepted = await f.authority.enqueueFixtureIfCurrent(permit, enqueue: {})
        #expect(!accepted)
        try await socket.stream.finish(); await f.registry.shutdownRealtimeRecovery()
    }

    @Test("shutdown revokes the local proof and joins a held renewal before bounded unsubscribe")
    func shutdownJoinsHeldSharedRenewal() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), gate = RegistryRenewalGate()
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let finished = Mutex(false), unsubscribed = Mutex(0)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in .granted(.init(fence: f.fence, memberRevision: 0,
            userBaselineSequence: 10, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
            await gate.wait()
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: request.command.expectedFence.baselineSequence,
                remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { _, _, _ in
            _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return .activated
        }, unsubscribe: { _, _, _ in unsubscribed.withLock { $0 += 1 }; return .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 1, now: { clock.withLock { $0 } })
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        clock.withLock { $0 = $0 + .seconds(2) }
        let renewal = Task { await coordinator.renewLeases() }
        try await waitUntil { await gate.entered }
        let shutdown = Task { await coordinator.shutdown(); finished.withLock { $0 = true } }
        try await waitUntil { await authority.renewalCheckpoint(fence: f.fence, serviceID: "owner") == nil }
        #expect(!finished.withLock { $0 })
        #expect(unsubscribed.withLock { $0 } == 0)
        await gate.release(); await renewal.value; await shutdown.value
        #expect(finished.withLock { $0 })
        #expect(unsubscribed.withLock { $0 } == 1)
        #expect(await coordinator.relationCount == 0)
        await coordinator.shutdown()
    }

    @Test("multiple users share one room renewal and multiple rooms share one peer batch")
    func sharedRoomRenewalBatchesByPeer() async throws {
        let first = try RegistryFixture(), second = try RegistryFixture(), other = UserID(uuid: UUID())
        let fences = [first.room: first.fence, second.room: second.fence]
        let clock = Mutex(ContinuousClock.now)
        let authority = V2GatewayRoomSubscriptionAuthority(now: { clock.withLock { $0 } })
        let ingress = V2GatewayRoomSubscriptionIngress(authority: authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let counts = Mutex((subscribes: 0, renewBatches: 0, renewedRooms: [RoomID]()))
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            counts.withLock { $0.subscribes += 1 }
            return .granted(.init(fence: fences[command.roomID]!, memberRevision: command.actorUserID == other ? 3 : 0,
                userBaselineSequence: 10, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
            counts.withLock { $0.renewBatches += 1; $0.renewedRooms.append(contentsOf: requests.map { $0.command.roomID }) }
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: request.command.expectedFence.baselineSequence,
                remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { command, _, _ in
            let members: [V2RoomSubscriptionMember] = command.roomID == first.room
                ? [first.member, .init(userID: other, memberRevision: 3)] : [second.member]
            let applied = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: members)), authenticatedServiceID: "owner", sourceShardID: "rooms")
            return applied == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 1, now: { clock.withLock { $0 } })
        let a = UUID(), b = UUID(), c = UUID(), newDevice = UUID()
        _ = try await coordinator.acquire(roomID: first.room, userID: first.user, reference: a)
        _ = try await coordinator.acquire(roomID: first.room, userID: other, reference: b)
        _ = try await coordinator.acquire(roomID: second.room, userID: second.user, reference: c)
        clock.withLock { $0 = $0 + .seconds(2) }
        await coordinator.renewLeases()
        #expect(counts.withLock { $0.renewBatches } == 1)
        #expect(Set(counts.withLock { $0.renewedRooms }) == [first.room, second.room])
        #expect(counts.withLock { $0.subscribes } == 3)
        clock.withLock { $0 = $0 + .seconds(2) }
        let renewedDevice = try await coordinator.acquire(roomID: first.room, userID: first.user, reference: newDevice)
        #expect(renewedDevice.memberRevision == 0)
        #expect(counts.withLock { $0.subscribes } == 3)
        await coordinator.release(reference: a); await coordinator.release(reference: b)
        await coordinator.release(reference: c); await coordinator.release(reference: newDevice)
        await coordinator.shutdown()
    }

    @Test("warm renewal reuses the confirmed route; explicit stale resolves once again")
    func warmRenewalAvoidsPhysicalResolution() async throws {
        let f = try RegistryFixture()
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let clock = Mutex(ContinuousClock.now)
        let counts = Mutex((resolves: 0, subscribes: 0, renews: 0, rejectOnce: false))
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway,
            resolve: { _, _ in
                counts.withLock { $0.resolves += 1 }
                return .init(activation: f.fence.activation, authenticatedServiceID: "owner")
            }, subscribe: { _, _, _ in
                counts.withLock { $0.subscribes += 1 }
                return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10,
                    remainingLeaseMilliseconds: 3_000))
            }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
                let stale = counts.withLock { value in
                    value.renews += 1; let reject = value.rejectOnce; value.rejectOnce = false; return reject
                }
                return requests.map { request in
                    .init(activation: request.activation, result: .result(stale ? .failure(.stale) : .renewed(.init(
                        fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: request.command.expectedFence.baselineSequence,
                        remainingLeaseMilliseconds: 3_000))))
                }
            }, activate: { _, _, _ in
                _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
                    authenticatedServiceID: "owner", sourceShardID: "rooms")
                return .activated
            }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            now: { clock.withLock { $0 } })
        let reference = UUID()
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: reference)
        clock.withLock { $0 = $0 + .seconds(2) }
        await coordinator.renewLeases()
        #expect(counts.withLock { $0.resolves } == 1)
        #expect(counts.withLock { $0.subscribes } == 1)
        #expect(counts.withLock { $0.renews } == 1)
        counts.withLock { $0.rejectOnce = true }
        clock.withLock { $0 = $0 + .seconds(2) }
        await coordinator.renewLeases()
        clock.withLock { $0 = $0 + .seconds(1) }
        await coordinator.renewLeases()
        #expect(counts.withLock { $0.resolves } == 2)
        #expect(counts.withLock { $0.subscribes } == 2)
        await coordinator.release(reference: reference)
        await coordinator.shutdown()
    }

    @Test("typed stale and uncertain renewal failures recover through bounded Directory confirmation",
        arguments: [V2RoomCallFailure.rolledBack(.staleActivation), .notAccepted(.retired),
            .notAccepted(.authorityLost), .notAccepted(.notReady), .outcomeUnknown], [false, true])
    func typedRouteRecovery(failure: V2RoomCallFailure, partialFailure: Bool) async throws {
        let f = try RegistryFixture(), other = UserID(uuid: UUID())
        let replacement = V2RoomSubscriptionFence(activation: .init(roomID: f.room,
            owner: f.fence.activation.owner, activationEpoch: try .init(2),
            host: .init(hostID: f.fence.activation.host.hostID, incarnationID: UUID())),
            subscriptionID: UUID(), generation: 1, baselineSequence: 12)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, offerEvent: { _, _ in }, offerHead: { _, _ in })
        let clock = Mutex(ContinuousClock.now)
        let state = Mutex((resolves: 0, inject: false, failed: false, activations: [V2RoomSubscriptionFence](), replacementUsers: Set<UserID>(), partialFailed: false))
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            let changed = state.withLock { value in value.resolves += 1; return value.failed }
            return .init(activation: changed ? replacement.activation : f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, token, _ in
            let reject = state.withLock { value in
                if value.inject && token == f.fence.activation { value.failed = true; return true }
                return false
            }
            if reject { throw failure }
            if token == replacement.activation {
                let refuse = state.withLock { value in
                    if partialFailure && command.actorUserID == other && !value.partialFailed {
                        value.partialFailed = true
                        return true
                    }
                    value.replacementUsers.insert(command.actorUserID)
                    return false
                }
                if refuse { return .failure(.unavailable) }
            }
            let fence = token == replacement.activation ? replacement : f.fence
            return .granted(.init(fence: fence, memberRevision: command.actorUserID == other ? 3 : 0,
                userBaselineSequence: fence.baselineSequence, remainingLeaseMilliseconds: 3_000))
        }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
            let inject = state.withLock { value in
                if value.inject { value.failed = true; return true }; return false
            }
            if inject { throw failure }
            return requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: request.command.expectedFence.baselineSequence,
                remainingLeaseMilliseconds: 3_000)))) }
        }, activate: { command, _, _ in
            state.withLock { $0.activations.append(command.fence) }
            let applied = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [f.member, .init(userID: other, memberRevision: 3)])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            #expect(applied == .appliedThrough(1))
            return .activated
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            now: { clock.withLock { $0 } })
        let firstReference = UUID(), secondReference = UUID()
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: firstReference)
        _ = try await coordinator.acquire(roomID: f.room, userID: other, reference: secondReference)
        state.withLock { $0.inject = true }
        clock.withLock { $0 = $0 + .seconds(2) }
        await coordinator.renewLeases()
        #expect(state.withLock { $0.resolves } == 1)
        clock.withLock { $0 = $0 + .seconds(1) }
        await coordinator.renewLeases()
        #expect(state.withLock { $0.resolves } == 2)
        if partialFailure {
            #expect(state.withLock { $0.partialFailed })
            #expect(!state.withLock { $0.replacementUsers.contains(other) })
            // An uncertain first rebuild can retain a second backoff step.
            clock.withLock { $0 = $0 + .seconds(2) }
            await coordinator.renewLeases()
        }
        #expect(state.withLock { $0.activations.last } == replacement)
        // Assert before acquire: reading cached receipts must not repair missing registrations.
        #expect(state.withLock { $0.replacementUsers } == Set([f.user, other]))
        let first = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: firstReference)
        let second = try await coordinator.acquire(roomID: f.room, userID: other, reference: secondReference)
        #expect(first.fence == replacement && second.fence == replacement)
        #expect(first.memberRevision == 0 && second.memberRevision == 3)
        #expect(await ingress.applyRoomSubscription(f.delivery(2, .revoke(userID: other, memberRevision: 4)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") != .appliedThrough(2))
        await coordinator.release(reference: firstReference)
        await coordinator.release(reference: secondReference)
        await coordinator.shutdown()
    }

    @Test("lost batch ACK accepts its cached prefix without repeating actual socket bodies")
    func batchRetryDoesNotRefanout() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        _ = try await f.registry.subscribeForegroundRoom(socket.stream, connectionID: socket.connectionID, roomID: f.room)
        let batch = V2RoomSubscriptionDeliveryBatch(deliveries: [
            f.delivery(1, .baseline(members: [f.member])),
            f.delivery(2, .event(f.event(11), members: [f.member])),
            f.delivery(3, .event(f.event(12), members: [f.member]))])
        let expected = V2RoomSubscriptionBatchResult(receipts: [.init(fence: f.fence, result: .appliedThrough(3))])
        #expect(await ingress.applyRoomSubscriptionBatch(batch, authenticatedServiceID: "owner", sourceShardID: "rooms") == expected)
        try await waitUntil { socket.writer.bodySequences == [11, 12] }
        #expect(socket.writer.bodySequences == [11, 12])
        #expect(await ingress.applyRoomSubscriptionBatch(batch, authenticatedServiceID: "owner", sourceShardID: "rooms") == expected)
        try await waitUntil { socket.writer.bodySequences == [11, 12] }
        #expect(socket.writer.bodySequences == [11, 12])
        let conflict = V2RoomSubscriptionDeliveryBatch(deliveries: [f.delivery(2, .revoke(userID: f.user, memberRevision: 0))])
        #expect(await ingress.applyRoomSubscriptionBatch(conflict, authenticatedServiceID: "owner", sourceShardID: "rooms").receipts.first?.result == .stale)
        try await socket.stream.finish(); await f.registry.shutdownRealtimeRecovery()
    }

    @Test("injected two-phase port shares user relation and retires only the last device")
    func sharedSignedSubscriptionPort() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let counts = Mutex((subscribes: 0, activates: 0, unsubscribes: 0))
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway-service",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway,
            resolve: { _, _ in .init(activation: f.fence.activation, authenticatedServiceID: "owner") },
            subscribe: { _, _, _ in
                counts.withLock { $0.subscribes += 1 }
                return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10,
                    remainingLeaseMilliseconds: 20_000))
            }, reset: { _, _, _ in .failure(.unavailable) }, renewBatch: { _, requests, _ in
                requests.map { request in .init(activation: request.activation, result: .result(.renewed(.init(
                    fence: request.command.expectedFence, appliedControlSequence: request.command.appliedControlSequence,
                committedRoomSequence: request.command.expectedFence.baselineSequence,
                    remainingLeaseMilliseconds: 20_000)))) }
            },
            activate: { _, _, _ in
                counts.withLock { $0.activates += 1 }
                let result = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
                    authenticatedServiceID: "owner", sourceShardID: "rooms")
                return result == .appliedThrough(1) ? .activated : .failure(.stale)
            }, unsubscribe: { _, _, _ in
                counts.withLock { $0.unsubscribes += 1 }; return .unsubscribed
            })
        try await f.registry.configureRoomSubscriptionPorts(ports, ingress: ingress)
        do {
            try await f.registry.acquireAccountRoomDelivery(userID: f.user, roomID: f.room, reference: UUID())
            Issue.record("A user without physical connections cannot acquire delivery")
        } catch V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable) {
            // Expected transient gap before account ticket cleanup.
        } catch {
            Issue.record("Expected online unavailability, received \(error)")
        }
        #expect(counts.withLock { $0.subscribes } == 0)
        let first = try await f.socket(), second = try await f.socket()
        _ = try await f.registry.subscribeForegroundRoom(first.stream, connectionID: first.connectionID, roomID: f.room)
        _ = try await f.registry.subscribeForegroundRoom(second.stream, connectionID: second.connectionID, roomID: f.room)
        try await waitUntil { first.writer.readyHeads == [10] && second.writer.readyHeads == [10] }
        #expect(counts.withLock { $0.subscribes } == 1)
        #expect(counts.withLock { $0.activates } == 1)
        // A later device reuses the account grant without another Owner baseline.
        // It must still recover an unopened room before another message arrives.
        let later = try await f.socket(), accountReference = UUID()
        try await f.registry.acquireAccountRoomDelivery(userID: f.user, roomID: f.room, reference: accountReference)
        try await waitUntil { later.writer.hints.contains(10) }
        #expect(later.writer.readyHeads.isEmpty)
        #expect(counts.withLock { $0.subscribes } == 1)
        #expect(counts.withLock { $0.activates } == 1)
        await f.registry.releaseAccountRoomDelivery(reference: accountReference)
        try await later.stream.finish()
        await f.registry.unsubscribeForegroundGroup(connectionID: first.connectionID, roomID: f.room)
        #expect(counts.withLock { $0.unsubscribes } == 0)
        await f.registry.unsubscribeForegroundGroup(connectionID: second.connectionID, roomID: f.room)
        #expect(counts.withLock { $0.unsubscribes } == 1)
        try await first.stream.finish(); try await second.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("all online devices receive room bodies; detail Ready S is independent of later H and Journal")
    func requestedDeviceAndIndependentReady() async throws {
        let f = try RegistryFixture()
        await f.registry.configureRealtimeCoverageValidation(current: { _, _ in nil }, confirms: { _, _, _ in false })
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let first = try await f.socket(), second = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        #expect(await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        _ = try await f.registry.subscribeForegroundRoom(first.stream, connectionID: first.connectionID, roomID: f.room)
        try await waitUntil { first.writer.readyHeads == [10] }
        #expect(second.writer.readyHeads.isEmpty)
        #expect(await ingress.applyRoomSubscription(f.delivery(2, .event(f.event(11), members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        try await waitUntil { first.writer.bodySequences == [11] }
        #expect(first.writer.bodySequences == [11])
        try await waitUntil { second.writer.bodySequences == [11] }
        #expect(second.writer.bodySequences == [11])
        #expect(await ingress.applyRoomSubscription(f.delivery(3, .head(highWatermark: 60)), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(3))
        try await waitUntil { first.writer.hints.contains(60) }
        #expect(first.writer.readyHeads == [10])
        // Adding a second requesting device does not replace the first gate.
        _ = try await f.registry.subscribeForegroundRoom(second.stream, connectionID: second.connectionID, roomID: f.room)
        try await waitUntil { second.writer.readyHeads == [10] }
        #expect(await ingress.applyRoomSubscription(f.delivery(4, .event(f.event(12), members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(4))
        try await waitUntil { first.writer.bodySequences == [11, 12] }
        #expect(first.writer.bodySequences == [11, 12])
        try await waitUntil { second.writer.bodySequences == [11, 12] }
        #expect(second.writer.bodySequences == [11, 12])
        #expect(first.writer.readyHeads == [10])
        try await first.stream.finish(); try await second.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("a slow Ready owner is independent; membership revoke rejects its delayed actual socket enqueue")
    func delayedReadyCannotOutliveRevocation() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let first = try await f.socket(holdReady: true), second = try await f.socket(), unopened = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        #expect(await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        _ = try await f.registry.subscribeForegroundRoom(first.stream, connectionID: first.connectionID, roomID: f.room)
        _ = try await f.registry.subscribeForegroundRoom(second.stream, connectionID: second.connectionID, roomID: f.room)
        try await waitUntil {
            let holding = await first.writer.isHoldingReady
            return holding && second.writer.readyHeads == [10]
        }
        #expect(first.writer.readyHeads.isEmpty)
        #expect(await ingress.applyRoomSubscription(f.delivery(2, .head(highWatermark: 24)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        try await waitUntil { unopened.writer.hints.contains(24) }
        #expect(await first.writer.isHoldingReady)
        #expect(unopened.writer.readyHeads.isEmpty)
        #expect(await ingress.applyRoomSubscription(f.delivery(3, authorization: 2, .revoke(userID: f.user, memberRevision: 1)), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(3))
        await first.writer.release()
        try await waitUntil { await first.writer.rejectedReady }
        #expect(first.writer.readyHeads.isEmpty)
        try await first.stream.finish(); try await second.stream.finish(); try await unopened.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("an expired socket permit retains H until a fresh trusted offer wakes it")
    func retainedHeadWaitsForFreshPermit() async throws {
        let f = try RegistryFixture(), socket = try await f.socket(holdReady: true)
        let lifecycle = UUID()
        await f.authority.registerFixtureConnection(socket.connectionID, userID: f.user, lifecycle: lifecycle, eventLoop: socket.writer.eventLoop)
        try #require(await f.authority.registerRoomInterest(connectionID: socket.connectionID,
            lifecycle: lifecycle, roomID: f.room, scopeGeneration: 1))
        try #require(await f.authority.install(fence: f.fence, serviceID: "owner", deadline: .now + .seconds(20)))
        _ = await f.authority.apply(f.delivery(1, .baseline(members: [f.member])), authenticatedServiceID: "owner")
        let authorization = try #require(await f.authority.capturePermits(roomID: f.room).first)
        let valid = Mutex(true)
        let gate: @Sendable (@Sendable () -> Void) -> Bool = { enqueue in
            guard valid.withLock({ $0 }) else { return false }
            return f.authority.enqueueIfCurrent(authorization, enqueue: enqueue)
        }
        let offered = await socket.stream.offerRoomSubscriptionHead(authorization, highWatermark: 99, permit: gate)
        #expect(offered)
        try await waitUntil { await socket.writer.isHoldingReady }
        valid.withLock { $0 = false }
        await socket.writer.release()
        try await waitUntil { await socket.writer.rejectedReady }
        #expect(socket.writer.hints.isEmpty)
        valid.withLock { $0 = true }
        let reoffered = await socket.stream.offerRoomSubscriptionHead(authorization, highWatermark: 11, permit: gate)
        #expect(reoffered)
        try await waitUntil { socket.writer.hints.contains(99) }
        #expect(socket.writer.readyHeads == [10])
        let sentCount = socket.writer.hints.filter { $0 == 99 }.count
        let repeated = await socket.stream.offerRoomSubscriptionHead(authorization, highWatermark: 99, permit: gate)
        #expect(repeated)
        let advanced = await socket.stream.offerRoomSubscriptionHead(authorization, highWatermark: 100, permit: gate)
        #expect(advanced)
        try await waitUntil { socket.writer.hints.contains(100) }
        // The advanced frame settles the same persistent writer after the
        // repeated offer; already admitted H=99 must not be sent again.
        #expect(socket.writer.hints.filter { $0 == 99 }.count == sentCount)
        #expect(socket.writer.readyHeads == [10])
        try await socket.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("heartbeat exchanges authoritative H and device-local C without granting or renewing")
    func heartbeatProgressIsConnectionLocal() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let first = try await f.socket(), second = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        _ = try await f.registry.subscribeForegroundRoom(first.stream, connectionID: first.connectionID, roomID: f.room)
        _ = try await f.registry.subscribeForegroundRoom(second.stream, connectionID: second.connectionID, roomID: f.room)
        _ = await ingress.applyRoomSubscription(f.delivery(2, .head(highWatermark: 24)),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        try await waitUntil { first.writer.readyHeads == [10] && second.writer.readyHeads == [10] }
        func exchange(_ socket: RegistrySocket, id: UInt64, reports: [IMV2GroupEventProgress] = []) async throws -> [IMV2GroupEventProgressState] {
            var request = IMV2Envelope(); request.requestID = id
            request.protocolVersion = IMV2ProtocolVersion.current
            request.heartbeat.clientTimeMs = 1; request.heartbeat.roomProgress = reports
            let encoded = try V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(request,
                frameVersion: UInt8(IMV2ProtocolVersion.current)), limits: f.limits)
            let responses = try await socket.stream.receive(encoded)
            let bytes = try #require(responses.first)
            return try V2ServerProtobufFrameCodec.decode(V2FrameCodec.decodeExactlyOne(bytes, limits: f.limits))
                .heartbeatAck.roomSubscriptionStates
        }
        let initial = try #require(try await exchange(first, id: 3).first)
        #expect(initial.highWatermark == 24)
        #expect(initial.appliedRoomSequence == 0) // G is never C.
        #expect(initial.ready)
        var report = IMV2GroupEventProgress(); report.roomID = f.room.rawValue
        report.scopeGeneration = initial.scopeGeneration; report.appliedRoomSequence = 20
        let accepted = try #require(try await exchange(first, id: 4, reports: [report]).first)
        #expect(accepted.appliedRoomSequence == 20)
        let peer = try #require(try await exchange(second, id: 3).first)
        #expect(peer.appliedRoomSequence == 0)
        report.appliedRoomSequence = 19
        let regressed = try #require(try await exchange(first, id: 5, reports: [report]).first)
        #expect(regressed.appliedRoomSequence == 20)
        report.appliedRoomSequence = 99
        let future = try #require(try await exchange(first, id: 6, reports: [report]).first)
        #expect(future.appliedRoomSequence == 20)
        report.scopeGeneration += 1; report.appliedRoomSequence = 24
        let stale = try #require(try await exchange(first, id: 7, reports: [report]).first)
        #expect(stale.appliedRoomSequence == 20)
        #expect(stale.scopeGeneration == initial.scopeGeneration)
        _ = await ingress.applyRoomSubscription(f.delivery(4, .head(highWatermark: 30)),
            authenticatedServiceID: "owner", sourceShardID: "rooms") // Control gap fails closed.
        let denied = try await exchange(first, id: 8, reports: [report])
        #expect(!denied.isEmpty)
        #expect(await f.authority.renewalCheckpoint(fence: f.fence, serviceID: "owner") == 1)
        try await first.stream.finish(); try await second.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("heartbeat progress cannot query multiple or malformed room scopes")
    func heartbeatRejectsUnboundedProgress() async throws {
        let f = try RegistryFixture(), socket = try await f.socket()
        var progress = IMV2GroupEventProgress(); progress.roomID = f.room.rawValue
        progress.scopeGeneration = 1
        var request = IMV2Envelope(); request.requestID = 3
        request.protocolVersion = IMV2ProtocolVersion.current
        request.heartbeat.roomProgress = [progress, progress]
        let encoded = try V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(request,
            frameVersion: UInt8(IMV2ProtocolVersion.current)), limits: f.limits)
        await #expect(throws: V2GatewaySessionError.unsupportedCommand) {
            _ = try await socket.stream.receive(encoded)
        }
        try await socket.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("signed terminal control rejects delayed actual socket enqueue without an H increase")
    func terminalControlRetiresRealSocket() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket(holdReady: true)
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        _ = try await f.registry.subscribeForegroundRoom(socket.stream, connectionID: socket.connectionID, roomID: f.room)
        try await waitUntil { await socket.writer.isHoldingReady }
        let terminal = f.delivery(2, .authorizationInvalidated)
        #expect(await ingress.applyRoomSubscription(terminal, authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        #expect(await f.authority.recoveryHighWatermark(roomID: f.room) == 10)
        await socket.writer.release()
        try await waitUntil { await socket.writer.rejectedReady }
        #expect(socket.writer.readyHeads.isEmpty)
        #expect(socket.writer.hints.isEmpty)
        #expect(await socket.stream.exchangeRoomProgress(.init()).isEmpty)
        #expect(await ingress.applyRoomSubscription(terminal, authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        #expect(await f.authority.capturePermits(roomID: f.room).isEmpty)
        let refused = await ingress.renew(fence: f.fence, sourceShardID: "rooms", serviceID: "owner",
            appliedControlSequence: 2, deadline: .now + .seconds(30))
        #expect(!refused)
        try await socket.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("local room unsubscribe closes detail scope while account delivery remains; connection revoke precedes slow close")
    func unsubscribeAndImmediateConnectionFence() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let first = try await f.socket(), second = try await f.socket()
        try #require(await ingress.install(fence: f.fence, sourceShardID: "rooms", serviceID: "owner", deadline: .now + .seconds(20)))
        #expect(await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(1))
        _ = try await f.registry.subscribeForegroundRoom(first.stream, connectionID: first.connectionID, roomID: f.room)
        _ = try await f.registry.subscribeForegroundRoom(second.stream, connectionID: second.connectionID, roomID: f.room)
        let old = try #require(await f.authority.capturePermits(roomID: f.room).first { $0.connectionID == first.connectionID })
        await f.registry.unsubscribeForegroundGroup(connectionID: first.connectionID, roomID: f.room)
        let stillCurrent = await f.authority.enqueueFixtureIfCurrent(old, enqueue: {})
        #expect(!stillCurrent)
        #expect(await ingress.applyRoomSubscription(f.delivery(2, .event(f.event(11), members: [f.member])), authenticatedServiceID: "owner", sourceShardID: "rooms") == .appliedThrough(2))
        try await waitUntil { first.writer.bodySequences == [11] }
        #expect(first.writer.bodySequences == [11])
        try await waitUntil { second.writer.bodySequences == [11] }
        #expect(second.writer.bodySequences == [11])
        _ = try await f.registry.subscribeForegroundRoom(first.stream, connectionID: first.connectionID, roomID: f.room)
        let fresh = try #require(await f.authority.capturePermits(roomID: f.room).first { $0.connectionID == first.connectionID })
        let resurrected = await f.authority.enqueueFixtureIfCurrent(old, enqueue: {})
        #expect(!resurrected)
        // This is the same immediate path used before any transport close await.
        first.stream.revokeRecoveryWorkImmediately()
        let closedPermit = await f.authority.enqueueFixtureIfCurrent(fresh, enqueue: {})
        #expect(!closedPermit)
        #expect(await f.authority.capturePermits(roomID: f.room).allSatisfy { $0.connectionID == second.connectionID })
        try await first.stream.finish(); try await second.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw RegistryFixtureError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum RegistryFixtureError: Error { case timeout }
private struct RegistryFixture: Sendable {
    let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
    let authority = V2GatewayRoomSubscriptionAuthority()
    let registry: V2DeviceConnectionRegistry
    let limits: V2FrameLimits
    let subscriptionID = UUID()
    init() throws {
        limits = try .init(maximumPayloadBytes: 16_384, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)])
        registry = V2DeviceConnectionRegistry(foregroundFrameLimits: limits)
    }
    var fence: V2RoomSubscriptionFence {
        .init(activation: .init(roomID: room, owner: try! .init(shardID: "rooms", epoch: 0),
            activationEpoch: try! .init(1), host: .init(hostID: try! .init("registry-test-owner"),
                incarnationID: UUID(uuidString: "00000000-0000-0000-0000-00000000ac01")!)),
            subscriptionID: subscriptionID, generation: 1, baselineSequence: 10)
    }
    var member: V2RoomSubscriptionMember { .init(userID: user, memberRevision: 0) }
    func delivery(_ sequence: UInt64, authorization: UInt64? = nil, _ payload: V2RoomSubscriptionPayload) -> V2RoomSubscriptionDelivery {
        .init(fence: fence, deliverySequence: sequence, authorizationSequence: authorization ?? (payload.isAuthorizationControl ? sequence : 1), payload: payload)
    }
    func event(_ sequence: UInt64) -> V2RealtimeRoomEvent {
        .init(roomID: room, highWatermark: sequence, sourceEventID: EventID(uuid: UUID()), roomSequence: sequence,
            projectionKind: "message", payload: Data([1]), recipientUserIDs: [user])
    }
    func socket(holdReady: Bool = false) async throws -> RegistrySocket {
        let device = DeviceID(uuid: UUID()), connection = UUID(), writer = RegistrySocketWriter(holdReady: holdReady)
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                authenticator: RegistrySocketAuthenticator(user: user), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: RegistrySocketHandler(), connectionID: connection, registry: registry)
        let transport = try await V2GatewayForegroundChannelFixture(record: { [weak writer] in writer?.record($0) })
        writer.installForeground(transport)
        let attached = await stream.attachFixtureTransport(deviceRevocationHandler: {}, outboundWriter: { _ in },
            requiredNotificationWriter: { _ in true }, scopedNotificationWriter: { await writer.write($0) },
            foregroundWriter: transport.writer)
        try #require(attached)
        let version = UInt8(IMV2ProtocolVersion.current)
        var hello = IMV2Envelope(); hello.requestID = 1; hello.clientHello.deviceID = device.rawValue
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]; hello.clientHello.supportedCapabilityProfiles = ["base"]
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
        var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = device.rawValue
        _ = try await stream.receive(V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
        return .init(stream: stream, connectionID: connection, writer: writer)
    }
}
private struct RegistrySocket: Sendable {
    let stream: V2GatewayByteStream
    let connectionID: UUID
    let writer: RegistrySocketWriter
}
private struct RegistrySocketAuthenticator: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: user, expiresAt: nil)
    }
}
private struct RegistrySocketHandler: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope { .init() }
}
private actor RegistrySocketWriter {
    private struct Output: Sendable {
        var ready: [UInt64] = []
        var hints: [UInt64] = []
        var bodies: [UInt64] = []
    }
    private nonisolated let output = Mutex(Output())
    nonisolated var readyHeads: [UInt64] { output.withLock { $0.ready } }
    nonisolated var hints: [UInt64] { output.withLock { $0.hints } }
    private nonisolated let foreground = Mutex<V2GatewayForegroundChannelFixture?>(nil)
    nonisolated var eventLoop: any EventLoop { foreground.withLock { $0!.channel.eventLoop } }
    nonisolated func installForeground(_ transport: V2GatewayForegroundChannelFixture) {
        foreground.withLock { $0 = transport }
    }
    nonisolated var bodySequences: [UInt64] {
        let transport = foreground.withLock { $0 }
        transport?.drain()
        return output.withLock { $0.bodies }
    }
    private let holdReady: Bool
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isHoldingReady = false
    private(set) var rejectedReady = false
    init(holdReady: Bool) { self.holdReady = holdReady }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func write(_ write: V2GatewayScopedNotificationWrite) async -> Bool {
        let envelope = Self.decode(write.bytes)
        let ready = envelope?.realtimeCoverage.state == .ready && envelope?.realtimeCoverage.scope == .room
        if ready, holdReady, !released {
            isHoldingReady = true; await withCheckedContinuation { continuation = $0 }
        }
        let accepted = write.enqueueIfCurrent { self.record(write.bytes) }
        if ready, !accepted { rejectedReady = true }
        return accepted
    }
    nonisolated func record(_ bytes: Data) {
        guard let envelope = Self.decode(bytes) else { return }
        output.withLock { value in
            switch envelope.body {
            case .realtimeCoverage(let state) where state.scope == .room && state.state == .ready:
                value.ready.append(state.highWatermark)
            case .groupEventAvailable(let event):
                if !event.eventPayload.isEmpty { value.bodies.append(event.roomSequence) }
                else { value.hints.append(event.highWatermark) }
            default: break
            }
        }
    }
    private nonisolated static func decode(_ bytes: Data) -> IMV2Envelope? {
        guard let limits = try? V2FrameLimits(maximumPayloadBytes: 16_384, acceptedVersions: [UInt8(IMV2ProtocolVersion.current)]) else { return nil }
        var decoder = V2FrameDecoder(limits: limits)
        guard let frame = try? decoder.append(bytes).first else { return nil }
        return try? V2ServerProtobufFrameCodec.decode(frame)
    }
}

private actor RegistryRenewalGate {
    private(set) var entered = false
    private(set) var enteredCount = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true; enteredCount += 1
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        let waiting = continuations; continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}
