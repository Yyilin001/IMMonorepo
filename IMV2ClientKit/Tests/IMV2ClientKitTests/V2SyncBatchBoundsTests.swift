import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2SyncBatchBoundsTests {
    @Test(arguments: [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max],
          [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func wireBounds(generation: UInt64, sequence: UInt64) async throws {
        let transport = V2ProtobufSyncTransport(wire: BatchBoundsWire(generation: generation, sequence: sequence), protocolVersion: 1)
        if generation > 0 && generation <= UInt64(Int64.max) && sequence > 0 && sequence <= UInt64(Int64.max) {
            guard case .ready(let batch) = try await transport.pull(syncToken: nil, maxRecords: 1) else {
                Issue.record("Expected a sync batch")
                return
            }
            #expect(batch.generation == generation)
            #expect(batch.records.map(\.sequence) == [sequence])
        } else {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
                _ = try await transport.pull(syncToken: nil, maxRecords: 1)
            }
        }
    }
}

private actor BatchBoundsWire: V2AuthenticatedFrameTransport {
    let generation: UInt64
    let sequence: UInt64
    init(generation: UInt64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }
    func request(_ frame: V2Frame) throws -> V2Frame {
        var response = IMV2Envelope()
        response.protocolVersion = 1
        response.requestID = frame.requestID
        response.syncBatch.generation = generation
        response.syncBatch.nextSyncToken = "next"
        response.syncBatch.syncReceipt = "receipt"
        response.syncBatch.capabilityProfile = "base"
        var record = IMV2SyncRecord()
        record.userSyncSequence = sequence
        record.sourceEventID = UUID().uuidString
        record.projectionKind = "message"
        record.payload = Data("{}".utf8)
        response.syncBatch.records = [record]
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}
