import Crypto
import DistributedCluster
import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorCluster

@Suite("Native room subscription boundary", .serialized)
struct V2LocalRoomSubscriptionTests {
    @Test("native delivery requires exact reference, shard permission, valid receipt and open lifecycle")
    func nativeBoundary() async throws {
        let f = try Fixture()
        let system = await makeSystem()
        let inbound = V2GatewayRealtimeInbound(identity: f.identity, signer: f.signer, trust: f.trust,
            ingress: Ingress(), serviceOwnerAccess: [f.signer.serviceID: ["rooms"]], limits: .init())
        // Deliberately not an encoded ActorID: successful delivery proves this
        // capability never attempts resolution, handshake or packet decoding.
        let descriptor = V2GatewayRealtimeDescriptor(identity: f.identity, endpointReference: Data([1]),
            address: "127.0.0.1", port: system.cluster.node.endpoint.port)
        let sender = V2RealtimeClusterSender(system: system, signer: f.signer, trust: f.trust,
            limits: .init(), local: (descriptor, inbound))
        var failure: (any Error)?
        do {
            let result = try await sender.sendRoomSubscriptionBatch(f.batch, sourceShardID: "rooms", to: descriptor)
            #expect(result.receipts == [.init(fence: f.fence, result: .stale)])
            let wrongReference = V2GatewayRealtimeDescriptor(identity: f.identity, endpointReference: Data([2]),
                address: descriptor.address, port: descriptor.port)
            await #expect(throws: (any Error).self) {
                try await sender.sendRoomSubscriptionBatch(f.batch, sourceShardID: "rooms", to: wrongReference)
            }
            await #expect(throws: V2ActorAuthenticationError.invalidRequest) {
                try await sender.sendRoomSubscriptionBatch(f.batch, sourceShardID: "other", to: descriptor)
            }
            let denied = V2RealtimeClusterSender(system: system, signer: f.denied, trust: f.trust,
                limits: .init(), local: (descriptor, inbound))
            await #expect(throws: V2ActorAuthenticationError.forbidden) {
                try await denied.sendRoomSubscriptionBatch(f.batch, sourceShardID: "rooms", to: descriptor)
            }
            #expect(await denied.stop(deadline: .now + .seconds(1)))
            try await inbound.configureRoomSubscription(InvalidReceiptHandler())
            await #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
                try await sender.sendRoomSubscriptionBatch(f.batch, sourceShardID: "rooms", to: descriptor)
            }
            await inbound.stop()
            await #expect(throws: V2ActorAuthenticationError.overloaded) {
                try await sender.sendRoomSubscriptionBatch(f.batch, sourceShardID: "rooms", to: descriptor)
            }
        } catch { failure = error }
        await inbound.stop()
        #expect(await sender.stop(deadline: .now + .seconds(1)))
        try await system.shutdown().wait()
        if let failure { throw failure }
    }

    @Test("production composition binds the local native capability and closes admission")
    func composition() async throws {
        let f = try Fixture(), system = await makeSystem()
        let transport = try buildRealtimeTransport(system: system, identity: f.identity,
            address: "127.0.0.1", port: system.cluster.node.endpoint.port, signer: f.signer, trust: f.trust,
            ingress: Ingress(), serviceOwnerAccess: [f.signer.serviceID: ["rooms"]], limits: .init())
        var failure: (any Error)?
        do {
            #expect(try await transport.sendRoomSubscriptionBatch(f.batch, sourceShardID: "rooms",
                to: transport.descriptor).receipts == [.init(fence: f.fence, result: .stale)])
            #expect(await transport.stop(deadline: .now + .seconds(1)))
            await #expect(throws: V2ActorAuthenticationError.overloaded) {
                try await transport.sendRoomSubscriptionBatch(f.batch, sourceShardID: "rooms", to: transport.descriptor)
            }
        } catch { failure = error }
        _ = await transport.stop(deadline: .now + .seconds(1))
        try await system.shutdown().wait()
        if let failure { throw failure }
    }

    private func makeSystem() async -> ClusterSystem {
        var settings = ClusterSystemSettings(name: "native-delivery", host: "127.0.0.1", port: Int.random(in: 30_000...60_000))
        settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
        return await ClusterSystem("native-delivery", settings: settings)
    }
    private struct Fixture {
        let signer: V2ActorSigningIdentity, denied: V2ActorSigningIdentity
        let trust: V2ActorTrustStore
        let identity: V2GatewayRealtimeIdentity
        let fence: V2RoomSubscriptionFence
        let batch: V2RoomSubscriptionDeliveryBatch
        init() throws {
            let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
            signer = try .init(serviceID: .init("local"), privateKey: key.rawRepresentation)
            denied = try .init(serviceID: .init("denied"), privateKey: other.rawRepresentation)
            trust = try .init(services: [
                .init(serviceID: signer.serviceID, publicKey: key.publicKey.rawRepresentation, permissions: [.realtimePublish, .realtimeReceive]),
                .init(serviceID: denied.serviceID, publicKey: other.publicKey.rawRepresentation, permissions: [.realtimeReceive])])
            identity = .init(nodeID: "local", serviceID: "local", incarnationID: UUID())
            let token = V2RoomActivationToken(roomID: .init(uuid: UUID()), owner: try .init(shardID: "rooms", epoch: 0),
                activationEpoch: try .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
            fence = .init(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
            batch = .init(deliveries: [.init(fence: fence, deliverySequence: 1, authorizationSequence: 1,
                payload: .baseline(members: [.init(userID: .init(uuid: UUID()), memberRevision: 0)]))])
        }
    }
    private struct Ingress: V2RealtimeIngress {
        func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance { .stale }
    }
    private struct InvalidReceiptHandler: V2RoomSubscriptionHandler {
        func applyRoomSubscription(_ delivery: V2RoomSubscriptionDelivery, authenticatedServiceID: String,
                                   sourceShardID: String) async -> V2RoomSubscriptionDeliveryResult { .stale }
        func applyRoomSubscriptionBatch(_ batch: V2RoomSubscriptionDeliveryBatch, authenticatedServiceID: String,
                                        sourceShardID: String) async -> V2RoomSubscriptionBatchResult { .init(receipts: []) }
    }
}
