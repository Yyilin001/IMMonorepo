import Foundation
import IMActorSystem
import NIOCore
import NIOEmbedded
import Testing

@Suite("Native actor framing")
struct IMWireTests {
    @Test func fragmentedFrameAndEarlyLengthRejection() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(IMFrameDecoder(maximumBytes: 1024), maximumBufferSize: 1028))
        defer { _ = try? channel.finish() }
        let frame = IMFrame(kind: .request, callID: 7, actorID: 9, methodID: 2, budgetMilliseconds: 50,
                            body: ByteBuffer(bytes: [1, 2, 3]))
        var bytes = try frame.encode(maximumBytes: 1024)
        try channel.writeInbound(bytes.readSlice(length: 3)!)
        #expect(try channel.readInbound(as: IMFrame.self) == nil)
        try channel.writeInbound(bytes)
        let decoded = try #require(try channel.readInbound(as: IMFrame.self))
        #expect(decoded.callID == 7 && decoded.actorID == 9 && decoded.methodID == 2)
        #expect(Array(decoded.body.readableBytesView) == [1, 2, 3])
        var header = ByteBuffer(); header.writeInteger(UInt32.max)
        #expect(throws: IMActorError.malformed) { try channel.writeInbound(header) }
    }
    @Test func identitySeparatesRoutingAndIncarnation() throws {
        let boot = UUID()
        let first = IMNode(id: "host", incarnationID: boot, endpoint: .init(host: "localhost", port: 9000))
        let moved = IMNode(id: "host", incarnationID: boot, endpoint: .init(host: "localhost", port: 9001))
        let restarted = IMNode(id: "host", endpoint: first.endpoint)
        #expect(first == moved && first != restarted)
        let id = IMActorID(node: first, localID: 42)
        var bytes = ByteBuffer(); try id.encodeWire(into: &bytes)
        #expect(try IMActorID.decodeWire(from: &bytes) == id)
        try bytes.imRequireEnd()
    }
}
