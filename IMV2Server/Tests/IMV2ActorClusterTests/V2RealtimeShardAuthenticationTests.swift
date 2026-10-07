import Crypto
import DistributedCluster
import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorCluster

@Suite("Realtime partition signed calls and actual drain")
struct V2RealtimeShardAuthenticationTests {
    @Test func uuidTopicKeysNormalizeEveryEntryAndPreserveOpaqueCase() throws {
        let upper = "EED841A8-28BD-5C9D-8BDC-896DAEDCF9A3", lower = upper.lowercased()
        let direct = V2RealtimeTopicKey(kind: .userSync, id: upper)
        let other = V2RealtimeTopicKey(kind: .userSync, id: lower)
        #expect(direct == other && direct.id == lower && direct.partitionID() == other.partitionID())
        let json = Data("{\"kind\":\"userSync\",\"id\":\"\(upper)\"}".utf8)
        let decoded = try JSONDecoder().decode(V2RealtimeTopicKey.self, from: json)
        #expect(decoded == direct)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(V2RealtimeTopicKey.self, from: encoded) == other)
        let topic = V2RealtimeTopic(kind: .userSync, id: upper, owner: try .init(shardID: "users", epoch: 0))
        #expect(V2RealtimeTopicKey(topic) == direct)
        #expect(Set([direct, other, decoded]).count == 1)
        #expect(V2RealtimeTopicKey(kind: .userSync, id: "Opaque-User").id == "Opaque-User")
        #expect(V2RealtimeTopicKey(kind: .userSync, id: "Opaque-User") != .init(kind: .userSync, id: "opaque-user"))
    }

    @Test func partitionEncodingIsStableAndOwnerIndependent() throws {
        #expect(V2RealtimeTopicKey(kind: .roomEvents, id: "room-1").partitionID() == 255)
        #expect(V2RealtimeTopicKey(kind: .userSync, id: "user-1").partitionID() == 27)
        let a = V2RealtimeTopic(kind: .roomEvents, id: "room-1", owner: try .init(shardID: "a", epoch: 1))
        let b = V2RealtimeTopic(kind: .roomEvents, id: "room-1", owner: try .init(shardID: "b", epoch: 99))
        #expect(V2RealtimeTopicKey(a) == V2RealtimeTopicKey(b))
    }

    @Test func cachedLeaseDurationUsesItsOriginalMonotonicDeadline() throws {
        let f = try Fixture()
        let descriptor = V2RealtimeShardDescriptor(token: f.token, endpointReference: Data([1]),
            address: "localhost", port: 7337, remainingLeaseMilliseconds: 10_000)
        let began = ContinuousClock.now, deadline = began + .seconds(10)
        #expect(v2RealtimeShardDescriptorSnapshot(descriptor, expiresAt: deadline, now: began + .seconds(3))?.remainingLeaseMilliseconds == 7_000)
        #expect(v2RealtimeShardDescriptorSnapshot(descriptor, expiresAt: deadline, now: deadline) == nil)
        #expect(v2RealtimeShardDescriptorSnapshot(descriptor, expiresAt: deadline, now: deadline + .seconds(1)) == nil)
        #expect(v2RealtimeShardDescriptorSnapshot(descriptor, expiresAt: began + .seconds(20), now: began + .seconds(3))?.remainingLeaseMilliseconds == 10_000)
    }

    @Test func controlIdentityPublishAuthorityAndReplay() async throws {
        let f = try Fixture()
        let grant = try await f.open()
        let request = f.control()
        let packet = try f.packet(.control(request), grant: grant, sequence: 1)
        let response = try await f.inbound.exchange(packet)
        let (reply, _) = try f.trust.verify(response, as: ShardReply.self, maximumBytes: 16_384)
        guard case .control(let result) = reply.result else { Issue.record("wrong reply kind"); return }
        #expect(result.appliedRevision == 0) // Renewal does not mutate the subscription revision.
        await #expect(throws: V2ActorAuthenticationError.replay) { try await f.inbound.exchange(packet) }
        let substituted = V2RealtimeShardControlRequest(token: f.token,
            session: .init(gateway: .init(identity: .init(nodeID: "other", serviceID: "other", incarnationID: f.gateway.incarnationID),
                endpointReference: Data([1]), address: "localhost", port: 7337), sessionID: UUID(), sessionGeneration: 1),
            baseRevision: 0, nextRevision: 0, mutation: .renew, payloadFingerprint: Data(repeating: 0, count: 32))
        await #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try await f.inbound.exchange(f.packet(.control(substituted), grant: grant, sequence: 2))
        }
        let forbidden = V2RealtimeShardPublishRequest(token: f.token,
            topic: .init(kind: .roomEvents, id: f.room.rawValue, owner: try .init(shardID: "forbidden", epoch: 0)),
            payload: .roomWake(roomID: f.room, highWatermark: 1))
        await #expect(throws: V2ActorAuthenticationError.forbidden) {
            try await f.inbound.exchange(f.packet(.publish(forbidden), grant: grant, sequence: 2))
        }
        let publish = V2RealtimeShardPublishRequest(token: f.token,
            topic: .init(kind: .roomEvents, id: f.room.rawValue, owner: try .init(shardID: "rooms", epoch: 0)),
            payload: .roomWake(roomID: f.room, highWatermark: 1))
        let published = try await f.inbound.exchange(f.packet(.publish(publish), grant: grant, sequence: 2))
        let (publishedReply, _) = try f.trust.verify(published, as: ShardReply.self, maximumBytes: 16_384)
        guard case .publish(let acceptance) = publishedReply.result else { Issue.record("wrong publish reply"); return }
        #expect(acceptance == .acceptedAsWatermark)
        #expect(await f.serving.calls == 2)
    }

    @Test func stopKeepsActuallyStartedControlUntilItsReplyCompletes() async throws {
        let f = try Fixture(held: true)
        let grant = try await f.open()
        let packet = try f.packet(.control(f.control()), grant: grant, sequence: 1)
        let actual = Task { try await f.inbound.exchange(packet) }
        await f.serving.waitForEntry()
        #expect(await f.inbound.stop(deadline: .now) == false)
        await #expect(throws: V2ActorAuthenticationError.overloaded) {
            try await f.inbound.exchange(f.packet(.control(f.control()), grant: grant, sequence: 2))
        }
        await f.serving.release()
        let response = try await actual.value
        let (reply, _) = try f.trust.verify(response, as: ShardReply.self, maximumBytes: 16_384)
        #expect(reply.sequence == 1)
        #expect(await f.inbound.stop(deadline: .now + .seconds(1)))
    }

    @Test func fixedRosterQualificationRequiresMajorityAndPreservesOnlyLiveGenerations() throws {
        let two = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b"])
        let now = ContinuousClock.now
        #expect(two.update(witnesses: ["a": now + .seconds(100), "outside": now + .seconds(100)]) == nil)
        let first = try #require(two.update(witnesses: ["b": now + .seconds(10)]))
        let refreshed = try #require(two.update(witnesses: ["b": now + .seconds(20)]))
        #expect(first.generation == refreshed.generation)
        #expect(two.update(witnesses: ["b": now - .seconds(1)]) == nil)
        let successor = try #require(two.update(witnesses: ["b": now + .seconds(20)]))
        #expect(successor.generation != first.generation)
        two.revoke(); #expect(two.snapshot() == nil)
        #expect(try #require(two.update(witnesses: ["b": now + .seconds(20)])).generation != successor.generation)
        let three = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        #expect(three.snapshot() == nil)
        let majority = try #require(three.update(witnesses: ["b": now + .seconds(4), "c": now + .seconds(9)]))
        #expect(majority.validUntil == now + .seconds(9))
        let five = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c", "d", "e"])
        let selected = try #require(five.update(witnesses: ["b": now + .seconds(4), "c": now + .seconds(9), "d": now + .seconds(7)]))
        #expect(selected.validUntil == now + .seconds(7))
        let standalone = V2ActorServiceQualification.standalone()
        #expect(standalone.snapshot()?.generation == standalone.snapshot()?.generation)
        #expect(!standalone.matches(localNodeID: "a", roster: ["a", "b"]))
    }

    @Test func discoveryAuthenticatesRequesterRosterAndRecipient() throws {
        let f = try Fixture(), digest = Data(repeating: 7, count: 32), challenge = UUID()
        let roster = [f.gateway.nodeID: f.gateway.serviceID, f.token.host.nodeID: f.token.host.serviceID]
        func verify(_ request: ShardDiscoveryRequest, signer: V2ActorSigningIdentity) throws -> ShardDiscoveryRequest {
            try v2VerifyShardDiscoveryRequest(signer.sign(request, maximumBytes: 16_384), trust: f.trust,
                recipient: f.token.host, roster: roster, rosterDigest: digest)
        }
        let request = ShardDiscoveryRequest(requester: f.gateway, recipientNodeID: f.token.host.nodeID, challenge: challenge, rosterDigest: digest)
        let accepted = try verify(request, signer: f.caller)
        #expect(accepted.requester == f.gateway && accepted.challenge == challenge)
        #expect(throws: V2ActorAuthenticationError.self) {
            try verify(.init(requester: f.gateway, recipientNodeID: "other", challenge: challenge, rosterDigest: digest), signer: f.caller)
        }
        #expect(throws: V2ActorAuthenticationError.self) {
            try verify(.init(requester: f.gateway, recipientNodeID: f.token.host.nodeID, challenge: challenge, rosterDigest: Data()), signer: f.caller)
        }
        #expect(throws: V2ActorAuthenticationError.self) {
            try verify(.init(requester: f.token.host, recipientNodeID: f.token.host.nodeID, challenge: challenge, rosterDigest: digest), signer: f.caller)
        }
    }

    @Test func softReferenceSuspensionDrainsAndReauthenticatesSameIncarnation() async throws {
        let f = try Fixture(held: true)
        let port = Int.random(in: 30_000...60_000)
        var settings = ClusterSystemSettings(name: "shard-soft-reference", host: "127.0.0.1", port: port)
        settings.threadPoolSize = 1
        settings.downingStrategy = .none; settings.onDownAction = .none
        let system = await ClusterSystem("shard-soft-reference", settings: settings)
        let inbound = V2RealtimeShardInbound(identity: f.token.host, signer: f.receiver, trust: f.trust,
            serving: f.serving, serviceOwnerAccess: [f.caller.serviceID: ["rooms"]], limits: .init())
        let endpoint = V2RealtimeShardEndpoint(actorSystem: system, service: inbound)
        let bytes = try JSONEncoder().encode(endpoint.id); inbound.bindEndpointReference(bytes)
        let target = V2GatewayRealtimeDescriptor(identity: f.token.host, endpointReference: bytes, address: "127.0.0.1", port: port)
        let sender = try V2RealtimeShardSender(system: system, signer: f.caller, trust: f.trust, limits: .init(), incarnation: f.gateway.incarnationID)
        do { _ = try await sender.exchange(.control(f.control()), to: target); Issue.record("first-use reference was automatically admitted") }
        catch { #expect(error as? V2ActorAuthenticationError == .sessionExpired) }
        try await sender.installAuthenticatedReference(target)
        let first = Task { try await sender.exchange(.control(f.control()), to: target) }
        await f.serving.waitForEntry()
        #expect(!(await sender.beginRetirement(f.token.host, reference: bytes)))
        do { _ = try await sender.exchange(.control(f.control()), to: target); Issue.record("suspended reference accepted a new call") }
        catch { #expect(error as? V2ActorAuthenticationError == .sessionExpired) }
        let successorIdentity = V2GatewayRealtimeIdentity(nodeID: f.token.host.nodeID, serviceID: f.token.host.serviceID, incarnationID: UUID())
        let successor = V2GatewayRealtimeDescriptor(identity: successorIdentity, endpointReference: bytes, address: "127.0.0.1", port: port)
        try await sender.installAuthenticatedReference(successor, observation: 2)
        do { try await sender.installAuthenticatedReference(target, observation: 1); Issue.record("late discovery replaced current admission") }
        catch { #expect(error as? V2ActorAuthenticationError == .sessionExpired) }
        #expect(await sender.beginRetirement(successorIdentity, reference: bytes))
        #expect(!(await sender.beginRetirement(f.token.host, reference: bytes)))
        do { _ = try await sender.exchange(.control(f.control()), to: successor); Issue.record("old retirement reopened successor admission") }
        catch { #expect(error as? V2ActorAuthenticationError == .sessionExpired) }
        await f.serving.release()
        _ = try await first.value // A dispatched old-generation reply remains valid.

        #expect(await sender.beginRetirement(f.token.host, reference: bytes))
        try await sender.installAuthenticatedReference(target, observation: 3)
        let topic = V2RealtimeTopic(kind: .roomEvents, id: f.room.rawValue, owner: try .init(shardID: "rooms", epoch: 1))
        let second = try await sender.exchange(.publish(.init(token: f.token, topic: topic, payload: .roomWake(roomID: f.room, highWatermark: 1))), to: target)
        if case .publish(.acceptedAsWatermark) = second {} else { Issue.record("same-incarnation reauthenticated call failed") }
        #expect(await f.serving.calls == 2)
        #expect(await sender.stop(deadline: .now + .seconds(2)))
        #expect(await inbound.stop(deadline: .now + .seconds(2)))
        try await system.shutdown().wait()
    }

    @Test func samePartitionMissesShareSignedDiscoveryDespitePartialCancellation() async throws {
        let f = try Fixture()
        let callerPort = Int.random(in: 30_000...44_999), peerPort = Int.random(in: 45_000...60_000)
        var callerSettings = ClusterSystemSettings(name: "shard-miss-caller", host: "127.0.0.1", port: callerPort)
        callerSettings.threadPoolSize = 1; callerSettings.downingStrategy = .none; callerSettings.onDownAction = .none
        var peerSettings = ClusterSystemSettings(name: "shard-miss-peer", host: "127.0.0.1", port: peerPort)
        peerSettings.threadPoolSize = 1; peerSettings.downingStrategy = .none; peerSettings.onDownAction = .none
        let callerSystem = await ClusterSystem("shard-miss-caller", settings: callerSettings)
        let peerSystem = await ClusterSystem("shard-miss-peer", settings: peerSettings)
        let peers: [V2RealtimeShardDiscoveryPeer] = [
            .init(nodeID: f.gateway.nodeID, serviceID: f.gateway.serviceID, address: "127.0.0.1", port: callerPort),
            .init(nodeID: f.token.host.nodeID, serviceID: f.token.host.serviceID, address: "127.0.0.1", port: peerPort)
        ]
        let roster = Dictionary(uniqueKeysWithValues: peers.map { ($0.nodeID, $0.serviceID) })
        let digest = Data(SHA256.hash(data: try JSONEncoder().encode(roster.sorted { $0.key < $1.key }.map { [$0.key, $0.value] })))
        let inbound = V2RealtimeShardInbound(identity: f.token.host, signer: f.receiver, trust: f.trust,
            serving: f.serving, serviceOwnerAccess: [f.caller.serviceID: ["rooms"]], limits: .init())
        let endpoint = V2RealtimeShardEndpoint(actorSystem: peerSystem, service: inbound)
        let reference = try JSONEncoder().encode(endpoint.id); inbound.bindEndpointReference(reference)
        let publisher = V2RealtimeShardPublisher(identity: f.token.host, signer: f.receiver, endpointID: endpoint.id,
            endpointReference: reference, trust: f.trust, roster: roster, rosterDigest: digest)
        try await publisher.install([.init(token: f.token, remainingLeaseMilliseconds: 30_000)])
        let beacon = V2RealtimeShardDiscoveryBeacon(actorSystem: peerSystem, publisher: publisher)
        await peerSystem.receptionist.checkIn(beacon, with: V2RealtimeShardDiscoveryBeacon.key(nodeID: f.token.host.nodeID))
        callerSystem.cluster.join(host: "127.0.0.1", port: peerPort)
        let transport = try buildRealtimeShardTransport(system: callerSystem, identity: f.gateway,
            address: "127.0.0.1", port: callerPort, signer: f.caller, trust: f.trust,
            serving: f.serving, serviceOwnerAccess: [f.caller.serviceID: ["rooms"]], discoveryPeers: peers, limits: .init())
        let barrier = SignedDiscoveryExecutorBarrier()
        var held: Task<Bool, Never>?
        var calls: [Task<V2RealtimeShardDescriptor, any Error>] = []
        do {
            let readyDeadline = ContinuousClock.now + .seconds(10)
            while await callerSystem.receptionist.lookup(V2RealtimeShardDiscoveryBeacon.key(nodeID: f.token.host.nodeID)).isEmpty {
                guard ContinuousClock.now < readyDeadline else { throw V2ActorAuthenticationError.sessionExpired }
                await Task.yield()
            }
            held = Task { await publisher.holdExecutorForSignedDiscovery(barrier) }
            while !barrier.entered.withLock({ $0 }) { await Task.yield() }
            await transport.start()
            calls = (0..<100).map { _ in Task { try await transport.resolve(partitionID: f.token.partitionID) } }
            let entryDeadline = ContinuousClock.now + .seconds(1)
            while await transport.metricsSnapshot().cacheMisses < 100 {
                guard ContinuousClock.now < entryDeadline else { throw V2ActorAuthenticationError.sessionExpired }
                await Task.yield()
            }
            let heldMetrics = await transport.metricsSnapshot()
            // discoveryPasses counts settled passes (pollFinished), not starts.
            // The signed-response executor is still held, so this one actual
            // pass must be active and none may have completed yet.
            #expect(heldMetrics.discoveryPasses == 0, "settled passes while held: \(heldMetrics.discoveryPasses)")
            #expect(heldMetrics.discoveryActive == 1, "active passes while held: \(heldMetrics.discoveryActive)")
            for call in calls.prefix(25) { call.cancel() }
            for call in calls.prefix(25) {
                do { _ = try await call.value; Issue.record("cancelled discovery waiter resolved") }
                catch { #expect(error is CancellationError) }
            }
            #expect(await transport.metricsSnapshot().discoveryActive == 1)
            barrier.release.signal()
            #expect(await held?.value == true)
            for call in calls.dropFirst(25) { #expect(try await call.value.token == f.token) }
            let result = await transport.metricsSnapshot()
            #expect(result.cacheMisses == 100 && result.cachedPartitions == 1)
            #expect(result.discoveryPasses == 1)
            let topic = V2RealtimeTopic(kind: .roomEvents, id: f.room.rawValue,
                owner: try .init(shardID: "rooms", epoch: 0))
            let callsBefore = await f.serving.calls
            for sequence in 1...10_000 {
                let cached = try await transport.resolve(partitionID: f.token.partitionID)
                #expect(cached.token == f.token)
                let reply = try await transport.publish(cached, request: .init(token: cached.token,
                    topic: topic, payload: .roomWake(roomID: f.room, highWatermark: UInt64(sequence))))
                #expect(reply == .acceptedAsWatermark)
            }
            let hot = await transport.metricsSnapshot()
            #expect(hot.cacheHits == result.cacheHits + 10_000)
            #expect(hot.cacheMisses == result.cacheMisses)
            #expect(await f.serving.calls == callsBefore + 10_000)
            // Periodic discovery runs independently; the exact hit/miss counts
            // establish that these calls did not enter cold discovery.
            #expect(await transport.stop(deadline: .now + .seconds(2)))
            let settled = await transport.metricsSnapshot()
            #expect(settled.discoveryActive == 0 && settled.pendingHandshakes == 0)
            #expect(await inbound.stop(deadline: .now + .seconds(2)))
            try await callerSystem.shutdown().wait(); try await peerSystem.shutdown().wait()
        } catch {
            barrier.release.signal()
            _ = await held?.value
            for call in calls { call.cancel() }
            for call in calls { _ = await call.result }
            _ = await transport.stop(deadline: .now + .seconds(2))
            _ = await inbound.stop(deadline: .now + .seconds(2))
            try? await callerSystem.shutdown().wait(); try? await peerSystem.shutdown().wait()
            throw error
        }
    }

    private struct Fixture: Sendable {
        let caller: V2ActorSigningIdentity
        let receiver: V2ActorSigningIdentity
        let trust: V2ActorTrustStore
        let gateway: V2GatewayRealtimeIdentity
        let token: V2RealtimeShardToken
        let room: RoomID
        let serving: Serving
        let inbound: V2RealtimeShardInbound
        init(held: Bool = false) throws {
            let room = RoomID(uuid: UUID()); self.room = room
            let callerKey = Curve25519.Signing.PrivateKey(), receiverKey = Curve25519.Signing.PrivateKey()
            caller = try .init(serviceID: V2ActorServiceID("gateway"), privateKey: callerKey.rawRepresentation)
            receiver = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("partition"), privateKey: receiverKey.rawRepresentation)
            trust = try .init(services: [
                .init(serviceID: caller.serviceID, publicKey: callerKey.publicKey.rawRepresentation,
                    permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: ["gateway-node"]),
                .init(serviceID: receiver.serviceID, publicKey: receiverKey.publicKey.rawRepresentation,
                    permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: ["partition-node"])
            ])
            gateway = .init(nodeID: "gateway-node", serviceID: "gateway", incarnationID: UUID())
            let identity = V2GatewayRealtimeIdentity(nodeID: "partition-node", serviceID: "partition", incarnationID: UUID())
            token = .init(partitionID: V2RealtimeTopicKey(kind: .roomEvents, id: room.rawValue).partitionID(), host: identity, epoch: 1, leaseToken: UUID())
            serving = Serving(held: held)
            inbound = .init(identity: identity, signer: receiver, trust: trust, serving: serving,
                serviceOwnerAccess: [caller.serviceID: ["rooms"]], limits: .init())
            inbound.bindEndpointReference(Data([7]))
        }
        func open() async throws -> RealtimeGrant {
            let hello = RealtimeHello(serviceID: caller.serviceID, version: 1, callerIncarnation: gateway.incarnationID,
                recipient: token.host, handshakeID: UUID(), endpointDigest: Data(SHA256.hash(data: Data([7]))))
            let response = try await inbound.openSession(caller.sign(hello, maximumBytes: 16_384))
            return try trust.verify(response, as: RealtimeGrant.self, maximumBytes: 16_384).0
        }
        func control() -> V2RealtimeShardControlRequest {
            .init(token: token, session: .init(gateway: .init(identity: gateway, endpointReference: Data([1]),
                address: "localhost", port: 7337), sessionID: UUID(), sessionGeneration: 1),
                baseRevision: 0, nextRevision: 0, mutation: .renew, payloadFingerprint: Data(repeating: 0, count: 32))
        }
        func packet(_ operation: ShardOperation, grant: RealtimeGrant, sequence: UInt64) throws -> V2ActorSignedPacket {
            try caller.sign(ShardCall(serviceID: caller.serviceID, version: 1, callerIncarnation: gateway.incarnationID,
                recipient: token.host, sessionID: grant.sessionID, sequence: sequence, attemptID: UUID(), operation: operation), maximumBytes: 262_144)
        }
    }
    private actor Serving: V2RealtimeShardServing {
        let held: Bool
        var calls = 0
        var entryWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseWaiter: CheckedContinuation<Void, Never>?
        init(held: Bool) { self.held = held }
        func waitForEntry() async { if calls > 0 { return }; await withCheckedContinuation { entryWaiters.append($0) } }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
        func control(_ request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
            calls += 1; entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
            if held { await withCheckedContinuation { releaseWaiter = $0 } }
            return .init(appliedRevision: request.nextRevision, remainingSessionMilliseconds: 10_000, status: .applied)
        }
        func publish(_ request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply {
            calls += 1; return .acceptedAsWatermark
        }
    }
}

// Test-only actor-executor barrier. The production signed advertisement and
// verification execute unchanged after release; no discovery result is mocked.
private final class SignedDiscoveryExecutorBarrier: @unchecked Sendable {
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
}
private extension V2RealtimeShardPublisher {
    func holdExecutorForSignedDiscovery(_ barrier: SignedDiscoveryExecutorBarrier) -> Bool {
        barrier.entered.withLock { $0 = true }
        return barrier.release.wait(timeout: .now() + 2) == .success
    }
}
