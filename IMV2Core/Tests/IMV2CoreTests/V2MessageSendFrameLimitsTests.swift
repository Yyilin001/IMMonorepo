import Foundation
import Testing
@testable import IMV2Core

struct V2MessageSendFrameLimitsTests {
    @Test func v45SendCanUseBoundedLargeFrameWhileOrdinaryFrameStaysSmall() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 64, maximumMessageSendPayloadBytes: 1_024, acceptedVersions: [45])
        let send = V2Frame(version: 45, command: .messageSendOperation, requestID: 1, payload: Data(repeating: 7, count: 512))
        let encoded = try V2FrameCodec.encode(send, limits: limits)
        #expect(try V2FrameCodec.decodeExactlyOne(encoded, limits: limits) == send)
        let ordinary = V2Frame(version: 45, command: .syncPull, requestID: 2, payload: Data(repeating: 7, count: 512))
        #expect(throws: V2FrameCodecError.payloadTooLarge(512)) { _ = try V2FrameCodec.encode(ordinary, limits: limits) }
        var decoder = V2FrameDecoder(limits: limits)
        var ordinaryHeader = encoded
        ordinaryHeader[4] = 0
        ordinaryHeader[5] = 30
        #expect(throws: V2FrameCodecError.declaredPayloadTooLarge(512)) { _ = try decoder.append(Data(ordinaryHeader.prefix(V2Frame.headerLength))) }
    }

    @Test func unsupportedOldVersionIsRejected() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 64, acceptedVersions: [45])
        let frame = V2Frame(version: 44, command: .messageSendOperationRecover, requestID: 1, payload: Data())
        #expect(throws: V2FrameCodecError.unsupportedVersion(44)) { _ = try V2FrameCodec.encode(frame, limits: limits) }
        let valid = try V2FrameCodec.encode(.init(version: 45, command: .messageSendOperationRecover, requestID: 1, payload: Data()), limits: limits)
        var oldHeader = valid
        oldHeader[2] = 44
        var decoder = V2FrameDecoder(limits: limits)
        #expect(throws: V2FrameCodecError.unsupportedVersion(44)) { _ = try decoder.append(Data(oldHeader.prefix(V2Frame.headerLength))) }
    }

    @Test func existingLargeOrdinaryLimitInitializerRemainsValid() throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 2_000_000, acceptedVersions: [44])
        #expect(limits.maximumPayloadBytes == 2_000_000)
    }
}
