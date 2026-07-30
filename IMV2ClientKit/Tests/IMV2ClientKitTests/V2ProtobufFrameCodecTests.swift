import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2ProtobufFrameCodecTests {
    @Test("generated protobuf envelope round-trips with matching header")
    func roundTrip() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 7
        envelope.protocolVersion = IMV2ProtocolVersion.current
        envelope.syncPull = .init()
        let frame = try V2ProtobufFrameCodec.encode(envelope, frameVersion: UInt8(IMV2ProtocolVersion.current))
        #expect(try V2ProtobufFrameCodec.decode(frame) == envelope)
    }

    @Test("header command and request ID cannot disagree with the envelope")
    func rejectsMismatchedHeader() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 8
        envelope.protocolVersion = 1
        envelope.syncPull = .init()
        let frame = try V2ProtobufFrameCodec.encode(envelope, frameVersion: 1)
        let wrongCommand = V2Frame(version: 1, command: .sendMessage, requestID: 8, payload: frame.payload)
        let wrongRequest = V2Frame(version: 1, command: .syncPull, requestID: 9, payload: frame.payload)
        #expect(throws: V2ProtobufFrameCodecError.headerCommandMismatch) { _ = try V2ProtobufFrameCodec.decode(wrongCommand) }
        #expect(throws: V2ProtobufFrameCodecError.requestIDMismatch) { _ = try V2ProtobufFrameCodec.decode(wrongRequest) }
    }

    @Test("client codec rejects unnegotiated frame flags before protobuf decoding")
    func rejectsFrameFlags() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 10
        envelope.protocolVersion = 1
        envelope.syncPull = .init()
        let plain = try V2ProtobufFrameCodec.encode(envelope, frameVersion: 1)
        let compressed = V2Frame(
            version: plain.version,
            flags: [.compressed],
            command: plain.command,
            requestID: plain.requestID,
            payload: plain.payload
        )
        #expect(throws: V2ProtobufFrameCodecError.unsupportedFrameFlags) {
            _ = try V2ProtobufFrameCodec.decode(compressed)
        }
        #expect(throws: V2ProtobufFrameCodecError.unsupportedFrameFlags) {
            _ = try V2ProtobufFrameCodec.encode(envelope, frameVersion: 1, flags: [.compressed])
        }
    }

    @Test("client codec applies the explicit protobuf nesting limit")
    func rejectsExcessiveMessageNesting() throws {
        let frame = try nestedSyncBatchFrame()
        #expect(throws: V2ProtobufFrameCodecError.payloadDecodeFailed) {
            _ = try V2ProtobufFrameCodec.decode(frame, maximumMessageDepth: 1)
        }
        #expect(throws: V2ProtobufFrameCodecError.invalidMessageDepthLimit) {
            _ = try V2ProtobufFrameCodec.decode(frame, maximumMessageDepth: 0)
        }
        #expect(try V2ProtobufFrameCodec.decode(frame, maximumMessageDepth: 8).syncBatch.records.count == 1)
    }

    private func nestedSyncBatchFrame() throws -> V2Frame {
        var envelope = IMV2Envelope()
        envelope.requestID = 11
        envelope.protocolVersion = 1
        envelope.syncBatch = .init()
        envelope.syncBatch.records = [.init()]
        return try V2ProtobufFrameCodec.encode(envelope, frameVersion: 1)
    }

    @Test("zero request ID is valid only for a state-free availability hint")
    func encodesAsyncAvailabilityHint() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 0
        envelope.protocolVersion = 1
        envelope.syncAvailable = .init()
        envelope.syncAvailable.eventID = 7
        envelope.syncAvailable.highWatermark = 11
        let frame = try V2ProtobufFrameCodec.encode(envelope, frameVersion: 1)
        #expect(frame.command == .syncAvailable)
        #expect(try V2ProtobufFrameCodec.decode(frame) == envelope)
    }
}
