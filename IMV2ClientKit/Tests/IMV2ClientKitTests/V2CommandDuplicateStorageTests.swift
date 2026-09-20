import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2CommandDuplicateStorageTests {
    @Test(arguments: ["membership", "withdrawal", "edit", "receipt"], [1.5, Double(Int64.max)])
    func duplicateRequiresExactInteger(lane: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-command-duplicate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), user = UserID(uuid: UUID()), operation = UUID()
        let now = Date(timeIntervalSince1970: 10)
        let table: String, column: String
        switch lane {
        case "membership": table = "v2_pending_membership_commands"; column = "expected_membership_revision"
        case "withdrawal": table = "v2_pending_message_withdrawals"; column = "expected_message_revision"
        case "edit": table = "v2_pending_message_edits"; column = "expected_message_revision"
        default: table = "v2_pending_read_receipts"; column = "read_through_room_sequence"
        }
        @Sendable func enqueue() async throws {
            switch lane {
            case "membership":
                try await store.enqueue(V2PendingMembershipCommand(roomID: room, operationID: .init(uuid: operation), targetUserID: user, action: .add, expectedMembershipRevision: 1, state: .pending, attemptCount: 0, nextAttemptAt: now, resultingMembershipRevision: nil, resultingRoomSequence: nil, terminalCode: nil, terminalCurrentRevision: nil))
            case "withdrawal":
                try await store.enqueue(V2PendingMessageWithdrawal(roomID: room, operationID: .init(uuid: operation), messageID: message, expectedMessageRevision: 1, state: .pending, attemptCount: 0, nextAttemptAt: now, resultingMessageRevision: nil, resultingRoomSequence: nil, terminalCode: nil, terminalCurrentRevision: nil))
            case "edit":
                try await store.enqueue(V2PendingMessageEdit(roomID: room, operationID: .init(uuid: operation), messageID: message, expectedMessageRevision: 1, text: "edit", state: .pending, attemptCount: 0, nextAttemptAt: now, resultingMessageRevision: nil, resultingRoomSequence: nil, terminalCode: nil, terminalCurrentRevision: nil))
            default:
                try await store.enqueue(V2PendingReadReceipt(roomID: room, operationID: .init(uuid: operation), readThroughRoomSequence: 1, state: .pending, attemptCount: 0, nextAttemptAt: now, resultingRoomSequence: nil, terminalCode: nil))
            }
        }
        do {
            try await enqueue()
            let pool = await store.databasePool
            try await pool.write { db in try db.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value]) }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await enqueue() }
            try await pool.read { db in
                let stored = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table)")
                let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table)")
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")
                #expect(stored == value && type == "real" && count == 1)
            }
            try await pool.write { db in try db.execute(sql: "UPDATE \(table) SET \(column) = 1") }
            try await enqueue()
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") } == 1)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test(arguments: [false, true], [1.5, Double(Int64.max)])
    func receiptHighWaterCannotHideCorruptSequence(acknowledged: Bool, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-receipt-water-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID())
        func command(_ sequence: UInt64) -> V2PendingReadReceipt {
            .init(roomID: room, operationID: .init(uuid: UUID()), readThroughRoomSequence: sequence, state: .pending, attemptCount: 0, nextAttemptAt: .init(timeIntervalSince1970: 10), resultingRoomSequence: nil, terminalCode: nil)
        }
        let first = command(1), larger = command(8), next = command(9)
        let column = acknowledged ? "resulting_room_sequence" : "read_through_room_sequence"
        do {
            try await store.enqueue(first); try await store.enqueue(larger)
            if acknowledged { try await store.markReadReceiptAcknowledged(operationID: first.operationID, roomSequence: 1) }
            let pool = await store.databasePool
            try await pool.write { db in try db.execute(sql: "UPDATE v2_pending_read_receipts SET \(column) = ? WHERE operation_id = ?", arguments: [value, first.operationID.rawValue]) }
            await #expect(throws: V2ClientCommandError.commandConflict) { _ = try await store.enqueueIfReadReceiptAdvances(next) }
            try await pool.read { db in
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM v2_pending_read_receipts")
                let stored = try Double.fetchOne(db, sql: "SELECT \(column) FROM v2_pending_read_receipts WHERE operation_id = ?", arguments: [first.operationID.rawValue])
                #expect(count == 2 && stored == value)
            }
            try await pool.write { db in try db.execute(sql: "UPDATE v2_pending_read_receipts SET \(column) = 1 WHERE operation_id = ?", arguments: [first.operationID.rawValue]) }
            #expect(try await store.enqueueIfReadReceiptAdvances(next))
            #expect(try await store.enqueueIfReadReceiptAdvances(next) == false)
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM v2_pending_read_receipts") } == 3)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    @Test(arguments: ["watermark", "pending", "acknowledged", "update"], [1.5, Double(Int64.max)])
    func effectiveReadWatermarkStorage(path: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "effective-watermark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), absent = RoomID(uuid: UUID())
        func batch(_ sequence: UInt64, through: Int) throws -> V2ClientSyncBatch {
            try .init(generation: 1, records: [.init(sequence: sequence, sourceEventID: .init(uuid: UUID()),
                projectionKind: "own_read_watermark", payload: JSONSerialization.data(withJSONObject: [
                    "room_id": room.rawValue, "read_through_room_sequence": through, "recorded_at_ms": 1000]))],
                nextSyncToken: .init("watermark"), receipt: .init("watermark"), hasMore: false, capabilityProfile: "base")
        }
        func command(_ through: UInt64) -> V2PendingReadReceipt {
            .init(roomID: room, operationID: .init(uuid: UUID()), readThroughRoomSequence: through, state: .pending,
                attemptCount: 0, nextAttemptAt: .init(timeIntervalSince1970: 10), resultingRoomSequence: nil, terminalCode: nil)
        }
        _ = try await store.apply(batch(1, through: 1))
        let small = command(1)
        try await store.enqueue(small)
        try await store.enqueue(command(8)) // A larger valid value must not hide a smaller REAL.
        if path == "acknowledged" { try await store.markReadReceiptAcknowledged(operationID: small.operationID, roomSequence: 1) }
        let storedWatermark = path == "watermark" || path == "update"
        let table = storedWatermark ? "v2_room_read_watermarks" : "v2_pending_read_receipts"
        let column = path == "acknowledged" ? "resulting_room_sequence" : "read_through_room_sequence"
        let key = storedWatermark ? "room_id" : "operation_id"
        let identifier = storedWatermark ? room.rawValue : small.operationID.rawValue
        let before = try await store.cursor()
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(key) = ?", arguments: [value, identifier]) }
        let incoming = try batch(2, through: 9)
        if path == "update" {
            await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.apply(incoming) }
        } else {
            await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.roomReadWatermark(roomID: room) }
            await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await store.roomReadWatermarks(roomIDs: [absent, room]) }
        }
        #expect(try await store.roomReadWatermarks(roomIDs: []).isEmpty)
        #expect(try await store.roomReadWatermark(roomID: absent) == nil)
        #expect(try await store.cursor() == before)
        let stored = try await store.databasePool.read { db in
            let raw = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table) WHERE \(key) = ?", arguments: [identifier])
            let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table) WHERE \(key) = ?", arguments: [identifier])
            return (raw, type)
        }
        #expect(stored.0 == value)
        #expect(stored.1 == "real")
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = 1 WHERE \(key) = ?", arguments: [identifier]) }
        #expect(try await store.roomReadWatermark(roomID: room) == 8)
        _ = try await store.apply(incoming)
        #expect(try await store.roomReadWatermark(roomID: room) == 9)
        #expect(try await store.cursor()?.appliedSequence == 2)
        try await store.close()
    }

}
