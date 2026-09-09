import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2ForwardImportPendingReason: Equatable, Sendable {
    case media
    case admission
    case finalization
}

public enum V2ForwardImportOutcome: Equatable, Sendable {
    case accepted(messageID: MessageID, roomSequence: UInt64)
    case rejected(code: String)
    case pending(V2ForwardImportPendingReason)
}

public enum V2ForwardInboxError: Error, Equatable, Sendable {
    case ownerChanged
    case targetNotFound
    case idempotencyConflict
    case capacityExceeded
    case corruptPersistenceState
}

/// Receives only server-created exports from the trusted owner transport. A
/// payload checksum alone is never authority for a client-supplied envelope.
/// Receiving is durable, but does not grant target membership or acceptance.
public struct PostgresV2ForwardInboxStore: Sendable {
    private let database: any Database
    private let maximumPendingPerRoom: Int

    public init(database: any Database, maximumPendingPerRoom: Int = 1_024) {
        precondition(maximumPendingPerRoom > 0)
        self.database = database
        self.maximumPendingPerRoom = maximumPendingPerRoom
    }

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

    public func status(exportID: UUID) async throws -> V2ForwardImportOutcome? {
        guard let sql = database as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        guard let row = try await sql.raw("""
            SELECT export_id, payload, payload_digest, state, result_message_id, result_room_sequence, error_code
            FROM im_v2.message_forward_inbox WHERE export_id = \(bind: exportID)
            """).first(decoding: ForwardInboxRow.self) else { return nil }
        return try row.outcome
    }

    /// Accepted-but-unfinalized messages deliberately have no terminal receipt.
    /// Terminal rows are immutable, so a later epoch or membership change does
    /// not revoke the evidence of the already completed target operation.
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

/// Constructed from a locked inbox and its immutable ready media mapping. It
/// never arrives on the ordinary SendMessage API or comes from attribution.
struct ForwardInboxAuthorization: Sendable {
    let export: V2ForwardExport
    let mediaIDs: [UUID]

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

func v2LockForwardInbox(exportID: UUID, sql: any SQLDatabase) async throws -> ForwardInboxRow {
    guard let row = try await sql.raw("""
        SELECT export_id, payload, payload_digest, state, result_message_id, result_room_sequence, error_code
        FROM im_v2.message_forward_inbox WHERE export_id = \(bind: exportID) FOR UPDATE
        """).first(decoding: ForwardInboxRow.self) else { throw V2ForwardInboxError.corruptPersistenceState }
    return row
}

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

func v2RejectForwardInbox(_ row: ForwardInboxRow, code: String, now: Date, sql: any SQLDatabase) async throws -> V2ForwardImportOutcome {
    guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
    guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
    try await sql.raw("""
        UPDATE im_v2.message_forward_inbox SET state = 'rejected', error_code = \(bind: code), completed_at = \(bind: now)
        WHERE export_id = \(bind: row.exportID) AND state = 'pending'
        """).run()
    return .rejected(code: code)
}

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
