import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

struct V2ProtobufFrameCodecTests {
    @Test("server protobuf codec rejects a mismatched command header")
    func rejectsMismatch() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 11
        envelope.protocolVersion = 1
        envelope.syncAck = .init()
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1)
        let mismatch = V2Frame(version: 1, command: .syncPull, requestID: 11, payload: frame.payload)
        #expect(throws: V2ServerProtobufFrameCodecError.headerCommandMismatch) { _ = try V2ServerProtobufFrameCodec.decode(mismatch) }
    }

    @Test("server codec rejects unnegotiated frame flags before protobuf decoding")
    func rejectsFrameFlags() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 12
        envelope.protocolVersion = 1
        envelope.syncPull = .init()
        let plain = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1)
        let compressed = V2Frame(
            version: plain.version,
            flags: [.compressed],
            command: plain.command,
            requestID: plain.requestID,
            payload: plain.payload
        )
        #expect(throws: V2ServerProtobufFrameCodecError.unsupportedFrameFlags) {
            _ = try V2ServerProtobufFrameCodec.decode(compressed)
        }
        #expect(throws: V2ServerProtobufFrameCodecError.unsupportedFrameFlags) {
            _ = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1, flags: [.compressed])
        }
    }

    @Test("server codec applies the explicit protobuf nesting limit")
    func rejectsExcessiveMessageNesting() throws {
        let frame = try nestedSyncBatchFrame()
        #expect(throws: V2ServerProtobufFrameCodecError.payloadDecodeFailed) {
            _ = try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: 1)
        }
        #expect(throws: V2ServerProtobufFrameCodecError.invalidMessageDepthLimit) {
            _ = try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: 0)
        }
        #expect(try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: 8).syncBatch.records.count == 1)
    }

    private func nestedSyncBatchFrame() throws -> V2Frame {
        var envelope = IMV2Envelope()
        envelope.requestID = 13
        envelope.protocolVersion = 1
        envelope.syncBatch = .init()
        envelope.syncBatch.records = [.init()]
        return try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1)
    }
}
