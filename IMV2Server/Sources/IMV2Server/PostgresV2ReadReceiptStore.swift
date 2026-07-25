import Fluent
import Foundation
import IMV2Core
import SQLKit

/// A receipt does not acknowledge transport delivery. This transaction only
/// advances explicit human-viewing state and records its stable operation ID.
public struct PostgresV2ReadReceiptStore: V2ReadReceiptStore {
    private let database: any Database
    public init(database: any Database) { self.database = database }
    public func record(command: V2RecordReadReceiptCommand, now: Date) async throws -> V2ReadReceiptOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let roomID = try receiptUUID(command.roomID), userID = try receiptUUID(command.actorUserID), operationID = try receiptUUID(command.operationID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: userID.uuidString + ":" + operationID.uuidString), 0))").run()
            if let prior = try await sql.raw("SELECT room_id, requested_room_sequence, resulting_room_sequence, recorded_at FROM im_v2.read_receipt_operations WHERE user_id = \(bind: userID) AND operation_id = \(bind: operationID)").first(decoding: ReceiptOperationRow.self) {
                guard prior.roomID == roomID, prior.requestedSequence == Int64(command.readThroughRoomSequence) else { return .idempotencyConflict }
                return .idempotent(try prior.result(userID: command.actorUserID))
            }
            guard let room = try await sql.raw("SELECT room_sequence, membership_revision FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReceiptRoomRow.self) else { throw V2ReadReceiptStoreError.roomNotFound }
            guard room.roomSequence >= 0, Int64(command.readThroughRoomSequence) <= room.roomSequence else { throw V2ReadReceiptStoreError.roomSequenceNotFound }
            let member = try await sql.raw("SELECT 1 AS exists FROM im_v2.room_memberships WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID) AND joined_revision <= \(bind: room.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))").first(decoding: ReceiptExistsRow.self)
            guard member != nil else { throw V2ReadReceiptStoreError.actorNotMember }
            let current = try await sql.raw("SELECT read_through_room_sequence FROM im_v2.room_read_receipts WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID) FOR UPDATE").first(decoding: ReceiptStateRow.self)?.sequence ?? 0
            let requested = try receiptSigned(command.readThroughRoomSequence), resulting = max(current, requested)
            if current == 0 {
                try await sql.raw("INSERT INTO im_v2.room_read_receipts (room_id, user_id, read_through_room_sequence, updated_at) VALUES (\(bind: roomID), \(bind: userID), \(bind: resulting), \(bind: now))").run()
            } else if resulting > current {
                try await sql.raw("UPDATE im_v2.room_read_receipts SET read_through_room_sequence = \(bind: resulting), updated_at = \(bind: now) WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID)").run()
            }
            try await sql.raw("INSERT INTO im_v2.read_receipt_operations (user_id, operation_id, room_id, requested_room_sequence, resulting_room_sequence, recorded_at) VALUES (\(bind: userID), \(bind: operationID), \(bind: roomID), \(bind: requested), \(bind: resulting), \(bind: now))").run()
            return .recorded(try .init(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: receiptUnsigned(resulting), recordedAt: now))
        }
    }
}

private struct ReceiptRoomRow: Decodable { let roomSequence: Int64; let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case roomSequence = "room_sequence", membershipRevision = "membership_revision" } }
private struct ReceiptExistsRow: Decodable { let exists: Int }
private struct ReceiptStateRow: Decodable { let sequence: Int64; enum CodingKeys: String, CodingKey { case sequence = "read_through_room_sequence" } }
private struct ReceiptOperationRow: Decodable { let roomID: UUID; let requestedSequence: Int64; let resultingSequence: Int64; let recordedAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", requestedSequence = "requested_room_sequence", resultingSequence = "resulting_room_sequence", recordedAt = "recorded_at" }; func result(userID: UserID) throws -> V2ReadReceipt { try .init(roomID: .init(roomID.uuidString), userID: userID, readThroughRoomSequence: receiptUnsigned(resultingSequence), recordedAt: recordedAt) } }
private func receiptUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: id.rawValue) else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return value }
private func receiptSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return Int64(value) }
private func receiptUnsigned(_ value: Int64) throws -> UInt64 { guard value > 0 else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return UInt64(value) }
