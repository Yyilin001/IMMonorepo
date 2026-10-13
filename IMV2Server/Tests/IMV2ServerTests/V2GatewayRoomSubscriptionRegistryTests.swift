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
