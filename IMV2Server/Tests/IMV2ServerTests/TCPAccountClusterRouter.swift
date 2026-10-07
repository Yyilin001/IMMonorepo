import Crypto
import Distributed
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerGateway
import IMV2ServerContracts
import Testing
@testable import IMV2ActorCluster

/// Uses the production signed distributed callback path between separate TCP nodes.
/// The owning TCP fixture joins every transport and ClusterSystem during cleanup.
actor TCPAccountClusterRouter {
    private let systems: [ClusterSystem]
    private let transports: [V2RealtimeTransportHandle]
    private init(systems: [ClusterSystem], transports: [V2RealtimeTransportHandle]) {
        self.systems = systems; self.transports = transports
    }

    static func start(ingresses: [V2GatewayRoomSubscriptionIngress],
                      journalHandlers: [any V2RealtimeJournalProjectionHandler] = []) async throws -> TCPAccountClusterRouter {
        precondition(journalHandlers.isEmpty || journalHandlers.count == ingresses.count)
        let keys = (0...ingresses.count).map { _ in Curve25519.Signing.PrivateKey() }
        let ids = try (0...ingresses.count).map { try V2ActorServiceID($0 == 0 ? "owner" : "tcp-gateway-\($0)") }
        let trust = try V2ActorTrustStore(services: zip(ids, keys).enumerated().map { index, pair in
            try .init(serviceID: pair.0, publicKey: pair.1.publicKey.rawRepresentation,
                permissions: index == 0 ? [.realtimePublish, .realtimeReceive] : [.realtimeReceive])
        })
        var systems: [ClusterSystem] = [], transports: [V2RealtimeTransportHandle] = []
        var ports: Set<Int> = []
        do {
            for index in ids.indices {
                var port = Int.random(in: 30_000...60_000)
                while !ports.insert(port).inserted { port = Int.random(in: 30_000...60_000) }
                let name = "account-tcp-\(UUID().uuidString)"
                var settings = ClusterSystemSettings(name: name, host: "127.0.0.1", port: port)
                settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
                settings.serialization.registerInbound(V2ActorAuthenticationError.self)
                settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [V2ActorAuthenticationError.self])
                let system = await ClusterSystem(name, settings: settings)
                systems.append(system)
                let signer = try V2ActorSigningIdentity(serviceID: ids[index], privateKey: keys[index].rawRepresentation)
                let transport = try buildRealtimeTransport(system: system,
                    identity: .init(nodeID: ids[index].rawValue, serviceID: ids[index].rawValue, incarnationID: UUID()),
                    address: "127.0.0.1", port: port, signer: signer, trust: trust, ingress: RejectingIngress(),
                    serviceOwnerAccess: [ids[0]: ["tcp-rooms", "room-a"]], limits: .init(callTimeout: .seconds(5)))
                transports.append(transport)
                if index > 0 {
                    try await transport.configureRoomSubscription(ingresses[index - 1])
                    if !journalHandlers.isEmpty { try await transport.configureJournalProjection(journalHandlers[index - 1]) }
                    let actorID = try JSONDecoder().decode(ClusterSystem.ActorID.self, from: transport.descriptor.endpointReference)
                    let remote = try V2GatewayRealtimeEndpoint.resolve(id: actorID, using: systems[0])
                    try #require(__isRemoteActor(remote))
                    systems[0].cluster.join(host: "127.0.0.1", port: port)
                }
            }
            return .init(systems: systems, transports: transports)
        } catch {
            for transport in transports { _ = await transport.stop(deadline: .now + .seconds(2)) }
            for system in systems { try? await system.shutdown().wait() }
            throw error
        }
    }

    func send(_ delivery: V2RoomSubscriptionDelivery, gateway: Int) async throws -> V2RoomSubscriptionDeliveryResult {
        try await transports[0].sendRoomSubscription(delivery, sourceShardID: delivery.fence.activation.owner.shardID,
            to: transports[gateway + 1].descriptor)
    }

    func descriptor(gateway: Int) -> V2GatewayRealtimeDescriptor {
        transports[gateway + 1].descriptor
    }

    func publisherIdentity() -> V2GatewayRealtimeIdentity {
        transports[0].descriptor.identity
    }

    func stop() async {
        for transport in transports { #expect(await transport.stop(deadline: .now + .seconds(2))) }
        for system in systems { try? await system.shutdown().wait() }
    }
    func sendMembership(user: IMV2Core.UserID, room: IMV2Core.RoomID, gateway: Int,
                        version: UInt64 = 1, source: V2RealtimeJournalSource? = nil,
                        sequence: Int64 = 1, sourceLease: V2RealtimePartitionLease? = nil, coldBaseline: Bool = false) async throws -> V2RealtimeJournalProjectionResult {
        let target = transports[gateway + 1].descriptor
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: transports[0].descriptor.identity.incarnationID,
            sourceLeaseEpoch: sourceLease?.epoch ?? 1, sourceLeaseToken: sourceLease?.token ?? UUID(),
            sourceLeaseExpiresAt: sourceLease.map { Date().addingTimeInterval($0.remainingLeaseSeconds) } ?? .distantFuture,
            routingPartitionEpoch: 1, routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1,
            gatewayIncarnationID: target.identity.incarnationID)
        return try await transports[0].sendJournalProjection(.init(
            source: source ?? .init(sourceID: "tcp-rooms", incarnationID: UUID(), partitionID: 1), fence: fence,
            payload: coldBaseline ? .baseline(minimumCut: sequence) : .changes(fromExclusive: sequence - 1, throughInclusive: sequence, entries: [
                .init(sequence: sequence, change: .userControlInvalidation(userID: user, controlVersion: version,
                    deviceID: nil, membershipRoomID: room))])), to: target)
    }
    private struct RejectingIngress: V2RealtimeIngress {
        func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance { .stale }
    }
}
