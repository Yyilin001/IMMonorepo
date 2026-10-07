import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ActorCluster

@Suite("Realtime callback authentication and admission")
struct V2RealtimeAuthenticationTests {
    @Test("caller-only callback authenticates owner and rejects replay before local admission")
    func ownerAndReplay() async throws {
        let callerKey = Curve25519.Signing.PrivateKey()
        let receiverKey = Curve25519.Signing.PrivateKey()
        let caller = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("publisher"), privateKey: callerKey.rawRepresentation)
        let receiver = try V2ActorSigningIdentity(serviceID: V2ActorServiceID("gateway"), privateKey: receiverKey.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: caller.serviceID, publicKey: callerKey.publicKey.rawRepresentation, permissions: [.realtimePublish]),
            .init(serviceID: receiver.serviceID, publicKey: receiverKey.publicKey.rawRepresentation, permissions: [.realtimeReceive])
        ])
        let identity = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())
        let ingress = Ingress()
        let inbound = V2GatewayRealtimeInbound(identity: identity, signer: receiver, trust: trust, ingress: ingress,
            serviceOwnerAccess: [caller.serviceID: ["room-a"]], limits: .init())
        inbound.bindEndpointReference(Data())
        let incarnation = UUID()
        let hello = RealtimeHello(serviceID: caller.serviceID, version: 1, callerIncarnation: incarnation, recipient: identity, handshakeID: UUID(), endpointDigest: Data(SHA256.hash(data: Data())))
        let substitutedReference = RealtimeHello(serviceID: caller.serviceID, version: 1,
            callerIncarnation: incarnation, recipient: identity, handshakeID: UUID(), endpointDigest: Data(repeating: 0, count: 32))
        await #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try await inbound.openSession(caller.sign(substitutedReference, maximumBytes: 16_384))
        }
        let grantPacket = try await inbound.openSession(caller.sign(hello, maximumBytes: 16_384))
        let (grant, _) = try trust.verify(grantPacket, as: RealtimeGrant.self, maximumBytes: 16_384)
        let room = RoomID(uuid: UUID())
        func call(sequence: UInt64, shard: String = "room-a") throws -> RealtimeCall {
            let delivery = V2RealtimeDelivery(topic: .init(kind: .roomEvents, id: room.rawValue,
                owner: try .init(shardID: shard, epoch: 0)), partitionID: V2RealtimeTopicKey(kind: .roomEvents, id: room.rawValue).partitionID(),
                partitionEpoch: 1, sessionID: UUID(), interestGeneration: 1, gatewayIncarnation: identity.incarnationID,
                payload: .roomWake(roomID: room, highWatermark: 1))
            return RealtimeCall(serviceID: caller.serviceID, version: 1, callerIncarnation: incarnation, recipient: identity,
                sessionID: grant.sessionID, sequence: sequence, attemptID: UUID(),
                batch: .init(recipient: identity, deliveries: [delivery]))
        }
        let packet = try caller.sign(call(sequence: 1), maximumBytes: 262_144)
        _ = try await inbound.exchange(packet)
        #expect(ingress.count == 1)
        await #expect(throws: V2ActorAuthenticationError.replay) { try await inbound.exchange(packet) }
        await #expect(throws: V2ActorAuthenticationError.forbidden) {
            try await inbound.exchange(caller.sign(call(sequence: 2, shard: "room-b"), maximumBytes: 262_144))
        }
        #expect(ingress.count == 1)
        ingress.acceptance.withLock { $0 = .acceptedAsWatermark }
        let degraded = try await inbound.exchange(caller.sign(call(sequence: 2), maximumBytes: 262_144))
        let (reply, _) = try trust.verify(degraded, as: RealtimeReply.self, maximumBytes: 16_384)
        #expect(reply.acceptance == .acceptedAsWatermark)
        #expect(reply.acceptance.wasAccepted)
        #expect(ingress.count == 2)
        await inbound.stop()
        await #expect(throws: V2ActorAuthenticationError.overloaded) { try await inbound.exchange(packet) }
    }
    @Test("journal RPC returns synchronous projection commit and shares replay fences")
    func journalProjectionCommit() async throws {
        let publisherKey = Curve25519.Signing.PrivateKey(), gatewayKey = Curve25519.Signing.PrivateKey()
        let publisher = try V2ActorSigningIdentity(serviceID: .init("publisher"), privateKey: publisherKey.rawRepresentation)
        let gateway = try V2ActorSigningIdentity(serviceID: .init("gateway"), privateKey: gatewayKey.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [
            .init(serviceID: publisher.serviceID, publicKey: publisherKey.publicKey.rawRepresentation, permissions: [.realtimePublish]),
            .init(serviceID: gateway.serviceID, publicKey: gatewayKey.publicKey.rawRepresentation, permissions: [.realtimeReceive])
        ])
        let identity = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())
        let ingress = Ingress(), handler = ProjectionHandler()
        let inbound = V2GatewayRealtimeInbound(identity: identity, signer: gateway, trust: trust, ingress: ingress,
            serviceOwnerAccess: [publisher.serviceID: ["source-a"]], limits: .init())
        inbound.bindEndpointReference(Data())
        try await inbound.configureJournalProjection(handler)
        await #expect(throws: V2ActorAuthenticationError.invalidConfiguration) { try await inbound.configureJournalProjection(handler) }
        let incarnation = UUID()
        let hello = RealtimeHello(serviceID: publisher.serviceID, version: 1, callerIncarnation: incarnation,
            recipient: identity, handshakeID: UUID(), endpointDigest: Data(SHA256.hash(data: Data())))
        let signedGrant = try await inbound.openSession(publisher.sign(hello, maximumBytes: 16_384))
        let (grant, _) = try trust.verify(signedGrant, as: RealtimeGrant.self, maximumBytes: 16_384)
        let source = V2RealtimeJournalSource(sourceID: "source-a", incarnationID: UUID(), partitionID: 0)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: incarnation, sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date().addingTimeInterval(60), routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: identity.incarnationID)
        let batch = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .changes(fromExclusive: 0, throughInclusive: 7, entries: []))
        let call = JournalProjectionCall(serviceID: publisher.serviceID, version: 1, callerIncarnation: incarnation,
            recipient: identity, sessionID: grant.sessionID, sequence: 1, attemptID: UUID(), batch: batch)
        let packet = try publisher.sign(call, maximumBytes: 262_144)
        let response = try await inbound.projectJournal(packet)
        let (reply, _) = try trust.verify(response, as: JournalProjectionReply.self, maximumBytes: 16_384)
        #expect(reply.result == .applied(.init(batchID: batch.batchID, source: source, fence: fence,
            appliedThrough: 7, snapshotInstalled: false)))
        #expect(handler.committed.withLock { $0 } == 7)
        #expect(ingress.count == 0)
        await #expect(throws: V2ActorAuthenticationError.replay) { try await inbound.projectJournal(packet) }
        await inbound.stop()
    }
    private final class ProjectionHandler: V2RealtimeJournalProjectionHandler {
        let committed = Mutex<Int64>(0)
        func applyJournalProjection(_ batch: V2RealtimeJournalProjectionBatch,
                                    authenticatedServiceID: String) -> V2RealtimeJournalProjectionResult {
            guard authenticatedServiceID == "publisher",
                  case .changes(_, let through, _) = batch.payload else { return .stale }
            committed.withLock { $0 = through }
            return .applied(.init(batchID: batch.batchID, source: batch.source, fence: batch.fence,
                appliedThrough: through, snapshotInstalled: false))
        }
    }
    private final class Ingress: V2RealtimeIngress {
        let offered = Mutex(0)
        let acceptance = Mutex(V2RealtimeAcceptance.accepted)
        var count: Int { offered.withLock { $0 } }
        func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance {
            offered.withLock { $0 += 1 }
            return acceptance.withLock { $0 }
        }
    }
}
