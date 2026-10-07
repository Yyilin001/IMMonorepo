import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

struct V2MessageAcceptanceReceiptTests {
    @Test("protobuf sends accept a bound metadata-only receipt without content echoed in ACK")
    func acceptsContentFreeReceipt() throws {
        let command = try command()
        let sent = try V2MessageSendOperationWireCodec.decode(command: V2MessageSendOperationWireCodec.encode(command: command))
        #expect(sent.command.text == "hello")
        #expect(sent.command.media.count == 1)
        #expect(sent.command.entities.first?.linkURL == URL(string: "https://example.com/private"))
        guard case .receipt(let proof) = try decoded(command: command), case .accepted(let accepted) = proof.outcome else {
            Issue.record("Expected bound receipt"); return
        }
        #expect(accepted.roomSequence == 7)
    }
    @Test(arguments: ["room", "zero", "overflow", "time"])
    func rejectsInvalidReceiptMetadata(_ fault: String) throws {
        let command = try command()
        #expect(throws: V2MessageSendTransportError.invalidResponse) { try decoded(command: command, fault: fault) }
    }
    private func decoded(command: V2MessageSendOperationCommand, fault: String? = nil) throws -> V2MessageSendOperationRecoveryResult {
        let receipt = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 7)), resolvedAtMilliseconds: 1_000_000)
        var response = IMV2Envelope()
        response.messageSendOperationResult = V2MessageSendOperationWireCodec.encode(result: .receipt(receipt))
        switch fault {
        case "room": response.messageSendOperationResult.receipt.identity.roomID = UUID().uuidString
        case "zero": response.messageSendOperationResult.receipt.accepted.roomSequence = 0
        case "overflow": response.messageSendOperationResult.receipt.accepted.roomSequence = .max
        case "time": response.messageSendOperationResult.receipt.resolvedAtMs = .max
        default: break
        }
        return try V2ProtobufMessageSendOperationClient.decodeCorrelatedResponse(response,
            identity: command.identity, fingerprint: command.fingerprint)
    }
    private func command() throws -> V2MessageSendOperationCommand {
        try .init(command: .init(roomID: .init(uuid: UUID()), senderUserID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "hello",
            media: [.init(mediaID: .init(uuid: UUID()))], mentions: [.user(.init(uuid: UUID()))],
            entities: [.init(offsetUTF16: 0, lengthUTF16: 5, kind: .link, linkURL: URL(string: "https://example.com/private"))],
            replyTo: .init(messageID: .init(uuid: UUID())), limits: .init(maxUTF8Bytes: 4096)), firstSubmissionDeadlineMilliseconds: 1_000_000)
    }
}
