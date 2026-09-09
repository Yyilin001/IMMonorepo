import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Source-side terminal evidence and pin release. There are no remote effects
/// inside this transaction. Neither timeouts nor exhausted retries are receipts.
public struct PostgresV2ForwardReceiptStore: Sendable {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func record(_ receipt: V2ForwardTerminalReceipt, now: Date) async throws {
        let export = receipt.export
        let intent = export.intent
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            guard let original = try await sql.raw("""
                SELECT payload, payload_digest FROM im_v2.message_forward_exports
                WHERE export_id = \(bind: intent.exportID)
                """).first(decoding: ReceiptExportRow.self),
                  original.payload == export.payload, original.digest == export.digest
            else { throw V2ForwardExportError.idempotencyConflict }
            if let prior = try await read(exportID: intent.exportID, sql: sql) {
                try match(prior, receipt: receipt)
                return
            }
            // Serialize quota release with new exports, and fence an old
            // source worker after ownership has changed. Exact terminal replay
            // above remains valid without reauthorizing the original message.
            guard let room = try await sql.raw("""
                SELECT room_shard_id, owner_epoch FROM im_v2.rooms
                WHERE room_id = \(bind: intent.sourceRoomID) FOR UPDATE
                """).first(decoding: ReceiptOwnerRow.self),
                  room.shardID == intent.sourceShardID, room.epoch == intent.sourceEpoch
            else { throw V2ForwardExportError.ownerChanged }
            let state: String, messageID: UUID?, sequence: Int64?, code: String?
            switch receipt.outcome {
            case .accepted(let message, let roomSequence):
                state = "completed"; messageID = message.uuidValue
                sequence = Int64(exactly: roomSequence); code = nil
                guard messageID != nil, sequence != nil else { throw V2ForwardExportError.corruptPersistenceState }
            case .rejected(let errorCode):
                state = "rejected"; messageID = nil; sequence = nil; code = errorCode
            case .pending: throw V2ForwardExportError.corruptPersistenceState
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardExportError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO im_v2.message_forward_export_receipts
                    (export_id, payload_digest, state, result_message_id, result_room_sequence, error_code, recorded_at)
                VALUES (\(bind: intent.exportID), \(bind: export.digest), \(bind: state),
                        \(bind: messageID), \(bind: sequence), \(bind: code), \(bind: now))
                ON CONFLICT (export_id) DO NOTHING
                """).run()
            guard let saved = try await read(exportID: intent.exportID, sql: sql)
            else { throw V2ForwardExportError.corruptPersistenceState }
            try match(saved, receipt: receipt)
        }
    }

    public func status(exportID: UUID) async throws -> V2ForwardImportOutcome? {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        return try await read(exportID: exportID, sql: sql)?.outcome
    }

    private func read(exportID: UUID, sql: any SQLDatabase) async throws -> ReceiptRow? {
        try await sql.raw("""
            SELECT payload_digest, state, result_message_id, result_room_sequence, error_code
            FROM im_v2.message_forward_export_receipts WHERE export_id = \(bind: exportID)
            """).first(decoding: ReceiptRow.self)
    }

    private func match(_ row: ReceiptRow, receipt: V2ForwardTerminalReceipt) throws {
        guard row.digest == receipt.export.digest, try row.outcome == receipt.outcome
        else { throw V2ForwardExportError.idempotencyConflict }
    }
}

private struct ReceiptExportRow: Decodable {
    let payload: Data; let digest: Data
    enum CodingKeys: String, CodingKey { case payload; case digest = "payload_digest" }
}
private struct ReceiptOwnerRow: Decodable {
    let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id"; case epoch = "owner_epoch" }
}
private struct ReceiptRow: Decodable {
    let digest: Data; let state: String; let messageID: UUID?; let sequence: Int64?; let code: String?
    enum CodingKeys: String, CodingKey {
        case digest = "payload_digest", state, messageID = "result_message_id"
        case sequence = "result_room_sequence", code = "error_code"
    }
    var outcome: V2ForwardImportOutcome {
        get throws {
            if state == "completed", let messageID, let sequence, sequence > 0, code == nil {
                return .accepted(messageID: .init(uuid: messageID), roomSequence: UInt64(sequence))
            }
            if state == "rejected", let code, !code.isEmpty, messageID == nil, sequence == nil {
                return .rejected(code: code)
            }
            throw V2ForwardExportError.corruptPersistenceState
        }
    }
}
