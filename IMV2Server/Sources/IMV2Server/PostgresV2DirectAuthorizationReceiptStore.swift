import FluentKit
import Foundation
import SQLKit

/// One durable control authorization attempt. Generations never expire merely
/// because a connection or caller disappeared.
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

enum V2DirectAuthorizationReceiptError: Error, Equatable, Sendable {
    case invalidAttempt, transactionRequired, identityConflict, ownerChanged, missingCompletion, attemptAborted
}

enum V2DirectAuthorizationDisposition: String, Codable, Sendable {
    case accepted, denied, aborted
}

struct V2DirectAuthorizationReceipt: Equatable, Sendable {
    let disposition: V2DirectAuthorizationDisposition
    let eventID: UUID?
}

/// Room-owned terminal proof. This primitive is not yet the control grant
/// coordinator: callers must create the durable control obligation before using
/// it and must keep the owner transaction open through the message write.
struct PostgresV2DirectAuthorizationReceiptStore: Sendable {
    let schema: String

    init(schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.schema = schema
    }

    /// Nil permits this exact attempt to proceed in this transaction. A terminal
    /// receipt is replayed without reopening authorization or updating its time.
    func prepare(_ attempt: V2DirectAuthorizationAttempt, transaction: any Database) async throws -> V2DirectAuthorizationReceipt? {
        if let receipt = try await checkAttempt(attempt, transaction: transaction) { return receipt }
        let sql = try transactionSQL(transaction)
        try await validateOwner(attempt, sql: sql)
        return nil
    }

    /// Only the operation lock: callers that also lock a forward source must
    /// retain their existing sorted room-lock order before validating the owner.
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
        // Changing generations must never change the immutable command. A new
        // generation may use a new owner after migration, but not new content.
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

    /// Read an immutable committed proof after the complete owner operation has
    /// returned. Absence is not an abort and must leave the control grant held.
    func committedReceipt(_ attempt: V2DirectAuthorizationAttempt, database: any Database) async throws -> V2DirectAuthorizationReceipt? {
        try attempt.validate()
        guard let sql = database as? any SQLDatabase else { throw V2DirectAuthorizationReceiptError.invalidAttempt }
        guard let row = try await sql.raw("""
            SELECT * FROM \(unsafeRaw: schema).direct_authorization_receipts
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID) AND generation = \(bind: attempt.generation)
            """).first(decoding: ReceiptRow.self) else { return nil }
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

    /// Called in the message transaction after its durable accepted/denied
    /// result. It cannot manufacture a committed proof from callback success.
    func finish(_ attempt: V2DirectAuthorizationAttempt, now: Date, transaction: any Database) async throws -> V2DirectAuthorizationReceipt {
        guard let receipt = try await finishIfPresent(attempt, now: now, transaction: transaction) else {
            throw V2DirectAuthorizationReceiptError.missingCompletion
        }
        return receipt
    }

    /// Admission misses have no durable message result. Keep the control grant
    /// held for retry/recovery instead of inventing a business denial.
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

    /// Revocation uses the SAME operation lock as message acceptance. If no
    /// committed result exists, the durable aborted row bars a late callback.
    /// Absence alone is never returned as cancellation proof.
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

/// Keep this key identical to the typed-array/JSON batch statement key.
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
