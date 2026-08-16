import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// A receipt does not acknowledge transport delivery. This transaction only
/// advances explicit human-viewing state and records its stable operation ID.
public struct PostgresV2ReadReceiptStore: V2ReadReceiptStore {
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing

    public init(database: any Database, shadowForwarder: any V2UserShardProjectionShadowing) {
        self.database = database
        self.shadowForwarder = shadowForwarder
    }
    public func record(command: V2RecordReadReceiptCommand, now: Date) async throws -> V2ReadReceiptOutcome {
        let result: (outcome: V2ReadReceiptOutcome, projectionRecipient: UserID?) = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let roomID = try receiptUUID(command.roomID), userID = try receiptUUID(command.actorUserID), operationID = try receiptUUID(command.operationID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: userID.uuidString + ":" + operationID.uuidString), 0))").run()
            if let prior = try await sql.raw("SELECT room_id, requested_room_sequence, resulting_room_sequence, recorded_at, projection_recipient_user_id FROM im_v2.read_receipt_operations WHERE user_id = \(bind: userID) AND operation_id = \(bind: operationID)").first(decoding: ReceiptOperationRow.self) {
                guard prior.roomID == roomID, prior.requestedSequence == Int64(command.readThroughRoomSequence) else { return (.idempotencyConflict, nil) }
                return (.idempotent(try prior.result(userID: command.actorUserID)), try prior.projectionRecipientUserID.map { try .init($0.uuidString) })
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
            let receipt = try V2ReadReceipt(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: receiptUnsigned(resulting), recordedAt: now)
            let recipient = resulting > current
                ? try await appendDirectProjectionIfVisible(
                    roomID: roomID, readerID: userID, command: command, receipt: receipt, sourceEventID: operationID, now: now, sql: sql
                )
                : nil
            try await sql.raw("INSERT INTO im_v2.read_receipt_operations (user_id, operation_id, room_id, requested_room_sequence, resulting_room_sequence, recorded_at, projection_recipient_user_id) VALUES (\(bind: userID), \(bind: operationID), \(bind: roomID), \(bind: requested), \(bind: resulting), \(bind: now), \(bind: recipient.flatMap { UUID(uuidString: $0.rawValue) }))").run()
            return (.recorded(receipt), recipient)
        }
        if let recipient = result.projectionRecipient {
            _ = try await shadowForwarder.shadowIfForwarding(
                userID: recipient,
                sourceEventID: try .init(command.operationID.rawValue),
                projectionKinds: ["direct_read_receipt"]
            )
        }
        return result.outcome
    }

    public func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) async throws -> V2SetReadReceiptPreferencesOutcome {
        let result: (outcome: V2SetReadReceiptPreferencesOutcome, shadowRequests: [ReceiptProjectionShadowRequest]) = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let actorID = try receiptUUID(command.actorUserID)
            let operationID = try receiptUUID(command.operationID)
            let lockKey = "v2-read-receipt-preference:" + actorID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let prior = try await sql.raw("SELECT allows_direct_read_receipts, allows_group_read_receipts, updated_at FROM im_v2.read_receipt_preference_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: ReceiptPreferenceOperationRow.self) {
                guard prior.allowsDirect == command.allowsDirectReadReceipts, prior.allowsGroup == command.allowsGroupReadReceipts else { return (.idempotencyConflict, []) }
                let requests = [try ReceiptProjectionShadowRequest(
                    userID: command.actorUserID,
                    sourceEventID: operationID,
                    projectionKinds: ["read_receipt_preferences"]
                )]
                return (.idempotent(try prior.preferences()), requests)
            }
            let priorDirect = try await sql.raw("SELECT allows_direct_read_receipts FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: actorID) FOR UPDATE").first(decoding: ReceiptPreferenceStateRow.self)?.allowsDirect ?? true
            try await sql.raw("INSERT INTO im_v2.user_read_receipt_preferences (user_id, allows_direct_read_receipts, allows_group_read_receipts, updated_at) VALUES (\(bind: actorID), \(bind: command.allowsDirectReadReceipts), \(bind: command.allowsGroupReadReceipts), \(bind: now)) ON CONFLICT (user_id) DO UPDATE SET allows_direct_read_receipts = EXCLUDED.allows_direct_read_receipts, allows_group_read_receipts = EXCLUDED.allows_group_read_receipts, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.read_receipt_preference_operations (actor_user_id, operation_id, allows_direct_read_receipts, allows_group_read_receipts, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: command.allowsDirectReadReceipts), \(bind: command.allowsGroupReadReceipts), \(bind: now))").run()
            try await appendPreferenceProjection(recipientID: actorID, sourceEventID: operationID, preferences: .init(allowsDirectReadReceipts: command.allowsDirectReadReceipts, allowsGroupReadReceipts: command.allowsGroupReadReceipts, updatedAt: now), now: now, sql: sql)
            let shadowRequests = [try ReceiptProjectionShadowRequest(
                userID: command.actorUserID,
                sourceEventID: operationID,
                projectionKinds: ["read_receipt_preferences"]
            )]
            if priorDirect && !command.allowsDirectReadReceipts {
                // A direct-room graph is unbounded. Commit only a durable
                // propagation intent here; a cursor-bounded worker emits and
                // mirrors the reciprocal tombstones outside request latency.
                try await sql.raw("INSERT INTO im_v2.read_receipt_preference_propagation_outbox (actor_user_id, operation_id, recorded_at, created_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: now), \(bind: now))").run()
            }
            return (.updated(.init(allowsDirectReadReceipts: command.allowsDirectReadReceipts, allowsGroupReadReceipts: command.allowsGroupReadReceipts, updatedAt: now)), shadowRequests)
        }
        for request in result.shadowRequests {
            _ = try await shadowForwarder.shadowIfForwarding(
                userID: request.userID,
                sourceEventID: request.sourceEventID,
                projectionKinds: request.projectionKinds
            )
        }
        return result.outcome
    }

    public func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        guard (1 ... 100).contains(pageSize) else { throw V2ReadReceiptStoreError.invalidRequest }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let room = try receiptUUID(roomID)
            let message = try receiptUUID(messageID)
            let actor = try receiptUUID(actorUserID)
            guard let context = try await sql.raw("""
                SELECT message.room_sequence,
                       event.committed_membership_revision,
                       room.membership_revision AS current_membership_revision
                FROM im_v2.messages AS message
                JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                JOIN im_v2.room_events AS event
                  ON event.room_id = message.room_id
                 AND event.room_sequence = message.room_sequence
                 AND event.event_type = 'message.accepted'
                WHERE message.message_id = \(bind: message)
                  AND message.room_id = \(bind: room)
                  AND room.room_kind = 'group'
                FOR SHARE OF room
                """).first(decoding: ReceiptReaderContextRow.self)
            else { throw V2ReadReceiptStoreError.messageNotFound }
            guard context.messageRoomSequence > 0,
                  context.committedMembershipRevision >= 0,
                  context.currentMembershipRevision >= 0
            else { throw V2ReadReceiptStoreError.corruptPersistenceState }

            let membership = try await sql.raw("""
                SELECT 1 AS exists
                WHERE EXISTS (
                    SELECT 1 FROM im_v2.room_memberships AS historical
                    WHERE historical.room_id = \(bind: room)
                      AND historical.user_id = \(bind: actor)
                      AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                      AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
                )
                  AND EXISTS (
                    SELECT 1 FROM im_v2.room_memberships AS current
                    WHERE current.room_id = \(bind: room)
                      AND current.user_id = \(bind: actor)
                      AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                      AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
                )
                  AND EXISTS (
                    SELECT 1 FROM im_v2.public_user_profiles AS profile
                    WHERE profile.user_id = \(bind: actor)
                      AND profile.state = 'active'
                      AND NOT EXISTS (
                          SELECT 1 FROM im_v2.account_disables AS disabled
                          WHERE disabled.user_id = profile.user_id
                      )
                )
                """).first(decoding: ReceiptExistsRow.self)
            guard membership != nil else { throw V2ReadReceiptStoreError.actorNotMember }
            let cursorValue = try cursor.map(receiptCursor)
            if let cursorValue {
                guard cursorValue.version == 3,
                      cursorValue.roomID == room,
                      cursorValue.messageID == message,
                      cursorValue.actorUserID == actor,
                      cursorValue.messageRoomSequence == context.messageRoomSequence,
                      cursorValue.committedMembershipRevision == context.committedMembershipRevision
                else { throw V2ReadReceiptStoreError.invalidRequest }
            }
            let rows: [ReceiptReaderRow]
            if let cursorValue {
                rows = try await readReceiptReaders(
                    roomID: room,
                    actorUserID: actor,
                    context: context,
                    after: cursorValue,
                    limit: pageSize + 1,
                    sql: sql
                )
            } else {
                rows = try await readReceiptReaders(
                    roomID: room,
                    actorUserID: actor,
                    context: context,
                    after: nil,
                    limit: pageSize + 1,
                    sql: sql
                )
            }
            let pageRows = Array(rows.prefix(pageSize))
            let readers = try pageRows.map { row in
                let userID = try UserID(row.userID.uuidString)
                guard let accountKind = V2AccountKind(rawValue: row.accountKind) else {
                    throw V2ReadReceiptStoreError.corruptPersistenceState
                }
                let identity = try V2PublicIdentity(
                    userID: userID,
                    handle: .init(row.publicHandle),
                    displayName: row.displayName,
                    accountKind: accountKind
                )
                return V2ReadReceiptReader(userID: userID, publicIdentity: identity)
            }
            let next = rows.count > pageSize ? try receiptCursorString(
                roomID: room,
                messageID: message,
                actorUserID: actor,
                context: context,
                readThroughRoomSequence: pageRows.last!.readThroughRoomSequence,
                userID: pageRows.last!.userID
            ) : nil
            return try .init(
                roomID: roomID,
                messageID: messageID,
                readers: readers,
                nextCursor: next
            )
        }
    }

    private func readReceiptReaders(
        roomID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow,
        after cursor: ReceiptCursor?,
        limit: Int,
        sql: any SQLDatabase
    ) async throws -> [ReceiptReaderRow] {
        if let cursor {
            return try await sql.raw("""
                SELECT receipt.user_id,
                       receipt.read_through_room_sequence,
                       profile.public_handle,
                       profile.display_name,
                       profile.account_kind
                FROM im_v2.room_read_receipts AS receipt
                LEFT JOIN im_v2.user_read_receipt_preferences AS preference
                  ON preference.user_id = receipt.user_id
                JOIN im_v2.public_user_profiles AS profile
                  ON profile.user_id = receipt.user_id
                 AND profile.state = 'active'
                WHERE receipt.room_id = \(bind: roomID)
                  AND receipt.user_id <> \(bind: actorUserID)
                  AND receipt.read_through_room_sequence >= \(bind: context.messageRoomSequence)
                  AND COALESCE(preference.allows_group_read_receipts, TRUE)
                  AND NOT EXISTS (
                      SELECT 1 FROM im_v2.account_disables AS disabled
                      WHERE disabled.user_id = receipt.user_id
                  )
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS historical
                      WHERE historical.room_id = receipt.room_id
                        AND historical.user_id = receipt.user_id
                        AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                        AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
                  )
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS current
                      WHERE current.room_id = receipt.room_id
                        AND current.user_id = receipt.user_id
                        AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                        AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
                  )
                  AND (receipt.read_through_room_sequence, receipt.user_id) < (
                      \(bind: cursor.readThroughRoomSequence), \(bind: cursor.userID)
                  )
                ORDER BY receipt.read_through_room_sequence DESC, receipt.user_id DESC
                LIMIT \(bind: limit)
                """).all(decoding: ReceiptReaderRow.self)
        }
        return try await sql.raw("""
            SELECT receipt.user_id,
                   receipt.read_through_room_sequence,
                   profile.public_handle,
                   profile.display_name,
                   profile.account_kind
            FROM im_v2.room_read_receipts AS receipt
            LEFT JOIN im_v2.user_read_receipt_preferences AS preference
              ON preference.user_id = receipt.user_id
            JOIN im_v2.public_user_profiles AS profile
              ON profile.user_id = receipt.user_id
             AND profile.state = 'active'
            WHERE receipt.room_id = \(bind: roomID)
              AND receipt.user_id <> \(bind: actorUserID)
              AND receipt.read_through_room_sequence >= \(bind: context.messageRoomSequence)
              AND COALESCE(preference.allows_group_read_receipts, TRUE)
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.account_disables AS disabled
                  WHERE disabled.user_id = receipt.user_id
              )
              AND EXISTS (
                  SELECT 1 FROM im_v2.room_memberships AS historical
                  WHERE historical.room_id = receipt.room_id
                    AND historical.user_id = receipt.user_id
                    AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                    AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
              )
              AND EXISTS (
                  SELECT 1 FROM im_v2.room_memberships AS current
                  WHERE current.room_id = receipt.room_id
                    AND current.user_id = receipt.user_id
                    AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                    AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
              )
            ORDER BY receipt.read_through_room_sequence DESC, receipt.user_id DESC
            LIMIT \(bind: limit)
            """).all(decoding: ReceiptReaderRow.self)
    }

    private func appendDirectProjectionIfVisible(roomID: UUID, readerID: UUID, command: V2RecordReadReceiptCommand, receipt: V2ReadReceipt, sourceEventID: UUID, now: Date, sql: any SQLDatabase) async throws -> UserID? {
        guard let peer = try await sql.raw("SELECT CASE WHEN lower_user_id = \(bind: readerID) THEN higher_user_id ELSE lower_user_id END AS user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: roomID) AND (lower_user_id = \(bind: readerID) OR higher_user_id = \(bind: readerID))").first(decoding: ReceiptPeerRow.self) else { return nil }
        let preferences = try await sql.raw("SELECT user_id, allows_direct_read_receipts FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: readerID) OR user_id = \(bind: peer.userID)").all(decoding: ReceiptPreferenceUserRow.self)
        let allowsReader = preferences.first(where: { $0.userID == readerID })?.allowsDirect ?? true
        let allowsPeer = preferences.first(where: { $0.userID == peer.userID })?.allowsDirect ?? true
        guard allowsReader && allowsPeer else { return nil }
        try await appendDirectProjection(recipientID: peer.userID, sourceEventID: sourceEventID, projection: .init(roomID: command.roomID, readerUserID: command.actorUserID, readThroughRoomSequence: receipt.readThroughRoomSequence, recordedAt: receipt.recordedAt, isVisible: true), now: now, sql: sql)
        return try .init(peer.userID.uuidString)
    }

    private func appendDirectProjection(recipientID: UUID, sourceEventID: UUID, projection: V2DirectReadReceiptProjection, now: Date, sql: any SQLDatabase) async throws {
        guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: recipientID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 RETURNING next_sequence").first(decoding: ReceiptSyncSequenceRow.self) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: recipientID), \(bind: sequence.nextSequence), \(bind: sourceEventID), 'direct_read_receipt', jsonb_build_object('room_id', \(bind: projection.roomID.rawValue), 'reader_user_id', \(bind: projection.readerUserID.rawValue), 'read_through_room_sequence', \(bind: try receiptSigned(projection.readThroughRoomSequence)), 'recorded_at_ms', \(bind: Int64(projection.recordedAt.timeIntervalSince1970 * 1_000)), 'is_visible', \(bind: projection.isVisible)), \(bind: now))").run()
    }

    private func appendPreferenceProjection(recipientID: UUID, sourceEventID: UUID, preferences: V2ReadReceiptPreferences, now: Date, sql: any SQLDatabase) async throws {
        guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: recipientID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 RETURNING next_sequence").first(decoding: ReceiptSyncSequenceRow.self) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: recipientID), \(bind: sequence.nextSequence), \(bind: sourceEventID), 'read_receipt_preferences', jsonb_build_object('allows_direct_read_receipts', \(bind: preferences.allowsDirectReadReceipts), 'allows_group_read_receipts', \(bind: preferences.allowsGroupReadReceipts), 'updated_at_ms', \(bind: Int64(preferences.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now))").run()
    }

}

private struct ReceiptRoomRow: Decodable { let roomSequence: Int64; let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case roomSequence = "room_sequence", membershipRevision = "membership_revision" } }
private struct ReceiptExistsRow: Decodable { let exists: Int }
private struct ReceiptStateRow: Decodable { let sequence: Int64; enum CodingKeys: String, CodingKey { case sequence = "read_through_room_sequence" } }
private struct ReceiptOperationRow: Decodable { let roomID: UUID; let requestedSequence: Int64; let resultingSequence: Int64; let recordedAt: Date; let projectionRecipientUserID: UUID?; enum CodingKeys: String, CodingKey { case roomID = "room_id", requestedSequence = "requested_room_sequence", resultingSequence = "resulting_room_sequence", recordedAt = "recorded_at", projectionRecipientUserID = "projection_recipient_user_id" }; func result(userID: UserID) throws -> V2ReadReceipt { try .init(roomID: .init(roomID.uuidString), userID: userID, readThroughRoomSequence: receiptUnsigned(resultingSequence), recordedAt: recordedAt) } }
private struct ReceiptPeerRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "user_id" } }
private struct ReceiptPreferenceUserRow: Decodable { let userID: UUID; let allowsDirect: Bool; enum CodingKeys: String, CodingKey { case userID = "user_id", allowsDirect = "allows_direct_read_receipts" } }
private struct ReceiptPreferenceStateRow: Decodable { let allowsDirect: Bool; enum CodingKeys: String, CodingKey { case allowsDirect = "allows_direct_read_receipts" } }
private struct ReceiptPreferenceOperationRow: Decodable { let allowsDirect: Bool; let allowsGroup: Bool; let updatedAt: Date; enum CodingKeys: String, CodingKey { case allowsDirect = "allows_direct_read_receipts", allowsGroup = "allows_group_read_receipts", updatedAt = "updated_at" }; func preferences() throws -> V2ReadReceiptPreferences { .init(allowsDirectReadReceipts: allowsDirect, allowsGroupReadReceipts: allowsGroup, updatedAt: updatedAt) } }
private struct ReceiptSyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private struct ReceiptReaderContextRow: Decodable {
    let messageRoomSequence: Int64
    let committedMembershipRevision: Int64
    let currentMembershipRevision: Int64
    enum CodingKeys: String, CodingKey {
        case messageRoomSequence = "room_sequence"
        case committedMembershipRevision = "committed_membership_revision"
        case currentMembershipRevision = "current_membership_revision"
    }
}
private struct ReceiptReaderRow: Decodable {
    let userID: UUID
    let readThroughRoomSequence: Int64
    let publicHandle: String
    let displayName: String
    let accountKind: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case readThroughRoomSequence = "read_through_room_sequence"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
    }
}
private struct ReceiptCursor: Codable {
    let version: Int
    let roomID: UUID
    let messageID: UUID
    let actorUserID: UUID
    let messageRoomSequence: Int64
    let committedMembershipRevision: Int64
    let readThroughRoomSequence: Int64
    let userID: UUID
}
private struct ReceiptProjectionShadowRequest: Sendable {
    let userID: UserID
    let sourceEventID: EventID
    let projectionKinds: Set<String>

    init(userID: UserID, sourceEventID: UUID, projectionKinds: Set<String>) throws {
        self.userID = userID
        self.sourceEventID = try .init(sourceEventID.uuidString)
        self.projectionKinds = projectionKinds
    }
}

/// UUIDv5-shaped, SHA-256-derived IDs keep one preference operation stable
/// across retries while giving each direct room its own projection identity.
/// The database's non-fan-out uniqueness fence can therefore remain strict.
func receiptTombstoneSourceEventID(operationID: UUID, roomID: UUID) -> UUID {
    let input = "im-v2:read-receipt-tombstone:\(operationID.uuidString.lowercased()):\(roomID.uuidString.lowercased())"
    var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
private func receiptCursor(_ value: String) throws -> ReceiptCursor { guard let data = Data(base64Encoded: value), let result = try? JSONDecoder().decode(ReceiptCursor.self, from: data) else { throw V2ReadReceiptStoreError.invalidRequest }; return result }
private func receiptCursorString(
    roomID: UUID,
    messageID: UUID,
    actorUserID: UUID,
    context: ReceiptReaderContextRow,
    readThroughRoomSequence: Int64,
    userID: UUID
) throws -> String {
    let encoded = try JSONEncoder().encode(ReceiptCursor(
        version: 3,
        roomID: roomID,
        messageID: messageID,
        actorUserID: actorUserID,
        messageRoomSequence: context.messageRoomSequence,
        committedMembershipRevision: context.committedMembershipRevision,
        readThroughRoomSequence: readThroughRoomSequence,
        userID: userID
    ))
    return encoded.base64EncodedString()
}
private func receiptUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: id.rawValue) else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return value }
private func receiptSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return Int64(value) }
private func receiptUnsigned(_ value: Int64) throws -> UInt64 { guard value > 0 else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return UInt64(value) }
