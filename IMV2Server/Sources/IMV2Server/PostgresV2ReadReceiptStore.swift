import Crypto
import Fluent
import Foundation
import IMV2Core
import PostgresNIO
import SQLKit

/// A receipt does not acknowledge transport delivery. This transaction only
/// advances explicit human-viewing state and records its stable operation ID.
public struct PostgresV2ReadReceiptStore:
    V2GroupReadReceiptOwnerStore,
    V2ReadReceiptControlStore,
    V2ReadReceiptBatchStore
{
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
            let requested = try receiptSigned(command.readThroughRoomSequence)
            if let groupResult = try await recordGroupOrReplay(
                roomID: roomID,
                userID: userID,
                operationID: operationID,
                requested: requested,
                command: command,
                now: now,
                sql: sql
            ) {
                return groupResult
            }
            guard let room = try await sql.raw("SELECT room_sequence, membership_revision FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReceiptRoomRow.self) else { throw V2ReadReceiptStoreError.roomNotFound }
            guard room.roomSequence >= 0, Int64(command.readThroughRoomSequence) <= room.roomSequence else { throw V2ReadReceiptStoreError.roomSequenceNotFound }
            let member = try await sql.raw("SELECT 1 AS exists FROM im_v2.room_memberships WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID) AND joined_revision <= \(bind: room.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))").first(decoding: ReceiptExistsRow.self)
            guard member != nil else { throw V2ReadReceiptStoreError.actorNotMember }
            let current = try await sql.raw("SELECT read_through_room_sequence FROM im_v2.room_read_receipts WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID) FOR UPDATE").first(decoding: ReceiptStateRow.self)?.sequence ?? 0
            let resulting = max(current, requested)
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

    /// Executes only the room-owned group receipt graph. A direct room is
    /// reported to the routed facade instead of being handled here because
    /// direct receipts also produce a user-owned reciprocal projection.
    public func recordGroup(
        command: V2RecordReadReceiptCommand,
        now: Date
    ) async throws -> V2GroupReadReceiptRecordingAttempt {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
            let roomID = try receiptUUID(command.roomID)
            let userID = try receiptUUID(command.actorUserID)
            let operationID = try receiptUUID(command.operationID)
            let requested = try receiptSigned(command.readThroughRoomSequence)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: userID.uuidString + ":" + operationID.uuidString), 0))").run()
            if let result = try await recordGroupOrReplay(
                roomID: roomID,
                userID: userID,
                operationID: operationID,
                requested: requested,
                command: command,
                now: now,
                sql: sql,
                allowDirectReplay: false
            ) {
                return .handled(result.outcome)
            }

            // This query is intentionally off the successful hot path. It
            // distinguishes a direct-room fallback from precise group errors
            // without adding a pre-read to every valid receipt.
            guard let diagnostic = try await sql.raw("""
                SELECT room.room_kind,
                       room.room_sequence,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.room_memberships AS membership
                           WHERE membership.room_id = room.room_id
                             AND membership.user_id = \(bind: userID)
                             AND membership.joined_revision <= room.membership_revision
                             AND (
                                 membership.left_revision IS NULL
                                 OR membership.left_revision > room.membership_revision
                             )
                       ) AS actor_is_member
                FROM im_v2.rooms AS room
                WHERE room.room_id = \(bind: roomID)
                """).first(decoding: ReceiptGroupDiagnosticRow.self)
            else { throw V2ReadReceiptStoreError.roomNotFound }
            guard diagnostic.roomKind == "group" else { return .notGroup }
            guard diagnostic.roomSequence >= requested else {
                throw V2ReadReceiptStoreError.roomSequenceNotFound
            }
            guard diagnostic.actorIsMember else {
                throw V2ReadReceiptStoreError.actorNotMember
            }
            throw V2ReadReceiptStoreError.corruptPersistenceState
        }
    }

    public func recordBatch(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2ReadReceiptRecordResult] {
        let groupResults = try await recordGroups(requests)
        var results: [V2ReadReceiptRecordResult] = []
        results.reserveCapacity(requests.count)
        for (index, result) in groupResults.enumerated() {
            switch result {
            case .success(.handled(let outcome)):
                results.append(.success(outcome))
            case .success(.notGroup):
                do {
                    results.append(.success(try await record(
                        command: requests[index].command,
                        now: requests[index].now
                    )))
                } catch let error as V2ReadReceiptStoreError {
                    results.append(.failure(error))
                }
            case .failure(let error):
                results.append(.failure(error))
            }
        }
        return results
    }

    /// Set-based group receipt transaction. One ordered advisory-lock graph
    /// fences every operation and `(room,user)` cursor before a single SQL
    /// statement validates membership, advances monotonic cursors and writes
    /// every idempotency record. Domain-invalid rows are returned separately;
    /// they never roll back valid rows in the same batch.
    public func recordGroups(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2GroupReadReceiptBatchResult] {
        guard !requests.isEmpty, requests.count <= 128 else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        let inputs = try requests.enumerated().map { index, request in
            try GroupReceiptBatchInput(ordinal: index, request: request)
        }
        let operationKeys = Set(inputs.map { GroupReceiptOperationKey(
            userID: $0.userID,
            operationID: $0.operationID
        ) })
        guard operationKeys.count == inputs.count else {
            // The process batcher keeps concurrent retries in different
            // waves. Rejecting an invalid direct caller here avoids duplicate
            // primary-key rows and preserves scalar replay semantics.
            throw V2ReadReceiptStoreError.invalidRequest
        }
        let rows = try await database.transaction { transaction in
            guard let postgres = transaction as? any PostgresDatabase else {
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
            let statement = try GroupReceiptBatchStatement(inputs: inputs)
            return try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let lockRows = try await connection.execute(
                        GroupReceiptBatchLockStatement(inputs: inputs),
                        logger: connection.logger
                    )
                    var acquiredLockCount: Int64?
                    for try await row in lockRows { acquiredLockCount = row }
                    guard let acquiredLockCount, acquiredLockCount > 0 else {
                        throw V2ReadReceiptStoreError.corruptPersistenceState
                    }
                    var decoded: [GroupReceiptBatchRow] = []
                    decoded.reserveCapacity(inputs.count)
                    let stream = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    for try await row in stream { decoded.append(row) }
                    return decoded
                }
            }.get()
        }
        guard rows.count == inputs.count,
              rows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2ReadReceiptStoreError.corruptPersistenceState }

        return try zip(requests, rows).map { request, row in
            switch row.status {
            case "recorded", "idempotent":
                guard let resulting = row.resultingSequence,
                      let recordedAt = row.recordedAt
                else { throw V2ReadReceiptStoreError.corruptPersistenceState }
                let receipt = try V2ReadReceipt(
                    roomID: request.command.roomID,
                    userID: request.command.actorUserID,
                    readThroughRoomSequence: receiptUnsigned(resulting),
                    recordedAt: recordedAt
                )
                let outcome: V2ReadReceiptOutcome = row.status == "recorded"
                    ? .recorded(receipt)
                    : .idempotent(receipt)
                return .success(.handled(outcome))
            case "idempotency_conflict":
                return .success(.handled(.idempotencyConflict))
            case "not_group":
                return .success(.notGroup)
            case "room_not_found":
                return .failure(.roomNotFound)
            case "room_sequence_not_found":
                return .failure(.roomSequenceNotFound)
            case "actor_not_member":
                return .failure(.actorNotMember)
            default:
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
        }
    }

    /// Group read state is room-owned, monotonic state. It does not advance
    /// `rooms.room_sequence`, so locking the room row only serializes receipts
    /// behind unrelated message appends and membership changes. The statement
    /// snapshot is a valid linearization point for the room/membership check;
    /// the receipt UPSERT itself serializes concurrent cursors for one user.
    ///
    /// The operation advisory lock is acquired by the caller in a preceding
    /// statement. Consequently an in-flight retry has committed before this
    /// statement takes its READ COMMITTED snapshot, allowing the same query to
    /// return the stable prior result without a speculative operation row.
    /// A new direct-room receipt returns nil and deliberately falls back to the
    /// existing projection-producing transaction below.
    private func recordGroupOrReplay(
        roomID: UUID,
        userID: UUID,
        operationID: UUID,
        requested: Int64,
        command: V2RecordReadReceiptCommand,
        now: Date,
        sql: any SQLDatabase,
        allowDirectReplay: Bool = true
    ) async throws -> (outcome: V2ReadReceiptOutcome, projectionRecipient: UserID?)? {
        guard let row = try await sql.raw("""
            WITH prior AS MATERIALIZED (
                SELECT room_id,
                       requested_room_sequence,
                       resulting_room_sequence,
                       recorded_at,
                       projection_recipient_user_id
                FROM im_v2.read_receipt_operations AS prior_operation
                WHERE prior_operation.user_id = \(bind: userID)
                  AND prior_operation.operation_id = \(bind: operationID)
                  AND (
                      \(bind: allowDirectReplay)
                      OR EXISTS (
                          SELECT 1
                          FROM im_v2.rooms AS prior_room
                          WHERE prior_room.room_id = prior_operation.room_id
                            AND prior_room.room_kind = 'group'
                      )
                  )
            ),
            eligible AS MATERIALIZED (
                SELECT room.room_id
                FROM im_v2.rooms AS room
                WHERE room.room_id = \(bind: roomID)
                  AND room.room_kind = 'group'
                  AND room.room_sequence >= \(bind: requested)
                  AND NOT EXISTS (SELECT 1 FROM prior)
                  AND EXISTS (
                      SELECT 1
                      FROM im_v2.room_memberships AS membership
                      WHERE membership.room_id = room.room_id
                        AND membership.user_id = \(bind: userID)
                        AND membership.joined_revision <= room.membership_revision
                        AND (
                            membership.left_revision IS NULL
                            OR membership.left_revision > room.membership_revision
                        )
                  )
            ),
            advanced AS (
                INSERT INTO im_v2.room_read_receipts
                    (room_id, user_id, read_through_room_sequence, updated_at)
                SELECT room_id, \(bind: userID), \(bind: requested), \(bind: now)
                FROM eligible
                ON CONFLICT (room_id, user_id) DO UPDATE
                SET read_through_room_sequence = GREATEST(
                        im_v2.room_read_receipts.read_through_room_sequence,
                        EXCLUDED.read_through_room_sequence
                    ),
                    updated_at = CASE
                        WHEN EXCLUDED.read_through_room_sequence
                            > im_v2.room_read_receipts.read_through_room_sequence
                        THEN EXCLUDED.updated_at
                        ELSE im_v2.room_read_receipts.updated_at
                    END
                RETURNING read_through_room_sequence
            ),
            recorded AS (
                INSERT INTO im_v2.read_receipt_operations
                    (user_id, operation_id, room_id,
                     requested_room_sequence, resulting_room_sequence,
                     recorded_at, projection_recipient_user_id)
                SELECT \(bind: userID), \(bind: operationID), \(bind: roomID),
                       \(bind: requested), advanced.read_through_room_sequence,
                       \(bind: now), NULL
                FROM advanced
                RETURNING room_id,
                          requested_room_sequence,
                          resulting_room_sequence,
                          recorded_at,
                          projection_recipient_user_id
            )
            SELECT 'prior' AS source,
                   room_id,
                   requested_room_sequence,
                   resulting_room_sequence,
                   recorded_at,
                   projection_recipient_user_id
            FROM prior
            UNION ALL
            SELECT 'recorded' AS source,
                   room_id,
                   requested_room_sequence,
                   resulting_room_sequence,
                   recorded_at,
                   projection_recipient_user_id
            FROM recorded
            LIMIT 1
            """).first(decoding: ReceiptGroupRecordRow.self) else { return nil }

        let projectionRecipient = try row.projectionRecipientUserID.map {
            try UserID($0.uuidString)
        }
        guard row.roomID == roomID, row.requestedSequence == requested else {
            return (.idempotencyConflict, nil)
        }
        let receipt = try V2ReadReceipt(
            roomID: command.roomID,
            userID: command.actorUserID,
            readThroughRoomSequence: receiptUnsigned(row.resultingSequence),
            recordedAt: row.recordedAt
        )
        switch row.source {
        case "prior": return (.idempotent(receipt), projectionRecipient)
        case "recorded": return (.recorded(receipt), projectionRecipient)
        default: throw V2ReadReceiptStoreError.corruptPersistenceState
        }
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

    public func readerCandidates(
        roomID: RoomID,
        messageID: MessageID,
        actorUserID: UserID,
        cursor: String?,
        pageSize: Int
    ) async throws -> V2GroupReadReceiptReaderCandidatePage {
        guard (1 ... 100).contains(pageSize) else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
            let room = try receiptUUID(roomID)
            let message = try receiptUUID(messageID)
            let actor = try receiptUUID(actorUserID)
            let context = try await receiptReaderContext(
                roomID: room, messageID: message, sql: sql
            )
            guard try await receiptActorIsMember(
                roomID: room, actorUserID: actor, context: context, sql: sql
            ) else { throw V2ReadReceiptStoreError.actorNotMember }
            let cursorValue = try cursor.map(receiptCursor)
            try validateReceiptCursor(
                cursorValue,
                roomID: room,
                messageID: message,
                actorUserID: actor,
                context: context
            )
            let rows = try await readReceiptCandidateRows(
                roomID: room,
                actorUserID: actor,
                context: context,
                after: cursorValue,
                limit: pageSize + 1,
                sql: sql
            )
            let pageRows = Array(rows.prefix(pageSize))
            let candidates = try pageRows.map {
                try V2GroupReadReceiptReaderCandidate(
                    userID: .init($0.userID.uuidString),
                    readThroughRoomSequence: receiptUnsigned(
                        $0.readThroughRoomSequence
                    )
                )
            }
            let next = rows.count > pageSize ? try receiptCursorString(
                roomID: room,
                messageID: message,
                actorUserID: actor,
                context: context,
                readThroughRoomSequence: pageRows.last!.readThroughRoomSequence,
                userID: pageRows.last!.userID
            ) : nil
            return .init(
                roomID: roomID,
                messageID: messageID,
                candidates: candidates,
                nextCursor: next
            )
        }
    }

    public func visibleReaderIdentities(
        actorUserID: UserID,
        candidateUserIDs: [UserID]
    ) async throws -> [UserID: V2PublicIdentity] {
        guard let sql = database as? any SQLDatabase else {
            throw V2ReadReceiptStoreError.corruptPersistenceState
        }
        let actor = try receiptUUID(actorUserID)
        guard try await sql.raw("""
            SELECT 1 AS exists
            FROM im_v2.public_user_profiles AS profile
            WHERE profile.user_id = \(bind: actor)
              AND profile.state = 'active'
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.account_disables AS disabled
                  WHERE disabled.user_id = profile.user_id
              )
            """).first(decoding: ReceiptExistsRow.self) != nil
        else { throw V2ReadReceiptStoreError.actorNotMember }
        guard !candidateUserIDs.isEmpty else { return [:] }
        let values = try candidateUserIDs.map(receiptUUID)
        let encoded = try receiptUUIDJSON(values)
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT value::uuid AS user_id
                FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
            )
            SELECT profile.user_id,
                   profile.public_handle,
                   profile.display_name,
                   profile.account_kind
            FROM requested
            INNER JOIN im_v2.public_user_profiles AS profile
              ON profile.user_id = requested.user_id
             AND profile.state = 'active'
            LEFT JOIN im_v2.user_read_receipt_preferences AS preference
              ON preference.user_id = requested.user_id
            LEFT JOIN im_v2.account_disables AS disabled
              ON disabled.user_id = requested.user_id
            WHERE disabled.user_id IS NULL
              AND COALESCE(preference.allows_group_read_receipts, TRUE)
            """).all(decoding: ReceiptVisibleIdentityRow.self)
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            let userID = try UserID(row.userID.uuidString)
            guard let accountKind = V2AccountKind(rawValue: row.accountKind)
            else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            return (userID, try V2PublicIdentity(
                userID: userID,
                handle: .init(row.publicHandle),
                displayName: row.displayName,
                accountKind: accountKind
            ))
        })
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

    private func receiptReaderContext(
        roomID: UUID,
        messageID: UUID,
        sql: any SQLDatabase
    ) async throws -> ReceiptReaderContextRow {
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
            WHERE message.message_id = \(bind: messageID)
              AND message.room_id = \(bind: roomID)
              AND room.room_kind = 'group'
            FOR SHARE OF room
            """).first(decoding: ReceiptReaderContextRow.self)
        else { throw V2ReadReceiptStoreError.messageNotFound }
        guard context.messageRoomSequence > 0,
              context.committedMembershipRevision >= 0,
              context.currentMembershipRevision >= 0
        else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        return context
    }

    private func receiptActorIsMember(
        roomID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow,
        sql: any SQLDatabase
    ) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 AS exists
            WHERE EXISTS (
                SELECT 1 FROM im_v2.room_memberships AS historical
                WHERE historical.room_id = \(bind: roomID)
                  AND historical.user_id = \(bind: actorUserID)
                  AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                  AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
            )
              AND EXISTS (
                SELECT 1 FROM im_v2.room_memberships AS current
                WHERE current.room_id = \(bind: roomID)
                  AND current.user_id = \(bind: actorUserID)
                  AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                  AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
            )
            """).first(decoding: ReceiptExistsRow.self) != nil
    }

    private func validateReceiptCursor(
        _ cursor: ReceiptCursor?,
        roomID: UUID,
        messageID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow
    ) throws {
        guard let cursor else { return }
        guard cursor.version == 3,
              cursor.roomID == roomID,
              cursor.messageID == messageID,
              cursor.actorUserID == actorUserID,
              cursor.messageRoomSequence == context.messageRoomSequence,
              cursor.committedMembershipRevision == context.committedMembershipRevision
        else { throw V2ReadReceiptStoreError.invalidRequest }
    }

    private func readReceiptCandidateRows(
        roomID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow,
        after cursor: ReceiptCursor?,
        limit: Int,
        sql: any SQLDatabase
    ) async throws -> [ReceiptReaderCandidateRow] {
        let cursorPredicate: SQLQueryString = if let cursor {
            """
              AND (receipt.read_through_room_sequence, receipt.user_id) < (
                    \(bind: cursor.readThroughRoomSequence), \(bind: cursor.userID)
                  )
            """
        } else {
            ""
        }
        return try await sql.raw("""
            SELECT receipt.user_id,
                   receipt.read_through_room_sequence
            FROM im_v2.room_read_receipts AS receipt
            WHERE receipt.room_id = \(bind: roomID)
              AND receipt.user_id <> \(bind: actorUserID)
              AND receipt.read_through_room_sequence >= \(bind: context.messageRoomSequence)
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
            \(cursorPredicate)
            ORDER BY receipt.read_through_room_sequence DESC, receipt.user_id DESC
            LIMIT \(bind: limit)
            """).all(decoding: ReceiptReaderCandidateRow.self)
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

private struct GroupReceiptOperationKey: Hashable {
    let userID: UUID
    let operationID: UUID
}

private struct GroupReceiptBatchInput: Sendable {
    let ordinal: Int32
    let roomID: UUID
    let userID: UUID
    let operationID: UUID
    let requestedSequence: Int64
    let nowUnixSeconds: Double

    init(ordinal: Int, request: V2ReadReceiptRecordRequest) throws {
        guard let ordinal = Int32(exactly: ordinal) else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        self.ordinal = ordinal
        roomID = try receiptUUID(request.command.roomID)
        userID = try receiptUUID(request.command.actorUserID)
        operationID = try receiptUUID(request.command.operationID)
        requestedSequence = try receiptSigned(
            request.command.readThroughRoomSequence
        )
        nowUnixSeconds = request.now.timeIntervalSince1970
        guard nowUnixSeconds.isFinite else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
    }
}

private struct GroupReceiptBatchRow: Sendable {
    let ordinal: Int
    let status: String
    let resultingSequence: Int64?
    let recordedAt: Date?
}

/// Operation locks must complete in a statement before the write statement
/// starts. PostgreSQL READ COMMITTED takes a snapshot at statement start; if
/// a retry waited for an in-flight operation lock inside the write statement,
/// that same snapshot could not see the commit it waited for.
private struct GroupReceiptBatchLockStatement: PostgresPreparedStatement {
    static let name = "im_v2_group_read_receipt_batch_locks_v3"
    static let sql = """
        WITH RECURSIVE input AS MATERIALIZED (
            SELECT source.room_id, source.user_id, source.operation_id
            FROM unnest($1::uuid[], $2::uuid[], $3::uuid[]) AS source(
                room_id, user_id, operation_id
            )
        ), lock_key_set AS MATERIALIZED (
            SELECT DISTINCT candidate.lock_key
            FROM (
                SELECT hashtextextended(
                    'v2-read-receipt-operation:' || input.user_id::text
                        || ':' || input.operation_id::text,
                    0
                ) AS lock_key
                FROM input
                UNION ALL
                SELECT hashtextextended(
                    'v2-read-receipt-state:' || input.room_id::text
                        || ':' || input.user_id::text,
                    0
                ) AS lock_key
                FROM input
            ) AS candidate
        ), ordered AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY lock_key) - 1)::integer
                       AS ordinal,
                   lock_key
            FROM lock_key_set
        ), acquired(ordinal, lock_acquired) AS (
            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.lock_key)
            FROM ordered
            WHERE ordered.ordinal = 0

            UNION ALL

            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.lock_key)
            FROM acquired AS previous
            JOIN ordered ON ordered.ordinal = previous.ordinal + 1
        )
        SELECT count(*)::bigint FROM acquired
        """

    typealias Row = Int64
    let inputs: [GroupReceiptBatchInput]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.userID))
        bindings.append(inputs.map(\.operationID))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Int64 {
        try row.decode(Int64.self)
    }
}

private struct GroupReceiptBatchStatement: PostgresPreparedStatement {
    static let name = "im_v2_group_read_receipt_batch_record_v1"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT source.ordinal, source.room_id, source.user_id,
                   source.operation_id, source.requested_sequence,
                   to_timestamp(source.now_unix_seconds) AS recorded_at
            FROM unnest(
                $1::integer[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::bigint[], $6::double precision[]
            ) AS source(
                ordinal, room_id, user_id, operation_id,
                requested_sequence, now_unix_seconds
            )
        ), prior AS MATERIALIZED (
            SELECT input.ordinal, operation.room_id,
                   operation.requested_room_sequence,
                   operation.resulting_room_sequence,
                   operation.recorded_at
            FROM input
            JOIN im_v2.read_receipt_operations AS operation
              ON operation.user_id = input.user_id
             AND operation.operation_id = input.operation_id
            JOIN im_v2.rooms AS prior_room
              ON prior_room.room_id = operation.room_id
             AND prior_room.room_kind = 'group'
        ), room_context AS MATERIALIZED (
            SELECT input.ordinal, room.room_kind, room.room_sequence,
                   CASE WHEN room.room_id IS NULL THEN NULL
                        ELSE EXISTS (
                            SELECT 1
                            FROM im_v2.room_memberships AS membership
                            WHERE membership.room_id = room.room_id
                              AND membership.user_id = input.user_id
                              AND membership.joined_revision
                                    <= room.membership_revision
                              AND (
                                  membership.left_revision IS NULL
                                  OR membership.left_revision
                                        > room.membership_revision
                              )
                        )
                   END AS actor_is_member
            FROM input
            LEFT JOIN im_v2.rooms AS room
              ON room.room_id = input.room_id
        ), eligible AS MATERIALIZED (
            SELECT input.*
            FROM input
            JOIN room_context AS context USING (ordinal)
            WHERE NOT EXISTS (
                    SELECT 1 FROM prior WHERE prior.ordinal = input.ordinal
                  )
              AND context.room_kind = 'group'
              AND context.room_sequence >= input.requested_sequence
              AND context.actor_is_member
        ), desired AS MATERIALIZED (
            SELECT room_id, user_id,
                   max(requested_sequence) AS requested_sequence,
                   max(recorded_at) AS recorded_at
            FROM eligible
            GROUP BY room_id, user_id
        ), advanced AS (
            INSERT INTO im_v2.room_read_receipts
                (room_id, user_id, read_through_room_sequence, updated_at)
            SELECT room_id, user_id, requested_sequence, recorded_at
            FROM desired
            ORDER BY room_id, user_id
            ON CONFLICT (room_id, user_id) DO UPDATE
            SET read_through_room_sequence = GREATEST(
                    im_v2.room_read_receipts.read_through_room_sequence,
                    EXCLUDED.read_through_room_sequence
                ),
                updated_at = CASE
                    WHEN EXCLUDED.read_through_room_sequence
                        > im_v2.room_read_receipts.read_through_room_sequence
                    THEN EXCLUDED.updated_at
                    ELSE im_v2.room_read_receipts.updated_at
                END
            RETURNING room_id, user_id, read_through_room_sequence
        ), recorded AS (
            INSERT INTO im_v2.read_receipt_operations
                (user_id, operation_id, room_id,
                 requested_room_sequence, resulting_room_sequence,
                 recorded_at, projection_recipient_user_id)
            SELECT eligible.user_id, eligible.operation_id, eligible.room_id,
                   eligible.requested_sequence,
                   advanced.read_through_room_sequence,
                   eligible.recorded_at, NULL
            FROM eligible
            JOIN advanced USING (room_id, user_id)
            ORDER BY eligible.user_id, eligible.operation_id
            RETURNING user_id, operation_id, resulting_room_sequence,
                      recorded_at
        )
        SELECT input.ordinal,
               CASE
                   WHEN prior.ordinal IS NOT NULL
                        AND prior.room_id = input.room_id
                        AND prior.requested_room_sequence
                              = input.requested_sequence
                   THEN 'idempotent'
                   WHEN prior.ordinal IS NOT NULL
                   THEN 'idempotency_conflict'
                   WHEN context.room_kind IS NULL
                   THEN 'room_not_found'
                   WHEN context.room_kind <> 'group'
                   THEN 'not_group'
                   WHEN context.room_sequence < input.requested_sequence
                   THEN 'room_sequence_not_found'
                   WHEN NOT context.actor_is_member
                   THEN 'actor_not_member'
                   WHEN recorded.operation_id IS NOT NULL
                   THEN 'recorded'
                   ELSE 'corrupt'
               END AS status,
               COALESCE(
                   prior.resulting_room_sequence,
                   recorded.resulting_room_sequence
               ) AS resulting_room_sequence,
               COALESCE(prior.recorded_at, recorded.recorded_at)
                   AS recorded_at
        FROM input
        JOIN room_context AS context USING (ordinal)
        LEFT JOIN prior USING (ordinal)
        LEFT JOIN recorded
          ON recorded.user_id = input.user_id
         AND recorded.operation_id = input.operation_id
        ORDER BY input.ordinal
        """

    typealias Row = GroupReceiptBatchRow
    let inputs: [GroupReceiptBatchInput]

    init(inputs: [GroupReceiptBatchInput]) throws {
        guard !inputs.isEmpty,
              inputs.enumerated().allSatisfy({
                  Int($0.element.ordinal) == $0.offset
              })
        else { throw V2ReadReceiptStoreError.invalidRequest }
        self.inputs = inputs
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(inputs.map(\.ordinal))
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.userID))
        bindings.append(inputs.map(\.operationID))
        bindings.append(inputs.map(\.requestedSequence))
        bindings.append(inputs.map(\.nowUnixSeconds))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> GroupReceiptBatchRow {
        let decoded = try row.decode(
            (Int32, String, Int64?, Date?).self
        )
        return .init(
            ordinal: Int(decoded.0),
            status: decoded.1,
            resultingSequence: decoded.2,
            recordedAt: decoded.3
        )
    }
}

private struct ReceiptRoomRow: Decodable { let roomSequence: Int64; let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case roomSequence = "room_sequence", membershipRevision = "membership_revision" } }
private struct ReceiptExistsRow: Decodable { let exists: Int }
private struct ReceiptStateRow: Decodable { let sequence: Int64; enum CodingKeys: String, CodingKey { case sequence = "read_through_room_sequence" } }
private struct ReceiptGroupRecordRow: Decodable {
    let source: String
    let roomID: UUID
    let requestedSequence: Int64
    let resultingSequence: Int64
    let recordedAt: Date
    let projectionRecipientUserID: UUID?
    enum CodingKeys: String, CodingKey {
        case source
        case roomID = "room_id"
        case requestedSequence = "requested_room_sequence"
        case resultingSequence = "resulting_room_sequence"
        case recordedAt = "recorded_at"
        case projectionRecipientUserID = "projection_recipient_user_id"
    }
}
private struct ReceiptGroupDiagnosticRow: Decodable {
    let roomKind: String
    let roomSequence: Int64
    let actorIsMember: Bool
    enum CodingKeys: String, CodingKey {
        case roomKind = "room_kind"
        case roomSequence = "room_sequence"
        case actorIsMember = "actor_is_member"
    }
}
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
private struct ReceiptReaderCandidateRow: Decodable {
    let userID: UUID
    let readThroughRoomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case readThroughRoomSequence = "read_through_room_sequence"
    }
}
private struct ReceiptVisibleIdentityRow: Decodable {
    let userID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
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
private func receiptUUIDJSON(_ values: [UUID]) throws -> String {
    let data = try JSONEncoder().encode(values.map(\.uuidString))
    guard let result = String(data: data, encoding: .utf8) else {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }
    return result
}
