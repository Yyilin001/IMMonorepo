import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 源端终态证据与置顶释放的持久化实现。
///
/// 该事务内不产生任何远程副作用；超时与重试耗尽都不构成终态回执，
/// 只有目标侧持久化的终态结果才能写入回执。
public struct PostgresV2ForwardReceiptStore: Sendable {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放转发导出与回执的数据库。
    public init(database: any Database) { self.database = database }

    /// 记录或重放一次终态回执。
    ///
    /// 顺序为：复核导出原文与摘要未变、命中已有回执则校验一致性、锁定源房间并校验归属、
    /// 写入回执、再读回校验。归属校验会与新导出串行化配额释放，并在归属迁移后栅栏掉旧源端工作器；
    /// 完全一致的终态回放不需要重新授权原始消息。
    ///
    /// - Parameters:
    ///   - receipt: 目标侧终态回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 导出记录不存在或内容不一致、归属已变更、结果仍为待处理、
    ///   序号无法写入 `Int64` 或时刻不可编码时抛出
    ///   ``V2ForwardExportError/idempotencyConflict`` 或
    ///   ``V2ForwardExportError/corruptPersistenceState``。
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

    /// 查询导出当前的终态结果。
    ///
    /// - Parameter exportID: 目标导出标识。
    /// - Returns: 终态结果；尚无回执时返回 `nil`。
    /// - Throws: 连接不支持 SQL 或回执行字段非法时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    public func status(exportID: UUID) async throws -> V2ForwardImportOutcome? {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        return try await read(exportID: exportID, sql: sql)?.outcome
    }

    /// 读取指定导出的回执行。
    ///
    /// - Parameters:
    ///   - exportID: 目标导出标识。
    ///   - sql: 当前事务使用的数据库连接。
    /// - Returns: 回执行；不存在时返回 `nil`。
    /// - Throws: 查询失败时抛出。
    private func read(exportID: UUID, sql: any SQLDatabase) async throws -> ReceiptRow? {
        try await sql.raw("""
            SELECT payload_digest, state, result_message_id, result_room_sequence, error_code
            FROM im_v2.message_forward_export_receipts WHERE export_id = \(bind: exportID)
            """).first(decoding: ReceiptRow.self)
    }

    /// 校验已有回执与本次终态结果完全一致。
    ///
    /// - Parameters:
    ///   - row: 已持久化的回执行。
    ///   - receipt: 本次提交的终态回执。
    /// - Throws: 摘要或结果不一致时抛出
    ///   ``V2ForwardExportError/idempotencyConflict``。
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
