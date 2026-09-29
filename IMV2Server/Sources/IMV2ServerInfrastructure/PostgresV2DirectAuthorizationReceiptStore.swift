import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit

/// 一次持久化的控制侧授权尝试。连接或调用方消失本身
/// 不会让授权代次过期。
struct V2DirectAuthorizationAttempt: Equatable, Sendable {
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let generation: Int64
    let recipientID: UUID
    let ownerShardID: String
    let ownerEpoch: Int64
    let fingerprint: Data

    func validate() throws {
        guard generation > 0, senderID != recipientID, ownerEpoch >= 0,
              !ownerShardID.isEmpty, fingerprint.count == 32 else {
            throw V2DirectAuthorizationReceiptError.invalidAttempt
        }
    }
}


enum V2DirectAuthorizationDisposition: String, Codable, Sendable {
    case accepted, denied, aborted
}

struct V2DirectAuthorizationReceipt: Equatable, Sendable {
    let disposition: V2DirectAuthorizationDisposition
    let eventID: UUID?
}

/// 房间所有者持有的终态证明。此基础组件不是控制侧授权协调器：
/// 调用方使用前须先创建持久化控制义务，
/// 并在消息写入期间保持所有者事务开启。
struct PostgresV2DirectAuthorizationReceiptStore: Sendable {
    let schema: String

    init(schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.schema = schema
    }

    /// 返回 nil 表示允许此次精确尝试在事务内继续。
    /// 终态回执直接重放，不重新开启授权，也不更新时间。
    func prepare(_ attempt: V2DirectAuthorizationAttempt, transaction: any Database) async throws -> V2DirectAuthorizationReceipt? {
        if let receipt = try await checkAttempt(attempt, transaction: transaction) { return receipt }
        let sql = try transactionSQL(transaction)
        try await validateOwner(attempt, sql: sql)
        return nil
    }

    /// 此处只获取操作锁；还需锁定转发源的调用方，
    /// 校验所有者前须保持既有的房间锁排序顺序。
    func checkAttempt(_ attempt: V2DirectAuthorizationAttempt, transaction: any Database) async throws -> V2DirectAuthorizationReceipt? {
        try attempt.validate()
        let sql = try transactionSQL(transaction)
        try await v2AcquireMessageOperationLock(roomID: attempt.roomID, senderID: attempt.senderID,
            clientMessageID: attempt.clientMessageID, sql: sql)
        if let row = try await sql.raw("""
            SELECT * FROM \(unsafeRaw: schema).direct_authorization_receipts
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID) AND generation = \(bind: attempt.generation)
            """).first(decoding: ReceiptRow.self) {
            guard row.matches(attempt) else { throw V2DirectAuthorizationReceiptError.identityConflict }
            return row.receipt
        }
        // 切换授权代次绝不能改变不可变命令，
        // 即使调用方提供了不同路由或重试上下文。
        if let prior = try await sql.raw("""
            SELECT * FROM \(unsafeRaw: schema).direct_authorization_receipts
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID)
            ORDER BY generation DESC LIMIT 1
            """).first(decoding: ReceiptRow.self) {
            guard prior.generation < attempt.generation, prior.recipientUserID == attempt.recipientID,
                  prior.requestFingerprint == attempt.fingerprint else {
                throw V2DirectAuthorizationReceiptError.identityConflict
            }
        }
        return nil
    }

    /// 完整的所有者操作返回后，读取不可变的已提交证明。
    /// 证明缺失不等于已中止，控制侧授权许可必须继续保留。
    func committedReceipt(_ attempt: V2DirectAuthorizationAttempt, database: any Database) async throws -> V2DirectAuthorizationReceipt? {
        try attempt.validate()
        guard let sql = database as? any SQLDatabase else { throw V2DirectAuthorizationReceiptError.invalidAttempt }
        guard let row = try await sql.raw("""
            SELECT * FROM \(unsafeRaw: schema).direct_authorization_receipts
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID) AND generation = \(bind: attempt.generation)
            """).first(decoding: ReceiptRow.self) else {
            // A permanent operation close also settles an already reserved control obligation.
            // It prohibits all late generations; absence alone remains unresolved.
            guard let closed=try await sql.raw("""
                SELECT fingerprint_version,request_fingerprint
                FROM \(unsafeRaw:schema).message_operation_closures
                WHERE room_id=\(bind:attempt.roomID) AND sender_user_id=\(bind:attempt.senderID)
                  AND client_message_id=\(bind:attempt.clientMessageID)
                """).first(decoding:ClosedAuthorizationFingerprint.self) else { return nil }
            guard closed.version==3,closed.fingerprint==attempt.fingerprint else { throw V2DirectAuthorizationReceiptError.identityConflict }
            return .init(disposition:.aborted,eventID:nil)
        }
        guard row.matches(attempt) else { throw V2DirectAuthorizationReceiptError.identityConflict }
        return row.receipt
    }

    private func validateOwner(_ attempt: V2DirectAuthorizationAttempt, sql: any SQLDatabase) async throws {
        guard let room = try await sql.raw("""
            SELECT room_shard_id, owner_epoch, room_kind
            FROM \(unsafeRaw: schema).rooms WHERE room_id = \(bind: attempt.roomID) FOR NO KEY UPDATE
            """).first(decoding: OwnerRow.self), room.roomShardID == attempt.ownerShardID,
              room.ownerEpoch == attempt.ownerEpoch, room.roomKind == "direct" else {
            throw V2DirectAuthorizationReceiptError.ownerChanged
        }
        guard let pair = try await sql.raw("""
            SELECT lower_user_id, higher_user_id FROM \(unsafeRaw: schema).direct_room_pairs
            WHERE room_id = \(bind: attempt.roomID)
            """).first(decoding: PairRow.self),
              Set([pair.lowerUserID, pair.higherUserID]) == Set([attempt.senderID, attempt.recipientID]) else {
            throw V2DirectAuthorizationReceiptError.identityConflict
        }
    }

    /// 消息事务产生持久化的接受或拒绝结果后调用。
    /// 不能仅凭回调成功就制造已提交证明。
    func finish(_ attempt: V2DirectAuthorizationAttempt, now: Date, transaction: any Database) async throws -> V2DirectAuthorizationReceipt {
        guard let receipt = try await finishIfPresent(attempt, now: now, transaction: transaction) else {
            throw V2DirectAuthorizationReceiptError.missingCompletion
        }
        return receipt
    }

    /// 准入未通过时没有持久化消息结果。保留控制侧授权许可
    /// 供重试或恢复使用，不虚构业务拒绝。
    func finishIfPresent(_ attempt: V2DirectAuthorizationAttempt, now: Date, transaction: any Database) async throws -> V2DirectAuthorizationReceipt? {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DirectAuthorizationReceiptError.invalidAttempt }
        if let existing = try await prepare(attempt, transaction: transaction) {
            guard existing.disposition != .aborted else { throw V2DirectAuthorizationReceiptError.attemptAborted }
            return existing
        }
        let sql = try transactionSQL(transaction)
        guard let completion = try await completion(attempt, sql: sql) else { return nil }
        try await insert(attempt, receipt: completion, now: now, sql: sql)
        return completion
    }

    /// 撤销与消息接受使用同一把操作锁。若不存在已提交结果，
    /// 持久化的中止记录会阻止迟到回调。仅凭记录缺失绝不返回取消证明。
    func abort(_ attempt: V2DirectAuthorizationAttempt, now: Date, database: any Database) async throws -> V2DirectAuthorizationReceipt {
        guard v2PostgresTimestampCanEncode(now) else { throw V2DirectAuthorizationReceiptError.invalidAttempt }
        return try await database.transaction { transaction in
            if let existing = try await prepare(attempt, transaction: transaction) { return existing }
            let sql = try transactionSQL(transaction)
            let receipt = try await completion(attempt, sql: sql)
                ?? V2DirectAuthorizationReceipt(disposition: .aborted, eventID: nil)
            try await insert(attempt, receipt: receipt, now: now, sql: sql)
            return receipt
        }
    }

    private func transactionSQL(_ transaction: any Database) throws -> any SQLDatabase {
        guard transaction.inTransaction, let sql = transaction as? any SQLDatabase else {
            throw V2DirectAuthorizationReceiptError.transactionRequired
        }
        return sql
    }

    private func completion(_ attempt: V2DirectAuthorizationAttempt, sql: any SQLDatabase) async throws -> V2DirectAuthorizationReceipt? {
        let results = try await sql.raw("""
            SELECT 'accepted' AS disposition, event_id, request_fingerprint, fingerprint_version,
                   direct_recipient_user_id AS recipient_user_id
            FROM \(unsafeRaw: schema).message_send_completions
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID)
            UNION ALL
            SELECT 'denied', source_event_id, request_fingerprint, fingerprint_version, \(bind: attempt.recipientID)::uuid
            FROM \(unsafeRaw: schema).direct_message_denials
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID)
            """).all(decoding: CompletionRow.self)
        guard !results.isEmpty else { return nil }
        guard results.count == 1, let row = results.first, row.fingerprintVersion == 3,
              row.requestFingerprint == attempt.fingerprint, row.recipientUserID == attempt.recipientID else {
            throw V2DirectAuthorizationReceiptError.identityConflict
        }
        return .init(disposition: row.disposition, eventID: row.eventID)
    }

    private func insert(_ attempt: V2DirectAuthorizationAttempt, receipt: V2DirectAuthorizationReceipt,
        now: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).direct_authorization_receipts
                (room_id, sender_user_id, client_message_id, generation, recipient_user_id,
                 owner_shard_id, owner_epoch, request_fingerprint, disposition, event_id, recorded_at)
            VALUES (\(bind: attempt.roomID), \(bind: attempt.senderID), \(bind: attempt.clientMessageID),
                \(bind: attempt.generation), \(bind: attempt.recipientID), \(bind: attempt.ownerShardID),
                \(bind: attempt.ownerEpoch), \(bind: attempt.fingerprint), \(bind: receipt.disposition.rawValue),
                \(bind: receipt.eventID), \(bind: now))
            """).run()
    }
}

/// 此键须与有类型数组或 JSON 批次语句使用的键完全一致。
func v2AcquireMessageOperationLock(roomID: UUID, senderID: UUID, clientMessageID: UUID, sql: any SQLDatabase) async throws {
    let key = "v2-message-operation:" + roomID.uuidString.lowercased() + ":" + senderID.uuidString.lowercased() + ":" + clientMessageID.uuidString.lowercased()
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
}

private struct OwnerRow: Decodable {
    let roomShardID: String; let ownerEpoch: Int64; let roomKind: String
    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id", ownerEpoch = "owner_epoch", roomKind = "room_kind"
    }
}
private struct PairRow: Decodable {
    let lowerUserID: UUID; let higherUserID: UUID
    enum CodingKeys: String, CodingKey { case lowerUserID = "lower_user_id", higherUserID = "higher_user_id" }
}
private struct CompletionRow: Decodable {
    let disposition: V2DirectAuthorizationDisposition; let eventID: UUID
    let requestFingerprint: Data; let fingerprintVersion: Int16; let recipientUserID: UUID?
    enum CodingKeys: String, CodingKey {
        case disposition, eventID = "event_id", requestFingerprint = "request_fingerprint"
        case fingerprintVersion = "fingerprint_version", recipientUserID = "recipient_user_id"
    }
}
private struct ReceiptRow: Decodable {
    let generation: Int64; let recipientUserID: UUID; let ownerShardID: String; let ownerEpoch: Int64
    let requestFingerprint: Data; let disposition: V2DirectAuthorizationDisposition; let eventID: UUID?
    enum CodingKeys: String, CodingKey {
        case generation, recipientUserID = "recipient_user_id", ownerShardID = "owner_shard_id", ownerEpoch = "owner_epoch"
        case requestFingerprint = "request_fingerprint", disposition, eventID = "event_id"
    }
    func matches(_ attempt: V2DirectAuthorizationAttempt) -> Bool {
        generation == attempt.generation && recipientUserID == attempt.recipientID && ownerShardID == attempt.ownerShardID
            && ownerEpoch == attempt.ownerEpoch && requestFingerprint == attempt.fingerprint
    }
    var receipt: V2DirectAuthorizationReceipt { .init(disposition: disposition, eventID: eventID) }
}

private struct ClosedAuthorizationFingerprint:Decodable {
    let version:Int16;let fingerprint:Data
    enum CodingKeys:String,CodingKey { case version="fingerprint_version",fingerprint="request_fingerprint" }
}
