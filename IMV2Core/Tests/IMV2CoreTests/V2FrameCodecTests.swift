import Foundation
import Testing
@testable import IMV2Core

struct V2FrameCodecTests {
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
