import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2CommandDuplicateStorageTests {
    @Test(arguments: [1.5, Double(Int64.max)])
    func duplicateRequiresExactInteger(value:Double) async throws {
        let f=try MembershipWorkFixture();defer { f.remove() }
        let now=Date(),intent=try V2MembershipIntent(roomID:f.room,actorUserID:f.account,operationID:.init(uuid:UUID()),targetUserID:f.target,action:.add,expectedMembershipRevision:1,confirmedUntilMilliseconds:UInt64((now.timeIntervalSince1970+120)*1000))
        let id=try await f.store.enqueueMembership(intent,activationID:UUID(),now:now)
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let original=try encoder.encode(intent)
        let malformed=Data(String(decoding:original,as:UTF8.self).replacingOccurrences(of:"\"expectedMembershipRevision\":1",with:"\"expectedMembershipRevision\":"+String(value)).utf8)
        try await f.store.databasePool.write { try $0.execute(sql:"UPDATE v2_membership_intents SET intent=? WHERE intent_id=?",arguments:[malformed,id.uuidString]) }
        await #expect(throws:(any Error).self) { _ = try await f.store.enqueueMembership(intent,activationID:UUID(),now:now) }
        let stored=try await f.store.databasePool.read { db in
            (try Data.fetchOne(db,sql:"SELECT intent FROM v2_membership_intents"),try Int.fetchOne(db,sql:"SELECT count(*) FROM v2_membership_intents"))
        }
        #expect(stored.0==malformed && stored.1==1)
        try await f.store.databasePool.write { try $0.execute(sql:"UPDATE v2_membership_intents SET intent=? WHERE intent_id=?",arguments:[original,id.uuidString]) }
        #expect(try await f.store.enqueueMembership(intent,activationID:UUID(),now:now)==id)
        try await f.store.close()
    }

    @Test(arguments: ["watermark", "pending", "intent", "update"], [1.5, Double(Int64.max)])
    func effectiveReadWatermarkStorage(path: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "effective-watermark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"), installationBinding: .init(value: UUID()))
        let room = RoomID(uuid: UUID()), absent = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        try await store.databasePool.write { try $0.execute(sql:"UPDATE v2_local_installation SET user_id=?",arguments:[user.rawValue]) }
        func batch(_ sequence: UInt64, through: Int) throws -> V2ClientSyncBatch {
            try .init(generation: 1, records: [.init(sequence: sequence, sourceEventID: .init(uuid: UUID()),
                projectionKind: "own_read_watermark", payload: JSONSerialization.data(withJSONObject: [
                    "room_id": room.rawValue, "read_through_room_sequence": through, "recorded_at_ms": 1000]))],
                nextSyncToken: .init("watermark"), receipt: .init("watermark"), hasMore: false, capabilityProfile: "base")
        }
        _ = try await store.apply(batch(1, through: 1))
        _ = try await store.enqueueReadReceiptIntent(accountID:user,roomID:room,readThrough:2)
        _ = try await store.prepareNextReadReceiptIntent(accountID:user)
        let small = try #require(try await store.dueOperationWork(now:.now,kinds:[.readReceipt]).first)
        _ = try await store.enqueueReadReceiptIntent(accountID:user,roomID:room,readThrough:8)
        let storedWatermark = path == "watermark" || path == "update"
        let table = storedWatermark ? "v2_room_read_watermarks" : path == "intent" ? "v2_read_receipt_intents" : "v2_read_receipt_operations"
        let column = storedWatermark ? "read_through_room_sequence" : path == "intent" ? "desired_sequence" : "requested_sequence"
        let key = path == "pending" ? "work_id" : "room_id"
        let identifier = path == "pending" ? small.id.uuidString : room.rawValue
        let before = try await store.cursor()
        try await store.databasePool.write { db in
            try db.execute(sql:"PRAGMA ignore_check_constraints=ON")
            defer { try? db.execute(sql:"PRAGMA ignore_check_constraints=OFF") }
            try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(key) = ?", arguments: [value, identifier])
        }
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
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = \(path == "intent" ? 8 : path == "pending" ? 2 : 1) WHERE \(key) = ?", arguments: [identifier]) }
        #expect(try await store.roomReadWatermark(roomID: room) == 8)
        _ = try await store.apply(incoming)
        #expect(try await store.roomReadWatermark(roomID: room) == 9)
        #expect(try await store.cursor()?.appliedSequence == 2)
        try await store.close()
    }

}
