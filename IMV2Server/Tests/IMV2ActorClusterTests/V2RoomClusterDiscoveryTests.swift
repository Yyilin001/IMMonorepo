import Crypto
import Distributed
@testable import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import NIOCore
import NIOPosix
import Synchronization
import Testing
@testable import IMV2ActorCluster

@Suite("Room Cluster signed discovery", .serialized)
struct V2RoomClusterDiscoveryTests {
    @Test("a TCP peer that closes or stalls before handshake cannot block a later host incarnation",
          arguments: [true, false])
    func rejoinAfterHandshakeFailure(closeImmediately: Bool) async throws {
        let port = Int.random(in: 30_000...60_000)
        let callerPort = Int.random(in: 30_000...60_000)
        let hostID = try V2ActorHostID("closed-handshake-host")
        let hostKey = Curve25519.Signing.PrivateKey()
        let callerKey = Curve25519.Signing.PrivateKey()
        let hostSigner = try V2ActorSigningIdentity(serviceID: .init("closed-host-service"),
                                                     privateKey: hostKey.rawRepresentation)
        let callerSigner = try V2ActorSigningIdentity(serviceID: .init("closed-caller-service"),
                                                       privateKey: callerKey.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: hostSigner.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                  permissions: [], hostedIDs: [hostID]),
            .init(serviceID: callerSigner.serviceID, publicKey: callerKey.publicKey.rawRepresentation,
                  permissions: [.roomCoordination]),
        ])
        let runtime = try V2RoomRuntimeConfiguration(
            maximumActiveRooms: 4, maximumConcurrentRestores: 2,
            maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 4,
            maximumActivationWaitersPerHost: 4, maximumConcurrentResolutions: 2,
            maximumConcurrentReservations: 2)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let accepted = Mutex(0)
        let disconnected = Mutex(false)
        let dropper = try await ServerBootstrap(group: group)
            // The real Cluster listener and its accepted sockets use SO_REUSEADDR.
            // Match both here: on Linux an accepted fake-peer socket can remain
            // in TIME_WAIT after the handshake watchdog closes it, otherwise
            // the replacement ClusterSystem cannot bind this same port.
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepted.withLock { $0 += 1 }
                channel.closeFuture.whenComplete { _ in disconnected.withLock { $0 = true } }
                return closeImmediately ? channel.close() : channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: port).get()
        do {
            let callerSystem = await makeSystem(port: callerPort)
            let caller = V2RoomClusterClient(system: callerSystem, signer: callerSigner,
                                             trust: trust, limits: try .init(), configuration: runtime)
            let peer = try V2RoomDiscoveryPeer(hostID: hostID, serviceID: hostSigner.serviceID,
                                               address: "127.0.0.1", port: port,
                                               accessibleShardIDs: ["pinned-shard"], maximumRooms: 1)
            let discovery = V2RoomClusterDiscovery(system: callerSystem, client: caller,
                trust: trust, configuration: try .init(peers: [peer], pollInterval: .milliseconds(100)))
            await discovery.start()
            try await waitUntil(discovery: discovery) { accepted.withLock { $0 > 0 } }
            // The stalled case must end through the initiating handshake's own
            // watchdog. Closing the fake listener first would hide that bug.
            try await waitUntil(discovery: discovery, timeout: .seconds(14)) {
                disconnected.withLock { $0 }
            }
            try await dropper.close().get()

            let hostSystem = await makeSystem(port: port)
            let published = try await publish(hostID: hostID, signer: hostSigner,
                                              system: hostSystem, port: port, availableRooms: 1)
            defer { withExtendedLifetime(published) {} }
            let owner = try V2RoomDataOwner(shardID: "pinned-shard", epoch: 0)
            try await waitUntil(discovery: discovery, timeout: .seconds(25)) {
                try await caller.candidates(for: owner).first?.identity == published.descriptor.identity
            }
            await discovery.stop()
            #expect(await discovery.quiesce(deadline: .now + .seconds(5)))
            await caller.stop()
            #expect(await caller.quiesce(deadline: .now + .seconds(2)))
            try await callerSystem.shutdown().wait()
            try await hostSystem.shutdown().wait()
            try await group.shutdownGracefully()
        } catch {
            try? await dropper.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("two real ClusterSystems discover a signed endpoint and replace its incarnation",
          arguments: ["127.0.0.1", "localhost"])
    func discoversRestartedHost(address: String) async throws {
        let port = Int.random(in: 30_000...60_000)
        let callerPort = Int.random(in: 30_000...60_000)
        let hostID = try V2ActorHostID("discovery-host")
        let hostKey = Curve25519.Signing.PrivateKey()
        let callerKey = Curve25519.Signing.PrivateKey()
        let hostSigner = try V2ActorSigningIdentity(serviceID: .init("discovery-service"),
                                                     privateKey: hostKey.rawRepresentation)
        let callerSigner = try V2ActorSigningIdentity(serviceID: .init("discovery-caller"),
                                                       privateKey: callerKey.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: hostSigner.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                  permissions: [], hostedIDs: [hostID]),
            .init(serviceID: callerSigner.serviceID, publicKey: callerKey.publicKey.rawRepresentation,
                  permissions: [.roomCoordination]),
        ])
        let limits = try V2ActorAuthenticationLimits()
        let runtime = try V2RoomRuntimeConfiguration(
            maximumActiveRooms: 4, maximumConcurrentRestores: 2,
            maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 4,
            maximumActivationWaitersPerHost: 4, maximumConcurrentResolutions: 2,
            maximumConcurrentReservations: 2, maximumResolveAttempts: 2
        )
        let callerSystem = await makeSystem(port: callerPort, address: address)
        let caller = V2RoomClusterClient(system: callerSystem, signer: callerSigner,
                                         trust: trust, limits: limits, configuration: runtime)
        let peer = try V2RoomDiscoveryPeer(hostID: hostID, serviceID: hostSigner.serviceID,
                                           address: address, port: port,
                                           accessibleShardIDs: ["pinned-shard"], maximumRooms: 2)
        let discovery = V2RoomClusterDiscovery(system: callerSystem, client: caller,
            trust: trust, configuration: try .init(peers: [peer], pollInterval: .milliseconds(100)))

        var hostSystem = await makeSystem(port: port, address: address)
        let first = try await publish(hostID: hostID, signer: hostSigner,
                                      system: hostSystem, port: port, availableRooms: 4)
        defer { withExtendedLifetime(first) {} }
        await discovery.start()
        let owner = try V2RoomDataOwner(shardID: "pinned-shard", epoch: 0)
        try await waitUntil(discovery: discovery) {
            try await caller.candidates(for: owner).first?.identity == first.descriptor.identity
        }
        let initial = try await #require(caller.candidates(for: owner).first)
        #expect(initial.accessibleShardIDs == ["pinned-shard"])
        #expect(initial.availableRooms == 2)
        for _ in 0..<3 { await discovery.pollOnce() }
        #expect(try await caller.candidates(for: owner).count == 1)

        // The signed advertisement above proves that the remote endpoint is
        // usable. For this restart test the old exact Node only needs to be
        // present in membership. Promotion from .joining to .up additionally
        // waits for leader election and gossip convergence, which is unrelated
        // to replacing the host's process incarnation.
        #expect(first.descriptor.endpointID.node == first.beacon.id.node)
        try await waitUntil(discovery: discovery) {
            guard let member = await callerSystem.cluster.membershipSnapshot.member(first.beacon.id.node) else {
                return false
            }
            return member.status == .joining || member.status == .up
        }

        // Close the actual transport channel, keeping both systems and the
        // exact signed beacon/endpoint alive. Cached remote controls must use
        // a newly handshaken channel without a membership down/replacement.
        let association = try #require(callerSystem._cluster?.getSpecificExistingAssociation(with: first.beacon.id.node))
        let oldChannel = try #require(association.lock.withLock { () -> (any Channel)? in
            if case .associated(let channel) = association.state { return channel }; return nil
        })
        try await oldChannel.close().get()
        try await waitUntil(discovery: discovery) {
            guard let current = callerSystem._cluster?.getSpecificExistingAssociation(with: first.beacon.id.node) else { return false }
            let reconnected = current.lock.withLock { () -> Bool in
                guard case .associated(let channel) = current.state else { return false }
                return channel.isActive && channel !== oldChannel
            }
            guard reconnected else { return false }
            return try await caller.candidates(for: owner).first?.identity == first.descriptor.identity
        }
        let sameMember = try #require(await callerSystem.cluster.membershipSnapshot.member(first.beacon.id.node))
        #expect(sameMember.status < .down)

        try await hostSystem.shutdown().wait()
        hostSystem = await makeSystem(port: port, address: address)
        let second = try await publish(hostID: hostID, signer: hostSigner,
                                       system: hostSystem, port: port, availableRooms: 1)
        defer { withExtendedLifetime(second) {} }
        #expect(second.descriptor.identity.incarnationID != first.descriptor.identity.incarnationID)
        try await waitUntil(discovery: discovery, timeout: .seconds(20)) {
            try await caller.candidates(for: owner).first?.identity == second.descriptor.identity
        }
        let replacement = try await #require(caller.candidates(for: owner).first)
        #expect(replacement.availableRooms == 1)
        #expect(try await caller.candidates(for: owner).count == 1)

        try await hostSystem.shutdown().wait()
        hostSystem = await makeSystem(port: port, address: address)
        let third = try await publish(hostID: hostID, signer: hostSigner,
                                      system: hostSystem, port: port, availableRooms: 2)
        defer { withExtendedLifetime(third) {} }
        try await waitUntil(discovery: discovery, timeout: .seconds(20)) {
            try await caller.candidates(for: owner).first?.identity == third.descriptor.identity
        }
        try await waitUntil(discovery: discovery) {
            await discovery.snapshot().pendingRetiredNodes == 0
        }
        #expect(try await caller.candidates(for: owner).count == 1)
        #expect(await caller.retiredDescriptorCount() == 0)
        await discovery.stop()
        #expect(await discovery.quiesce(deadline: .now + .seconds(5)))
        await caller.stop()
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        try await callerSystem.shutdown().wait()
        try await hostSystem.shutdown().wait()
    }

    @Test("lookup over its hard candidate limit skips all probes and registration")
    func oversizedLookup() async throws {
        let port = Int.random(in: 30_000...60_000)
        let callerPort = Int.random(in: 30_000...60_000)
        let hostID = try V2ActorHostID("crowded-host")
        let key = Curve25519.Signing.PrivateKey()
        let signer = try V2ActorSigningIdentity(serviceID: .init("crowded-service"),
                                                privateKey: key.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: signer.serviceID, publicKey: key.publicKey.rawRepresentation,
                  permissions: [], hostedIDs: [hostID])
        ])
        let runtime = try V2RoomRuntimeConfiguration(
            maximumActiveRooms: 2, maximumConcurrentRestores: 1,
            maximumActivationWaitersPerRoom: 1, maximumPendingActivations: 2,
            maximumActivationWaitersPerHost: 2, maximumConcurrentResolutions: 1,
            maximumConcurrentReservations: 1
        )
        let hostSystem = await makeSystem(port: port)
        let callerSystem = await makeSystem(port: callerPort)
        let first = try await publish(hostID: hostID, signer: signer, system: hostSystem,
                              port: port, availableRooms: 1)
        let second = try await publish(hostID: hostID, signer: signer, system: hostSystem,
                              port: port, availableRooms: 1)
        defer { withExtendedLifetime((first, second)) {} }
        let caller = V2RoomClusterClient(system: callerSystem, signer: signer,
                                         trust: trust, limits: try .init(), configuration: runtime)
        let peer = try V2RoomDiscoveryPeer(hostID: hostID, serviceID: signer.serviceID,
                                           address: "127.0.0.1", port: port,
                                           accessibleShardIDs: ["pinned-shard"], maximumRooms: 1)
        let discovery = V2RoomClusterDiscovery(system: callerSystem, client: caller,
            trust: trust, configuration: try .init(peers: [peer], maximumCandidatesPerHost: 1))
        callerSystem.cluster.join(host: "127.0.0.1", port: port)
        let keyForHost = V2RoomDiscoveryBeacon.key(for: hostID)
        let deadline = ContinuousClock.now + .seconds(10)
        while await callerSystem.receptionist.lookup(keyForHost).count < 2 {
            guard ContinuousClock.now < deadline else {
                Issue.record("two Receptionist registrations did not arrive"); break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await discovery.pollOnce()
        #expect(await discovery.snapshot().oversizedLookups == 1)
        #expect(try await caller.candidates(for: .init(shardID: "pinned-shard", epoch: 0)).isEmpty)
        await discovery.stop()
        await caller.stop()
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        try await callerSystem.shutdown().wait()
        try await hostSystem.shutdown().wait()
    }

    @Test("a receptionist ActorID signed by a different service grants no candidate")
    func rejectsWrongSigner() async throws {
        let port = Int.random(in: 30_000...60_000)
        let callerPort = Int.random(in: 30_000...60_000)
        let hostID = try V2ActorHostID("signed-host")
        let correctKey = Curve25519.Signing.PrivateKey()
        let rogueKey = Curve25519.Signing.PrivateKey()
        let expected = try V2ActorServiceID("expected-host-service")
        let rogue = try V2ActorSigningIdentity(serviceID: .init("rogue-service"),
                                               privateKey: rogueKey.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: expected, publicKey: correctKey.publicKey.rawRepresentation,
                  permissions: [], hostedIDs: [hostID]),
            .init(serviceID: rogue.serviceID, publicKey: rogueKey.publicKey.rawRepresentation,
                  permissions: [])
        ])
        let hostSystem = await makeSystem(port: port)
        let callerSystem = await makeSystem(port: callerPort)
        let published = try await publish(hostID: hostID, signer: rogue,
                                          system: hostSystem, port: port, availableRooms: 1)
        defer { withExtendedLifetime(published) {} }
        let runtime = try V2RoomRuntimeConfiguration(
            maximumActiveRooms: 2, maximumConcurrentRestores: 1,
            maximumActivationWaitersPerRoom: 1, maximumPendingActivations: 2,
            maximumActivationWaitersPerHost: 2, maximumConcurrentResolutions: 1,
            maximumConcurrentReservations: 1
        )
        let caller = V2RoomClusterClient(system: callerSystem, signer: rogue,
                                         trust: trust, limits: try .init(), configuration: runtime)
        let peer = try V2RoomDiscoveryPeer(hostID: hostID, serviceID: expected,
                                           address: "127.0.0.1", port: port,
                                           accessibleShardIDs: ["pinned-shard"], maximumRooms: 1)
        let discovery = V2RoomClusterDiscovery(system: callerSystem, client: caller,
            trust: trust, configuration: try .init(peers: [peer]))
        callerSystem.cluster.join(host: "127.0.0.1", port: port)
        try await waitForLookup(system: callerSystem,
                                key: V2RoomDiscoveryBeacon.key(for: hostID), count: 1)
        await discovery.pollOnce()
        #expect(try await caller.candidates(for: .init(shardID: "pinned-shard", epoch: 0)).isEmpty)
        await discovery.stop()
        await caller.stop()
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        try await callerSystem.shutdown().wait()
        try await hostSystem.shutdown().wait()
    }

    private func makeSystem(port: Int, address: String = "127.0.0.1") async -> ClusterSystem {
        var settings = ClusterSystemSettings(name: "v2-discovery-test", host: address, port: port)
        settings.threadPoolSize = 1
        settings.downingStrategy = .none
        settings.onDownAction = .none
        settings.serialization.registerInbound(V2ActorAuthenticationError.self)
        settings.remoteCall.codableErrorAllowance =
            .custom(allowedTypes: [V2ActorAuthenticationError.self])
        return await ClusterSystem("v2-discovery-test", settings: settings)
    }

    private func publish(hostID: V2ActorHostID, signer: V2ActorSigningIdentity,
                         system: ClusterSystem, port: Int,
                         availableRooms: Int) async throws -> Published {
        let endpoint = DiscoveryTestEndpoint(actorSystem: system)
        let descriptor = try V2RoomClusterHostDescriptor(
            identity: .init(hostID: hostID, incarnationID: UUID()), endpointID: endpoint.id,
            address: endpoint.id.node.host, port: port,
            accessibleShardIDs: ["untrusted-claim"], availableRooms: availableRooms, isHealthy: true)
        let beacon = V2RoomDiscoveryBeacon(actorSystem: system, descriptor: descriptor,
                                            signer: signer, state: .init())
        await system.receptionist.checkIn(beacon, with: V2RoomDiscoveryBeacon.key(for: hostID))
        return .init(descriptor: descriptor, endpoint: endpoint, beacon: beacon)
    }

    private func waitUntil(discovery: V2RoomClusterDiscovery,
                           timeout: Duration = .seconds(10),
                           condition: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                throw V2ActorAuthenticationError.overloaded
            }
            await discovery.pollOnce()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForLookup(system: ClusterSystem,
                               key: DistributedReception.Key<V2RoomDiscoveryBeacon>,
                               count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while await system.receptionist.lookup(key).count < count {
            guard ContinuousClock.now < deadline else {
                throw V2ActorAuthenticationError.overloaded
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private struct Published {
    let descriptor: V2RoomClusterHostDescriptor
    let endpoint: DiscoveryTestEndpoint
    let beacon: V2RoomDiscoveryBeacon
}

private distributed actor DiscoveryTestEndpoint {
    typealias ActorSystem = ClusterSystem
}
