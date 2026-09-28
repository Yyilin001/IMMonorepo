import Foundation
import Testing
@testable import IMV2Core

@Suite("Monotonic read watermark recovery")
struct ReadReceiptRecoveryTests {
    @Test("frozen commands bind identity and watermark without first deadline")
    func commandBoundary() throws {
        let c = try command(2)
        #expect(try JSONDecoder().decode(V2RecordReadReceiptCommand.self,from:JSONEncoder().encode(c)) == c)
        let altered = try V2RecordReadReceiptCommand(roomID:c.roomID,actorUserID:c.actorUserID,operationID:c.operationID,readThroughRoomSequence:3)
        #expect(try c.identity == altered.identity)
        #expect(try c.fingerprint != altered.fingerprint)
        #expect(V2CommandPolicy.registered(for:.readReceipt).firstSubmissionWindowMilliseconds == nil)
        let malformed = Data(String(decoding:try JSONEncoder().encode(c),as:UTF8.self).replacingOccurrences(of:"\"readThroughRoomSequence\":2",with:"\"readThroughRoomSequence\":0").utf8)
        #expect(throws:(any Error).self) { try JSONDecoder().decode(V2RecordReadReceiptCommand.self,from:malformed) }
    }
    @Test("current max proof is distinct from evidence of the original operation")
    func proofBoundary() throws {
        let c = try command(2)
        let receipt = try V2ReadReceipt(roomID:c.roomID,userID:c.actorUserID,readThroughRoomSequence:3,recordedAt:Date())
        let original = try V2ReadReceiptOperationReceipt(command:c,receipt:receipt)
        let proof = try V2ReadReceiptWatermarkProof(command:c,watermark:receipt)
        #expect(V2ReadReceiptRecoveryResult.originalReceipt(original) != .watermarkProof(proof))
        #expect(try JSONDecoder().decode(V2ReadReceiptWatermarkProof.self,from:JSONEncoder().encode(proof)) == proof)
        #expect(throws:V2ReadReceiptRecoveryValidationError.invalidProof) {
            try V2ReadReceiptWatermarkProof(command:c,watermark:.init(roomID:c.roomID,userID:c.actorUserID,readThroughRoomSequence:1,recordedAt:Date()))
        }
        #expect(throws:V2ReadReceiptRecoveryValidationError.invalidProof) {
            try V2ReadReceiptOperationReceipt(command:c,receipt:.init(roomID:c.roomID,userID:.init(uuid:UUID()),readThroughRoomSequence:3,recordedAt:Date()))
        }
    }
    private func command(_ sequence:UInt64) throws -> V2RecordReadReceiptCommand {
        try .init(roomID:.init(uuid:UUID()),actorUserID:.init(uuid:UUID()),operationID:.init(uuid:UUID()),readThroughRoomSequence:sequence)
    }
}
