import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2SocialStoredRevisionTests {
    @Test(arguments: ["state_version", "preference_revision", "reader_preference_revision", "viewer_preference_revision", "read_through_room_sequence"], [1.5, Double(Int64.max)])
    func invalidStoredRevisionRollsBackSync(field: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-social-revision-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), reader = UserID(uuid: UUID())
        let table: String, kind: String
        switch field {
        case "state_version": table = "v2_direct_sending_capabilities"; kind = "direct_sending_capability"
        case "preference_revision": table = "v2_read_receipt_preference"; kind = "read_receipt_preferences"
        default: table = "v2_direct_read_receipt_projections"; kind = "direct_read_receipt"
        }
        func page(_ sequence: UInt64) throws -> V2ClientSyncBatch {
            let payload: [String: Any]
            switch field {
            case "state_version":
                payload = ["room_id": room.rawValue, "state_version": sequence, "can_send": sequence == 1, "updated_at_ms": 1750000000000]
            case "preference_revision":
                payload = ["preference_revision": sequence, "allows_direct_read_receipts": sequence == 1, "allows_group_read_receipts": true, "updated_at_ms": 1750000000000]
            default:
                payload = ["room_id": room.rawValue, "reader_user_id": reader.rawValue,
                    "reader_preference_revision": sequence, "viewer_preference_revision": sequence,
                    "is_visible": true, "read_through_room_sequence": sequence == 1 ? 1 : 7, "recorded_at_ms": 1750000000000]
            }
            let record = try V2ClientSyncRecord(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: kind, payload: JSONSerialization.data(withJSONObject: payload))
            return try .init(generation: 1, records: [record], nextSyncToken: .init("test-\(sequence)"), receipt: .init("test-\(sequence)"), hasMore: false, capabilityProfile: "base")
        }
        do {
            _ = try await store.apply(page(1))
            let cursor = try await store.cursor(), next = try page(2)
            let pool = await store.databasePool
            try await pool.write { db in try db.execute(sql: "UPDATE \(table) SET \(field) = ?", arguments: [value]) }
            if field == "state_version" {
                await #expect(throws: V2ClientSyncError.storageRangeExceeded) { _ = try await store.directSendingCapability(roomID: room) }
            }
            if field == "read_through_room_sequence" {
                await #expect(throws: V2ClientSyncError.storageRangeExceeded) { _ = try await store.directReadReceipt(roomID: room) }
            }
            await #expect(throws: V2ClientSyncError.storageRangeExceeded) { _ = try await store.apply(next) }
            #expect(try await store.cursor() == cursor)
            try await pool.read { db in
                let stored = try Double.fetchOne(db, sql: "SELECT \(field) FROM \(table)")
                let type = try String.fetchOne(db, sql: "SELECT typeof(\(field)) FROM \(table)")
                #expect(stored == value && type == "real")
            }
            try await pool.write { db in try db.execute(sql: "UPDATE \(table) SET \(field) = 1") }
            _ = try await store.apply(next)
            #expect(try await store.cursor()?.appliedSequence == 2)
            switch field {
            case "state_version": #expect(try await store.directSendingCapability(roomID: room)?.canSend == false)
            case "preference_revision": #expect(try await store.readReceiptPreference()?.allowsDirectReadReceipts == false)
            default: #expect(try await store.directReadReceipt(roomID: room)?.readThroughRoomSequence == 7)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
