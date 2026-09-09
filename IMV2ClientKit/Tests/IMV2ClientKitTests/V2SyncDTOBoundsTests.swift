import Foundation
import IMV2Core
import IMV2ClientKit
import Testing

struct V2SyncDTOBoundsTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 0, 2_000, Double.greatestFiniteMagnitude])
    func resetExpiryDateBounds(seconds: Double) throws {
        func makeReset() throws -> V2ClientResetRequired {
            try .init(snapshotID: .init(uuid: UUID()), generation: 1, baseSequence: 0, expiresAt: Date(timeIntervalSince1970: seconds))
        }
        if seconds.isFinite {
            #expect(try makeReset().expiresAt == Date(timeIntervalSince1970: seconds))
        } else {
            #expect(throws: V2ClientSyncError.snapshotMismatch) { try makeReset() }
        }
    }

    @Test(arguments: ["record", "batch", "resetGeneration", "resetBase"], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func construction(field: String, value: UInt64) throws {
        func construct() throws -> UInt64 {
            switch field {
            case "record": return try V2ClientSyncRecord(sequence: value, sourceEventID: .init(uuid: UUID()), projectionKind: "message", payload: Data("{}".utf8)).sequence
            case "batch": return try V2ClientSyncBatch(generation: value, records: [], nextSyncToken: .init("token"), receipt: .init("receipt"), hasMore: false, capabilityProfile: "base").generation
            default:
                let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: field == "resetGeneration" ? value : 1, baseSequence: field == "resetBase" ? value : 0, expiresAt: .distantFuture)
                return field == "resetGeneration" ? reset.generation : reset.baseSequence
            }
        }
        if value > UInt64(Int64.max) {
            #expect(throws: V2ClientSyncError.storageRangeExceeded) { try construct() }
        } else if value == 0 && field != "resetBase" {
            #expect(throws: field == "record" ? V2ClientSyncError.invalidRecordOrdering : .generationMismatch) { try construct() }
        } else { #expect(try construct() == value) }
    }
}
