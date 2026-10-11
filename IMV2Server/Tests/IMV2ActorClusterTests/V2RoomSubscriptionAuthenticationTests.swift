import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ActorCluster

@Suite("Room subscription signed transport")
struct V2RoomSubscriptionAuthenticationTests {
    @Test("PB batch bytes preserve all signed envelope fields and exact packet limits")
    func protobufBatchEnvelope() throws {
        let fixture = try Fixture()
        var builder = V2RoomSubscriptionDeliveryBatch.Builder()
        #expect(try builder.append(fixture.delivery, maximumBytes: 262_144))
        let call = RoomSubscriptionBatchCall(serviceID: fixture.publisher.serviceID, version: 1,
            callerIncarnation: fixture.incarnation, recipient: fixture.identity,
            sessionID: UUID(), sequence: 17, attemptID: UUID(), sourceShardID: "room-a",
            batch: builder.finish())
        let bytes = try V2ActorProtobuf.encode(call)
        let packet = try fixture.publisher.sign(call, maximumBytes: bytes.count)
        let decoded = try fixture.trust.verify(packet, as: RoomSubscriptionBatchCall.self,
            maximumBytes: bytes.count).0
        #expect(decoded.serviceID == call.serviceID && decoded.version == call.version)
        #expect(decoded.callerIncarnation == call.callerIncarnation && decoded.recipient == call.recipient)
        #expect(decoded.sessionID == call.sessionID && decoded.sequence == call.sequence)
        #expect(decoded.attemptID == call.attemptID && decoded.sourceShardID == call.sourceShardID)
        #expect(decoded.batch == call.batch)
        #expect(throws: V2ActorAuthenticationError.oversized) {
            try fixture.publisher.sign(call, maximumBytes: bytes.count - 1)
        }
        var altered = packet.body
        altered[altered.startIndex] ^= 1
        #expect(throws: V2ActorAuthenticationError.invalidSignature) {
            try fixture.trust.verify(.init(signerID: packet.signerID, body: altered,
                signature: packet.signature), as: RoomSubscriptionBatchCall.self, maximumBytes: bytes.count)
        }
    }
    @Test("room delivery authenticates shard, recipient and session before synchronous authority")
    func signedRoomAuthority() async throws {
        let fixture = try Fixture()
        let session = try await fixture.open()
        let handler = Handler()
        // Missing trusted configuration is an explicit stale result, never admission.
        let missing = try await fixture.reply(fixture.call(session: session, sequence: 1))
        #expect(missing.result == .stale)
        try await fixture.inbound.configureRoomSubscription(handler)
        await #expect(throws: V2ActorAuthenticationError.invalidConfiguration) {
            try await fixture.inbound.configureRoomSubscription(handler)
        }
        await #expect(throws: V2ActorAuthenticationError.forbidden) {
            try await fixture.reply(fixture.call(session: session, sequence: 2, shard: "room-b"))
        }
        await #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try await fixture.reply(fixture.call(session: session, sequence: 2,
                recipient: .init(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())))
        }
        await #expect(throws: V2ActorAuthenticationError.sessionExpired) {
            try await fixture.reply(fixture.call(session: UUID(), sequence: 2))
        }
        #expect(handler.count == 0)
        let accepted = fixture.call(session: session, sequence: 2)
        let reply = try await fixture.reply(accepted)
        #expect(reply.result == .appliedThrough(1))
        #expect(reply.sessionID == session && reply.attemptID == accepted.attemptID && reply.sequence == 2)
        #expect(handler.count == 1)
        await #expect(throws: V2ActorAuthenticationError.replay) { try await fixture.reply(accepted) }
        await #expect(throws: V2ActorAuthenticationError.replay) {
            try await fixture.reply(fixture.call(session: session, sequence: 3, attempt: accepted.attemptID))
        }
        #expect(handler.count == 1)
        // The room RPC cannot bypass another RPC's shared session replay window.
        let topic = V2RealtimeTopicKey(kind: .roomEvents, id: fixture.delivery.fence.roomID.rawValue)
        let legacy = V2RealtimeDelivery(topic: .init(kind: .roomEvents, id: fixture.delivery.fence.roomID.rawValue,
            owner: try .init(shardID: "room-a", epoch: 0)), partitionID: topic.partitionID(),
            partitionEpoch: 1, sessionID: UUID(), interestGeneration: 1,
            gatewayIncarnation: fixture.identity.incarnationID,
            payload: .roomWake(roomID: fixture.delivery.fence.roomID, highWatermark: 1))
        let reused = RealtimeCall(serviceID: fixture.publisher.serviceID, version: 1,
            callerIncarnation: fixture.incarnation, recipient: fixture.identity,
            sessionID: session, sequence: 2, attemptID: UUID(),
            batch: .init(recipient: fixture.identity, deliveries: [legacy]))
        await #expect(throws: V2ActorAuthenticationError.replay) {
            try await fixture.inbound.exchange(fixture.publisher.sign(reused, maximumBytes: 262_144))
        }
        // Retrying the same room control with a new transport attempt is allowed.
        #expect(try await fixture.reply(fixture.call(session: session, sequence: 3)).result == .appliedThrough(1))
        #expect(handler.count == 2)
        handler.result.withLock { $0 = .snapshotRequired }
        #expect(try await fixture.reply(fixture.call(session: session, sequence: 4)).result == .snapshotRequired)
        handler.result.withLock { $0 = .stale }
        #expect(try await fixture.reply(fixture.call(session: session, sequence: 5)).result == .stale)
        #expect(fixture.ingress.offered.withLock { $0 } == 0)
        await fixture.inbound.stop()
        await #expect(throws: V2ActorAuthenticationError.overloaded) {
            try await fixture.reply(fixture.call(session: session, sequence: 6))
        }
    }

    @Test("signed batch RPC is bounded and returns one cumulative receipt per exact room fence")
    func batchAuthorityAndBounds() async throws {
        let fixture = try Fixture()
        let session = try await fixture.open()
        let handler = Handler()
        try await fixture.inbound.configureRoomSubscription(handler)
        let activation = fixture.delivery.fence.activation
        let otherActivation = V2RoomActivationToken(roomID: RoomID(uuid: UUID()), owner: activation.owner,
            activationEpoch: activation.activationEpoch, host: activation.host)
        let otherFence = V2RoomSubscriptionFence(activation: otherActivation, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        let second = V2RoomSubscriptionDelivery(fence: otherFence, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: []))
        let batch = V2RoomSubscriptionDeliveryBatch(deliveries: [fixture.delivery, second])
        let call = RoomSubscriptionBatchCall(serviceID: fixture.publisher.serviceID, version: 1,
            callerIncarnation: fixture.incarnation, recipient: fixture.identity, sessionID: session,
            sequence: 1, attemptID: UUID(), sourceShardID: "room-a", batch: batch)
        let packet = try fixture.publisher.sign(call, maximumBytes: 262_144)
        let response = try await fixture.inbound.deliverRoomSubscriptionBatch(packet)
        let (reply, _) = try fixture.trust.verify(response, as: RoomSubscriptionBatchReply.self, maximumBytes: 262_144)
        #expect(reply.result.receipts == [.init(fence: fixture.delivery.fence, result: .appliedThrough(1)),
                                         .init(fence: otherFence, result: .appliedThrough(1))])
        #expect(handler.count == 2)
        await #expect(throws: V2ActorAuthenticationError.replay) {
            try await fixture.inbound.deliverRoomSubscriptionBatch(packet)
        }
        #expect(handler.count == 2)
        await #expect(throws: V2ActorAuthenticationError.replay) {
            try await fixture.reply(fixture.call(session: session, sequence: 1))
        }
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionBatch(batch, sourceShardID: "room-a", limits: .init(maximumBatchItems: 1))
        }
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionBatch(batch, sourceShardID: "room-a", limits: .init(maximumPacketBytes: 64))
        }
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionBatch(.init(deliveries: []), sourceShardID: "room-a", limits: .init())
        }
        let gap = V2RoomSubscriptionDelivery(fence: fixture.delivery.fence, deliverySequence: 1, authorizationSequence: 1, payload: .head(highWatermark: 1))
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionBatch(.init(deliveries: [fixture.delivery, gap]), sourceShardID: "room-a", limits: .init())
        }
        let replacementFence = V2RoomSubscriptionFence(activation: activation, subscriptionID: UUID(), generation: 2, baselineSequence: 0)
        let mixed = V2RoomSubscriptionDelivery(fence: replacementFence, deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: []))
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionBatch(.init(deliveries: [fixture.delivery, mixed]), sourceShardID: "room-a", limits: .init())
        }
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try validateRoomSubscriptionBatchReceipt(.init(receipts: [.init(fence: fixture.delivery.fence, result: .appliedThrough(1))]), batch: batch)
        }
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try validateRoomSubscriptionBatchReceipt(.init(receipts: [.init(fence: fixture.delivery.fence, result: .appliedThrough(2)),
                .init(fence: otherFence, result: .appliedThrough(1))]), batch: batch)
        }
        await fixture.inbound.stop()
    }

    @Test("room transport rejects malformed deliveries and uncommitted receipts")
    func roomValidation() throws {
        let fixture = try Fixture()
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionDelivery(fixture.delivery, sourceShardID: "", limits: .init())
        }
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionDelivery(fixture.delivery, sourceShardID: "other", limits: .init())
        }
        let malformed = V2RoomSubscriptionDelivery(fence: fixture.delivery.fence,
            deliverySequence: 0, authorizationSequence: 1, payload: fixture.delivery.payload)
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateRoomSubscriptionDelivery(malformed, sourceShardID: "room-a", limits: .init())
        }
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try validateRoomSubscriptionReceipt(.appliedThrough(0), delivery: fixture.delivery)
        }
    }

    private struct Fixture {
        let publisher: V2ActorSigningIdentity
        let trust: V2ActorTrustStore
        let identity: V2GatewayRealtimeIdentity
        let incarnation = UUID()
        let delivery: V2RoomSubscriptionDelivery
        let inbound: V2GatewayRealtimeInbound
        let ingress = Ingress()
        init() throws {
            let publisherKey = Curve25519.Signing.PrivateKey(), gatewayKey = Curve25519.Signing.PrivateKey()
            publisher = try .init(serviceID: .init("publisher"), privateKey: publisherKey.rawRepresentation)
            let gateway = try V2ActorSigningIdentity(serviceID: .init("gateway"), privateKey: gatewayKey.rawRepresentation)
            trust = try .init(services: [
                .init(serviceID: publisher.serviceID, publicKey: publisherKey.publicKey.rawRepresentation, permissions: [.realtimePublish]),
                .init(serviceID: gateway.serviceID, publicKey: gatewayKey.publicKey.rawRepresentation, permissions: [.realtimeReceive])
            ])
            identity = .init(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())
            let activation = V2RoomActivationToken(roomID: RoomID(uuid: UUID()),
                owner: try .init(shardID: "room-a", epoch: 0), activationEpoch: try .init(1),
                host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
            delivery = .init(fence: .init(activation: activation, subscriptionID: UUID(),
                generation: 1, baselineSequence: 0), deliverySequence: 1, authorizationSequence: 1, payload: .baseline(members: []))
            inbound = .init(identity: identity, signer: gateway, trust: trust, ingress: ingress,
                serviceOwnerAccess: [publisher.serviceID: ["room-a"]], limits: .init())
            inbound.bindEndpointReference(Data())
        }
        func open() async throws -> UUID {
            let hello = RealtimeHello(serviceID: publisher.serviceID, version: 1, callerIncarnation: incarnation,
                recipient: identity, handshakeID: UUID(), endpointDigest: Data(SHA256.hash(data: Data())))
            let signed = try await inbound.openSession(publisher.sign(hello, maximumBytes: 16_384))
            let (grant, _) = try trust.verify(signed, as: RealtimeGrant.self, maximumBytes: 16_384)
            return grant.sessionID
        }
        func call(session: UUID, sequence: UInt64, shard: String = "room-a",
                  recipient: V2GatewayRealtimeIdentity? = nil, attempt: UUID = UUID()) -> RoomSubscriptionCall {
            .init(serviceID: publisher.serviceID, version: 1, callerIncarnation: incarnation,
                recipient: recipient ?? identity, sessionID: session, sequence: sequence, attemptID: attempt,
                sourceShardID: shard, delivery: delivery)
        }
        func reply(_ call: RoomSubscriptionCall) async throws -> RoomSubscriptionReply {
            let response = try await inbound.deliverRoomSubscription(publisher.sign(call, maximumBytes: 262_144))
            return try trust.verify(response, as: RoomSubscriptionReply.self, maximumBytes: 16_384).0
        }
    }
    private final class Handler: V2RoomSubscriptionHandler {
        let applied = Mutex(0)
        let result = Mutex(V2RoomSubscriptionDeliveryResult.appliedThrough(1))
        var count: Int { applied.withLock { $0 } }
        func applyRoomSubscription(_ delivery: V2RoomSubscriptionDelivery,
                                   authenticatedServiceID: String, sourceShardID: String) -> V2RoomSubscriptionDeliveryResult {
            guard authenticatedServiceID == "publisher", sourceShardID == "room-a" else { return .stale }
            applied.withLock { $0 += 1 }
            return result.withLock { $0 }
        }

        func applyRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch,
                                        authenticatedServiceID: String,
                                        sourceShardID: String) async -> V2RoomSubscriptionBatchResult {
            var order: [V2RoomSubscriptionFence] = []
            var results: [V2RoomSubscriptionFence: V2RoomSubscriptionDeliveryResult] = [:]
            for delivery in batch.deliveries {
                if results[delivery.fence] == nil { order.append(delivery.fence) }
                if let previous = results[delivery.fence] {
                    switch previous { case .snapshotRequired, .stale: continue; case .appliedThrough: break }
                }
                results[delivery.fence] = await applyRoomSubscription(delivery,
                    authenticatedServiceID: authenticatedServiceID, sourceShardID: sourceShardID)
            }
            return .init(receipts: order.map { .init(fence: $0, result: results[$0]!) })
        }
    }
    private final class Ingress: V2RealtimeIngress {
        let offered = Mutex(0)
        func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance {
            offered.withLock { $0 += 1 }; return .accepted
        }
    }
}
