import Foundation
import Testing
@testable import IMV2Core

struct V2FrameCodecTests {
    @Test(arguments: [-1, Int(UInt32.max) + 1, Int.max])
    func rejectsPayloadLimitsOutsideWireRange(limit: Int) {
        #expect(throws: V2FrameCodecError.invalidLimits) {
            _ = try V2FrameLimits(maximumPayloadBytes: limit, acceptedVersions: [1])
        }
    }

    @Test(arguments: [0, 32, Int(UInt32.max)])
    func maximumDeclaredLengthIsCheckedWithoutAllocatingPayload(limit: Int) throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: limit, acceptedVersions: [1])
        let empty = V2Frame(version: 1, command: .clientHello, requestID: UInt64.max, payload: Data())
        let encoded = try V2FrameCodec.encode(empty, limits: limits)
        #expect(try V2FrameCodec.decodeExactlyOne(encoded, limits: limits) == empty)
        var header = encoded
        header.replaceSubrange(14..<18, with: [0xff, 0xff, 0xff, 0xff])
        var decoder = V2FrameDecoder(limits: limits)
        if limit == Int(UInt32.max) {
            #expect(try decoder.append(header).isEmpty)
            #expect(decoder.hasBufferedBytes)
            #expect(throws: V2FrameCodecError.trailingPartialFrame) { try decoder.finish() }
        } else {
            #expect(throws: V2FrameCodecError.declaredPayloadTooLarge(Int(UInt32.max))) { _ = try decoder.append(header) }
        }
    }

    @Test("a frame round-trips across arbitrary TLS byte boundaries")
    func fragmentedRoundTrip() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 32, acceptedVersions: [1])
        let original = V2Frame(version: 1, flags: [.compressed], command: .sendMessage, requestID: 42, payload: Data("hello".utf8))
        let wire = try V2FrameCodec.encode(original, limits: limits)
        var decoder = V2FrameDecoder(limits: limits)

        #expect(try decoder.append(Data(wire.prefix(5))).isEmpty)
        #expect(try decoder.append(Data(wire.dropFirst(5).prefix(8))).isEmpty)
        #expect(try decoder.append(Data(wire.dropFirst(13))) == [original])
        #expect(throws: Never.self) { try decoder.finish() }
    }

    @Test("a decoded frame does not leave a nonzero-index buffer for the next frame")
    func coalescedFramesRemainDecodable() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 32, acceptedVersions: [1])
        let first = V2Frame(version: 1, command: .heartbeat, requestID: 1, payload: Data())
        let second = V2Frame(version: 1, command: .syncPull, requestID: 2, payload: Data("next".utf8))
        var wire = try V2FrameCodec.encode(first, limits: limits)
        wire.append(try V2FrameCodec.encode(second, limits: limits))

        var decoder = V2FrameDecoder(limits: limits)
        #expect(try decoder.append(wire) == [first, second])
        #expect(throws: Never.self) { try decoder.finish() }
    }

    @Test("a dense coalesced read drains in bounded frame batches")
    func drainsExcessiveCoalescedFramesInBatches() throws {
        let limits = try V2FrameLimits(
            maximumPayloadBytes: 0,
            maximumFramesPerAppend: 4,
            acceptedVersions: [1]
        )
        var wire = Data()
        for requestID in 1...5 {
            wire.append(try V2FrameCodec.encode(
                .init(version: 1, command: .heartbeat, requestID: UInt64(requestID), payload: Data()),
                limits: limits
            ))
        }
        var decoder = V2FrameDecoder(limits: limits)
        #expect(try decoder.append(wire).map(\.requestID) == [1, 2, 3, 4])
        #expect(decoder.hasBufferedBytes)
        #expect(try decoder.append(Data()).map(\.requestID) == [5])
        #expect(!decoder.hasBufferedBytes)
    }

    @Test("a declared oversize payload fails before payload bytes arrive")
    func rejectsOversizedHeader() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 3, acceptedVersions: [1])
        let frame = V2Frame(version: 1, command: .syncPull, requestID: 1, payload: Data(repeating: 0, count: 4))
        var wire = try V2FrameCodec.encode(frame, limits: try V2FrameLimits(maximumPayloadBytes: 4, acceptedVersions: [1]))
        wire.removeLast(4)
        var decoder = V2FrameDecoder(limits: limits)
        #expect(throws: V2FrameCodecError.declaredPayloadTooLarge(4)) { _ = try decoder.append(wire) }
    }

    @Test("wrong magic, unsupported version and close-mid-frame are rejected")
    func rejectsInvalidFraming() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 8, acceptedVersions: [1])
        var wrongMagic = try V2FrameCodec.encode(.init(version: 1, command: .clientHello, requestID: 0, payload: Data()), limits: limits)
        wrongMagic[0] = 0
        var decoder = V2FrameDecoder(limits: limits)
        #expect(throws: V2FrameCodecError.invalidMagic) { _ = try decoder.append(wrongMagic) }

        var partial = V2FrameDecoder(limits: limits)
        #expect(try partial.append(Data([0x49, 0x4D])).isEmpty)
        #expect(throws: V2FrameCodecError.trailingPartialFrame) { try partial.finish() }
    }
}
