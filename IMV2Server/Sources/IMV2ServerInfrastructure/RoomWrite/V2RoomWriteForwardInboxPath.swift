import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// The Store owns each transaction and its post-commit work. These phases
/// borrow its connection and retain the inbox, operation, then room lock order.
struct V2RoomWriteForwardInboxPath: Sendable {
    let activationScope: V2RoomActivationWriteScope?

    /// The Store owns authorization receipt checks and scalar acceptance. Both
    /// callbacks execute on this same borrowed transaction connection.
    struct AcceptanceOperations: Sendable {
        let acquireOperationLock: @Sendable (UUID, UUID, UUID, any SQLDatabase) async throws -> Void
        let validateCommand: @Sendable (V2SendMessageCommand) throws -> Void
        let acceptMessage: @Sendable (V2SendMessageCommand, ForwardInboxAuthorization, any Database) async throws -> RoomWriteCommit
    }

    func preflight(
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
        // 限制值不参与命令身份。接受事务中应用当前限制，
        // 保持持久化 INVALID_ARGUMENT 拒绝和已接受回执恢复语义。
        let identityLimits = try V2MessageCommandLimits(maxUTF8Bytes: max(export.intent.text.utf8.count, 1))
        return (try authority.command(limits: identityLimits), nil)
    }

    func accept(
        export: V2ForwardExport,
        limits: V2MessageCommandLimits,
        now: Date,
        transaction: any Database,
        operations: AcceptanceOperations
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
        // 保持收件箱 -> 消息操作 -> 房间锁的顺序。
        // 命令校验可能持久化拒绝结果，因此此前须先设置围栏；
        // 上方的回执与待处理读取也分别在返回前经过围栏检查。
        try await operations.acquireOperationLock(export.intent.targetRoomID,
            export.intent.actorUserID, export.intent.targetClientMessageID, sql)
        try await v2AssertForwardInboxOwner(authority, sql: sql)
        try await activationScope?.require([export.intent.targetRoomID], sql: sql)
        guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
        do {
            // 后续部署采用更小的文本上限时，
            // 不能使已提交回执的恢复结果失效。
            let replayLimits = row.state == "accepted"
                ? try V2MessageCommandLimits(maxUTF8Bytes: max(export.intent.text.utf8.count, 1)) : limits
            let command = try authority.command(limits: replayLimits)
            try operations.validateCommand(command)
            let commit = try await operations.acceptMessage(command, authority, transaction)
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

    func complete(
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
