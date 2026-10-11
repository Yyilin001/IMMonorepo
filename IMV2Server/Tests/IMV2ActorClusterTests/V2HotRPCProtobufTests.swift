import Foundation
import IMV2Core
import IMV2ActorContracts
import SwiftProtobuf
import Testing
@testable import IMV2ActorCluster

@Suite("Fixed RPC Protobuf boundary")
struct V2HotRPCProtobufTests {
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
    @Test func renewalBatchAndMixedOutcomes() throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let token = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 0), activationEpoch: .init(1), host: .init(hostID: .init("host"), incarnationID: UUID()))
        let fence = V2RoomSubscriptionFence(activation: token, subscriptionID: UUID(), generation: 1, baselineSequence: 0)
        let command = V2RoomSubscriptionRenewCommand(roomID: room, actorUserID: user, gatewayDescriptor: .init(identity: .init(nodeID: "gw", serviceID: "gw", incarnationID: UUID()), endpointReference: Data([1]), address: "localhost", port: 9999), expectedFence: fence, appliedControlSequence: 1)
        let request = V2ActorRPCRequest.subscriptionRenewBatch([.init(token: token, command: command)])
        #expect(try V2ActorProtobuf.decode(V2ActorRPCRequest.self, from: V2ActorProtobuf.encode(request)) == request)
        let outcomes: [V2RoomSubscriptionRenewBatchOutcome] = [.init(token: token, outcome: .result(.activated)), .init(token: token, outcome: .failure(.outcomeUnknown))]
        for response: V2ActorRPCResponse in [.subscriptionRenewBatch(outcomes), .completed(false), .acknowledged, .ready(token: token, physicalReference: Data([0, 1, 255]))] {
            #expect(try V2ActorProtobuf.decode(V2ActorRPCResponse.self, from: V2ActorProtobuf.encode(response)) == response)
        }
    }
}
