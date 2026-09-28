import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2ClientKit
import IMV2Core
import Testing

struct V2MessageAcceptanceReceiptTests {
    @Test("rich sends accept a bound metadata-only receipt without content echoed in ACK")
    func acceptsContentFreeReceipt() async throws {
        let command = try command(), wire = ReceiptHTTP(command: command)
        let client = try V2HTTPMessageSendOperationClient(baseURL: URL(string: "https://account.example")!, credentials: ReceiptCredentials(), transport: wire)
        guard case .receipt(let proof) = try await client.submit(command), case .accepted(let accepted) = proof.outcome else { Issue.record("Expected bound receipt"); return }
        #expect(accepted.roomSequence == 7)
        let sent = try #require(await wire.sentMessage())
        #expect(sent.command.text == "hello")
        #expect(sent.command.media.count == 1)
        #expect(sent.command.entities.first?.linkURL == URL(string: "https://example.com/private"))
    }
    @Test(arguments: ["room", "zero", "overflow", "time"])
    func rejectsInvalidReceiptMetadata(_ fault: String) async throws {
        let command = try command(), wire = ReceiptHTTP(command: command, fault: fault)
        let client = try V2HTTPMessageSendOperationClient(baseURL: URL(string: "https://account.example")!, credentials: ReceiptCredentials(), transport: wire)
        await #expect(throws: (any Error).self) { try await client.submit(command) }
    }
    private func command() throws -> V2MessageSendOperationCommand {
        try .init(command: .init(roomID: .init(uuid: UUID()), senderUserID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "hello",
            media: [.init(mediaID: .init(uuid: UUID()))], mentions: [.user(.init(uuid: UUID()))],
            entities: [.init(offsetUTF16: 0, lengthUTF16: 5, kind: .link, linkURL: URL(string: "https://example.com/private"))],
            replyTo: .init(messageID: .init(uuid: UUID())), limits: .init(maxUTF8Bytes: 4096)), firstSubmissionDeadlineMilliseconds: 1_000_000)
    }
}
private struct ReceiptCredentials: V2ClientMediaEdgeCredentialProvider {
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken: "fixture", deviceID: .init(uuid: UUID())) }
}
private actor ReceiptHTTP: V2ClientMediaEdgeHTTPTransport {
    let command: V2MessageSendOperationCommand
    let fault: String?
    private var sent: V2MessageSendOperationCommand?
    init(command: V2MessageSendOperationCommand, fault: String? = nil) { self.command = command; self.fault = fault }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        sent = try JSONDecoder().decode(V2MessageSendOperationCommand.self, from: #require(request.httpBody))
        let receipt = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
            outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: 7)), resolvedAtMilliseconds: 1_000_000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var body = String(decoding: try encoder.encode(V2MessageSendOperationRecoveryResult.receipt(receipt)), as: UTF8.self)
        switch fault {
        case "room": body = body.replacingOccurrences(of: command.command.roomID.rawValue, with: UUID().uuidString)
        case "zero": body = body.replacingOccurrences(of: "\"roomSequence\":7", with: "\"roomSequence\":0")
        case "overflow": body = body.replacingOccurrences(of: "\"roomSequence\":7", with: "\"roomSequence\":18446744073709551615")
        case "time": body = body.replacingOccurrences(of: "\"resolvedAtMilliseconds\":1000000", with: "\"resolvedAtMilliseconds\":-1")
        default: break
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
    func sentMessage() -> V2MessageSendOperationCommand? { sent }
}
