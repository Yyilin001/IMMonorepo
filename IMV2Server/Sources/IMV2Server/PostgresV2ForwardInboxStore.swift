import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 转发导入仍未完成的原因。
public enum V2ForwardImportPendingReason: Equatable, Sendable {
    /// 仍在等待媒体就绪。
    case media
    /// 仍在等待目标准入额度。
    case admission
    /// 媒体与准入均已就绪，正在收尾提交。
    case finalization
}

/// 转发导入的结果。
public enum V2ForwardImportOutcome: Equatable, Sendable {
    /// 目标侧已接受，附带消息标识与房间序号。
    case accepted(messageID: MessageID, roomSequence: UInt64)
    /// 目标侧拒绝，附带稳定错误码。
    case rejected(code: String)
    /// 仍在处理中，附带原因。
    case pending(V2ForwardImportPendingReason)
}

/// 转发收件箱错误。
public enum V2ForwardInboxError: Error, Equatable, Sendable {
    /// 目标房间归属已变更。
    case ownerChanged
    /// 目标房间或收件箱记录不存在。
    case targetNotFound
    /// 同一幂等标识已被不同载荷占用。
    case idempotencyConflict
    /// 目标房间的未完成导入数量已达上限。
    case capacityExceeded
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 转发收件箱的 PostgreSQL 实现，只接收来自受信归属通道的服务端导出。
///
/// 载荷校验和本身绝不构成对客户端提交信封的授权。接收是持久化的，
/// 但并不因此授予目标成员资格或表示目标已接受。
public struct PostgresV2ForwardInboxStore: Sendable {
    private let database: any Database
    private let maximumPendingPerRoom: Int

    /// 组合数据库与单房间未完成导入上限。
    ///
    /// - Parameters:
    ///   - database: 存放转发收件箱与导入状态的数据库。
    ///   - maximumPendingPerRoom: 单房间允许的未完成导入数量，需大于零，默认 1024。
    ///
    /// 上限非正时直接失败，避免出现无界收件箱。
    public init(database: any Database, maximumPendingPerRoom: Int = 1_024) {
        precondition(maximumPendingPerRoom > 0)
        self.database = database
        self.maximumPendingPerRoom = maximumPendingPerRoom
    }

    /// 持久化接收一次转发导出。
    ///
    /// 接收会校验导出摘要、目标归属与单房间未完成上限，并写入收件箱行；
    /// 已存在完全一致的记录时按幂等处理。
    ///
    /// - Parameters:
    ///   - export: 待接收的转发导出。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 归属已变更时抛出 ``V2ForwardInboxError/ownerChanged``；
    ///   已存在载荷不一致的记录时抛出 ``V2ForwardInboxError/idempotencyConflict``；
    ///   超过单房间上限时抛出 ``V2ForwardInboxError/capacityExceeded``；
    ///   持久化异常时抛出 ``V2ForwardInboxError/corruptPersistenceState``。
    public func receive(_ export: V2ForwardExport, now: Date) async throws {
        let intent = export.intent
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
            if try await matchesExisting(export, sql: sql) { return }
            // Check existing immutable bindings before taking any room lock.
            // The quota mutex serializes new receipts for this target. Only a
            // new binding takes SHARE through insertion, fencing epoch changes
            // without waiting on an existing inbox held by acceptance.
            let key = "v2-forward-inbox-room:\(intent.targetRoomID)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
            if try await matchesExisting(export, sql: sql) { return }
            guard let room = try await sql.raw("""
                SELECT room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id = \(bind: intent.targetRoomID) FOR SHARE
                """).first(decoding: ForwardInboxOwnerRow.self)
            else { throw V2ForwardInboxError.targetNotFound }
            guard room.shardID == intent.targetShardID, room.epoch == intent.targetEpoch
            else { throw V2ForwardInboxError.ownerChanged }
            let pending = try await sql.raw("""
                SELECT export_id FROM im_v2.message_forward_inbox
                WHERE target_room_id = \(bind: intent.targetRoomID) AND state IN ('pending', 'accepted')
                LIMIT \(bind: maximumPendingPerRoom)
                """).all(decoding: ForwardInboxIDRow.self)
            guard pending.count < maximumPendingPerRoom else { throw V2ForwardInboxError.capacityExceeded }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO im_v2.message_forward_inbox
                    (export_id, actor_user_id, operation_id, source_message_id, target_room_id,
                     target_client_message_id, payload, payload_digest, state, created_at)
                VALUES (\(bind: intent.exportID), \(bind: intent.actorUserID), \(bind: intent.operationID),
                        \(bind: intent.sourceMessageID), \(bind: intent.targetRoomID),
                        \(bind: intent.targetClientMessageID), \(bind: export.payload), \(bind: export.digest),
                        'pending', \(bind: now)) ON CONFLICT DO NOTHING
                """).run()
            guard try await matchesExisting(export, sql: sql) else { throw V2ForwardInboxError.idempotencyConflict }
            for (ordinal, media) in intent.media.enumerated() {
                try await sql.raw("""
                    INSERT INTO im_v2.message_forward_inbox_media (export_id, ordinal, source_media_id, state)
                    VALUES (\(bind: intent.exportID), \(bind: ordinal), \(bind: media.mediaID), 'pending')
                    ON CONFLICT (export_id, ordinal) DO NOTHING
                    """).run()
            }
        }
    }

    private func matchesExisting(_ export: V2ForwardExport, sql: any SQLDatabase) async throws -> Bool {
        guard let row = try await sql.raw("""
            SELECT payload, payload_digest FROM im_v2.message_forward_inbox WHERE export_id = \(bind: export.intent.exportID)
            """).first(decoding: ForwardInboxPayloadRow.self) else { return false }
        guard row.payload == export.payload, row.digest == export.digest else { throw V2ForwardInboxError.idempotencyConflict }
        return true
    }

    /// 查询导出当前的导入结果。
    ///
    /// - Parameter exportID: 目标导出标识。
    /// - Returns: 导入结果；尚无记录时返回 `nil`。
    /// - Throws: 连接不支持 SQL 或记录无法解码时抛出
    ///   ``V2ForwardInboxError/corruptPersistenceState``。
    public func status(exportID: UUID) async throws -> V2ForwardImportOutcome? {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        guard let row = try await sql.raw("""
            SELECT export_id, payload, payload_digest, state, result_message_id, result_room_sequence, error_code
            FROM im_v2.message_forward_inbox WHERE export_id = \(bind: exportID)
            """).first(decoding: ForwardInboxRow.self) else { return nil }
        return try row.outcome
    }

    /// 读取导出对应的终态回执。
    ///
    /// 已接受但尚未终结的消息刻意没有终态回执。
    /// 终态行不可变，因此之后的任期或成员变更不会撤销已完成目标操作的证据。
    ///
    /// - Parameter exportID: 目标导出标识。
    /// - Returns: 终态回执；尚未进入终态时返回 `nil`。
    /// - Throws: 记录不可解码或回执构造失败时抛出
    ///   ``V2ForwardInboxError/corruptPersistenceState``。
    public func terminalReceipt(exportID: UUID) async throws -> V2ForwardTerminalReceipt? {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        guard let row = try await sql.raw("""
            SELECT export_id, payload, payload_digest, state, result_message_id, result_room_sequence, error_code
            FROM im_v2.message_forward_inbox WHERE export_id = \(bind: exportID)
            """).first(decoding: ForwardInboxRow.self) else { return nil }
        let outcome = try row.outcome
        if case .pending = outcome { return nil }
        return try .init(export: row.export, outcome: outcome)
    }
}

struct ForwardInboxRow: Decodable, Sendable {
    let exportID: UUID
    let payload: Data
    let digest: Data
    let state: String
    let messageID: UUID?
    let roomSequence: Int64?
    let errorCode: String?
    enum CodingKeys: String, CodingKey {
        case exportID = "export_id", payload, digest = "payload_digest", state
        case messageID = "result_message_id", roomSequence = "result_room_sequence", errorCode = "error_code"
    }
    var export: V2ForwardExport {
        get throws {
            let value = try V2ForwardExport(payload: payload, digest: digest)
            guard value.intent.exportID == exportID else { throw V2ForwardInboxError.corruptPersistenceState }
            return value
        }
    }
    var outcome: V2ForwardImportOutcome {
        get throws {
            switch state {
            case "completed":
                guard let messageID, let roomSequence, roomSequence > 0, errorCode == nil
                else { throw V2ForwardInboxError.corruptPersistenceState }
                return .accepted(messageID: .init(uuid: messageID), roomSequence: UInt64(roomSequence))
            case "rejected":
                guard let errorCode, !errorCode.isEmpty, messageID == nil, roomSequence == nil
                else { throw V2ForwardInboxError.corruptPersistenceState }
                return .rejected(code: errorCode)
            case "accepted": return .pending(.finalization)
            case "pending": return .pending(try export.intent.media.isEmpty ? .admission : .media)
            default: throw V2ForwardInboxError.corruptPersistenceState
            }
        }
    }
}

/// 由已加锁的收件箱记录与其不可变就绪媒体映射构造的接受命令。
///
/// 它绝不会从普通发送 API 进入，也不来自归属推断。
struct ForwardInboxAuthorization: Sendable {
    let export: V2ForwardExport
    let mediaIDs: [UUID]

    /// 构造目标房间的发送命令。
    ///
    /// - Parameter limits: 消息命令限制。
    /// - Returns: 目标房间的发送命令。
    /// - Throws: 字段不满足命令约束时抛出。
    func command(limits: V2MessageCommandLimits) throws -> V2SendMessageCommand {
        let intent = export.intent
        return try .init(
            roomID: .init(uuid: intent.targetRoomID), senderUserID: .init(uuid: intent.actorUserID),
            clientMessageID: .init(uuid: intent.targetClientMessageID), text: intent.text,
            media: mediaIDs.map { .init(mediaID: .init(uuid: $0)) }, entities: intent.entities,
            forwardedFrom: .init(messageID: .init(uuid: intent.sourceMessageID),
                                 senderUserID: .init(uuid: intent.sourceSenderUserID),
                                 sourceRevision: .init(UInt64(intent.sourceRevision))), limits: limits
        )
    }
}

/// 锁定并读取指定导出的收件箱记录。
///
/// - Parameters:
///   - exportID: 目标导出标识。
///   - sql: 当前事务使用的数据库连接。
/// - Returns: 已加锁的收件箱记录。
/// - Throws: 记录不存在时抛出 ``V2ForwardInboxError/targetNotFound``；
///   持久化异常时抛出 ``V2ForwardInboxError/corruptPersistenceState``。
func v2LockForwardInbox(exportID: UUID, sql: any SQLDatabase) async throws -> ForwardInboxRow {
    guard let row = try await sql.raw("""
        SELECT export_id, payload, payload_digest, state, result_message_id, result_room_sequence, error_code
        FROM im_v2.message_forward_inbox WHERE export_id = \(bind: exportID) FOR UPDATE
        """).first(decoding: ForwardInboxRow.self) else { throw V2ForwardInboxError.corruptPersistenceState }
    return row
}

/// 重新校验收件箱记录的归属与授权依据。
///
/// - Parameters:
///   - row: 已加锁的收件箱记录。
///   - sql: 当前事务使用的数据库连接。
/// - Returns: 授权依据；不满足条件时返回 `nil`。
/// - Throws: 持久化异常时抛出 ``V2ForwardInboxError/corruptPersistenceState``。
func v2ForwardInboxAuthorization(_ row: ForwardInboxRow, sql: any SQLDatabase) async throws -> ForwardInboxAuthorization? {
    let export = try row.export
    let media = try await sql.raw("""
        SELECT ordinal, source_media_id, target_media_id, object_digest, state
        FROM im_v2.message_forward_inbox_media WHERE export_id = \(bind: row.exportID)
        ORDER BY ordinal FOR SHARE
        """).all(decoding: ForwardInboxMediaRow.self)
    guard media.count == export.intent.media.count else { throw V2ForwardInboxError.corruptPersistenceState }
    for (ordinal, mapping) in media.enumerated() {
        guard mapping.ordinal == ordinal, mapping.sourceID == export.intent.media[ordinal].mediaID
        else { throw V2ForwardInboxError.corruptPersistenceState }
    }
    guard media.allSatisfy({ $0.state == "ready" }) else { return nil }
    let ids = try media.map { mapping in
        guard let id = mapping.targetID, mapping.digest?.count == 32 else { throw V2ForwardInboxError.corruptPersistenceState }
        return id
    }
    guard Set(ids).count == ids.count else { throw V2ForwardInboxError.corruptPersistenceState }
    return .init(export: export, mediaIDs: ids)
}

/// 记录目标侧接受结果。
///
/// - Parameters:
///   - row: 已加锁的收件箱记录。
///   - receipt: 消息接受回执。
///   - now: 服务端统一授时时刻。
///   - sql: 当前事务使用的数据库连接。
/// - Throws: 持久化异常时抛出 ``V2ForwardInboxError/corruptPersistenceState``。
func v2RecordForwardInboxAcceptance(_ row: ForwardInboxRow, receipt: V2MessageAcceptanceReceipt, now: Date, sql: any SQLDatabase) async throws {
    guard let messageID = receipt.messageID.uuidValue,
          receipt.roomSequence > 0, receipt.roomSequence <= UInt64(Int64.max)
    else { throw V2ForwardInboxError.corruptPersistenceState }
    if row.state == "accepted" {
        guard row.messageID == messageID, row.roomSequence == Int64(receipt.roomSequence)
        else { throw V2ForwardInboxError.corruptPersistenceState }
        return
    }
    guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
    guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
    try await sql.raw("""
        UPDATE im_v2.message_forward_inbox SET state = 'accepted', result_message_id = \(bind: messageID),
            result_room_sequence = \(bind: Int64(receipt.roomSequence)), accepted_at = \(bind: now)
        WHERE export_id = \(bind: row.exportID) AND state = 'pending'
        """).run()
}

/// 把收件箱记录标记为拒绝。
///
/// - Parameters:
///   - row: 已加锁的收件箱记录。
///   - code: 稳定错误码。
///   - now: 服务端统一授时时刻。
///   - sql: 当前事务使用的数据库连接。
/// - Returns: 拒绝结果。
/// - Throws: 持久化异常时抛出 ``V2ForwardInboxError/corruptPersistenceState``。
func v2RejectForwardInbox(_ row: ForwardInboxRow, code: String, now: Date, sql: any SQLDatabase) async throws -> V2ForwardImportOutcome {
    guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
    guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
    try await sql.raw("""
        UPDATE im_v2.message_forward_inbox SET state = 'rejected', error_code = \(bind: code), completed_at = \(bind: now)
        WHERE export_id = \(bind: row.exportID) AND state = 'pending'
        """).run()
    return .rejected(code: code)
}

/// 断言收件箱授权依据与目标房间当前归属一致。
///
/// - Parameters:
///   - authorization: 收件箱授权依据。
///   - sql: 当前事务使用的数据库连接。
/// - Throws: 归属不一致时抛出 ``V2ForwardInboxError/ownerChanged``。
func v2AssertForwardInboxOwner(_ authorization: ForwardInboxAuthorization, sql: any SQLDatabase) async throws {
    let intent = authorization.export.intent
    // Acceptance calls after message-operation and room locks; completion
    // calls after the inbox lock. Retain the owner through the caller's commit,
    // including when a migration changed it while this statement waited.
    guard let room = try await sql.raw("""
        SELECT room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id = \(bind: intent.targetRoomID) FOR NO KEY UPDATE
        """).first(decoding: ForwardInboxOwnerRow.self),
          room.shardID == intent.targetShardID, room.epoch == intent.targetEpoch
    else { throw V2ForwardInboxError.ownerChanged }
}

private struct ForwardInboxPayloadRow: Decodable {
    let payload: Data; let digest: Data
    enum CodingKeys: String, CodingKey { case payload; case digest = "payload_digest" }
}
private struct ForwardInboxIDRow: Decodable {
    let exportID: UUID
    enum CodingKeys: String, CodingKey { case exportID = "export_id" }
}
private struct ForwardInboxOwnerRow: Decodable {
    let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id"; case epoch = "owner_epoch" }
}
private struct ForwardInboxMediaRow: Decodable {
    let ordinal: Int; let sourceID: UUID; let targetID: UUID?; let digest: Data?; let state: String
    enum CodingKeys: String, CodingKey {
        case ordinal, state; case sourceID = "source_media_id"; case targetID = "target_media_id"; case digest = "object_digest"
    }
}
