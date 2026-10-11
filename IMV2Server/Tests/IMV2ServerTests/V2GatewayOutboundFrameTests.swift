import Foundation
import IMV2Core
import NIOCore
import NIOFoundationCompat
import SwiftProtobuf
import Testing
@testable import IMV2ServerGateway

@Suite("owned protobuf outbound frames")
struct V2GatewayOutboundFrameTests {
    @Test("direct NIO encoding preserves the complete wire format", arguments: [false, true])
    func wireCompatibility(compressed: Bool) throws {
        var envelope = IMV2Envelope()
        envelope.protocolVersion = UInt32(IMV2ProtocolVersion.current)
        envelope.requestID = 0x0102030405060708
        envelope.error.code = String(repeating: "error-contract-", count: 500)
        let version = UInt8(IMV2ProtocolVersion.current)
        let frame = try V2ServerProtobufFrameCodec.encodeBuffered(envelope,
            frameVersion: version, compression: compressed ? .zlib : nil,
            compressionThresholdBytes: 0, maximumExpansionRatio: 1024)
        let limits = try V2FrameLimits(maximumPayloadBytes: 65_536, acceptedVersions: [version])
        try frame.validate(limits: limits)
        #expect(frame.header.flags.contains(.compressed) == compressed)
        #expect(frame.buffer.getData(at: 0, length: frame.buffer.readableBytes) ==
            (try V2FrameCodec.encode(frame.dataFrame, limits: limits)))
        if !compressed {
            #expect(frame.dataFrame.payload == (try envelope.serializedData()))
        }
        #expect(try V2ServerProtobufFrameCodec.decode(frame.dataFrame,
            compression: compressed ? .zlib : nil, maximumExpansionRatio: 1024) == envelope)
        envelope.error.code = "changed after encoding"
        #expect(try V2ServerProtobufFrameCodec.decode(frame.dataFrame,
            compression: compressed ? .zlib : nil, maximumExpansionRatio: 1024) != envelope)
        let tooSmall = try V2FrameLimits(maximumPayloadBytes: frame.payloadCount - 1, acceptedVersions: [version])
        #expect(throws: V2FrameCodecError.payloadTooLarge(frame.payloadCount)) { try frame.validate(limits: tooSmall) }
    }

    @Test("serialization adapter honors initialization and mutable payload bounds")
    func adapterContract() throws {
        var bytes = V2ProtobufOutputBytes(repeating: 0xAB, count: 33)
        #expect(bytes.withUnsafeBytes { Array($0) } == Array(repeating: 0xAB, count: 33))
        bytes.withUnsafeMutableBytes { payload in payload[0] = 0x12; payload[32] = 0x34 }
        #expect(bytes.buffer.getInteger(at: 0, as: UInt16.self) == 0)
        #expect(bytes.count == 33)
        let payloadAddress = bytes.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
        let header = V2Frame(version: UInt8(IMV2ProtocolVersion.current), command: .heartbeat,
            requestID: 42, payload: Data())
        let frame = V2GatewayOutboundFrame(header: header, payload: consume bytes)
        let wirePayloadAddress = frame.buffer.withUnsafeReadableBytes {
            UInt(bitPattern: $0.baseAddress!.advanced(by: V2Frame.headerLength))
        }
        #expect(wirePayloadAddress == payloadAddress)
        #expect(frame.buffer.getInteger(at: 6, as: UInt64.self) == 42)
        #expect(frame.dataFrame.payload.first == 0x12 && frame.dataFrame.payload.last == 0x34)
    }
}
