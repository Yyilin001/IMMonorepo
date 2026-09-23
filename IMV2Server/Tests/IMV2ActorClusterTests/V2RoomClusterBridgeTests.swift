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
        let request = V2RoomRequest.messaging(.send(.init(
            roomID: fixture.room, actorUserID: user,
            clientMessageID: ClientMessageID(uuid: UUID()), text: "signed",
            media: [], mentions: [], entities: [], replyTo: nil
        )))
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
        #expect(await caller.sessionCount() == 1)
        #expect(await caller.physicalReferenceCount() == 1)
        await caller.stop()
        #expect((await fixture.host.drain(deadline: deadline)).completed)
        await fixture.inbound.stop()
        try await callerSystem.shutdown().wait()
        try await fixture.system.shutdown().wait()
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
        let trust: V2ActorTrustStore

        init() async throws {
            owner = try .init(shardID: "allowed", epoch: 0)
            identity = .init(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
            let clientKey = Curve25519.Signing.PrivateKey()
            let hostKey = Curve25519.Signing.PrivateKey()
            client = try .init(serviceID: V2ActorServiceID("gateway"),
                               privateKey: clientKey.rawRepresentation)
            let signer = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("host"),
                                                    privateKey: hostKey.rawRepresentation)
            trust = try .init(services: [
                .init(serviceID: client.serviceID, publicKey: clientKey.publicKey.rawRepresentation,
                      permissions: [.userRoomCalls]),
                .init(serviceID: signer.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                      permissions: [], hostedIDs: [identity.hostID]),
            ])
            configuration = try V2RoomRuntimeConfiguration(
                maximumActiveRooms: 2, maximumConcurrentRestores: 1,
                maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 2,
                maximumActivationWaitersPerHost: 2, maximumConcurrentResolutions: 1,
                maximumConcurrentReservations: 1
            )
            host = .init(
                identity: identity, leaseStore: LeaseStore(), configuration: configuration,
                budget: V2RoomCommandBudget(configuration: configuration), classify: { _ in .barrier },
                factory: .init { _ in
                    .init(restore: { _ in }, execute: { _ in .committed([]) },
                          invalidateReservation: { _ in }, close: {})
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
                limits: limits, allowedShards: ["allowed"],
                serviceShardAccess: [client.serviceID: ["allowed"]], actorSystem: system
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
}
