import Crypto
import Distributed
@testable import IMActorSystem
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
            // the replacement IMActorSystem cannot bind this same port.
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepted.withLock { $0 += 1 }
                channel.closeFuture.whenComplete { _ in disconnected.withLock { $0 = true } }
                return closeImmediately ? channel.close() : channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: port).get()
        do {
            let callerSystem = try await makeSystem(port: callerPort)
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

            let hostSystem = try await makeSystem(port: port)
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
            try await callerSystem.shutdown()
            try await hostSystem.shutdown()
            try await group.shutdownGracefully()
        } catch {
            try? await dropper.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("two real IMActorSystems discover a signed endpoint and replace its incarnation",
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
        let callerSystem = try await makeSystem(port: callerPort, address: address)
        let caller = V2RoomClusterClient(system: callerSystem, signer: callerSigner,
                                         trust: trust, limits: limits, configuration: runtime)
        let peer = try V2RoomDiscoveryPeer(hostID: hostID, serviceID: hostSigner.serviceID,
                                           address: address, port: port,
                                           accessibleShardIDs: ["pinned-shard"], maximumRooms: 2)
        let discovery = V2RoomClusterDiscovery(system: callerSystem, client: caller,
            trust: trust, configuration: try .init(peers: [peer], pollInterval: .milliseconds(100)))

        var hostSystem = try await makeSystem(port: port, address: address)
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

        #expect(first.descriptor.endpointID.node == first.beacon.id.node)
        #expect(callerSystem.peerSnapshot.available[first.beacon.id.node] == true)
        // Close real connections without changing the peer's physical identity.
        callerSystem.retire(node: first.beacon.id.node)
        try await waitUntil(discovery: discovery) {
            guard callerSystem.peerSnapshot.available[first.beacon.id.node] == true else { return false }
            return try await caller.candidates(for: owner).first?.identity == first.descriptor.identity
        }

        try await hostSystem.shutdown()
        hostSystem = try await makeSystem(port: port, address: address)
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

        try await hostSystem.shutdown()
        hostSystem = try await makeSystem(port: port, address: address)
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
        try await callerSystem.shutdown()
        try await hostSystem.shutdown()
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
        let hostSystem = try await makeSystem(port: port)
        let callerSystem = try await makeSystem(port: callerPort)
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
        callerSystem.connect(host: "127.0.0.1", port: port)
        let keyForHost = V2RoomDiscoveryBeacon.key(for: hostID)
        let deadline = ContinuousClock.now + .seconds(10)
        while try await callerSystem.lookup(keyForHost, at: .init(host: "127.0.0.1", port: port)).count < 2 {
            guard ContinuousClock.now < deadline else {
                Issue.record("two Directory registrations did not arrive"); break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        await discovery.pollOnce()
        #expect(await discovery.snapshot().oversizedLookups == 1)
        #expect(try await caller.candidates(for: .init(shardID: "pinned-shard", epoch: 0)).isEmpty)
        await discovery.stop()
        await caller.stop()
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        try await callerSystem.shutdown()
        try await hostSystem.shutdown()
    }

    @Test("a directory ActorID signed by a different service grants no candidate")
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
        let hostSystem = try await makeSystem(port: port)
        let callerSystem = try await makeSystem(port: callerPort)
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
        callerSystem.connect(host: "127.0.0.1", port: port)
        try await waitForLookup(system: callerSystem,
                                key: V2RoomDiscoveryBeacon.key(for: hostID), endpoint: .init(host: "127.0.0.1", port: port), count: 1)
        await discovery.pollOnce()
        #expect(try await caller.candidates(for: .init(shardID: "pinned-shard", epoch: 0)).isEmpty)
        await discovery.stop()
        await caller.stop()
        #expect(await caller.quiesce(deadline: .now + .seconds(2)))
        try await callerSystem.shutdown()
        try await hostSystem.shutdown()
    }

    @Test("authorized live peers add, remove and rejoin without downing the process")
    func updatesLivePeers() async throws {
        let port = Int.random(in: 30_000...45_000)
        let callerPort = Int.random(in: 45_001...60_000)
        let hostID = try V2ActorHostID("live-discovery-host")
        let hostKey = Curve25519.Signing.PrivateKey()
        let callerKey = Curve25519.Signing.PrivateKey()
        let hostSigner = try V2ActorSigningIdentity(serviceID: .init("live-host-service"), privateKey: hostKey.rawRepresentation)
        let callerSigner = try V2ActorSigningIdentity(serviceID: .init("live-caller-service"), privateKey: callerKey.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: hostSigner.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                  permissions: [], hostedIDs: [hostID]),
            .init(serviceID: callerSigner.serviceID, publicKey: callerKey.publicKey.rawRepresentation,
                  permissions: [.roomCoordination]),
        ])
        let callerSystem = try await makeSystem(port: callerPort)
        let hostSystem = try await makeSystem(port: port)
        let caller = V2RoomClusterClient(system: callerSystem, signer: callerSigner,
            trust: trust, limits: try .init(), configuration: try .init())
        let peer = try V2RoomDiscoveryPeer(hostID: hostID, serviceID: hostSigner.serviceID,
            address: "127.0.0.1", port: port, accessibleShardIDs: ["pinned-shard"], maximumRooms: 2)
        let discovery = V2RoomClusterDiscovery(system: callerSystem, client: caller, trust: trust,
            configuration: try .init(peers: [peer], pollInterval: .milliseconds(100)))
        do {
            // Start with a committed empty room roster, then admit the live host.
            try await discovery.installAuthorizedPeers([], revision: 1)
            await discovery.start()
            let published = try await publish(hostID: hostID, signer: hostSigner,
                system: hostSystem, port: port, availableRooms: 4)
            defer { withExtendedLifetime(published) {} }
            let owner = try V2RoomDataOwner(shardID: "pinned-shard", epoch: 0)
            #expect(try await caller.candidates(for: owner).isEmpty)
            try await discovery.installAuthorizedPeers([peer], revision: 2)
            try await waitUntil(discovery: discovery) {
                try await caller.candidates(for: owner).first(where: \.isHealthy)?.identity == published.descriptor.identity
            }
            #expect(try await caller.candidates(for: owner).first?.availableRooms == 2)
            await discovery.suspendAuthorization()
            for _ in 0..<3 { await discovery.pollOnce() }
            #expect(try await caller.candidates(for: owner).allSatisfy { !$0.isHealthy })
            // Fresh confirmation at the same revision must recover; probes alone cannot.
            try await discovery.installAuthorizedPeers([peer], revision: 2)
            try await waitUntil(discovery: discovery) {
                try await caller.candidates(for: owner).first(where: \.isHealthy)?.identity == published.descriptor.identity
            }
            // Invalid revisions and retained endpoint changes leave the route intact.
            await #expect(throws: V2ActorPlacementError.self) {
                try await discovery.installAuthorizedPeers([], revision: 1)
            }
            await #expect(throws: V2ActorPlacementError.self) {
                try await discovery.installAuthorizedPeers([], revision: 2)
            }
            let moved = try V2RoomDiscoveryPeer(hostID: hostID, serviceID: hostSigner.serviceID,
                address: "127.0.0.1", port: port + 1, accessibleShardIDs: ["pinned-shard"], maximumRooms: 2)
            await #expect(throws: V2ActorPlacementError.self) {
                try await discovery.installAuthorizedPeers([moved], revision: 3)
            }
            #expect(try await caller.candidates(for: owner).count == 1)
            // Race an explicit poll with removal. No old probe may restore the route.
            let oldPoll = Task { await discovery.pollOnce() }
            try await discovery.installAuthorizedPeers([], revision: 3)
            await oldPoll.value
            for _ in 0..<3 { await discovery.pollOnce() }
            #expect(try await caller.candidates(for: owner).allSatisfy { !$0.isHealthy })
            #expect(throws: V2RoomCallFailure.self) {
                try caller.resolvePolicyHost(hostID: hostID, endpoint: "pinned-shard")
            }
            #expect(await discovery.snapshot().activeHosts == 0)
            try await discovery.installAuthorizedPeers([], revision: 3) // exact retry
            #expect(callerSystem.peerSnapshot.available[published.beacon.id.node] == true)
            try await discovery.installAuthorizedPeers([peer], revision: 4)
            try await waitUntil(discovery: discovery) {
                try await caller.candidates(for: owner).first(where: \.isHealthy)?.identity == published.descriptor.identity
            }
            #expect(await discovery.quiesce(deadline: .now + .seconds(5)))
            #expect(await caller.quiesce(deadline: .now + .seconds(5)))
            try await callerSystem.shutdown()
            try await hostSystem.shutdown()
        } catch {
            _ = await discovery.quiesce(deadline: .now + .seconds(5))
            _ = await caller.quiesce(deadline: .now + .seconds(5))
            try? await callerSystem.shutdown()
            try? await hostSystem.shutdown()
            throw error
        }
    }

    private func makeSystem(port: Int, address: String = "127.0.0.1") async throws -> IMActorSystem {
        var settings = IMActorSystemSettings(name: "v2-discovery-test", host: address, port: port)
        settings.threadPoolSize = 1


        settings.errorTypes = [V2ActorAuthenticationError.self]

        return try await V2ActorRPCManifest.makeSystem("v2-discovery-test", settings: settings)
    }

    private func publish(hostID: V2ActorHostID, signer: V2ActorSigningIdentity,
                         system: IMActorSystem, port: Int,
                         availableRooms: Int) async throws -> Published {
        let endpoint = DiscoveryTestEndpoint(actorSystem: system)
        let descriptor = try V2RoomClusterHostDescriptor(
            identity: .init(hostID: hostID, incarnationID: UUID()), endpointID: endpoint.id,
            address: endpoint.id.node.endpoint.host, port: port,
            accessibleShardIDs: ["untrusted-claim"], availableRooms: availableRooms, isHealthy: true)
        let beacon = V2RoomDiscoveryBeacon(actorSystem: system, descriptor: descriptor,
                                            signer: signer, state: .init())
        try system.publish(beacon, as: V2RoomDiscoveryBeacon.key(for: hostID))
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

    private func waitForLookup(system: IMActorSystem,
                               key: IMServiceKey<V2RoomDiscoveryBeacon>,
                               endpoint: IMEndpoint, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await system.lookup(key, at: endpoint).count < count {
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
    typealias ActorSystem = IMActorSystem
}
