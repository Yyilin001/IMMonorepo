import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 源端终态证据与置顶释放的持久化实现。
///
/// 该事务内不产生任何远程副作用；超时与重试耗尽都不构成终态回执，
/// 只有目标侧持久化的终态结果才能写入回执。
public struct PostgresV2ForwardReceiptStore: Sendable {
    private let database: any Database
    private var activationScope: V2RoomActivationWriteScope?

    /// 组合数据库。
    ///
    /// - Parameter database: 存放转发导出与回执的数据库。
    public init(database: any Database) { self.database = database; self.activationScope = nil }

    public func usingActivationToken(_ token: V2RoomActivationToken) throws -> Self {
        var scoped = self
        scoped.activationScope = try .init(tokens: [token])
        return scoped
    }

    /// 记录或重放一次终态回执。
    ///
    /// 顺序为：复核导出身份与摘要未变、命中已有回执则校验一致性、锁定源房间并校验归属、
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
        try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            guard let original = try await sql.raw("""
                SELECT source_room_id, source_shard_id, source_epoch, payload_digest FROM im_v2.message_forward_exports
                WHERE export_id = \(bind: receipt.exportID)
                """).first(decoding: ReceiptExportRow.self),
                  original.digest == receipt.payloadDigest
            else { throw V2ForwardExportError.idempotencyConflict }
            if let activationScope {
                let token = try activationScope.token(for: original.sourceRoomID)
                guard token.owner.shardID == original.sourceShardID,
                      token.owner.epoch == original.sourceEpoch else {
                    throw V2RoomActivationLeaseError.activationChanged
                }
                try await activationScope.require([original.sourceRoomID], sql: sql)
            }
            if let prior = try await read(exportID: receipt.exportID, sql: sql) {
                try match(prior, receipt: receipt)
                return
            }
            // 将配额释放与新导出串行化；所有权改变后阻止旧源工作器继续写入。
            // 上方的精确终态重放仍有效，无须重新授权原始消息。
            guard let room = try await sql.raw("""
                SELECT room_shard_id, owner_epoch FROM im_v2.rooms
                WHERE room_id = \(bind: original.sourceRoomID) FOR NO KEY UPDATE
                """).first(decoding: ReceiptOwnerRow.self),
                  room.shardID == original.sourceShardID, room.epoch == original.sourceEpoch
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
                VALUES (\(bind: receipt.exportID), \(bind: receipt.payloadDigest), \(bind: state),
                        \(bind: messageID), \(bind: sequence), \(bind: code), \(bind: now))
                ON CONFLICT (export_id) DO NOTHING
                """).run()
            guard let saved = try await read(exportID: receipt.exportID, sql: sql)
            else { throw V2ForwardExportError.corruptPersistenceState }
            try match(saved, receipt: receipt)
        }
    }

    /// 无须加载内容信封即可重放终态配对。导出身份仍是权威；
    /// 源绑定改变属于冲突。
    public func terminalStatus(actor: UserID, operation: MessageForwardOperationID,
                        source: V2ForwardMessageReference, target: RoomID) async throws -> V2ForwardImportOutcome? {
        guard let actorID = actor.uuidValue, let operationID = operation.uuidValue,
              let sourceID = source.messageID.uuidValue, let sourceRoom = source.roomID.uuidValue,
              let targetID = target.uuidValue else { throw V2ForwardExportError.invalidRequest }
        guard let sql = database as? any SQLDatabase else { throw V2ForwardExportError.corruptPersistenceState }
        if let rejection = try await forwardPreparationRejection(actor: actorID, operation: operationID, source: source, target: target, sql: sql) { return .rejected(code: rejection) }
        guard let row = try await sql.raw("""
            SELECT export.source_room_id, export.source_content_revision,
                   export.payload_digest AS export_digest,
                   receipt.payload_digest, receipt.state, receipt.result_message_id,
                   receipt.result_room_sequence, receipt.error_code
            FROM im_v2.message_forward_exports AS export
            JOIN im_v2.message_forward_export_receipts AS receipt USING (export_id)
            WHERE export.actor_user_id = \(bind: actorID) AND export.operation_id = \(bind: operationID)
              AND export.source_message_id = \(bind: sourceID) AND export.target_room_id = \(bind: targetID)
            """).first(decoding: TerminalPairRow.self) else { return nil }
        guard row.sourceRoomID == sourceRoom, row.sourceRevision == source.revision.signedValue else {
            throw V2ForwardExportError.idempotencyConflict
        }
        guard row.exportDigest.count == 32, row.exportDigest == row.receipt.digest else {
            throw V2ForwardExportError.corruptPersistenceState
        }
        return try row.receipt.outcome
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
    private func read(exportID: UUID, sql: any SQLDatabase) async throws -> V2ForwardReceiptRow? {
        try await sql.raw("""
            SELECT payload_digest, state, result_message_id, result_room_sequence, error_code
            FROM im_v2.message_forward_export_receipts WHERE export_id = \(bind: exportID)
            """).first(decoding: V2ForwardReceiptRow.self)
    }

    /// 校验已有回执与本次终态结果完全一致。
    ///
    /// - Parameters:
    ///   - row: 已持久化的回执行。
    ///   - receipt: 本次提交的终态回执。
    /// - Throws: 摘要或结果不一致时抛出
    ///   ``V2ForwardExportError/idempotencyConflict``。
    private func match(_ row: V2ForwardReceiptRow, receipt: V2ForwardTerminalReceipt) throws {
        guard row.digest == receipt.payloadDigest, try row.outcome == receipt.outcome
        else { throw V2ForwardExportError.idempotencyConflict }
    }
}

private struct ReceiptExportRow: Decodable {
    let sourceRoomID: UUID; let sourceShardID: String; let sourceEpoch: Int64; let digest: Data
    enum CodingKeys: String, CodingKey {
        case sourceRoomID = "source_room_id", sourceShardID = "source_shard_id", sourceEpoch = "source_epoch", digest = "payload_digest"
    }
}
private struct ReceiptOwnerRow: Decodable {
    let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id"; case epoch = "owner_epoch" }
}
struct V2ForwardReceiptRow: Decodable {
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

private struct TerminalPairRow: Decodable {
    let sourceRoomID: UUID
    let sourceRevision: Int64
    let exportDigest: Data
    let receipt: V2ForwardReceiptRow
    enum CodingKeys: String, CodingKey {
        case sourceRoomID = "source_room_id", sourceRevision = "source_content_revision", exportDigest = "export_digest"
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceRoomID = try values.decode(UUID.self, forKey: .sourceRoomID)
        sourceRevision = try values.decode(Int64.self, forKey: .sourceRevision)
        exportDigest = try values.decode(Data.self, forKey: .exportDigest)
        receipt = try V2ForwardReceiptRow(from: decoder)
    }
}

/// A source rejection is created under the exact export lock before any export/handoff exists.
func forwardPreparationRejection(actor: UUID, operation: UUID, source: V2ForwardMessageReference, target: RoomID, sql: any SQLDatabase) async throws -> String? {
    guard let row = try await sql.raw("""
        SELECT source_room_id,source_content_revision,error_code FROM im_v2.forward_preparation_rejections
        WHERE actor_user_id=\(bind:actor) AND operation_id=\(bind:operation) AND source_message_id=\(bind:source.messageID.uuidValue!) AND target_room_id=\(bind:target.uuidValue!)
        """).first(decoding: ForwardPreparationRejectionRow.self) else { return nil }
    guard row.source_room_id == source.roomID.uuidValue, row.source_content_revision == source.revision.signedValue else { throw V2ForwardExportError.idempotencyConflict }
    return row.error_code
}
private struct ForwardPreparationRejectionRow: Decodable {
    let source_room_id: UUID; let source_content_revision: Int64; let error_code: String
}
