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
        struct RawTopic: Encodable { let kind: V2RealtimeTopicKind; let id: String }
        let wire = try V2ActorProtobuf.encode(RawTopic(kind: .userSync, id: upper))
        let decoded = try V2ActorProtobuf.decode(V2RealtimeTopicKey.self, from: wire)
        #expect(decoded == direct)
        let encoded = try V2ActorProtobuf.encode(decoded)
        #expect(try V2ActorProtobuf.decode(V2RealtimeTopicKey.self, from: encoded) == other)
        let topic = V2RealtimeTopic(kind: .userSync, id: upper, owner: try .init(shardID: "users", epoch: 0))
        #expect(V2RealtimeTopicKey(topic) == direct)
        #expect(Set([direct, other, decoded]).count == 1)
        #expect(V2RealtimeTopicKey(kind: .userSync, id: "Opaque-User").id == "Opaque-User")
        #expect(V2RealtimeTopicKey(kind: .userSync, id: "Opaque-User") != .init(kind: .userSync, id: "opaque-user"))
    }

    @Test func standbyRefreshesCommittedMembershipBeforeJoining() async throws {
        let f = try Fixture()
        let port = Int.random(in: 30_000...44_999)
        var settings = ClusterSystemSettings(name: "standby-refresh", host: "127.0.0.1", port: port)
        settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
        let system = await ClusterSystem("standby-refresh", settings: settings)
        let existing = V2RealtimeShardDiscoveryPeer(nodeID: f.token.host.nodeID,
            serviceID: f.token.host.serviceID, address: "127.0.0.1", port: port + 1)
        let local = V2RealtimeShardDiscoveryPeer(nodeID: f.gateway.nodeID,
            serviceID: f.gateway.serviceID, address: "127.0.0.1", port: port)
        let record = try V2ActorServiceMembershipRecord(revision: 1, current: [existing.nodeID], peers: [existing])
        let qualification = try V2ActorServiceQualification(localNodeID: f.gateway.nodeID,
            membership: record.membership, allowNonMember: true)
        let transport = try buildRealtimeShardTransport(system: system, identity: f.gateway,
            address: local.address, port: local.port, signer: f.caller, trust: f.trust,
            serving: f.serving, serviceOwnerAccess: [f.caller.serviceID: ["rooms"]],
            discoveryPeers: [existing], limits: .init(), serviceQualification: qualification)
        do {
            await transport.start()
            try await transport.installCommittedMembership(record)
            try await transport.installCommittedMembership(record)
            #expect(qualification.snapshot() == nil)
            #expect(await transport.metricsSnapshot().cachedPartitions == 0)
            let moved = V2RealtimeShardDiscoveryPeer(nodeID: local.nodeID, serviceID: local.serviceID,
                address: local.address, port: local.port + 2)
            await #expect(throws: V2ActorAuthenticationError.self) {
                try await transport.installCommittedMembership(.init(revision: 2, current: [existing.nodeID],
                    next: [existing.nodeID, local.nodeID], peers: [existing, moved]))
            }
            #expect(qualification.membership.revision == 1)
            // Allow the initial nonmember refresh to enter its one-second sleep.
            // Joining must initiate evidence collection without a business miss.
            try await Task.sleep(for: .milliseconds(100))
            let before = await transport.metricsSnapshot().discoveryPasses
            try await transport.installCommittedMembership(.init(revision: 2, current: [existing.nodeID],
                next: [existing.nodeID, local.nodeID], peers: [existing, local]))
            let discoveryDeadline = ContinuousClock.now + .milliseconds(500)
            while await transport.metricsSnapshot().discoveryPasses == before,
                  ContinuousClock.now < discoveryDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await transport.metricsSnapshot().discoveryPasses > before)
            #expect(qualification.membership.revision == 2)
            #expect(qualification.snapshot() == nil) // The absent old voter still cannot authorize service.
            #expect(await transport.stop(deadline: .now + .seconds(5)))
            try await system.shutdown().wait()
        } catch {
            _ = await transport.stop(deadline: .now + .seconds(5))
            try? await system.shutdown().wait()
            throw error
        }
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

    @Test(arguments: [false, true]) func controlIdentityPublishAuthorityAndReplay(dynamic: Bool) async throws {
        let f = try Fixture(dynamic: dynamic)
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
        #expect(two.update(witnesses: ["a": now + .seconds(100), "outside": now + .seconds(100)], membershipRevision: 1) == nil)
        let first = try #require(two.update(witnesses: ["b": now + .seconds(10)], membershipRevision: 1))
        let refreshed = try #require(two.update(witnesses: ["b": now + .seconds(20)], membershipRevision: 1))
        #expect(first.generation == refreshed.generation)
        #expect(two.update(witnesses: ["b": now - .seconds(1)], membershipRevision: 1) == nil)
        let successor = try #require(two.update(witnesses: ["b": now + .seconds(20)], membershipRevision: 1))
        #expect(successor.generation != first.generation)
        two.revoke(); #expect(two.snapshot() == nil)
        #expect(try #require(two.update(witnesses: ["b": now + .seconds(20)], membershipRevision: 1)).generation != successor.generation)
        let three = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c"])
        #expect(three.snapshot() == nil)
        let majority = try #require(three.update(witnesses: ["b": now + .seconds(4), "c": now + .seconds(9)], membershipRevision: 1))
        #expect(majority.validUntil == now + .seconds(9))
        let five = try V2ActorServiceQualification(localNodeID: "a", roster: ["a", "b", "c", "d", "e"])
        let selected = try #require(five.update(witnesses: ["b": now + .seconds(4), "c": now + .seconds(9), "d": now + .seconds(7)], membershipRevision: 1))
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
                recipient: f.token.host, roster: roster, rosterDigest: digest, membershipRevision: 1)
        }
        let request = ShardDiscoveryRequest(requester: f.gateway, recipientNodeID: f.token.host.nodeID, challenge: challenge, rosterDigest: digest, membershipRevision: 1)
        let accepted = try verify(request, signer: f.caller)
        #expect(accepted.requester == f.gateway && accepted.challenge == challenge)
        for revision in [UInt64(0), 2, UInt64.max] {
            #expect(throws: V2ActorAuthenticationError.self) {
                try verify(.init(requester: f.gateway, recipientNodeID: f.token.host.nodeID,
                    challenge: challenge, rosterDigest: digest, membershipRevision: revision), signer: f.caller)
            }
        }
        #expect(throws: V2ActorAuthenticationError.self) {
            try verify(.init(requester: f.gateway, recipientNodeID: "other", challenge: challenge, rosterDigest: digest, membershipRevision: 1), signer: f.caller)
        }
        #expect(throws: V2ActorAuthenticationError.self) {
            try verify(.init(requester: f.gateway, recipientNodeID: f.token.host.nodeID, challenge: challenge, rosterDigest: Data(), membershipRevision: 1), signer: f.caller)
        }
        #expect(throws: V2ActorAuthenticationError.self) {
            try verify(.init(requester: f.token.host, recipientNodeID: f.token.host.nodeID, challenge: challenge, rosterDigest: digest, membershipRevision: 1), signer: f.caller)
        }
    }

    @Test func discoveryDigestBindsMembershipPhaseAndRevision() throws {
        let roster = ["a": "service-a", "b": "service-b"]
        let stable = try V2ActorServiceQualification.Membership(revision: 2, current: ["a", "b"])
        let joint = try V2ActorServiceQualification.Membership(revision: 2, current: ["a"], next: ["a", "b"])
        let next = try V2ActorServiceQualification.Membership(revision: 3, current: ["a", "b"])
        let digest = try v2RealtimeMembershipDigest(roster: roster, membership: stable)
        #expect(digest == (try v2RealtimeMembershipDigest(roster: ["b": "service-b", "a": "service-a"], membership: stable)))
        #expect(digest != (try v2RealtimeMembershipDigest(roster: roster, membership: joint)))
        #expect(digest != (try v2RealtimeMembershipDigest(roster: roster, membership: next)))
        #expect(digest != (try v2RealtimeMembershipDigest(roster: ["a": "other", "b": "service-b"], membership: stable)))
        #expect(throws: V2ActorAuthenticationError.self) {
            try v2RealtimeMembershipDigest(roster: ["a": "service-a"], membership: stable)
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
        let bytes = try V2ActorProtobuf.encode(endpoint.id); inbound.bindEndpointReference(bytes)
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

    @Test(arguments: [UInt64(1), UInt64(7)])
    func samePartitionMissesShareSignedDiscoveryDespitePartialCancellation(revision: UInt64) async throws {
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
        let membership = try V2ActorServiceQualification.Membership(revision: revision, current: Set(roster.keys))
        let qualification = try V2ActorServiceQualification(localNodeID: f.gateway.nodeID, membership: membership)
        let digest = try v2RealtimeMembershipDigest(roster: roster, membership: membership)
        let inbound = V2RealtimeShardInbound(identity: f.token.host, signer: f.receiver, trust: f.trust,
            serving: f.serving, serviceOwnerAccess: [f.caller.serviceID: ["rooms"]], limits: .init())
        let endpoint = V2RealtimeShardEndpoint(actorSystem: peerSystem, service: inbound)
        let reference = try V2ActorProtobuf.encode(endpoint.id); inbound.bindEndpointReference(reference)
        let publisher = V2RealtimeShardPublisher(identity: f.token.host, signer: f.receiver, endpointID: endpoint.id,
            endpointReference: reference, trust: f.trust, roster: roster, rosterDigest: digest, membershipRevision: revision)
        try await publisher.install([.init(token: f.token, remainingLeaseMilliseconds: 30_000)], membershipRevision: revision)
        let beacon = V2RealtimeShardDiscoveryBeacon(actorSystem: peerSystem, publisher: publisher)
        await peerSystem.receptionist.checkIn(beacon, with: V2RealtimeShardDiscoveryBeacon.key(nodeID: f.token.host.nodeID))
        callerSystem.cluster.join(host: "127.0.0.1", port: peerPort)
        let transport = try buildRealtimeShardTransport(system: callerSystem, identity: f.gateway,
            address: "127.0.0.1", port: callerPort, signer: f.caller, trust: f.trust,
            serving: f.serving, serviceOwnerAccess: [f.caller.serviceID: ["rooms"]], discoveryPeers: peers, limits: .init(),
            serviceQualification: qualification)
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
            #expect(qualification.membership.revision == revision)
            #expect(qualification.snapshot() != nil)
            await transport.suspendMembershipConfirmation()
            #expect(qualification.snapshot() == nil)
            #expect(qualification.update(witnesses: [f.token.host.nodeID: .now + .seconds(10)], membershipRevision: revision) == nil)
            #expect(await transport.metricsSnapshot().cachedPartitions == 0)
            try await transport.installCommittedMembership(.init(revision: revision,
                current: Array(roster.keys), peers: peers))
            #expect(try await transport.resolve(partitionID: f.token.partitionID).token == f.token)
            let survivor = revision == 7 ? f.token.host.nodeID : f.gateway.nodeID
            let joint = try V2ActorServiceQualification.Membership(revision: revision + 1,
                current: Set(roster.keys), next: [survivor])
            let jointDigest = try v2RealtimeMembershipDigest(roster: roster, membership: joint)
            try await transport.installMembership(joint, peers: peers)
            #expect(qualification.snapshot() == nil)
            #expect(await transport.metricsSnapshot().cachedPartitions == 0)
            try await transport.installMembership(joint, peers: peers) // Exact retry.
            try await publisher.installMembership(roster: roster, digest: jointDigest, revision: revision + 1)
            await #expect(throws: V2ActorAuthenticationError.self) {
                try await publisher.install([.init(token: f.token, remainingLeaseMilliseconds: 30_000)], membershipRevision: revision)
            }
            try await publisher.install([.init(token: f.token, remainingLeaseMilliseconds: 30_000)], membershipRevision: revision + 1)
            #expect(try await transport.resolve(partitionID: f.token.partitionID).token == f.token)
            #expect(qualification.snapshot() != nil)
            // Commit removal of the peer. Its cached route and witness must
            // disappear without declaring the still-running process dead.
            let final = try V2ActorServiceQualification.Membership(revision: revision + 2, current: [survivor])
            let finalPeers = peers.filter { $0.nodeID == survivor }
            try await transport.installMembership(final, peers: finalPeers)
            try await transport.installMembership(final, peers: finalPeers)
            #expect(await transport.metricsSnapshot().cachedPartitions == 0)
            if survivor == f.gateway.nodeID {
                #expect(await transport.reachableNodeIDs() == [f.gateway.nodeID])
            } else {
                #expect(qualification.snapshot() == nil)
                #expect(await transport.reachableNodeIDs().isEmpty)
                await #expect(throws: V2ActorAuthenticationError.forbidden) {
                    try await transport.installPartitions([.init(token: f.token, remainingLeaseMilliseconds: 30_000)])
                }
                try await transport.installPartitions([])
            }
            let caughtUp = try V2ActorServiceMembershipRecord(revision: revision + 4,
                current: [survivor], peers: finalPeers)
            try await transport.installCommittedMembership(caughtUp)
            #expect(qualification.membership.revision == revision + 4)
            try await transport.installCommittedMembership(caughtUp)
            await #expect(throws: V2ActorServiceQualification.ConfigurationError.self) {
                try await transport.installMembership(joint, peers: peers)
            }
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

    @Test(arguments: ["release", "cancel", "retire", "stop", "deadline", "queueFull"])
    func controlsWaitForActualPeerCapacity(action: String) async throws {
        let f = try Fixture(held: true)
        let port = Int.random(in: 30_000...60_000)
        var settings = ClusterSystemSettings(name: "control-admission-\(action)", host: "127.0.0.1", port: port)
        settings.threadPoolSize = 1
        settings.downingStrategy = .none; settings.onDownAction = .none
        let system = await ClusterSystem("control-admission-\(action)", settings: settings)
        let inbound = V2RealtimeShardInbound(identity: f.token.host, signer: f.receiver, trust: f.trust,
            serving: f.serving, serviceOwnerAccess: [f.caller.serviceID: ["rooms"]], limits: .init())
        let endpoint = V2RealtimeShardEndpoint(actorSystem: system, service: inbound)
        let bytes = try V2ActorProtobuf.encode(endpoint.id); inbound.bindEndpointReference(bytes)
        let target = V2GatewayRealtimeDescriptor(identity: f.token.host, endpointReference: bytes,
            address: "127.0.0.1", port: port)
        let sender = try V2RealtimeShardSender(system: system, signer: f.caller, trust: f.trust,
            limits: .init(callTimeout: .seconds(10)), incarnation: f.gateway.incarnationID)
        var calls: [Task<ShardResult, any Error>] = []
        do {
            try await sender.installAuthenticatedReference(target)
            for _ in 0..<2 { calls.append(Task { try await sender.exchange(.control(f.control()), to: target) }) }
            try await waitForControlState { await f.serving.calls == 2 }
            let count = action == "queueFull" ? 256 : 1
            for _ in 0..<count {
                calls.append(Task {
                    try await sender.exchange(.control(f.control()), to: target,
                        admissionDeadline: action == "deadline" ? .now + .milliseconds(100) : nil)
                })
            }
            try await waitForControlState { await sender.metrics().9 == count }
            let held = await sender.metrics()
            #expect(held.0 == 2 && held.2 == 2 && held.6 == 0)
            switch action {
            case "cancel":
                calls[2].cancel()
                await #expect(throws: CancellationError.self) { try await calls[2].value }
            case "retire":
                #expect(!(await sender.beginRetirement(f.token.host, reference: bytes)))
                await #expect(throws: V2ActorAuthenticationError.sessionExpired) { try await calls[2].value }
            case "stop":
                #expect(!(await sender.stop(deadline: .now)))
                await #expect(throws: V2ActorAuthenticationError.overloaded) { try await calls[2].value }
            case "deadline":
                await #expect(throws: V2ActorAuthenticationError.overloaded) { try await calls[2].value }
                #expect(await sender.metrics().8[.control]?[.queueTimeout] == 1)
            case "queueFull":
                await #expect(throws: V2ActorAuthenticationError.overloaded) {
                    try await sender.exchange(.control(f.control()), to: target)
                }
                #expect(await sender.metrics().8[.control]?[.queueFull] == 1)
                for call in calls.dropFirst(2) { call.cancel() }
                for call in calls.dropFirst(2) { _ = await call.result }
            default: break
            }
            if action != "release" { try await waitForControlState { await sender.metrics().9 == 0 } }
            // A cancelled/expired waiter must not release either dispatched RPC.
            #expect(await sender.metrics().2 == 2)
            await f.serving.release()
            for call in calls.prefix(2) { _ = try await call.value }
            if action == "release" {
                _ = try await calls[2].value
                #expect(await f.serving.calls == 3)
                #expect(await sender.metrics().6 == 0)
            } else { #expect(await f.serving.calls == 2) }
            #expect(await sender.metrics().9 == 0)
            #expect(await sender.stop(deadline: .now + .seconds(2)))
            #expect(await inbound.stop(deadline: .now + .seconds(2)))
            try await system.shutdown().wait()
        } catch {
            for call in calls { call.cancel() }
            await f.serving.release()
            for call in calls { _ = await call.result }
            _ = await sender.stop(deadline: .now + .seconds(2))
            _ = await inbound.stop(deadline: .now + .seconds(2))
            try? await system.shutdown().wait()
            throw error
        }
    }
    private func waitForControlState(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await ready()) {
            guard ContinuousClock.now < deadline else { throw V2ActorAuthenticationError.overloaded }
            try await Task.sleep(for: .milliseconds(1))
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
        init(held: Bool = false, dynamic: Bool = false) throws {
            let room = RoomID(uuid: UUID()); self.room = room
            let callerKey = Curve25519.Signing.PrivateKey(), receiverKey = Curve25519.Signing.PrivateKey()
            caller = try .init(serviceID: V2ActorServiceID("gateway"), privateKey: callerKey.rawRepresentation)
            receiver = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("partition"), privateKey: receiverKey.rawRepresentation)
            let callerTrust = try V2ActorTrustedService(serviceID: caller.serviceID, publicKey: callerKey.publicKey.rawRepresentation,
                permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: ["gateway-node"], sourceIDs: ["rooms"])
            let authorityKey = Curve25519.Signing.PrivateKey(), authorityID = try V2ActorServiceID("authority"), deployment = UUID()
            let authority = try V2ActorSigningIdentity(serviceID: authorityID, privateKey: authorityKey.rawRepresentation)
            var services = [try V2ActorTrustedService(serviceID: receiver.serviceID, publicKey: receiverKey.publicKey.rawRepresentation,
                permissions: [.realtimePublish, .realtimeReceive], gatewayNodeIDs: ["partition-node"]),
                try V2ActorTrustedService(serviceID: authorityID, publicKey: authorityKey.publicKey.rawRepresentation, permissions: [])]
            if !dynamic { services.append(callerTrust) }
            trust = try .init(services: services, admissionAuthority: .init(deploymentID: deployment, serviceID: authorityID))
            gateway = .init(nodeID: "gateway-node", serviceID: "gateway", incarnationID: UUID())
            let identity = V2GatewayRealtimeIdentity(nodeID: "partition-node", serviceID: "partition", incarnationID: UUID())
            token = .init(partitionID: V2RealtimeTopicKey(kind: .roomEvents, id: room.rawValue).partitionID(), host: identity, epoch: 1, leaseToken: UUID())
            serving = Serving(held: held)
            inbound = .init(identity: identity, signer: receiver, trust: trust, serving: serving,
                serviceOwnerAccess: dynamic ? [:] : [caller.serviceID: ["rooms"]], limits: .init())
            inbound.bindEndpointReference(Data([7]))
            if dynamic {
                try trust.admitAuthorizedServices(authority.sign(V2ActorTrustAdmission(deploymentID: deployment,
                    services: [callerTrust]), maximumBytes: 262_144))
            }
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
        var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        var released = false
        init(held: Bool) { self.held = held }
        func waitForEntry() async { if calls > 0 { return }; await withCheckedContinuation { entryWaiters.append($0) } }
        func release() { released = true; releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll() }
        func control(_ request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
            calls += 1; entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
            if held && !released { await withCheckedContinuation { releaseWaiters.append($0) } }
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
