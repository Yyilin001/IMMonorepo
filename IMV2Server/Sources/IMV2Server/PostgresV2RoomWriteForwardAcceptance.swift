import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

// Each stage borrows the exact transaction supplied by the Store. The Store
// retains the three transaction boundaries, authorization coordination, and
// all post-commit cache/credit finalization.
extension PostgresV2RoomWriteStore {
    func preflightForwardInboxInTransaction(
        export: V2ForwardExport,
        transaction: any Database
    ) async throws -> (V2SendMessageCommand?, V2ForwardImportOutcome?) {
        guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
        try await activationScope?.require([export.intent.targetRoomID], sql: sql)
        guard row.digest == export.digest else { throw V2ForwardInboxError.idempotencyConflict }
        if row.state == "completed" || row.state == "rejected" { return (nil, try row.outcome) }
        guard row.payload == export.payload else { throw V2ForwardInboxError.idempotencyConflict }
        guard let authority = try await v2ForwardInboxAuthorization(row, sql: sql) else {
            guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
            return (nil, .pending(.media))
        }
        // Limits do not contribute to command identity. Apply current
        // limits in the acceptance transaction, preserving its durable
        // INVALID_ARGUMENT rejection and accepted-receipt recovery.
        let identityLimits = try V2MessageCommandLimits(maxUTF8Bytes: max(export.intent.text.utf8.count, 1))
        return (try authority.command(limits: identityLimits), nil)
    }

    func acceptForwardInboxInTransaction(
        export: V2ForwardExport,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        transaction: any Database
    ) async throws -> (
        outcome: V2ForwardImportOutcome,
        command: V2SendMessageCommand?,
        commit: RoomWriteCommit?
    ) {
        guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
        guard row.digest == export.digest else { throw V2ForwardInboxError.idempotencyConflict }
        if row.state == "completed" || row.state == "rejected" {
            try await activationScope?.require([export.intent.targetRoomID], sql: sql)
            return (try row.outcome, nil, nil)
        }
        guard row.payload == export.payload else { throw V2ForwardInboxError.idempotencyConflict }
        guard let authority = try await v2ForwardInboxAuthorization(row, sql: sql) else {
            guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
            try await activationScope?.require([export.intent.targetRoomID], sql: sql)
            return (.pending(.media), nil, nil)
        }
        // Preserve inbox -> message operation -> room lock ordering.
        // Fence before command validation can persist a rejection;
        // receipt and pending reads above are separately fenced before return.
        try await acquireMessageOperationLock(roomID: export.intent.targetRoomID,
            senderID: export.intent.actorUserID, clientMessageID: export.intent.targetClientMessageID, sql: sql)
        try await v2AssertForwardInboxOwner(authority, sql: sql)
        try await activationScope?.require([export.intent.targetRoomID], sql: sql)
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
        do {
            // Recovery of an already committed receipt must not be
            // invalidated by a later deployment's smaller text limit.
            let replayLimits = row.state == "accepted"
                ? try V2MessageCommandLimits(maxUTF8Bytes: max(export.intent.text.utf8.count, 1)) : limits
            let command = try authority.command(limits: replayLimits)
            try validateAuthorizationCommand(command)
            let commit = try await acceptInTransaction(
                command: command, capacityProfile: capacityProfile, identifiers: identifiers, now: now,
                roomID: export.intent.targetRoomID, senderID: export.intent.actorUserID,
                cachedDirectPolicy: nil, importedForward: authority, transaction: transaction
            )
            switch commit.outcome {
            case .accepted, .idempotent:
                guard let receipt = commit.outcome.acceptanceReceipt else { throw V2ForwardInboxError.corruptPersistenceState }
                try await v2RecordForwardInboxAcceptance(row, receipt: receipt, now: now, sql: sql)
                return (.pending(.finalization), command, commit)
            case .denied:
                return (try await v2RejectForwardInbox(row, code: "DIRECT_MESSAGE_RESTRICTED", now: now, sql: sql), nil, nil)
            case .idempotencyConflict:
                return (try await v2RejectForwardInbox(row, code: "IDEMPOTENCY_CONFLICT", now: now, sql: sql), nil, nil)
            case .rateLimited, .unavailable:
                return (.pending(.admission), nil, nil)
            }
        } catch V2RoomWriteStoreError.actorNotEligible {
            return (try await v2RejectForwardInbox(row, code: "FORBIDDEN", now: now, sql: sql), nil, nil)
        } catch V2RoomWriteStoreError.actorMuted {
            return (try await v2RejectForwardInbox(row, code: "ACTOR_MUTED", now: now, sql: sql), nil, nil)
        } catch V2RoomWriteStoreError.roomFrozen {
            return (try await v2RejectForwardInbox(row, code: "ROOM_FROZEN", now: now, sql: sql), nil, nil)
        } catch V2SendMessageValidationError.invalidTextLength {
            return (try await v2RejectForwardInbox(row, code: "INVALID_ARGUMENT", now: now, sql: sql), nil, nil)
        }
    }

    func completeForwardInboxInTransaction(
        export: V2ForwardExport,
        commit: RoomWriteCommit,
        now: Date,
        transaction: any Database
    ) async throws -> V2ForwardImportOutcome {
        guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
        let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
        try await activationScope?.require([export.intent.targetRoomID], sql: sql)
        if row.state == "completed" { return try row.outcome }
        try await v2AssertForwardInboxOwner(.init(export: try row.export, mediaIDs: []), sql: sql)
        guard row.state == "accepted", let receipt = commit.outcome.acceptanceReceipt,
              row.messageID == receipt.messageID.uuidValue,
              row.roomSequence == Int64(exactly: receipt.roomSequence)
        else { throw V2ForwardInboxError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.message_forward_inbox SET state = 'completed', completed_at = \(bind: now)
            WHERE export_id = \(bind: row.exportID) AND state = 'accepted'
            """).run()
        return .accepted(messageID: receipt.messageID, roomSequence: receipt.roomSequence)
    }
}
