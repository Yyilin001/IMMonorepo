import Crypto
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import Testing
@testable import IMV2ActorCluster

@Suite("Room Cluster bridge authenticates native distributed exchanges", .serialized)
struct V2RoomClusterBridgeTests {
    @Test("concurrent discovery and suspension publish the actual Peer state")
    func concurrentDirectoryPublication() async throws {
        let fixture = try await Fixture()
        let directory = V2RoomClusterDirectory()
        let budget = V2RoomClusterBudget(configuration: fixture.configuration, maximumSessions: fixture.limits.maximumSessions)
        let references = V2RoomClusterReferenceCache(capacity: fixture.configuration.maximumCachedLocations)
        let control = V2RoomClusterDirectoryControl(directory: directory, maximumPeers: fixture.limits.maximumSessions,
            join: { _ in }, factory: { hostID in
                V2RoomClusterPeer(system: fixture.system, signer: fixture.coordinator, trust: fixture.trust,
                    limits: fixture.limits, configuration: fixture.configuration, callerIncarnation: UUID(),
                    localPort: nil, stableHostID: hostID, budget: budget, references: references)
            })
        do {
            let descriptor = try V2RoomClusterHostDescriptor(identity: fixture.identity,
                endpointID: fixture.endpoint.id, address: "127.0.0.1", port: fixture.port,
                accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true)
            try await control.install(descriptor, join: false)
            let peer = try #require(directory.inspectionPeer(for: fixture.identity.hostID))
            for _ in 0..<200 {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await control.install(descriptor, join: false) }
                    group.addTask { _ = await control.suspend(fixture.identity) }
                    try await group.waitForAll()
                }
                let actual = await peer.directorySuspended(fixture.identity)
                #expect(directory.routingSnapshot().suspended.contains(fixture.identity) == actual)
            }
        } catch {
            await control.stop()
            try await fixture.system.shutdown().wait()
            throw error
        }
        await control.stop()
        try await fixture.system.shutdown().wait()
    }
    @Test("published routing snapshots retain their version across restart and suspension")
    func routingSnapshotVersions() async throws {
        let fixture = try await Fixture()
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.coordinator,
            trust: fixture.trust, limits: fixture.limits, configuration: fixture.configuration)
        do {
            func descriptor(_ identity: V2ActorHostIdentity) throws -> V2RoomClusterHostDescriptor {
                try .init(identity: identity, endpointID: fixture.endpoint.id, address: "127.0.0.1",
                    port: fixture.port, accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true)
            }
            try await caller.installDiscovered(descriptor(fixture.identity))
            let old = caller.routingSnapshot()
            let replacement = V2ActorHostIdentity(hostID: fixture.identity.hostID, incarnationID: UUID())
            try await caller.installDiscovered(descriptor(replacement))
            #expect(try old.resolvePolicyHost(hostID: replacement.hostID, endpoint: "allowed") == fixture.identity)
            #expect(try caller.resolvePolicyHost(hostID: replacement.hostID, endpoint: "allowed") == replacement)
            _ = await caller.suspendUnreachableHost(replacement)
            #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) {
                try caller.resolvePolicyHost(hostID: replacement.hostID, endpoint: "allowed")
            }
            await caller.stop()
            #expect(throws: V2RoomCallFailure.notAccepted(.retired)) {
                try caller.resolvePolicyHost(hostID: replacement.hostID, endpoint: "allowed")
            }
        } catch {
            await caller.stop()
            try await fixture.system.shutdown().wait()
            throw error
        }
        try await fixture.system.shutdown().wait()
    }
    @Test("saturated recovery does not reject bounded renewal batches from six authenticated peers")
    func renewalAdmissionIsIndependentOfRecovery() throws {
        var admission = V2RoomBatchAdmission(maximumRenewalBatches: 12)
        func check(_ kind: V2RoomBatchAdmission.Kind, _ peer: String, accepted: Bool = true) throws {
            let result = admission.acquire(kind, peer: try V2ActorServiceID(peer))
            #expect(result == accepted)
        }
        for peer in ["gateway-0", "gateway-1"] {
            try check(.recovery, peer)
            try check(.recovery, peer)
        }
        try check(.recovery, "gateway-2", accepted: false)
        for index in 0..<6 {
            let peer = "gateway-\(index)"
            try check(.renewal, peer)
            try check(.renewal, peer)
            try check(.renewal, peer, accepted: false)
        }
        try check(.renewal, "gateway-6", accepted: false)
        admission.release(.renewal, peer: try V2ActorServiceID("gateway-0"))
        try check(.renewal, "gateway-0")
        admission.release(.recovery, peer: try V2ActorServiceID("gateway-0"))
        try check(.recovery, "gateway-2")
    }
    @Test("signed recovery batches enforce request bytes before caller dispatch and after host authentication")
    func signedRecoveryBatchRequestByteBoundary() async throws {
        let gate = RecoveryBatchGate()
        // The owner contract has no byte limit. All 100 room/viewer pairs are
        // legal; repeated owner metadata makes this packet exceed the batch cap.
        let shard = "allowed-" + String(repeating: "s", count: 1_024)
        let fixture = try await Fixture(coordinatorUserCalls: true, recoveryBatchGate: gate,
            ownerShardID: shard)
        var settings = ClusterSystemSettings(name: "v2-recovery-byte-caller", host: "127.0.0.1",
            port: Int.random(in: 30_000...60_000))
        settings.threadPoolSize = 1
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        let remoteSystem = await ClusterSystem("v2-recovery-byte-caller", settings: settings)
        let caller = V2RoomClusterClient(system: remoteSystem, signer: fixture.coordinator,
            trust: fixture.trust, limits: fixture.limits, configuration: fixture.configuration)
        var failure: (any Error)?
        do {
            try await caller.register(.init(identity: fixture.identity, endpointID: fixture.endpoint.id,
                address: "127.0.0.1", port: fixture.port, accessibleShardIDs: [shard],
                availableRooms: 2, isHealthy: true))
            guard case .ready(let token) = try await caller.activate(on: fixture.identity,
                roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(2)) else {
                throw V2ActorAuthenticationError.invalidConfiguration
            }
            let end = ContinuousClock.now + .seconds(2)
            let items = (0..<100).map { _ in
                V2RoomRecoveryBatchCallItem(token: token,
                    query: .init(roomID: token.roomID, actorUserID: .init(uuid: UUID()), kind: .state),
                    deadline: end)
            }
            _ = try await caller.invokeRecoveryBatch(on: fixture.identity,
                items: [items[0]], deadline: end)
            #expect(await gate.executedItemCounts == [1])
            let before = await caller.callMetricsSnapshot()
            let beforeDispatch = try #require(before.recoveryStages[.actualDispatch])
            #expect(beforeDispatch.started == 1 && beforeDispatch.completed == 1 && beforeDispatch.active == 0)
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                _ = try await caller.invokeRecoveryBatch(on: fixture.identity, items: items, deadline: end)
            }
            let after = await caller.callMetricsSnapshot()
            let afterDispatch = try #require(after.recoveryStages[.actualDispatch])
            #expect(afterDispatch.started == beforeDispatch.started && afterDispatch.completed == beforeDispatch.completed)
            #expect(afterDispatch.active == 0)
            #expect(await caller.dispatchedCallCount() == 0)
            #expect(await gate.executedItemCounts == [1])

            // Bypass the caller's 64 KiB encoder using the existing generic
            // signing limit. The actual remote endpoint must authenticate this
            // trusted principal and reject its bytes before business admission.
            let endpoint = try V2RoomHostEndpoint.resolve(id: fixture.endpoint.id, using: remoteSystem)
            let hello = V2ActorSessionHello(serviceID: fixture.coordinator.serviceID,
                callerIncarnation: UUID(), recipient: fixture.identity, handshakeID: UUID())
            let signedGrant = try await endpoint.openSession(fixture.coordinator.sign(hello, maximumBytes: 16_384))
            let grant = try fixture.trust.verifySessionGrant(signedGrant, for: hello, maximumBytes: 16_384)
            let call = V2ActorAuthenticatedCall(serviceID: fixture.coordinator.serviceID,
                callerIncarnation: grant.callerIncarnation, recipient: fixture.identity,
                sessionID: grant.sessionID, sequence: 1, attemptID: UUID(), traceID: UUID(),
                remainingBudget: try .init(2_000), principal: .service,
                request: .recoveryBatch(items.map { .init(token: $0.token, query: $0.query) }))
            let packet = try fixture.coordinator.sign(call, maximumBytes: fixture.limits.maximumRequestBytes)
            #expect(packet.body.count > 65_536)
            await expectAuthentication(.oversized) { _ = try await endpoint.exchange(packet) }
            #expect(await gate.executedItemCounts == [1])
            #expect(await fixture.inbound.inFlightRequestCount() == 0)
        } catch { failure = error }
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        await fixture.inbound.stop()
        try await remoteSystem.shutdown().wait()
        try await fixture.system.shutdown().wait()
        if let failure { throw failure }
    }

    @Test("a signed two-node recovery batch binds viewers and retains cancelled actual calls")
    func signedRecoveryBatchViewerBindingAndActualDrain() async throws {
        let gate = RecoveryBatchGate()
        let fixture = try await Fixture(maximumInboundRequests: 8, maximumActiveRooms: 3,
            coordinatorUserCalls: true, recoveryBatchGate: gate,
            maximumActivationWaitersPerHost: 16, maximumConcurrentReservations: 3)
        var settings = ClusterSystemSettings(name: "v2-recovery-batch-caller", host: "127.0.0.1",
            port: Int.random(in: 30_000...60_000))
        settings.threadPoolSize = 1
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        let remoteSystem = await ClusterSystem("v2-recovery-batch-caller", settings: settings)
        let caller = V2RoomClusterClient(system: remoteSystem, signer: fixture.coordinator,
            trust: fixture.trust, limits: fixture.limits, configuration: fixture.configuration)
        var running: [Task<[V2RoomRecoveryBatchCallOutcome], any Error>] = []
        var failure: (any Error)?
        do {
            try await caller.register(.init(identity: fixture.identity, endpointID: fixture.endpoint.id,
                address: "127.0.0.1", port: fixture.port, accessibleShardIDs: ["allowed"],
                availableRooms: 3, isHealthy: true))
            guard case .ready(let first) = try await caller.activate(on: fixture.identity,
                roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(2)),
                  case .ready(let second) = try await caller.activate(on: fixture.identity,
                roomID: .init(uuid: UUID()), owner: fixture.owner, deadline: .now + .seconds(2)) else {
                throw V2ActorAuthenticationError.invalidConfiguration
            }
            let viewers = [UserID(uuid: UUID()), UserID(uuid: UUID())]
            let missing = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: fixture.owner,
                activationEpoch: try .init(1), host: fixture.identity)
            let end = ContinuousClock.now + .seconds(2)
            func item(_ token: V2RoomActivationToken, _ user: UserID) -> V2RoomRecoveryBatchCallItem {
                .init(token: token, query: .init(roomID: token.roomID, actorUserID: user, kind: .state), deadline: end)
            }
            let mixed = [item(first, viewers[0]), item(first, viewers[1]), item(missing, viewers[0])]
            let answers = try await caller.invokeRecoveryBatch(on: fixture.identity, items: mixed, deadline: end)
            #expect(answers.count == 3)
            for index in 0..<2 {
                #expect(answers[index].token == first && answers[index].query.actorUserID == viewers[index])
                guard case .result(.recovery(.state(.state(let state)))) = answers[index].outcome else {
                    throw V2ActorAuthenticationError.invalidRequest
                }
                #expect(state.roomID == first.roomID && state.head == 7)
            }
            guard case .failure = answers[2].outcome else { throw V2ActorAuthenticationError.invalidRequest }
            #expect(await gate.executedItemCounts == [2]) // Missing room never enters the business callback.

            let endpoint = try V2RoomHostEndpoint.resolve(id: fixture.endpoint.id, using: remoteSystem)
            // Both packets are validly signed. A user principal cannot forward
            // a second viewer; a user-only service cannot use service forwarding.
            for (signer, principal) in [(fixture.coordinator, V2ActorCallPrincipal.user(viewers[0])),
                                         (fixture.client, V2ActorCallPrincipal.service)] {
                let hello = V2ActorSessionHello(serviceID: signer.serviceID, callerIncarnation: UUID(),
                    recipient: fixture.identity, handshakeID: UUID())
                let signedGrant = try await endpoint.openSession(signer.sign(hello, maximumBytes: 16_384))
                let grant = try fixture.trust.verifySessionGrant(signedGrant, for: hello, maximumBytes: 16_384)
                let call = V2ActorAuthenticatedCall(serviceID: signer.serviceID, callerIncarnation: grant.callerIncarnation,
                    recipient: fixture.identity, sessionID: grant.sessionID, sequence: 1,
                    attemptID: UUID(), traceID: UUID(), remainingBudget: try .init(2_000), principal: principal,
                    request: .recoveryBatch(mixed.prefix(2).map { .init(token: $0.token, query: $0.query) }))
                await expectAuthentication(.forbidden) {
                    _ = try await endpoint.exchange(signer.sign(call, maximumBytes: 65_536))
                }
            }
            await gate.hold()
            let heldEnd = ContinuousClock.now + .seconds(2)
            for token in [first, second] {
                let held = V2RoomRecoveryBatchCallItem(token: token,
                    query: .init(roomID: token.roomID, actorUserID: viewers[0], kind: .state), deadline: heldEnd)
                running.append(Task { try await caller.invokeRecoveryBatch(on: fixture.identity,
                    items: [held], deadline: heldEnd) })
            }
            try await waitUntil { await gate.heldCount == 2 }
            #expect(await caller.dispatchedCallCount() == 2)
            running[0].cancel()
            do { _ = try await running[0].value; Issue.record("cancelled batch waiter unexpectedly succeeded") }
            catch { #expect(error as? V2RoomCallFailure == .outcomeUnknown) }
            #expect(await caller.dispatchedCallCount() == 2)
            let cancelledMetrics = await caller.callMetricsSnapshot()
            let heldStage = try #require(cancelledMetrics.recoveryStages[.actualDispatch])
            #expect(heldStage.active == 2 && heldStage.started == 3 && heldStage.completed == 1)
            #expect(heldStage.itemsStarted == 5 && heldStage.oldestMilliseconds >= 0)
            #expect(cancelledMetrics.batchCallerCancellations == 1)
            await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
                _ = try await caller.invokeRecoveryBatch(on: fixture.identity,
                    items: [.init(token: first, query: mixed[0].query, deadline: heldEnd)], deadline: heldEnd)
            }
            #expect((await caller.callMetricsSnapshot()).batchRejectedPeer == 1)
            #expect(!(await caller.quiesce(deadline: .now + .milliseconds(20))))
            #expect(!(await fixture.inbound.quiesce(deadline: .now + .milliseconds(20))))
        } catch { failure = error }
        await gate.release()
        for task in running { _ = await task.result }
        try await waitUntil { await caller.dispatchedCallCount() == 0 }
        let drainedMetrics = await caller.callMetricsSnapshot()
        #expect(drainedMetrics.recoveryStages[.actualDispatch]?.active == 0)
        #expect(drainedMetrics.recoveryStages[.actualDispatch]?.started == 3)
        #expect(drainedMetrics.recoveryStages[.actualDispatch]?.completed == 3)
        #expect(drainedMetrics.recoveryStages[.sessionCallerWait]?.active == 0)
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        #expect(await fixture.inbound.quiesce(deadline: .now + .seconds(2)))
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        await fixture.inbound.stop()
        try await remoteSystem.shutdown().wait()
        try await fixture.system.shutdown().wait()
        if let failure { throw failure }
    }

    @Test("same-token reconstruction survives cleanup of the previous physical installation")
    func physicalInstallationCleanup() async throws {
        let fixture = try await Fixture()
        guard case .ready(let token) = try await fixture.host.activate(
            roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(2)) else {
            Issue.record("expected ready"); return
        }
        let original = try await fixture.inbound.physicalReference(for: token)
        let originalID = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: original)
        #expect(await fixture.inbound.removePhysicalReference(for: token, actorID: originalID))
        let replacement = try await fixture.inbound.physicalReference(for: token)
        let replacementID = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: replacement)
        #expect(originalID != replacementID)
        #expect(!(await fixture.inbound.removePhysicalReference(for: token, actorID: originalID)))
        let retained = try await fixture.inbound.physicalReference(for: token)
        let retainedID = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: retained)
        #expect(retainedID == replacementID)
        #expect(await fixture.inbound.actorCount() == 1)
        #expect(await fixture.host.isReady(token: token))
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        do {
            _ = try await fixture.inbound.physicalReference(for: token)
            Issue.record("retired activation published a reference")
        } catch {
            #expect(error as? V2RoomCallFailure == .notAccepted(.staleActivation))
        }
        await fixture.inbound.reconcileActors()
        #expect(await fixture.inbound.actorCount() == 0)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
    }

    @Test("node-local exchange uses the signed hello then the same replay, shard and bound-token gate")
    func localExchangeChecks() async throws {
        let fixture = try await Fixture()
        let hello = V2ActorSessionHello(serviceID: fixture.client.serviceID,
            callerIncarnation: UUID(), recipient: fixture.identity, handshakeID: UUID())
        let (signedGrant, capability) = try await fixture.inbound.openLocalSession(
            fixture.client.sign(hello, maximumBytes: 10_000), generation: fixture.generation)
        let grant = try fixture.trust.verifySessionGrant(signedGrant, for: hello, maximumBytes: 10_000)
        let first = fixture.call(grant: grant, sequence: 1,
            request: .activate(roomID: fixture.room, owner: fixture.owner))
        let ready = try await fixture.inbound.exchangeLocal(V2ActorLocalPayload(first),
            capability: capability, generation: fixture.generation, boundToken: nil)
        guard case .ready(let token, _) = try fixture.trust.verifyLocalReply(ready, for: first,
            from: fixture.identity, maximumBytes: 10_000) else {
            Issue.record("local activation did not return its exact token"); return
        }
        await expectAuthentication(.replay) {
            _ = try await fixture.inbound.exchangeLocal(V2ActorLocalPayload(first),
                capability: capability, generation: fixture.generation, boundToken: nil)
        }
        await expectAuthentication(.wrongRecipient) {
            _ = try await fixture.inbound.exchangeLocal(V2ActorLocalPayload(fixture.call(
                grant: grant, sequence: 2, request: .lookup(token))),
                capability: capability, generation: UUID(), boundToken: nil)
        }
        let wrongShard = try V2RoomDataOwner(shardID: "forbidden", epoch: 0)
        await expectAuthentication(.forbidden) {
            _ = try await fixture.inbound.exchangeLocal(V2ActorLocalPayload(fixture.call(
                grant: grant, sequence: 2,
                request: .activate(roomID: .init(uuid: UUID()), owner: wrongShard))),
                capability: capability, generation: fixture.generation, boundToken: nil)
        }
        await expectAuthentication(.wrongRecipient) {
            _ = try await fixture.inbound.exchangeLocal(V2ActorLocalPayload(fixture.call(
                grant: grant, sequence: 3, request: .lookup(token))),
                capability: capability, generation: fixture.generation, boundToken: token)
        }
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
    }

    @Test("signed local activation publishes a physical actor and denies other shards")
    func signedActivationAndShardAccess() async throws {
        let fixture = try await Fixture()
        let grant = try await fixture.open()
        let call = fixture.call(grant: grant, sequence: 1,
                                request: .activate(roomID: fixture.room, owner: fixture.owner))
        let packet = try fixture.client.sign(call, maximumBytes: 10_000)
        let signed = try await fixture.endpoint.exchange(packet)
        let reply = try fixture.trust.verifyReply(signed, for: call, maximumBytes: 10_000)
        guard case .ready(let token, let idBytes) = reply else {
            Issue.record("expected ready token and physical ActorID"); return
        }
        #expect(token.roomID == fixture.room)
        #expect(!idBytes.isEmpty)
        let actor = try V2RoomClusterActor.resolve(
            id: JSONDecoder().decode(ClusterSystem.ActorID.self, from: idBytes), using: fixture.system
        )
        let wrongShard = try V2RoomDataOwner(shardID: "forbidden", epoch: 0)
        let denied = fixture.call(grant: grant, sequence: 2,
                                  request: .activate(roomID: RoomID(uuid: UUID()), owner: wrongShard))
        await expectAuthentication(.forbidden) {
            _ = try await fixture.endpoint.exchange(fixture.client.sign(denied, maximumBytes: 10_000))
        }
        let lookup = fixture.call(grant: grant, sequence: 3, request: .lookup(token))
        await expectAuthentication(.wrongRecipient) {
            _ = try await actor.exchange(fixture.client.sign(lookup, maximumBytes: 10_000))
        }
        let user = UserID(uuid: UUID())
        let request = try V2RoomRequest.messaging(.sendOperation(try .init(command: try .init(
            roomID: fixture.room, senderUserID: user,
            clientMessageID: ClientMessageID(uuid: UUID()), text: "signed",
            media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)))
        let otherEpoch = V2RoomActivationToken(roomID: fixture.room, owner: fixture.owner,
                                                activationEpoch: try .init(2), host: fixture.identity)
        let wrongToken = fixture.call(grant: grant, sequence: 4,
                                      request: .invoke(token: otherEpoch, request: request),
                                      principal: .user(user))
        await expectAuthentication(.wrongRecipient) {
            _ = try await actor.exchange(fixture.client.sign(wrongToken, maximumBytes: 10_000))
        }
        let drained = await fixture.host.drain(deadline: .now + .seconds(2))
        #expect(drained.completed)
        await fixture.inbound.reconcileActors()
        #expect(await fixture.inbound.actorCount() == 0)
        let stale = fixture.call(grant: grant, sequence: 5,
                                 request: .invoke(token: token, request: request),
                                 principal: .user(user))
        let staleReply = try await actor.exchange(fixture.client.sign(stale, maximumBytes: 10_000))
        #expect(try fixture.trust.verifyReply(staleReply, for: stale, maximumBytes: 10_000)
                == .failure(.notAccepted(.staleActivation)))
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
    }

    @Test("two ClusterSystems exchange host-signed room identities over the transport")
    func remoteActivation() async throws {
        let fixture = try await Fixture()
        var settings = ClusterSystemSettings(name: "v2-room-bridge-test", host: "127.0.0.1",
                                             port: Int.random(in: 30_000...60_000))
        settings.threadPoolSize = 1
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
        let callerSystem = await ClusterSystem("v2-room-bridge-test", settings: settings)
        let caller = V2RoomClusterClient(system: callerSystem, signer: fixture.client,
                                         trust: fixture.trust, limits: fixture.limits,
                                         configuration: fixture.configuration)
        try await caller.register(.init(
            identity: fixture.identity, endpointID: fixture.endpoint.id,
            address: "127.0.0.1", port: fixture.port,
            accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true
        ))
        let deadline = ContinuousClock.now + .seconds(10)
        let activation = try await caller.activate(on: fixture.identity, roomID: fixture.room,
                                                    owner: fixture.owner, deadline: deadline)
        guard case .ready(let token) = activation else { Issue.record("expected ready"); return }
        #expect(try await caller.lookup(token, deadline: deadline))
        #expect(!(await caller.canInvokeCachedLocally(token)))
        let user = UserID(uuid: UUID())
        do {
            _ = try await caller.invokeCachedLocally(token,
                request: .messaging(.sendOperation(try .init(command: try .init(roomID: fixture.room, senderUserID: user,
                    clientMessageID: .init(uuid: UUID()), text: "remote-hint-denied",
                    media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000))),
                principal: .user(user), deadline: deadline)
            Issue.record("remote host accepted a local-only hint")
        } catch {
            #expect(error as? V2RoomCallFailure == .notAccepted(.staleActivation))
        }
        #expect(await caller.sessionCount() == 1)
        #expect(await caller.physicalReferenceCount() == 1)
        await caller.stop()
        #expect((await fixture.host.drain(deadline: deadline)).completed)
        await fixture.inbound.stop()
        try await callerSystem.shutdown().wait()
        try await fixture.system.shutdown().wait()
    }

    @Test("admission bounds calls before authentication and includes session hello")
    func boundedInboundAdmission() async throws {
        let gate = RestoreGate()
        let fixture = try await Fixture(restoreGate: gate, maximumInboundRequests: 1)
        let grant = try await fixture.open()
        let firstCall = fixture.call(grant: grant, sequence: 1,
                                     request: .activate(roomID: fixture.room, owner: fixture.owner))
        let first = Task {
            try await fixture.endpoint.exchange(fixture.client.sign(firstCall, maximumBytes: 10_000))
        }
        try await gate.waitForEntry()
        #expect(await fixture.inbound.inFlightRequestCount() == 1)
        let second = fixture.call(grant: grant, sequence: 2,
                                  request: .activate(roomID: fixture.room, owner: fixture.owner))
        await expectAuthentication(.overloaded) {
            _ = try await fixture.endpoint.exchange(fixture.client.sign(second, maximumBytes: 10_000))
        }
        await expectAuthentication(.overloaded) { _ = try await fixture.open() }
        await gate.open()
        let signed = try await first.value
        guard case .ready = try fixture.trust.verifyReply(signed, for: firstCall, maximumBytes: 10_000) else {
            Issue.record("first admitted activation did not complete"); return
        }
        #expect(await fixture.inbound.inFlightRequestCount() == 0)
        #expect((await fixture.host.drain(deadline: .now + .seconds(2))).completed)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
    }

    @Test("a pending remote reservation consumes the caller's global slot")
    func pendingReservationCapacity() async throws {
        let gate = RestoreGate()
        let fixture = try await Fixture(executeGate: gate)
        guard case .ready(let token) = try await fixture.host.activate(
            roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(3)
        ) else { Issue.record("expected ready"); return }
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.coordinator,
                                         trust: fixture.trust, limits: fixture.limits,
                                         configuration: fixture.configuration)
        try await caller.register(.init(
            identity: fixture.identity, endpointID: fixture.endpoint.id,
            address: "127.0.0.1", port: fixture.port,
            accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true
        ))
        #expect(try await caller.lookup(token, deadline: .now + .seconds(3)))
        let user = UserID(uuid: UUID())
        let request = try V2RoomRequest.messaging(.sendOperation(try .init(command: try .init(
            roomID: fixture.room, senderUserID: user,
            clientMessageID: ClientMessageID(uuid: UUID()), text: "hold",
            media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)))
        let executing = Task {
            try await fixture.host.invoke(token: token, encodedRequest: JSONEncoder().encode(request),
                                          deadline: .now + .seconds(3))
        }
        try await gate.waitForEntry()
        let first = Task {
            try await caller.reserve(token, requestID: UUID(), deadline: .now + .seconds(3))
        }
        try await waitUntil { await caller.reservationSlotSnapshot() == 1 }
        do {
            _ = try await caller.reserve(token, requestID: UUID(), deadline: .now + .seconds(3))
            Issue.record("second reservation crossed the global client bound")
        } catch {
            #expect(error as? V2RoomCallFailure == .notAccepted(.overloaded))
        }
        await gate.open()
        _ = try await executing.value
        let grant = try await first.value
        #expect(await caller.abort(grant, deadline: .now + .seconds(3)))
        #expect(await caller.reservationSlotSnapshot() == 0)
        await caller.stop()
        #expect((await fixture.host.drain(deadline: .now + .seconds(3))).completed)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
    }

    @Test("cancelling one bounded session waiter leaves its shared hello alive")
    func sharedHelloCancellation() async throws {
        let gate = RestoreGate()
        let fixture = try await Fixture(restoreGate: gate, maximumInboundRequests: 1,
                                        maximumResolveAttempts: 16)
        let grant = try await fixture.open()
        let blockerCall = fixture.call(grant: grant, sequence: 1,
                                       request: .activate(roomID: fixture.room, owner: fixture.owner))
        let blocker = Task {
            try await fixture.endpoint.exchange(fixture.client.sign(blockerCall, maximumBytes: 10_000))
        }
        try await gate.waitForEntry()
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.client,
                                         trust: fixture.trust, limits: fixture.limits,
                                         configuration: fixture.configuration)
        try await caller.register(.init(
            identity: fixture.identity, endpointID: fixture.endpoint.id,
            address: "127.0.0.1", port: fixture.port,
            accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true
        ))
        let deadline = ContinuousClock.now + .seconds(3)
        let first = Task {
            try await caller.activate(on: fixture.identity, roomID: fixture.room,
                                      owner: fixture.owner, deadline: deadline)
        }
        let second = Task {
            try await caller.activate(on: fixture.identity, roomID: fixture.room,
                                      owner: fixture.owner, deadline: deadline)
        }
        try await waitUntil { await caller.handshakeWaiterSnapshot() == 2 }
        let cancelledAt = ContinuousClock.now
        first.cancel()
        do { _ = try await first.value; Issue.record("cancelled waiter succeeded") }
        catch { #expect(error as? V2RoomCallFailure == .notAccepted(.cancelled)) }
        #expect(cancelledAt.duration(to: .now) < .milliseconds(150))
        #expect(await caller.handshakeWaiterSnapshot() == 1)
        await gate.open()
        _ = try await blocker.value
        guard case .ready(let token) = try await second.value else {
            Issue.record("remaining waiter did not complete shared hello"); return
        }
        #expect(token.roomID == fixture.room)
        #expect(await caller.sessionCount() == 1)
        await caller.stop()
        #expect((await fixture.host.drain(deadline: .now + .seconds(3))).completed)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
    }

    @Test("native finish timeout retains the dispatch slot until invalidation ends")
    func timedOutNativeFinish() async throws {
        let gate = RestoreGate()
        let fixture = try await Fixture(invalidationGate: gate)
        guard case .ready(let token) = try await fixture.host.activate(
            roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(3)
        ) else { Issue.record("expected ready"); return }
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.coordinator,
                                         trust: fixture.trust, limits: fixture.limits,
                                         configuration: fixture.configuration)
        try await caller.register(.init(
            identity: fixture.identity, endpointID: fixture.endpoint.id,
            address: "127.0.0.1", port: fixture.port,
            accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true
        ))
        #expect(try await caller.lookup(token, deadline: .now + .seconds(3)))
        let grant = try await caller.reserve(token, requestID: UUID(), deadline: .now + .seconds(3))
        try await caller.markDispatched(grant, deadline: .now + .seconds(3))
        let finished = Task {
            await caller.finish(grant, completion: .committed,
                                deadline: .now + .milliseconds(100))
        }
        try await gate.waitForEntry()
        #expect(!(await finished.value))
        #expect(await caller.dispatchedCallCount() == 1)
        #expect(!(await caller.quiesce(deadline: .now + .milliseconds(30))))
        await gate.open()
        try await waitUntil { await caller.dispatchedCallCount() == 0 }
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        #expect((await fixture.host.drain(deadline: .now + .seconds(3))).completed)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
    }

    @Test("a failed Host activation coalesces recovery while its actual restore remains owned")
    func sharedHostRecoveryAfterNativeTimeout() async throws {
        let probeStarted = ContinuousClock.now
        let firstLookupDeadline = probeStarted + .milliseconds(300)
        #expect(V2RoomClusterClient.recoveryProbeDeadline(for: firstLookupDeadline, now: probeStarted)
                == firstLookupDeadline)
        #expect(V2RoomClusterClient.recoveryProbeDeadline(for: probeStarted + .seconds(30), now: probeStarted)
                == probeStarted + .seconds(3))
        let gate = RestoreGate()
        let blockedRoom = RoomID(uuid: UUID())
        let fixture = try await Fixture(restoreGate: gate, maximumActiveRooms: 3, restoreGateRoom: blockedRoom)
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.coordinator,
            trust: fixture.trust, limits: fixture.limits, configuration: fixture.configuration)
        var testError: (any Error)?
        do {
            try await caller.register(.init(identity: fixture.identity, endpointID: fixture.endpoint.id,
                address: "127.0.0.1", port: fixture.port, accessibleShardIDs: ["allowed"],
                availableRooms: 2, isHealthy: true))
            guard case .ready(let first) = try await caller.activate(on: fixture.identity,
                roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(3)),
                  case .ready(let second) = try await caller.activate(on: fixture.identity,
                roomID: .init(uuid: UUID()), owner: fixture.owner, deadline: .now + .seconds(3)) else {
                throw V2ActorAuthenticationError.invalidConfiguration
            }
            let timedOut = Task {
                try await caller.activate(on: fixture.identity, roomID: blockedRoom,
                    owner: fixture.owner, deadline: .now + .milliseconds(100))
            }
            try await gate.waitForEntry()
            do { _ = try await timedOut.value; Issue.record("gated activation unexpectedly completed") }
            catch {
                let failure = error as? V2RoomCallFailure
                #expect(failure == .notAccepted(.deadlineExceeded) || failure == .outcomeUnknown)
            }
            // Recovery backoff is a monotonic availability delay, never a lease expiry shortcut.
            try await Task.sleep(for: .milliseconds(120))
            let recovered = try await withThrowingTaskGroup(of: Bool.self) { group in
                for token in [first, second] {
                    group.addTask { try await caller.lookup(token, deadline: .now + .seconds(3)) }
                }
                var values: [Bool] = []
                for try await value in group { values.append(value) }
                return values
            }
            #expect(recovered.count == 2 && recovered.allSatisfy { $0 })
            let metrics = await caller.callMetricsSnapshot()
            #expect(metrics.hostRecoveryProbes == 1)
            #expect(metrics.activeHostRecoveries == 0)
            #expect(await caller.physicalReferenceCount() == 2)
            // Activation's caller has timed out, but the actual restore is still owned by Host.
            #expect(!(await fixture.host.drain(deadline: .now + .milliseconds(30))).completed)
        } catch { testError = error }
        await gate.open()
        try await waitUntil { await caller.dispatchedCallCount() == 0 }
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        #expect((await caller.callMetricsSnapshot()).activeHostRecoveries == 0)
        #expect((await fixture.host.drain(deadline: .now + .seconds(3))).completed)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
        if let testError { throw testError }
    }

    @Test("a room RPC transport failure preserves a healthy second room cache on the same host")
    func failedRoomDoesNotSuspendHealthyRoom() async throws {
        let gate = RestoreGate()
        let fixture = try await Fixture(invalidationGate: gate, coordinatorUserCalls: true)
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.coordinator,
            trust: fixture.trust, limits: fixture.limits, configuration: fixture.configuration)
        var testError: (any Error)?
        do {
            try await caller.register(.init(identity: fixture.identity, endpointID: fixture.endpoint.id,
                address: "127.0.0.1", port: fixture.port, accessibleShardIDs: ["allowed"],
                availableRooms: 2, isHealthy: true))
            guard case .ready(let first) = try await caller.activate(on: fixture.identity,
                roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(3)),
                  case .ready(let second) = try await caller.activate(on: fixture.identity,
                roomID: .init(uuid: UUID()), owner: fixture.owner, deadline: .now + .seconds(3)) else {
                throw V2ActorAuthenticationError.invalidConfiguration
            }
            let grant = try await caller.reserve(first, requestID: UUID(), deadline: .now + .seconds(3))
            try await caller.markDispatched(grant, deadline: .now + .seconds(3))
            let timedOut = Task {
                await caller.finish(grant, completion: .committed, deadline: .now + .milliseconds(100))
            }
            try await gate.waitForEntry()
            #expect(!(await timedOut.value))
            #expect(await caller.dispatchedCallCount() == 1)
            let before = await caller.callMetricsSnapshot()
            let user = UserID(uuid: UUID())
            let request = try V2RoomRequest.messaging(.sendOperation(try .init(command: try .init(
                roomID: second.roomID, senderUserID: user, clientMessageID: .init(uuid: UUID()),
                text: "healthy-peer-room", media: [], mentions: [], entities: [], replyTo: nil,
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)))
            let result = try await caller.tryInvokeCached(second, request: request,
                principal: .user(user), deadline: .now + .seconds(3))
            guard case .response(let response) = result else { throw V2ActorAuthenticationError.invalidConfiguration }
            #expect(response == .recovery(.failure(.invalidRequest)))
            let after = await caller.callMetricsSnapshot()
            #expect(after.roomLookups == before.roomLookups)
            #expect(after.roomInvocations == before.roomInvocations + 1)
            #expect(after.hostRecoveryProbes == 0)
            #expect(await caller.physicalReferenceCount() == 1) // only the failed room was evicted
            #expect(await caller.dispatchedCallCount() == 1)
            #expect(!(await caller.quiesce(deadline: .now + .milliseconds(30))))
        } catch { testError = error }
        await gate.open()
        try await waitUntil { await caller.dispatchedCallCount() == 0 }
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        #expect((await fixture.host.drain(deadline: .now + .seconds(3))).completed)
        await fixture.inbound.stop()
        try await fixture.system.shutdown().wait()
        if let testError { throw testError }
    }

    @Test("cancelled caller leaves a dispatched inbound operation tracked through late completion")
    func cancelledDispatchedCallFinishesPhysically() async throws {
        let gate = RestoreGate()
        let fixture = try await Fixture(executeGate: gate)
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.client,
                                         trust: fixture.trust, limits: fixture.limits,
                                         configuration: fixture.configuration)
        var inFlight: Task<V2RoomResponse, any Error>?
        var exerciseError: (any Error)?
        do {
            guard case .ready(let token) = try await fixture.host.activate(
                roomID: fixture.room, owner: fixture.owner, deadline: .now + .seconds(3)
            ) else {
                Issue.record("expected ready")
                throw V2ActorAuthenticationError.invalidConfiguration
            }
            try await caller.register(.init(
                identity: fixture.identity, endpointID: fixture.endpoint.id,
                address: "127.0.0.1", port: fixture.port,
                accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true
            ))
            guard try await caller.lookup(token, deadline: .now + .seconds(3)) else {
                Issue.record("expected physical room lookup")
                throw V2ActorAuthenticationError.invalidConfiguration
            }
            let user = UserID(uuid: UUID())
            let request = try V2RoomRequest.messaging(.sendOperation(try .init(command: try .init(
                roomID: fixture.room, senderUserID: user,
                clientMessageID: ClientMessageID(uuid: UUID()), text: "late-completion",
                media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)))
            let call = Task {
                try await caller.invoke(token, request: request, principal: .user(user),
                                        deadline: .now + .seconds(3))
            }
            inFlight = call
            try await gate.waitForEntry()
            #expect(await fixture.inbound.inFlightRequestCount() == 1)
            #expect(await caller.dispatchedCallCount() == 1)
            #expect(await fixture.executionCount.snapshot() == 0)
            call.cancel()
            do {
                _ = try await call.value
                Issue.record("cancelled dispatched write returned success")
            } catch {
                #expect(error as? V2RoomCallFailure == .outcomeUnknown)
            }
            #expect(await caller.dispatchedCallCount() == 1)
            #expect(await fixture.executionCount.snapshot() == 0)
            #expect(!(await caller.quiesce(deadline: .now + .milliseconds(30))))
            await gate.open()
            try await waitUntil { await caller.dispatchedCallCount() == 0 }
            #expect(await fixture.executionCount.snapshot() == 1)
        } catch {
            exerciseError = error
        }

        // Even a failure before gate entry must let a late inbound arrival
        // finish before stopping the client and shutting down ClusterSystem.
        await gate.openAndRemainOpen()
        if let inFlight {
            inFlight.cancel()
            _ = try? await inFlight.value
        }
        let clientDrained = await caller.quiesce(deadline: .now + .seconds(3))
        let hostDrained = await fixture.host.drain(deadline: .now + .seconds(3))
        await fixture.inbound.stop()
        var shutdownError: (any Error)?
        do { try await fixture.system.shutdown().wait() }
        catch { shutdownError = error }
        if let exerciseError { throw exerciseError }
        if let shutdownError { throw shutdownError }
        #expect(clientDrained)
        #expect(hostDrained.completed)
    }

    @Test("replacement preserves a dispatched old-incarnation signed reply until completion")
    func replacementDrainsOldRPC() async throws {
        let gate = RestoreGate()
        let fixture = try await Fixture(restoreGate: gate)
        let caller = V2RoomClusterClient(system: fixture.system, signer: fixture.client,
                                         trust: fixture.trust, limits: fixture.limits,
                                         configuration: fixture.configuration)
        try await caller.register(.init(
            identity: fixture.identity, endpointID: fixture.endpoint.id,
            address: "127.0.0.1", port: fixture.port,
            accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true
        ))
        let inFlight = Task {
            try await caller.activate(on: fixture.identity, roomID: fixture.room,
                                      owner: fixture.owner, deadline: .now + .seconds(3))
        }
        try await gate.waitForEntry()
        let replacement = V2ActorHostIdentity(hostID: fixture.identity.hostID,
                                               incarnationID: UUID())
        try await caller.installDiscovered(.init(
            identity: replacement, endpointID: fixture.endpoint.id,
            address: "127.0.0.1", port: fixture.port,
            accessibleShardIDs: ["allowed"], availableRooms: 2, isHealthy: true
        ))
        #expect(await caller.retiredDescriptorCount() == 1)
        await gate.open()
        guard case .ready(let token) = try await inFlight.value else {
            Issue.record("the old signed reply was discarded"); return
        }
        #expect(token.host == fixture.identity)
        try await waitUntil { await caller.retiredDescriptorCount() == 0 }
        await caller.stop()
        #expect((await fixture.host.drain(deadline: .now + .seconds(3))).completed)
        await fixture.inbound.stop()
        #expect(await caller.quiesce(deadline: .now + .seconds(3)))
        try await fixture.system.shutdown().wait()
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw V2ActorAuthenticationError.overloaded }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func expectAuthentication(_ expected: V2ActorAuthenticationError,
                                      action: () async throws -> Void) async {
        do { try await action(); Issue.record("unexpected authorization") }
        catch { #expect(error as? V2ActorAuthenticationError == expected) }
    }

    private struct Fixture {
        let system: ClusterSystem
        let endpoint: V2RoomHostEndpoint
        let inbound: V2RoomClusterInboundService
        let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
        let configuration: V2RoomRuntimeConfiguration
        let limits: V2ActorAuthenticationLimits
        let port: Int
        let room = RoomID(uuid: UUID())
        let owner: V2RoomDataOwner
        let identity: V2ActorHostIdentity
        let client: V2ActorSigningIdentity
        let coordinator: V2ActorSigningIdentity
        let trust: V2ActorTrustStore
        let generation = UUID()
        let executionCount: ExecutionCount

        init(restoreGate: RestoreGate? = nil, executeGate: RestoreGate? = nil,
             invalidationGate: RestoreGate? = nil,
             maximumInboundRequests: Int = 2,
             maximumResolveAttempts: Int = 3,
             maximumActiveRooms: Int = 2, restoreGateRoom: RoomID? = nil,
             coordinatorUserCalls: Bool = false, recoveryBatchGate: RecoveryBatchGate? = nil,
             maximumActivationWaitersPerHost: Int = 2, maximumConcurrentReservations: Int = 1,
             ownerShardID: String = "allowed") async throws {
            owner = try .init(shardID: ownerShardID, epoch: 0)
            identity = .init(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
            let clientKey = Curve25519.Signing.PrivateKey()
            let coordinatorKey = Curve25519.Signing.PrivateKey()
            let hostKey = Curve25519.Signing.PrivateKey()
            client = try .init(serviceID: V2ActorServiceID("gateway"),
                               privateKey: clientKey.rawRepresentation)
            coordinator = try .init(serviceID: V2ActorServiceID("coordinator"),
                                    privateKey: coordinatorKey.rawRepresentation)
            let signer = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("host"),
                                                    privateKey: hostKey.rawRepresentation)
            trust = try .init(services: [
                .init(serviceID: client.serviceID, publicKey: clientKey.publicKey.rawRepresentation,
                      permissions: [.userRoomCalls]),
                .init(serviceID: coordinator.serviceID,
                      publicKey: coordinatorKey.publicKey.rawRepresentation,
                      permissions: coordinatorUserCalls ? [.roomCoordination, .userRoomCalls] : [.roomCoordination]),
                .init(serviceID: signer.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                      permissions: [], hostedIDs: [identity.hostID]),
            ])
            configuration = try V2RoomRuntimeConfiguration(
                maximumActiveRooms: maximumActiveRooms, maximumConcurrentRestores: 1,
                maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 2,
                maximumActivationWaitersPerHost: maximumActivationWaitersPerHost, maximumConcurrentResolutions: 1,
                maximumConcurrentReservations: maximumConcurrentReservations,
                maximumResolveAttempts: maximumResolveAttempts
            )
            let count = ExecutionCount()
            executionCount = count
            host = .init(
                identity: identity, leaseStore: LeaseStore(), configuration: configuration,
                budget: V2RoomCommandBudget(configuration: configuration), classify: { _ in .barrier },
                factory: .init(recoveryBatch: { items in
                    if let recoveryBatchGate { await recoveryBatchGate.execute(items.count) }
                    return .committed(items.map { item in
                        .init(token: item.token, query: item.query,
                            outcome: .result(.recovery(.state(.state(.init(roomID: item.query.roomID,
                                ownerEpoch: UInt64(item.token.owner.epoch), viewerMembershipRevision: 1,
                                head: 7, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0))))))
                    })
                }) { token in
                    .init(restore: { _ in
                        if let restoreGate, restoreGateRoom == nil || restoreGateRoom == token.roomID {
                            await restoreGate.wait()
                        }
                    },
                          execute: { turn in
                              if let executeGate { await executeGate.wait() }
                              await count.record()
                              return .committed(turn.items.map { _ in .recovery(.failure(.invalidRequest)) })
                          },
                          invalidateReservation: { _ in
                              if let invalidationGate { await invalidationGate.wait() }
                          }, close: {})
                }
            )
            port = Int.random(in: 30_000...60_000)
            var settings = ClusterSystemSettings(name: "v2-room-bridge-test", host: "127.0.0.1",
                                                 port: port)
            settings.threadPoolSize = 1
            settings.serialization.registerInbound(V2ActorAuthenticationError.self)
            settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
            system = await ClusterSystem("v2-room-bridge-test", settings: settings)
            limits = try V2ActorAuthenticationLimits()
            inbound = try .init(
                identity: identity, host: host,
                authenticator: .init(host: identity, trust: trust, limits: limits), signer: signer,
                limits: limits, allowedShards: [owner.shardID],
                serviceShardAccess: [client.serviceID: [owner.shardID],
                                     coordinator.serviceID: [owner.shardID]],
                maximumInboundRequests: maximumInboundRequests,
                localGeneration: generation, actorSystem: system
            )
            endpoint = V2RoomHostEndpoint(actorSystem: system, service: inbound)
            await host.start()
            await inbound.startWatching()
        }

        func open() async throws -> V2ActorSessionGrant {
            let hello = V2ActorSessionHello(serviceID: client.serviceID, callerIncarnation: UUID(),
                                            recipient: identity, handshakeID: UUID())
            let reply = try await endpoint.openSession(client.sign(hello, maximumBytes: 10_000))
            return try trust.verifySessionGrant(reply, for: hello, maximumBytes: 10_000)
        }

        func call(grant: V2ActorSessionGrant, sequence: UInt64,
                  request: V2ActorRPCRequest,
                  principal: V2ActorCallPrincipal = .service) -> V2ActorAuthenticatedCall {
            .init(serviceID: client.serviceID, callerIncarnation: grant.callerIncarnation,
                  recipient: identity, sessionID: grant.sessionID, sequence: sequence,
                  attemptID: UUID(), traceID: UUID(), remainingBudget: try! .init(2_000),
                  principal: principal, request: request)
        }
    }

    private actor LeaseStore: V2RoomActivationLeaseStore {
        private var current: [RoomID: V2RoomActivationLease] = [:]
        private var epoch: Int64 = 0

        func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
            current[roomID]
        }
        func acquire(roomID: RoomID, owner: V2RoomDataOwner, host: V2ActorHostIdentity,
                     duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
            if let lease = current[roomID] { return .occupied(lease) }
            epoch += 1
            let token = V2RoomActivationToken(roomID: roomID, owner: owner,
                                              activationEpoch: try .init(epoch), host: host)
            let lease = try makeLease(token, duration: duration)
            current[roomID] = lease
            return .acquired(lease)
        }
        func renew(token: V2RoomActivationToken,
                   duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
            guard current[token.roomID]?.token == token else { throw V2RoomActivationLeaseError.activationChanged }
            let lease = try makeLease(token, duration: duration)
            current[token.roomID] = lease
            return lease
        }
        func release(token: V2RoomActivationToken) async throws -> Bool {
            guard current[token.roomID]?.token == token else { return false }
            current.removeValue(forKey: token.roomID)
            return true
        }
        private func makeLease(_ token: V2RoomActivationToken,
                               duration: V2ActorMilliseconds) throws -> V2RoomActivationLease {
            let observed = Date(timeIntervalSince1970: 1_000)
            return try .init(token: token, databaseObservedAt: observed,
                             expiresAt: observed.addingTimeInterval(Double(duration.rawValue) / 1_000))
        }
    }

    private actor RecoveryBatchGate {
        private var blocked = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private(set) var executedItemCounts: [Int] = []
        var heldCount: Int { held.count }
        func hold() { blocked = true }
        func execute(_ count: Int) async {
            executedItemCounts.append(count)
            if blocked { await withCheckedContinuation { held.append($0) } }
        }
        func release() {
            blocked = false
            let old = held; held.removeAll()
            for continuation in old { continuation.resume() }
        }
    }

    private actor RestoreGate {
        private var entered = false
        private var remainOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            if remainOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func waitForEntry() async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !entered {
                guard ContinuousClock.now < deadline else { throw V2ActorAuthenticationError.overloaded }
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        func open() { continuation?.resume(); continuation = nil }

        func openAndRemainOpen() {
            remainOpen = true
            open()
        }
    }

    private actor ExecutionCount {
        private var value = 0

        func record() { value += 1 }
        func snapshot() -> Int { value }
    }
}
