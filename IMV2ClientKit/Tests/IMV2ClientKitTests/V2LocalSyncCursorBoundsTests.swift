import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2LocalSyncCursorBoundsTests {
    @Test(arguments: [UInt64(1), 2, UInt64(Int64.max)], [UInt64(1), 2, UInt64(Int64.max)])
    func resetGenerationMustMatchCursor(generation: UInt64, resetGeneration: UInt64) throws {
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: resetGeneration, baseSequence: 10, expiresAt: .distantFuture)
        func makeCursor() throws -> V2LocalSyncCursor {
            try .init(state: .resetPending, generation: generation, appliedSequence: 5,
                      serverAcknowledgedSequence: 5, syncToken: nil,
                      pendingAcknowledgementReceipt: nil, pendingAcknowledgementSequence: nil, pendingReset: reset)
        }
        if generation == resetGeneration {
            let cursor = try makeCursor()
            #expect(cursor.generation == generation && cursor.pendingReset == reset)
        } else {
            #expect(throws: V2ClientSyncError.resetFenceMismatch) { try makeCursor() }
        }
    }

    @Test(arguments: ["generation", "applied", "acknowledged", "pendingAck", "resetGeneration", "resetBase"],
          [UInt64(1), UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func integerBounds(field: String, value: UInt64) throws {
        let resetting = field.hasPrefix("reset")
        let generation: UInt64 = ["generation", "resetGeneration"].contains(field) ? value : 1
        let applied: UInt64 = ["applied", "acknowledged", "pendingAck"].contains(field) ? value : 0
        let snapshotID = SnapshotID(uuid: UUID())
        func reset() throws -> V2ClientResetRequired? {
            resetting ? try V2ClientResetRequired(snapshotID: snapshotID, generation: generation,
            baseSequence: field == "resetBase" ? value : 0, expiresAt: .distantFuture) : nil
        }
        func cursor() throws -> V2LocalSyncCursor {
            try .init(state: resetting ? .resetPending : .ready, generation: generation,
                appliedSequence: applied, serverAcknowledgedSequence: field == "acknowledged" ? value : 0,
                syncToken: nil, pendingAcknowledgementReceipt: field == "pendingAck" ? .init("receipt") : nil,
                pendingAcknowledgementSequence: field == "pendingAck" ? value : nil, pendingReset: reset())
        }
        if value > UInt64(Int64.max) {
            #expect(throws: V2ClientSyncError.storageRangeExceeded) { _ = try cursor() }
        } else {
            let result = try cursor()
            #expect(result.generation == generation)
            #expect(result.appliedSequence == applied)
            #expect(result.pendingReset == (try reset()))
            #expect(result.serverAcknowledgedSequence == (field == "acknowledged" ? value : 0))
            #expect(result.pendingAcknowledgementSequence == (field == "pendingAck" ? value : nil))
        }
    }
}
