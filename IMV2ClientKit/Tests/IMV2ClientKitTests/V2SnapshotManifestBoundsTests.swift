import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2SnapshotManifestBoundsTests {
    @Test(arguments: [0, 1, V2SnapshotProjectionV3Codec.maximumPageCount], [false, true])
    func pageByteCapacity(pageCount: Int, overLimit: Bool) throws {
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 1, baseSequence: 0, expiresAt: .distantFuture)
        let bytes = UInt64(pageCount) * UInt64(V2SnapshotProjectionV3Codec.maximumPageBytes) + (overLimit ? 1 : 0)
        func construct() throws -> V2ClientSnapshotManifest {
            try .init(reset: reset, rootDigest: "root", pageCount: pageCount, totalItems: UInt64(pageCount), totalBytes: bytes,
                nextSyncToken: .init("next"), receipt: .init("receipt"), capabilityProfile: "base")
        }
        if overLimit {
            #expect(throws: V2ClientSyncError.snapshotMismatch) { try construct() }
        } else {
            #expect(try construct().totalBytes == bytes)
        }
    }

    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func persistenceBounds(generation: UInt64, base: UInt64) async throws {
        let snapshotID = SnapshotID(uuid: UUID())
        let valid = generation > 0 && generation <= UInt64(Int64.max) && base <= UInt64(Int64.max)
        let wire = SnapshotBoundsWire(snapshotID: snapshotID, generation: generation, base: base)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        if valid {
            let reset = try V2ClientResetRequired(snapshotID: snapshotID, generation: generation, baseSequence: base,
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
            let manifest = try V2ClientSnapshotManifest(reset: reset, rootDigest: String(repeating: "0", count: 64), pageCount: 0,
                totalItems: 0, totalBytes: 0, nextSyncToken: .init("next"), receipt: .init("receipt"), capabilityProfile: "base")
            #expect(manifest.reset == reset)
            guard case .resetRequired(let received) = try await transport.pull(syncToken: nil, maxRecords: 1) else {
                Issue.record("Expected an exact reset boundary")
                return
            }
            #expect(received == reset)
        } else {
            let expected: V2ClientSyncError = generation > UInt64(Int64.max) || base > UInt64(Int64.max) ? .storageRangeExceeded : .generationMismatch
            #expect(throws: expected) {
                try V2ClientResetRequired(snapshotID: snapshotID, generation: generation, baseSequence: base, expiresAt: .distantFuture)
            }
            // Invalid wire fields remain representable by the test transport;
            // invalid domain reset objects can no longer be constructed.
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
                try await transport.pull(syncToken: nil, maxRecords: 1)
            }
        }
    }
}

private actor SnapshotBoundsWire: V2AuthenticatedFrameTransport {
    let snapshotID: SnapshotID
    let generation: UInt64
    let base: UInt64
    private(set) var requestCount = 0
    init(snapshotID: SnapshotID, generation: UInt64, base: UInt64) { self.snapshotID = snapshotID; self.generation = generation; self.base = base }
    func request(_ frame: V2Frame) throws -> V2Frame {
        requestCount += 1
        var response = IMV2Envelope()
        response.protocolVersion = 1
        response.requestID = frame.requestID
        response.resetRequired.snapshotID = snapshotID.rawValue
        response.resetRequired.generation = generation
        response.resetRequired.baseUserSyncSequence = base
        response.resetRequired.expiresAtMs = 2_000_000_000_000
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}
