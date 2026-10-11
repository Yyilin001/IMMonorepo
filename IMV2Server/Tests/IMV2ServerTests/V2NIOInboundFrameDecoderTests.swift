import Foundation
import IMV2Core
import NIOCore
import Testing
@testable import IMV2ServerGateway

struct V2NIOInboundFrameDecoderTests {
    @Test("All TCP split positions preserve frames and bounded drain order")
    func fragmentationAndCoalescing() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 256,
            maximumFramesPerAppend: 3, acceptedVersions: [45])
        let expected = (0..<10).map { index in
            V2Frame(version: 45, command: .heartbeat, requestID: UInt64(index + 1),
                payload: Data(repeating: UInt8(index), count: index * 7))
        }
        let wire = try expected.reduce(into: Data()) { $0.append(try V2FrameCodec.encode($1, limits: limits)) }
        for split in 0...wire.count {
            var decoder = V2NIOInboundFrameDecoder(limits: limits)
            var frames = try decoder.append(ByteBuffer(bytes: wire.prefix(split)))
            frames += try decoder.append(ByteBuffer(bytes: wire.dropFirst(split)))
            while decoder.hasBufferedBytes { frames += try decoder.append(ByteBuffer()) }
            #expect(try frames.map(materialize) == expected)
            try decoder.finish()
        }
    }

    @Test("Declared length is rejected before payload allocation; partial EOF is rejected")
    func rejectsMalformedInput() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 256, acceptedVersions: [45])
        let frame = V2Frame(version: 45, command: .heartbeat, requestID: 1, payload: Data([1, 2]))
        var wire = ByteBuffer(bytes: try V2FrameCodec.encode(frame, limits: limits))
        wire.setInteger(UInt32.max, at: 14)
        var decoder = V2NIOInboundFrameDecoder(limits: limits)
        #expect(throws: V2FrameCodecError.declaredPayloadTooLarge(Int(UInt32.max))) {
            try decoder.append(wire)
        }
        decoder = .init(limits: limits)
        _ = try decoder.append(ByteBuffer(bytes: [0]))
        #expect(throws: V2FrameCodecError.trailingPartialFrame) { try decoder.finish() }
    }

    @Test("Large send ceiling is enabled only after authentication")
    func negotiatedSendLimit() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 16,
            maximumMessageSendPayloadBytes: 128, acceptedVersions: [44, 45])
        let frame = V2Frame(version: 45, command: .messageSendOperation, requestID: 3,
            payload: Data(repeating: 1, count: 64))
        let bytes = ByteBuffer(bytes: try V2FrameCodec.encode(frame, limits: limits))
        var decoder = V2NIOInboundFrameDecoder(limits: limits)
        #expect(throws: V2FrameCodecError.declaredPayloadTooLarge(64)) { try decoder.append(bytes) }
        decoder = .init(limits: limits)
        decoder.setAllowsLargeMessageSendFrames(true)
        #expect(try decoder.append(bytes).map(materialize) == [frame])
        var oldVersion = bytes
        oldVersion.setInteger(UInt8(44), at: 2)
        #expect(throws: V2FrameCodecError.unsupportedVersion(44)) { try decoder.append(oldVersion) }
    }

    @Test("Owned slices remain intact after the decoder accepts more input")
    func retainedPayloadAndSpanDecode() throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 256, acceptedVersions: [version])
        var envelope = IMV2Envelope()
        envelope.protocolVersion = IMV2ProtocolVersion.current; envelope.requestID = 8
        envelope.heartbeat.clientTimeMs = 123
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version)
        let wire = try V2FrameCodec.encode(frame, limits: limits)
        var decoder = V2NIOInboundFrameDecoder(limits: limits)
        // Keep a partial following frame in the same allocation. Appending its
        // remainder must never mutate the already handed-off payload slice.
        var first = ByteBuffer(bytes: wire)
        first.writeBytes(wire.prefix(5))
        let retained = try #require(decoder.append(first).first)
        _ = try decoder.append(ByteBuffer(bytes: wire.dropFirst(5)))
        #expect(try V2ServerProtobufFrameCodec.decode(retained) == envelope)
        #expect(try materialize(retained) == frame)
        try decoder.finish()
    }

    @Test("Small complete frames borrow the receive allocation; oversized buffers are detached")
    func payloadStorageOwnership() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 256, acceptedVersions: [45])
        let frame = V2Frame(version: 45, command: .heartbeat, requestID: 1,
            payload: Data(repeating: 7, count: 32))
        let wire = try V2FrameCodec.encode(frame, limits: limits)
        let small = ByteBuffer(bytes: wire)
        let address = small.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress!) }
        var decoder = V2NIOInboundFrameDecoder(limits: limits)
        let decoded = try #require(decoder.append(small).first)
        let payloadAddress = decoded.withPayload { $0.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } }
        #expect(payloadAddress == address + UInt(V2Frame.headerLength))

        var oversized = ByteBufferAllocator().buffer(capacity: 1_048_576)
        oversized.writeBytes(wire)
        let sliceResult = oversized.readSlice(length: oversized.readableBytes)
        let oversizedSlice = try #require(sliceResult)
        let oversizedAddress = oversizedSlice.withUnsafeReadableBytes { UInt(bitPattern: $0.baseAddress!) }
        decoder = .init(limits: limits)
        let detached = try #require(decoder.append(oversizedSlice).first)
        let detachedAddress = detached.withPayload { $0.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) } }
        #expect(detachedAddress != oversizedAddress + UInt(V2Frame.headerLength))
        #expect(try materialize(detached) == frame)
    }

    private func materialize(_ frame: V2GatewayInboundFrame) throws -> V2Frame {
        let payload = frame.withPayload { $0.withUnsafeBytes { Data($0) } }
        return .init(version: frame.version, flags: frame.flags, command: frame.command,
            requestID: frame.requestID, payload: payload)
    }
}
