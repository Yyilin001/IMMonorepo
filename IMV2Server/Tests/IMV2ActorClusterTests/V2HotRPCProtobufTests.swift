import DistributedCluster
import Foundation
import IMV2Core
import IMV2ActorContracts
import SwiftProtobuf
import Testing
@testable import IMV2ActorCluster

@Suite("Fixed RPC Protobuf boundary")
struct V2HotRPCProtobufTests {
    @Test("delivery session pulses use fixed PB and preserve every generation and identity")
    func deliverySessionFixedEnvelope() throws {
        let host = V2ActorHostIdentity(hostID: try .init("host"), incarnationID: UUID())
        let gateway = V2GatewayRealtimeIdentity(nodeID: "gateway", serviceID: "gateway", incarnationID: UUID())
        let session = V2RoomDeliverySession(host: host, gateway: gateway, generation: 9)
        for kind in [V2RoomDeliverySessionPulse.Kind.open, .retire] {
            let call = RoomDeliverySessionCall(serviceID: try .init("publisher"), version: 1,
                callerIncarnation: UUID(), recipient: gateway, sessionID: UUID(), sequence: 13, attemptID: UUID(),
                sourceNode: .init(systemName: "publisher", host: "127.0.0.1", port: 9001, nid: .init(42)), sourceShardID: "rooms", pulse: .init(session: session, kind: kind, sequence: 7))
            let bytes = try V2ActorProtobuf.encode(call)
            let wire = try Im_Actor_V1_HotDeliverySessionCall(serializedBytes: bytes)
            #expect(wire.pulse.kind == kind.rawValue && wire.pulse.sequence == 7)
            #expect(wire.pulse.session.generation == 9 && wire.sourceShardID == "rooms")
            #expect(try V2ActorProtobuf.decode(RoomDeliverySessionCall.self, from: bytes) == call)
            for result in [V2RoomDeliverySessionResult.accepted, .resetRequired, .stale] {
                let reply = RoomDeliverySessionReply(recipient: gateway, sessionID: call.sessionID,
                    sequence: call.sequence, attemptID: call.attemptID, result: result)
                #expect(try V2ActorProtobuf.decode(RoomDeliverySessionReply.self, from: V2ActorProtobuf.encode(reply)) == reply)
            }
            var missingNode = wire; missingNode.sourceNode = Data()
            #expect(throws: (any Error).self) {
                try V2ActorProtobuf.decode(RoomDeliverySessionCall.self, from: missingNode.serializedData())
            }
            var invalid = wire; invalid.pulse.session.generation = 0
            #expect(throws: (any Error).self) {
                try V2ActorProtobuf.decode(RoomDeliverySessionCall.self, from: invalid.serializedData())
            }
        }
    }
    @Test func invokeUsesFixedEnvelopeAndRejectsGenericHotRequest() throws {
        let room = RoomID(uuid: UUID()), host = V2ActorHostIdentity(hostID: try .init("host"), incarnationID: UUID())
        let token = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0), activationEpoch: .init(1), host: host)
        let operation = try V2MessageSendOperationCommand(command: .init(roomID: room, senderUserID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "hello", limits: .init(maxUTF8Bytes: 1024)), firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
        let request = V2ActorRPCRequest.invoke(token: token, request: .messaging(.sendOperation(operation)))
        let call = V2ActorAuthenticatedCall(serviceID: try .init("gateway"), callerIncarnation: UUID(), recipient: host, sessionID: UUID(), sequence: 1, attemptID: UUID(), traceID: UUID(), remainingBudget: try .init(1000), principal: .user(operation.command.senderUserID), request: request)
        let encoded = try V2ActorProtobuf.encode(call), outer = try Im_Actor_V1_AuthenticatedCall(serializedBytes: encoded)
        let rpc = try Im_Actor_V1_HotRPCRequest(serializedBytes: outer.requestBody)
        #expect(rpc.invoke.request.send.text == "hello")
        #expect(try V2ActorProtobuf.decode(V2ActorAuthenticatedCall.self, from: encoded) == call)
        let receipt = try V2MessageSendOperationReceipt(identity: operation.identity, fingerprint: operation.fingerprint, outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 1)), resolvedAtMilliseconds: 1)
        let reply = V2ActorAuthenticatedReply(call: call, response: .result(.messaging(.sendOperation(.receipt(receipt)))))
        #expect(try V2ActorProtobuf.decode(V2ActorAuthenticatedReply.self, from: V2ActorProtobuf.encode(reply)) == reply)
        var cold = Im_Actor_V1_HotRPCRequest(); cold.coldValue = try V2ActorProtobuf.encodeValue(request)
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2ActorRPCRequest.self, from: cold.serializedData()) }
        let control = V2ActorRPCRequest.activate(roomID: room, owner: token.owner)
        #expect(try V2ActorProtobuf.decode(V2ActorRPCRequest.self, from: V2ActorProtobuf.encode(control)) == control)
    }

}
