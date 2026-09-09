import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2GatewayErrorRevisionBoundsTests {
    @Test(arguments: ["REVISION_CONFLICT", "TEMPORARY_UNAVAILABLE"],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func revisionBounds(code: String, revision: UInt64) async throws {
        let wire = ErrorRevisionWire(code: code, revision: revision)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let expected: V2RealtimeTransportError
        if code == "REVISION_CONFLICT" && revision > UInt64(Int64.max) {
            expected = .unexpectedResponse
        } else {
            expected = .server(code: code, retryable: true, retryAfterSeconds: 3,
                currentRevision: code == "REVISION_CONFLICT" ? revision : nil)
        }
        await #expect(throws: expected) {
            try await transport.acknowledge(generation: 1, highestContiguousSequence: 0, receipt: .init("receipt"))
        }
        await #expect(throws: V2RealtimeTransportError.server(code: "REVISION_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: 12)) {
            try await transport.acknowledge(generation: 1, highestContiguousSequence: 0, receipt: .init("receipt"))
        }
        #expect(await wire.requestIDs == [1, 2])
    }
}

private actor ErrorRevisionWire: V2AuthenticatedFrameTransport {
    let code: String
    let revision: UInt64
    private(set) var requestIDs: [UInt64] = []
    init(code: String, revision: UInt64) { self.code = code; self.revision = revision }
    func request(_ frame: V2Frame) throws -> V2Frame {
        requestIDs.append(frame.requestID)
        let first = requestIDs.count == 1
        var response = IMV2Envelope()
        response.protocolVersion = 1
        response.requestID = frame.requestID
        response.error.code = first ? code : "REVISION_CONFLICT"
        response.error.currentRevision = first ? revision : 12
        response.error.retryable = first
        response.error.retryAfterSeconds = first ? 3 : 0
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}
