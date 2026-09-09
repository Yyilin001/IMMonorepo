import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2MessageAcceptanceReceiptTests {
    @Test("rich sends accept a metadata-only receipt and do not need content echoed in ACK")
    func acceptsContentFreeReceipt() async throws {
        let wire = ReceiptWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let roomID = try RoomID("room-1")
        let result = try await transport.sendMessage(
            roomID: roomID, clientMessageID: .init("client-1"), text: "hello",
            media: [.init(mediaID: .init("media-1"))], mentions: [.user(.init("user-1"))],
            entities: [.init(offsetUTF16: 0, lengthUTF16: 5, kind: .link, linkURL: URL(string: "https://example.com/private"))],
            replyTo: .init(messageID: .init("prior-message"))
        )
        #expect(result.roomID == roomID)
        #expect(result.messageID == (try MessageID("accepted-message")))
        #expect(result.roomSequence == 7)
        #expect(result.createdAt == Date(timeIntervalSince1970: 1_000))
        let sent = try #require(await wire.sentMessage())
        #expect(sent.content.text == "hello")
        #expect(sent.content.mediaIds == ["media-1"])
        #expect(sent.content.entities.first?.linkURL == "https://example.com/private")
    }

    @Test(arguments: ["room", "zero", "overflow", "time"])
    func rejectsInvalidReceiptMetadata(_ fault: String) async throws {
        let transport = V2ProtobufSyncTransport(wire: ReceiptWire(fault: fault), protocolVersion: UInt8(IMV2ProtocolVersion.current))
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.sendMessage(roomID: .init("room-1"), clientMessageID: .init("client-1"), text: "hello", media: [], mentions: [])
        }
    }
}

private actor ReceiptWire: V2AuthenticatedFrameTransport {
    let fault: String?
    private var sent: IMV2SendMessage?
    init(fault: String? = nil) { self.fault = fault }

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .sendMessage(let command)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        sent = command
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.messageAccepted = .init()
        response.messageAccepted.messageID = "accepted-message"
        response.messageAccepted.roomID = fault == "room" ? "different-room" : command.roomID
        response.messageAccepted.roomSequence = fault == "zero" ? 0 : fault == "overflow" ? UInt64.max : 7
        response.messageAccepted.serverCreatedAtMs = fault == "time" ? -1 : 1_000_000
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }

    func sentMessage() -> IMV2SendMessage? { sent }
}
