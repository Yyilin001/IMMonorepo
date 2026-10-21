import Foundation
import Synchronization
import Testing
import NIOCore
import NIOPosix
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
@testable import IMV2ServerGateway

@Suite("Real Registry room-local subscription sockets", .timeLimit(.minutes(1)))
struct V2GatewayRoomSubscriptionRegistryTests {
    @Test("A fresh authority for an existing socket scope does not restart its Recovering predecessor")
    func authorityRefreshPreservesScopePredecessor() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket()
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
        _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        _ = try await f.registry.subscribeForegroundRoom(socket.stream, connectionID: socket.connectionID, roomID: f.room)
        try await waitUntil { socket.writer.readyHeads == [10] }
        let old = try #require(await f.authority.capturePermits(roomID: f.room).first)
        let recovering = socket.writer.recoveringGenerations.count
        let replacement = V2RoomSubscriptionFence(activation: f.fence.activation,
            subscriptionID: UUID(), generation: 2, baselineSequence: 20)
        try #require(await ingress.installTestSession(fence: replacement, sourceShardID: "rooms",
            serviceID: "owner", afterAuthoritativeReset: true))
        _ = await ingress.applyRoomSubscription(.init(fence: replacement, deliverySequence: 1,
            authorizationSequence: 1, payload: .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        try await waitUntil { socket.writer.readyHeads == [10, 20] }
        #expect(socket.writer.recoveringGenerations.count == recovering)
        #expect(!(await f.authority.enqueueFixtureIfCurrent(old, enqueue: {})))
        let current = try #require(await f.authority.capturePermits(roomID: f.room).first)
        #expect(current.scopeGeneration == old.scopeGeneration)
        #expect(await f.authority.enqueueFixtureIfCurrent(current, enqueue: {}))
        try await socket.stream.finish(); await f.registry.shutdownRealtimeRecovery()
    }

    @Test("Room progress demand repairs a retired session even when its notification was missed")
    func progressDemandRepairsMissedSessionNotification() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let session = V2RoomDeliverySession(host: f.fence.activation.host, gateway: gateway.identity, generation: 1)
        let nextSession = V2RoomDeliverySession(host: session.host, gateway: gateway.identity, generation: 2)
        let nextFence = V2RoomSubscriptionFence(activation: f.fence.activation,
            subscriptionID: UUID(), generation: 2, baselineSequence: 10)
        let resets = Mutex(0)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            if resets.withLock({ $0 }) == 0 {
                _ = f.authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner")
            }
            return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10, deliverySession: session))
        }, reset: { _, _, _ in
            resets.withLock { $0 += 1 }
            _ = await ingress.applyDeliverySession(.init(session: nextSession, kind: .open, sequence: 1), authenticatedServiceID: "owner")
            return .granted(.init(fence: nextFence, memberRevision: 0, userBaselineSequence: 10, deliverySession: nextSession))
        }, activate: { command, _, _ in
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence,
                deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        try await f.registry.configureRoomSubscriptionPorts(ports, ingress: ingress)
        let socket = try await f.socket()
        _ = try await f.registry.subscribeForegroundRoom(socket.stream, connectionID: socket.connectionID, roomID: f.room)
        try await waitUntil { socket.writer.readyHeads.count == 1 }
        // Retire the actual gate without the coordinator callback. Progress
        // observes the loss, and must wake the existing bounded repair owner.
        _ = f.authority.applyDeliverySession(.init(session: session, kind: .retire, sequence: 2), serviceID: "owner")
        #expect(await socket.stream.exchangeRoomProgress(.init()).isEmpty)
        do {
            let until = ContinuousClock.now + .seconds(2)
            while resets.withLock({ $0 }) == 0, ContinuousClock.now < until { await Task.yield() }
            try #require(resets.withLock { $0 } > 0)
            try await waitUntil { socket.writer.readyHeads.count == 2 }
            #expect(resets.withLock { $0 } == 1)
        } catch {
            try await socket.stream.finish(); await f.registry.shutdownRealtimeRecovery()
            throw error
        }
        try await socket.stream.finish(); await f.registry.shutdownRealtimeRecovery()
    }

    @Test("a suspended repair admission neither spins due-room timers nor escapes shutdown", arguments: [false, true])
    func suspendedRepairAdmissionOwnsItsWake(closeWhileHeld: Bool) async throws {
        let f = try RegistryFixture(), reads = Mutex(0), calls = Mutex<[RoomID: Int]>([:])
        let paused = Mutex(false), closed = Mutex(false)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let bToken = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: f.fence.activation.owner,
            activationEpoch: f.fence.activation.activationEpoch,
            host: .init(hostID: try .init("other-admission-host"), incarnationID: UUID()))
        let bFence = V2RoomSubscriptionFence(activation: bToken, subscriptionID: UUID(), generation: 1, baselineSequence: 10)
        let fences = [f.room: f.fence, bToken.roomID: bFence]
        let sessions = fences.mapValues { V2RoomDeliverySession(host: $0.activation.host, gateway: gateway.identity, generation: 1) }
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: fences[room]!.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            let count = calls.withLock { $0[command.roomID, default: 0] += 1; return $0[command.roomID]! }
            guard count == 1 else { return .failure(.unauthorized) }
            let session = sessions[command.roomID]!
            _ = f.authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner")
            return .granted(.init(fence: fences[command.roomID]!, memberRevision: 0,
                userBaselineSequence: 10, deliverySession: session))
        }, reset: { _, _, _ in .failure(.unauthorized) }, activate: { command, _, _ in
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence,
                deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 4, now: { reads.withLock { $0 += 1 }; return .now })
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        _ = try await coordinator.acquire(roomID: bToken.roomID, userID: f.user, reference: UUID())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), unblock = DispatchSemaphore(value: 0)
        do {
            let loop = group.next(), connection = UUID(), lifecycle = UUID()
            try #require(await f.authority.registerFixtureConnection(connection, userID: f.user,
                lifecycle: lifecycle, eventLoop: loop))
            try #require(await f.authority.registerRoomInterest(connectionID: connection,
                lifecycle: lifecycle, roomID: f.room, scopeGeneration: 1))
            try #require(await f.authority.capturePermits(roomID: f.room).count == 1)
            await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
                loop.execute { entered.resume(); unblock.wait() }
            }
            let pause = Task { _ = await f.authority.pause(fence: f.fence); paused.withLock { $0 = true } }
            try await Task.sleep(for: .milliseconds(50))
            #expect(!paused.withLock { $0 })
            _ = f.authority.applyDeliverySession(.init(session: sessions[f.room]!, kind: .retire, sequence: 2), serviceID: "owner")
            await coordinator.start()
            await coordinator.sessionChanged(host: f.fence.activation.host)
            let until = ContinuousClock.now + .seconds(2)
            while await coordinator.pendingRepairCount != 0, ContinuousClock.now < until { await Task.yield() }
            try #require(await coordinator.pendingRepairCount == 0)
            #expect(calls.withLock { $0[f.room] } == 1)
            _ = f.authority.applyDeliverySession(.init(session: sessions[bToken.roomID]!, kind: .retire, sequence: 2), serviceID: "owner")
            let before = reads.withLock { $0 }
            await coordinator.sessionChanged(host: bToken.host)
            try await Task.sleep(for: .milliseconds(100))
            let redundantPasses = reads.withLock { $0 - before }
            print("repair-admission now reads while suspended: \(redundantPasses)")
            #expect(redundantPasses < 32)
            let otherDeadline = ContinuousClock.now + .milliseconds(250)
            while calls.withLock({ $0[bToken.roomID, default: 0] }) < 2,
                  ContinuousClock.now < otherDeadline { await Task.yield() }
            #expect(calls.withLock { $0[bToken.roomID] } == 2)
            #expect(calls.withLock { $0[f.room] } == 1)
            if closeWhileHeld {
                let closing = Task { await coordinator.shutdown(); closed.withLock { $0 = true } }
                try await Task.sleep(for: .milliseconds(50))
                #expect(!closed.withLock { $0 })
                unblock.signal(); await pause.value; await closing.value
            } else {
                unblock.signal(); await pause.value
                await coordinator.shutdown()
            }
            await f.authority.shutdown(); try await group.shutdownGracefully()
        } catch {
            unblock.signal(); await coordinator.shutdown(); await f.authority.shutdown()
            try? await group.shutdownGracefully(); throw error
        }
    }

    @Test("late same-room cleanup cannot clear a successor scope's actual Ready", arguments: [false, true])
    func staleRoomEndPreservesSuccessor(endCurrent: Bool) async throws {
        let f = try RegistryFixture()
        _ = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket(), lifecycle = UUID()
        do {
            try #require(await f.authority.registerFixtureConnection(socket.connectionID, userID: f.user,
                lifecycle: lifecycle, eventLoop: socket.writer.eventLoop))
            try #require(await f.authority.registerRoomInterest(connectionID: socket.connectionID,
                lifecycle: lifecycle, roomID: f.room, scopeGeneration: 2))
            try #require(await f.authority.installTestSession(fence: f.fence, serviceID: "owner"))
            _ = await f.authority.apply(f.delivery(1, .baseline(members: [f.member])), authenticatedServiceID: "owner")
            let permit = try #require(await f.authority.capturePermits(roomID: f.room).first)
            await socket.stream.beginRoomSubscription(roomID: f.room, scopeGeneration: 2,
                permit: f.authority.interestPermit(connectionID: socket.connectionID, lifecycle: lifecycle,
                    roomID: f.room, generation: 2))
            try #require(await socket.stream.offerRoomSubscriptionHead(permit, highWatermark: 10,
                permit: { enqueue in f.authority.enqueueIfCurrent(permit, enqueue: enqueue) }))
            try await waitUntil { socket.writer.readyHeads == [10] }
            let before = await socket.stream.exchangeRoomProgress(IMV2Heartbeat())
            try #require(before.first?.ready == true)
            // The old scope's asynchronous cleanup may return after this new
            // Ready. Its room matches, but its exact scope generation does not.
            await socket.stream.endRoomSubscription(roomID: f.room, scopeGeneration: endCurrent ? 2 : 1)
            let after = await socket.stream.exchangeRoomProgress(IMV2Heartbeat())
            #expect(after.first?.ready == !endCurrent)
            #expect(after.first?.scopeGeneration == 2)
            #expect(socket.writer.readyHeads == [10])
        } catch {
            try? await socket.stream.finish(); await f.registry.shutdownRealtimeRecovery(); throw error
        }
        try await socket.stream.finish(); await f.registry.shutdownRealtimeRecovery()
    }

    @Test("last-room retirement joins the actual socket projection before reacquisition or shutdown", arguments: [0, 1, 2])
    func lastRoomRetirementBlocksReacquisition(mode: Int) async throws {
        let f = try RegistryFixture(), other = UserID(uuid: UUID())
        let calls = Mutex(0), releaseFinished = Mutex(false), shutdownFinished = Mutex(false)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let session = V2RoomDeliverySession(host: f.fence.activation.host, gateway: gateway.identity, generation: 1)
        let replacement = V2RoomSubscriptionFence(activation: f.fence.activation, subscriptionID: UUID(),
            generation: f.fence.generation + 1, baselineSequence: f.fence.baselineSequence)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            calls.withLock { $0 += 1 }
            _ = f.authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1), serviceID: "owner")
            return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10, deliverySession: session))
        }, reset: { _, _, _ in
            .granted(.init(fence: replacement, memberRevision: 0, userBaselineSequence: 10, deliverySession: session))
        }, activate: { command, _, _ in
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1,
                authorizationSequence: 1, payload: .baseline(members: [f.member, .init(userID: other, memberRevision: 0)])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress)
        let original = UUID()
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: original)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), unblock = DispatchSemaphore(value: 0)
        do {
            let loop = group.next(), connection = UUID(), lifecycle = UUID()
            let nextUser = mode == 1 ? other : f.user
            try #require(await f.authority.registerFixtureConnection(connection, userID: nextUser,
                lifecycle: lifecycle, eventLoop: loop))
            try #require(await f.authority.registerRoomInterest(connectionID: connection, lifecycle: lifecycle,
                roomID: f.room, scopeGeneration: 1))
            try #require(await f.authority.capturePermits(roomID: f.room).count == 1)
            await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
                loop.execute { entered.resume(); unblock.wait() }
            }
            let retiring = Task { await coordinator.release(reference: original); releaseFinished.withLock { $0 = true } }
            let until = ContinuousClock.now + .seconds(2)
            while await coordinator.relationCount != 0, ContinuousClock.now < until { await Task.yield() }
            #expect(await coordinator.relationCount == 0)
            #expect(!releaseFinished.withLock { $0 })
            if mode == 2 {
                let closing = Task { await coordinator.shutdown(); shutdownFinished.withLock { $0 = true } }
                try await Task.sleep(for: .milliseconds(100))
                #expect(!shutdownFinished.withLock { $0 })
                unblock.signal()
                await retiring.value; await closing.value
            } else {
                let next = Task { try await coordinator.acquire(roomID: f.room, userID: nextUser, reference: UUID()) }
                try await Task.sleep(for: .milliseconds(100))
                #expect(calls.withLock { $0 } == 1)
                unblock.signal()
                await retiring.value
                let grant = try await next.value
                #expect(grant.fence == replacement)
                #expect(calls.withLock { $0 } == 2)
                #expect(await f.authority.authorizationCheckpoint(fence: grant.fence, serviceID: "owner") != nil)
            }
            await coordinator.shutdown(); await f.authority.shutdown()
            try await group.shutdownGracefully()
        } catch {
            unblock.signal()
            await coordinator.shutdown(); await f.authority.shutdown()
            try? await group.shutdownGracefully()
            throw error
        }
    }
    @Test("a busy socket retains Recovering without probing its EventLoop permit on the stream actor")
    func busySocketRetainsRoomCoverage() async throws {
        let f = try RegistryFixture()
        let socket = try await f.socket(refuseFirstRecovering: true)
        let loop = socket.writer.eventLoop
        await socket.stream.sendRealtimeCoverage(scope: .room, scopeID: f.room.rawValue,
            scopeGeneration: 1, ready: false, reason: .installing, scopePermit: { enqueue in
                guard loop.inEventLoop else { return false }
                enqueue(); return true
            })
        let deadline = ContinuousClock.now + .seconds(2)
        while socket.writer.recoveringGenerations.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(socket.writer.recoveringGenerations == [1])
        #expect(socket.writer.readyHeads.isEmpty)
        try await socket.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }
    @Test("stage metrics distinguish a stalled activation from completed subscription and queue")
    func activationStageFailureMetrics() async throws {
        let f = try RegistryFixture(), probe = SubscriptionAdmissionProbe()
        let metrics = V2RoomSubscriptionHeadDeliveryMetrics()
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10,
                deliverySession: testDeliverySession(fence: f.fence, gateway: gateway.identity, authority: f.authority)))
        }, reset: { _, _, _ in .failure(.unauthorized) }, activate: { _, _, _ in
            await probe.hold()
            throw V2RoomCallFailure.outcomeUnknown
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress, metrics: metrics)
        let job = Task { try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID()) }
        await probe.waitForStart()
        let waiting = metrics.snapshot().phases[.foreground] ?? [:]
        #expect(waiting[.queue]?.active == 0)
        #expect(waiting[.subscribe]?.completed == 1)
        #expect(waiting[.install]?.completed == 1)
        #expect(waiting[.activate]?.active == 1)
        #expect(waiting[.slot]?.active == 1)
        await probe.release()
        do { _ = try await job.value; Issue.record("unknown activation outcome must remain an error") }
        catch V2RoomCallFailure.outcomeUnknown { }
        await coordinator.shutdown()
        let finished = metrics.snapshot().phases[.foreground] ?? [:]
        #expect(finished[.activate]?.outcomes[.outcomeUnknown] == 1)
        #expect(finished[.slot]?.outcomes[.outcomeUnknown] == 1)
        #expect(finished.values.allSatisfy { $0.active == 0 })
        await f.authority.shutdown()
    }
    @Test("foreground callers coalesce a fresh acquisition after shared session retirement", arguments: [false, true])
    func retiredSessionJoinsFreshAcquisition(backgroundRepair: Bool) async throws {
        let f = try RegistryFixture(), probe = SubscriptionAdmissionProbe()
        let calls = Mutex(0), resets = Mutex(0)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let old = V2RoomDeliverySession(host: f.fence.activation.host, gateway: gateway.identity, generation: 1)
        let fresh = V2RoomDeliverySession(host: old.host, gateway: old.gateway, generation: 2)
        let fence = V2RoomSubscriptionFence(activation: f.fence.activation, subscriptionID: UUID(),
            generation: f.fence.generation + 1, baselineSequence: f.fence.baselineSequence)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n > 1 { await probe.hold() }
            let session = n == 1 ? old : fresh
            #expect(f.authority.applyDeliverySession(.init(session: session, kind: .open, sequence: 1),
                serviceID: "owner") == .accepted)
            return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10, deliverySession: session))
        }, reset: { command, _, _ in
            #expect(command.replacingDeliverySession == nil)
            resets.withLock { $0 += 1 }
            return .granted(.init(fence: fence, memberRevision: 0, userBaselineSequence: 10, deliverySession: fresh))
        }, activate: { command, _, _ in
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1,
                authorizationSequence: 1, payload: .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 1)
        let retained = UUID()
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: retained)
        #expect(f.authority.applyDeliverySession(.init(session: old, kind: .retire, sequence: 2),
            serviceID: "owner") == .accepted)
        // A caller must recover even without the maintenance worker; when it
        // is running, foreground and background still share exactly one flight.
        if backgroundRepair {
            await coordinator.start()
            await coordinator.sessionChanged(host: old.host)
        }
        let references = (0..<8).map { _ in UUID() }
        let jobs = references.map { reference in
            Task { try await coordinator.acquire(roomID: f.room, userID: f.user, reference: reference) }
        }
        let until = ContinuousClock.now + .seconds(2)
        while await probe.calls == 0, ContinuousClock.now < until { await Task.yield() }
        #expect(await probe.calls == 1)
        await probe.release()
        for job in jobs {
            do {
                let grant = try await job.value
                #expect(grant.deliverySession == fresh && grant.fence == fence)
            } catch { Issue.record("fresh acquisition failed: \(error)") }
        }
        #expect(calls.withLock { $0 } == 2)
        #expect(resets.withLock { $0 } == 1)
        #expect(await coordinator.referenceCount == 9)
        await coordinator.shutdown()
        await f.authority.shutdown()
    }
    @Test("a first subscription repairs a session retired only at the Gateway")
    func coldRoomRepairsUnilateralSessionRetirement() async throws {
        let f = try RegistryFixture()
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let old = V2RoomDeliverySession(host: f.fence.activation.host, gateway: gateway.identity, generation: 1)
        let fresh = V2RoomDeliverySession(host: old.host, gateway: old.gateway, generation: 2)
        let fence = V2RoomSubscriptionFence(activation: f.fence.activation, subscriptionID: UUID(),
            generation: f.fence.generation + 1, baselineSequence: f.fence.baselineSequence)
        let resets = Mutex(0)
        _ = f.authority.applyDeliverySession(.init(session: old, kind: .open, sequence: 1), serviceID: "owner")
        _ = f.authority.applyDeliverySession(.init(session: old, kind: .retire, sequence: 2), serviceID: "owner")
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            // Host still considers this generation live; the room itself has
            // never been installed, so requiresBaseline alone cannot recover.
            .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10, deliverySession: old))
        }, reset: { command, _, _ in
            #expect(command.replacingDeliverySession == old)
            resets.withLock { $0 += 1 }
            _ = f.authority.applyDeliverySession(.init(session: fresh, kind: .open, sequence: 1), serviceID: "owner")
            return .granted(.init(fence: fence, memberRevision: 0, userBaselineSequence: 10, deliverySession: fresh))
        }, activate: { command, _, _ in
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1,
                authorizationSequence: 1, payload: .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress)
        do {
            let grant = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
            #expect(grant.deliverySession == fresh && grant.fence == fence)
            #expect(resets.withLock { $0 } == 1)
        } catch { Issue.record("unilateral retirement must recover: \(error)") }
        await coordinator.shutdown()
        await f.authority.shutdown()
    }

    @Test("a blocked repair cannot consume the foreground subscription reservation")
    func repairLeavesForegroundCapacity() async throws {
        let f = try RegistryFixture(), repair = SubscriptionAdmissionProbe()
        let firstCalls = Mutex(0), otherEntered = Mutex(false)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let session = V2RoomDeliverySession(host: f.fence.activation.host, gateway: gateway.identity, generation: 1)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: .init(roomID: room, owner: f.fence.activation.owner,
                activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host), authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            if command.roomID != f.room {
                otherEntered.withLock { $0 = true }
                return .failure(.unauthorized)
            }
            if firstCalls.withLock({ $0 += 1; return $0 }) > 1 {
                await repair.hold()
                return .failure(.unauthorized)
            }
            return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10,
                deliverySession: testDeliverySession(fence: f.fence, gateway: gateway.identity, authority: f.authority)))
        }, reset: { _, _, _ in .failure(.unauthorized) }, activate: { command, _, _ in
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1,
                authorizationSequence: 1, payload: .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 2, requestTimeout: .seconds(5))
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        await coordinator.start()
        #expect(f.authority.applyDeliverySession(.init(session: session, kind: .retire, sequence: 2),
            serviceID: "owner") == .accepted)
        await coordinator.sessionChanged(host: f.fence.activation.host)
        await repair.waitForStart()
        let other = Task { try await coordinator.acquire(roomID: .init(uuid: UUID()), userID: f.user, reference: UUID()) }
        let until = ContinuousClock.now + .seconds(1)
        while !otherEntered.withLock({ $0 }), ContinuousClock.now < until { await Task.yield() }
        #expect(otherEntered.withLock { $0 })
        await repair.release()
        _ = try? await other.value
        await coordinator.shutdown()
        #expect(await coordinator.queuedCallCount == 0)
    }
    @Test("invalidations during a repair remain coalesced until the actual flight ends", arguments: [false, true])
    func inFlightRepairRetainsInvalidations(recovers: Bool) async throws {
        let f = try RegistryFixture(), repair = SubscriptionAdmissionProbe()
        let calls = Mutex(0), offeredHeads = Mutex(0)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in offeredHeads.withLock { $0 += 1 } })
        let session = V2RoomDeliverySession(host: f.fence.activation.host, gateway: gateway.identity, generation: 1)
        let fresh = V2RoomDeliverySession(host: session.host, gateway: session.gateway, generation: 2)
        let replacement = V2RoomSubscriptionFence(activation: f.fence.activation, subscriptionID: UUID(),
            generation: f.fence.generation + 1, baselineSequence: f.fence.baselineSequence)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            let attempt = calls.withLock { $0 += 1; return $0 }
            if attempt == 2 { await repair.hold() }
            if attempt > 1 {
                guard recovers else { return .failure(.unauthorized) }
                _ = f.authority.applyDeliverySession(.init(session: fresh, kind: .open, sequence: 1), serviceID: "owner")
                return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10, deliverySession: fresh))
            }
            return .granted(.init(fence: f.fence, memberRevision: 0, userBaselineSequence: 10,
                deliverySession: testDeliverySession(fence: f.fence, gateway: gateway.identity, authority: f.authority)))
        }, reset: { _, _, _ in
            .granted(.init(fence: replacement, memberRevision: 0, userBaselineSequence: 10, deliverySession: fresh))
        }, activate: { command, _, _ in
            if command.fence == replacement {
                // A baseline may already have arrived before an activation ACK
                // is replayed. Its one-shot head offer is not a retained proof
                // that a later socket projection was selected by that publish.
                let result = await f.authority.apply(.init(fence: command.fence, deliverySequence: 1,
                    authorizationSequence: 1, payload: .baseline(members: [f.member])), authenticatedServiceID: "owner")
                if case .applied = result { return .activated }
                return .failure(.stale)
            }
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence, deliverySequence: 1,
                authorizationSequence: 1, payload: .baseline(members: [f.member])),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(1) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        // One spare maintenance slot makes the old pop-and-skip branch runnable.
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 4)
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        await coordinator.start()
        #expect(f.authority.applyDeliverySession(.init(session: session, kind: .retire, sequence: 2),
            serviceID: "owner") == .accepted)
        await coordinator.sessionChanged(host: session.host)
        await repair.waitForStart()
        for _ in 0..<32 { await coordinator.sessionChanged(host: session.host) }
        // Keep the actual RPC suspended while an eligible maintenance wake runs.
        // The signal must neither disappear nor start a concurrent repair RPC.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await coordinator.pendingRepairCount == 1)
        #expect(calls.withLock { $0 } == 2)
        await repair.release()
        if recovers {
            let until = ContinuousClock.now + .seconds(2)
            while await f.authority.authorizationCheckpoint(fence: replacement, serviceID: "owner") == nil,
                  ContinuousClock.now < until { await Task.yield() }
            #expect(await f.authority.authorizationCheckpoint(fence: replacement, serviceID: "owner") != nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(calls.withLock { $0 } == 2)
            #expect(offeredHeads.withLock { $0 } >= 2)
        }
        await coordinator.shutdown()
        #expect(await coordinator.pendingRepairCount == 0)
        await f.authority.shutdown()
    }
    @Test("partial room repair retries the missing member even after its sibling restores a ready baseline")
    func partialRepairDoesNotMistakeRoomReadinessForMemberReadiness() async throws {
        let f = try RegistryFixture(), other = UserID(uuid: UUID())
        let members = [f.member, V2RoomSubscriptionMember(userID: other, memberRevision: 0)]
        let state = Mutex((repairing: false, first: Optional<UserID>.none, failed: false, installed: false))
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let session = V2RoomDeliverySession(host: f.fence.activation.host, gateway: gateway.identity, generation: 1)
        let fresh = V2RoomDeliverySession(host: session.host, gateway: session.gateway, generation: 2)
        let replacement = V2RoomSubscriptionFence(activation: f.fence.activation, subscriptionID: UUID(),
            generation: 2, baselineSequence: 10)
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { command, _, _ in
            let decision = state.withLock { value -> (Bool, Bool, Bool) in
                guard value.repairing else { return (false, false, false) }
                if value.first == nil { value.first = command.actorUserID }
                if command.actorUserID != value.first, !value.failed {
                    value.failed = true
                    return (true, true, value.installed)
                }
                return (true, false, value.installed)
            }
            if decision.1 { return .failure(.unavailable) }
            let deliverySession = decision.0 ? fresh : session
            _ = f.authority.applyDeliverySession(.init(session: deliverySession, kind: .open, sequence: 1), serviceID: "owner")
            return .granted(.init(fence: decision.2 ? replacement : f.fence, memberRevision: 0,
                userBaselineSequence: 10, deliverySession: deliverySession))
        }, reset: { _, _, _ in
            .granted(.init(fence: replacement, memberRevision: 0, userBaselineSequence: 10, deliverySession: fresh))
        }, activate: { command, _, _ in
            let payload: V2RoomSubscriptionPayload
            let sequence: UInt64
            if command.fence == f.fence {
                payload = .baseline(members: members); sequence = 1
            } else {
                let first = state.withLock { value in
                    let first = !value.installed; value.installed = true; return first
                }
                if first {
                    payload = .baseline(members: [.init(userID: command.actorUserID, memberRevision: 0)])
                    sequence = 1
                } else if await f.authority.authorizedMemberRevision(roomID: f.room, userID: command.actorUserID) != nil {
                    return .activated
                } else {
                    payload = .grant(member: .init(userID: command.actorUserID, memberRevision: 0), baselineSequence: 10)
                    sequence = 2
                }
            }
            let result = await ingress.applyRoomSubscription(.init(fence: command.fence,
                deliverySequence: sequence, authorizationSequence: sequence, payload: payload),
                authenticatedServiceID: "owner", sourceShardID: "rooms")
            return result == .appliedThrough(sequence) ? .activated : .failure(.stale)
        }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 4)
        _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        _ = try await coordinator.acquire(roomID: f.room, userID: other, reference: UUID())
        state.withLock { $0.repairing = true }
        await coordinator.start()
        _ = f.authority.applyDeliverySession(.init(session: session, kind: .retire, sequence: 2), serviceID: "owner")
        await coordinator.sessionChanged(host: session.host)
        let until = ContinuousClock.now + .seconds(4)
        var restored = false
        while ContinuousClock.now < until {
            let first = await f.authority.authorizedMemberRevision(roomID: f.room, userID: f.user)
            let second = await f.authority.authorizedMemberRevision(roomID: f.room, userID: other)
            restored = state.withLock { $0.failed } && first != nil && second != nil
            if restored { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.withLock { $0.failed })
        #expect(restored)
        await coordinator.shutdown()
        await f.authority.shutdown()
    }
    @Test("queued subscriptions expire or retire without issuing an Owner call", arguments: [false, true])
    func queuedDeadlineAndRetirement(retire: Bool) async throws {
        let f = try RegistryFixture(), probe = SubscriptionAdmissionProbe()
        let metrics = V2RoomSubscriptionHeadDeliveryMetrics()
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: .init(roomID: room, owner: f.fence.activation.owner,
                activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host), authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in await probe.hold(); return .failure(.unauthorized) },
        reset: { _, _, _ in .failure(.unauthorized) }, activate: { _, _, _ in .failure(.unauthorized) },
        unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 1, requestTimeout: retire ? .seconds(5) : .milliseconds(100), metrics: metrics)
        let first = Task { try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID()) }
        await probe.waitForStart()
        let reference = UUID()
        let second = Task { try await coordinator.acquire(roomID: .init(uuid: UUID()), userID: f.user, reference: reference) }
        let until = ContinuousClock.now + .seconds(1)
        while await coordinator.queuedCallCount == 0, ContinuousClock.now < until { await Task.yield() }
        #expect(await coordinator.queuedCallCount == 1)
        #expect(await coordinator.acquisitionTaskCount == 1)
        #expect(metrics.snapshot().phases[.foreground]?[.queue]?.active == 1)
        #expect(metrics.snapshot().phases[.foreground]?[.subscribe]?.active == 1)
        if retire { await coordinator.release(reference: reference) }
        do { _ = try await second.value; Issue.record("queued work must fail before invoking Owner") }
        catch V2GatewayRoomSubscriptionCoordinationError.superseded { #expect(retire) }
        catch V2GatewayRoomSubscriptionCoordinationError.deadlineExpired { #expect(!retire) }
        #expect(await probe.calls == 1)
        #expect(await coordinator.queuedCallCount == 0)
        #expect(await coordinator.acquisitionTaskCount == 1)
        await probe.release()
        _ = try? await first.value
        await coordinator.shutdown()
        let phases = metrics.snapshot().phases[.foreground] ?? [:]
        #expect(phases[.queue]?.active == 0)
        #expect(phases[.queue]?.completed == 2)
        #expect(phases[.queue]?.outcomes[retire ? .superseded : .deadline] == 1)
        #expect(phases[.taskStart]?.completed == 1)
        #expect(phases[.slot]?.active == 0)
        #expect(phases[.slot]?.completed == 1)
        #expect(phases[.subscribe]?.outcomes[.refused] == 1)
    }
    @Test("a burst retains queued data without creating RPC tasks and shutdown joins actual work")
    func queuedBurstOwnsOnlyAdmittedTasks() async throws {
        let f = try RegistryFixture(), probe = SubscriptionAdmissionProbe(), ownerCalls = Mutex(0)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 20,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { room, _ in
            .init(activation: .init(roomID: room, owner: f.fence.activation.owner,
                activationEpoch: f.fence.activation.activationEpoch, host: f.fence.activation.host),
                authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in
            ownerCalls.withLock { $0 += 1 }
            await probe.hold()
            return .failure(.unauthorized)
        }, reset: { _, _, _ in .failure(.unauthorized) }, activate: { _, _, _ in .failure(.unauthorized) },
        unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            maximumConcurrentCalls: 1, requestTimeout: .seconds(10))
        let first = Task { try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID()) }
        await probe.waitForStart()
        let joined = Task { try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID()) }
        let joinedUntil = ContinuousClock.now + .seconds(2)
        while await coordinator.referenceCount < 2, ContinuousClock.now < joinedUntil { await Task.yield() }
        #expect(await coordinator.referenceCount == 2)
        joined.cancel()
        do { _ = try await joined.value; Issue.record("cancelling a coalesced caller must not wait for the shared RPC") }
        catch is CancellationError { }
        #expect(await coordinator.referenceCount == 1)
        #expect(await coordinator.acquisitionTaskCount == 1)
        let queued = (0..<12).map { _ in
            Task { try await coordinator.acquire(roomID: .init(uuid: UUID()), userID: f.user, reference: UUID()) }
        }
        let until = ContinuousClock.now + .seconds(2)
        while await coordinator.queuedCallCount < queued.count, ContinuousClock.now < until { await Task.yield() }
        #expect(await coordinator.queuedCallCount == queued.count)
        #expect(await coordinator.acquisitionTaskCount == 1)
        queued[0].cancel()
        do { _ = try await queued[0].value; Issue.record("cancelled queued caller must leave immediately") }
        catch is CancellationError { }
        #expect(await coordinator.queuedCallCount == queued.count - 1)
        #expect(await coordinator.acquisitionTaskCount == 1)
        #expect(ownerCalls.withLock { $0 } == 1)
        let stopped = Mutex(false)
        let shutdown = Task { await coordinator.shutdown(); stopped.withLock { $0 = true } }
        for caller in queued.dropFirst() {
            do { _ = try await caller.value; Issue.record("shutdown must reject queued requests") }
            catch V2GatewayRoomSubscriptionCoordinationError.closed { }
        }
        #expect(await coordinator.queuedCallCount == 0)
        #expect(await coordinator.acquisitionTaskCount == 1)
        #expect(!stopped.withLock { $0 })
        await probe.release()
        _ = try? await first.value
        await shutdown.value
        #expect(ownerCalls.withLock { $0 } == 1)
        #expect(await coordinator.acquisitionTaskCount == 0)
        #expect(await coordinator.referenceCount == 0)
        await f.authority.shutdown()
    }
    @Test("route cooldown survives last-reference retirement and prevents repeated resolution")
    func routeCooldownSurvivesRetirement() async throws {
        let f = try RegistryFixture(), clock = Mutex(ContinuousClock.now), resolves = Mutex(0)
        let gateway = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 9000)
        let ingress = V2GatewayRoomSubscriptionIngress(authority: f.authority, maximumRooms: 10,
            offerEvent: { _, _ in }, offerHead: { _, _ in })
        let ports = V2GatewayRoomSubscriptionPorts(gateway: gateway, resolve: { _, _ in
            let count = resolves.withLock { $0 += 1; return $0 }
            if count == 1 { throw V2RoomCallFailure.notAccepted(.unavailable) }
            return .init(activation: f.fence.activation, authenticatedServiceID: "owner")
        }, subscribe: { _, _, _ in .failure(.unauthorized) }, reset: { _, _, _ in .failure(.unauthorized) },
        activate: { _, _, _ in .failure(.unauthorized) }, unsubscribe: { _, _, _ in .unsubscribed })
        let coordinator = try V2GatewayRoomSubscriptionCoordinator(ports: ports, ingress: ingress,
            now: { clock.withLock { $0 } })
        _ = try? await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        #expect(await coordinator.referenceCount == 0)
        do { _ = try await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID()); Issue.record("cooldown must reject") }
        catch V2GatewayRoomSubscriptionCoordinationError.refused(.unavailable) { }
        #expect(resolves.withLock { $0 } == 1)
        clock.withLock { $0 += .seconds(2) }
        _ = try? await coordinator.acquire(roomID: f.room, userID: f.user, reference: UUID())
        #expect(resolves.withLock { $0 } == 2)
        await coordinator.shutdown()
    }
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
                userBaselineSequence: 10, deliverySession: testDeliverySession(fence: fences[command.roomID]!, gateway: gateway.identity, authority: authority)))
        }, reset: { command, _, _ in
            resets.withLock { $0 += 1 }
            let fresh = V2RoomSubscriptionFence(activation: command.expectedFence.activation,
                subscriptionID: UUID(), generation: command.expectedFence.generation + 1, baselineSequence: 10)
            return .granted(.init(fence: fresh, memberRevision: 0,
                userBaselineSequence: 10, deliverySession: testDeliverySession(fence: fresh, gateway: gateway.identity, authority: authority)))
        },
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
            #expect(await authority.authorizationCheckpoint(fence: nextFence, serviceID: "owner") == 1)
            await coordinator.release(reference: second)
            for fence in extraFences {
                let reference = UUID()
                let fresh = try await coordinator.acquire(roomID: fence.roomID, userID: f.user, reference: reference)
                #expect(fresh.fence.generation == 2)
                #expect(!(await ingress.installTestSession(fence: fence, sourceShardID: "rooms",
                    serviceID: "owner")))
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
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
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
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
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
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
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









    @Test("lost batch ACK accepts its cached prefix without repeating actual socket bodies")
    func batchRetryDoesNotRefanout() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket()
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
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
        #expect(await ingress.applyRoomSubscriptionBatch(conflict, authenticatedServiceID: "owner", sourceShardID: "rooms").receipts.first?.result == .snapshotRequired)
        #expect(await f.authority.requiresBaseline(fence: f.fence))
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
                    deliverySession: testDeliverySession(fence: f.fence, gateway: gateway.identity, authority: f.authority)))
            }, reset: { _, _, _ in .failure(.unavailable) },
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
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
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
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
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

    @Test("head work releases its idle task and a later offer restarts delivery")
    func headWorkerReleasesAndRestarts() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket(holdReady: true)
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
        _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        _ = try await f.registry.subscribeForegroundRoom(socket.stream, connectionID: socket.connectionID, roomID: f.room)
        try await waitUntil { await socket.writer.isHoldingReady }
        #expect(await socket.stream.roomSubscriptionWriterCount == 1)
        let authorization = try #require(await f.authority.capturePermits(roomID: f.room).first)
        let permit: @Sendable (@Sendable () -> Void) -> Bool = {
            f.authority.enqueueIfCurrent(authorization, enqueue: $0)
        }
        // Multiple heads arriving during the actual Ready write stay coalesced.
        for head in [UInt64(20), 80, 60] {
            #expect(await socket.stream.offerRoomSubscriptionHead(authorization, highWatermark: head, permit: permit))
        }
        #expect(await socket.stream.roomSubscriptionWriterCount == 1)
        await socket.writer.release()
        try await waitUntil { socket.writer.hints.contains(80) }
        let idleDeadline = ContinuousClock.now + .seconds(2)
        while await socket.stream.roomSubscriptionWriterCount != 0, ContinuousClock.now < idleDeadline { await Task.yield() }
        #expect(await socket.stream.roomSubscriptionWriterCount == 0)
        #expect(socket.writer.readyHeads == [10])
        #expect(await socket.stream.offerRoomSubscriptionHead(authorization, highWatermark: 81, permit: permit))
        try await waitUntil { socket.writer.hints.contains(81) }
        let secondIdleDeadline = ContinuousClock.now + .seconds(2)
        while await socket.stream.roomSubscriptionWriterCount != 0, ContinuousClock.now < secondIdleDeadline { await Task.yield() }
        #expect(await socket.stream.roomSubscriptionWriterCount == 0)
        #expect(socket.writer.readyHeads == [10])
        try await socket.stream.finish()
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("closing joins a head write that is still held by the socket owner")
    func closeJoinsActualHeadWrite() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let socket = try await f.socket(holdReady: true)
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
        _ = await ingress.applyRoomSubscription(f.delivery(1, .baseline(members: [f.member])),
            authenticatedServiceID: "owner", sourceShardID: "rooms")
        _ = try await f.registry.subscribeForegroundRoom(socket.stream, connectionID: socket.connectionID, roomID: f.room)
        try await waitUntil { await socket.writer.isHoldingReady }
        let closed = Mutex(false)
        let closing = Task {
            try await socket.stream.finish()
            closed.withLock { $0 = true }
        }
        try await waitUntil { !socket.stream.connectionAllowsDispatch() }
        #expect(!closed.withLock { $0 })
        #expect(await socket.stream.roomSubscriptionWriterCount == 1)
        await socket.writer.release()
        try await closing.value
        #expect(closed.withLock { $0 })
        #expect(await socket.stream.roomSubscriptionWriterCount == 0)
        #expect(socket.writer.readyHeads.isEmpty)
        await f.registry.shutdownRealtimeRecovery()
    }

    @Test("an expired socket permit retains H until a fresh trusted offer wakes it")
    func retainedHeadWaitsForFreshPermit() async throws {
        let f = try RegistryFixture(), socket = try await f.socket(holdReady: true)
        let lifecycle = UUID()
        await f.authority.registerFixtureConnection(socket.connectionID, userID: f.user, lifecycle: lifecycle, eventLoop: socket.writer.eventLoop)
        try #require(await f.authority.registerRoomInterest(connectionID: socket.connectionID,
            lifecycle: lifecycle, roomID: f.room, scopeGeneration: 1))
        try #require(await f.authority.installTestSession(fence: f.fence, serviceID: "owner"))
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



    @Test("local room unsubscribe closes detail scope while account delivery remains; connection revoke precedes slow close")
    func unsubscribeAndImmediateConnectionFence() async throws {
        let f = try RegistryFixture()
        let ingress = try await f.registry.configureRoomSubscriptionIngress(authority: f.authority)
        let first = try await f.socket(), second = try await f.socket()
        try #require(await ingress.installTestSession(fence: f.fence, sourceShardID: "rooms", serviceID: "owner"))
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
    func socket(holdReady: Bool = false, refuseFirstRecovering: Bool = false) async throws -> RegistrySocket {
        let device = DeviceID(uuid: UUID()), connection = UUID()
        let writer = RegistrySocketWriter(holdReady: holdReady, refuseFirstRecovering: refuseFirstRecovering)
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
        var recovering: [UInt64] = []
        var hints: [UInt64] = []
        var bodies: [UInt64] = []
    }
    private nonisolated let output = Mutex(Output())
    nonisolated var readyHeads: [UInt64] { output.withLock { $0.ready } }
    nonisolated var recoveringGenerations: [UInt64] { output.withLock { $0.recovering } }
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
    private var refuseFirstRecovering: Bool
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isHoldingReady = false
    private(set) var rejectedReady = false
    init(holdReady: Bool, refuseFirstRecovering: Bool = false) {
        self.holdReady = holdReady; self.refuseFirstRecovering = refuseFirstRecovering
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func write(_ write: V2GatewayScopedNotificationWrite) async -> Bool {
        let envelope = Self.decode(write.bytes)
        if refuseFirstRecovering, envelope?.realtimeCoverage.scope == .room,
           envelope?.realtimeCoverage.state == .recovering {
            refuseFirstRecovering = false
            return false // Transport admission failed before evaluating any permit.
        }
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
            case .realtimeCoverage(let state) where state.scope == .room && state.state == .recovering:
                value.recovering.append(state.scopeGeneration)
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

private actor SubscriptionAdmissionProbe {
    private(set) var calls = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        calls += 1; entered?.resume(); entered = nil
        await withCheckedContinuation { held = $0 }
    }
    func waitForStart() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { held?.resume(); held = nil }
}
