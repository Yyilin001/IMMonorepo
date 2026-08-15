import Foundation
import GRDB
import IMV2Core

/// Durable command queues are isolated from sync projection application, but
/// keep the same actor and SQLite pool so each command transition remains a
/// single local transaction.
extension GRDBV2LocalSyncStore {
    public func enqueue(_ command: V2PendingMessageCommand) throws {
        try databasePool.write { db in
            guard (!command.text.isEmpty || !command.media.isEmpty),
                  command.media.count <= V2MessageCommandLimits.maxMediaAttachments,
                  Set(command.media).count == command.media.count,
                  command.mentions.count <= V2MessageCommandLimits.maxMentions,
                  Set(command.mentions).count == command.mentions.count,
                  command.state == .pending, command.attemptCount == 0,
                  command.acceptedMessageID == nil, command.acceptedRoomSequence == nil, command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            let mediaIDs = try Self.encodeMedia(command.media)
            let mentionTargets = try Self.encodeMentions(command.mentions)
            let entities = try Self.encodeEntities(command.entities, text: command.text)
            let replyToMessageID = command.replyTo?.messageID.rawValue
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, text, media_ids, mention_targets, entities, reply_to_message_id FROM v2_pending_message_commands WHERE client_message_id = ?", arguments: [command.clientMessageID.rawValue]) {
                let roomID: String = existing["room_id"]
                let text: String = existing["text"]
                let existingMedia: String = existing["media_ids"]
                let existingMentions: String = existing["mention_targets"]
                let existingEntities: String = existing["entities"]
                let existingReplyToMessageID: String? = existing["reply_to_message_id"]
                guard roomID == command.roomID.rawValue, text == command.text, existingMedia == mediaIDs, existingMentions == mentionTargets, existingEntities == entities, existingReplyToMessageID == replyToMessageID else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_commands
                    (client_message_id, room_id, text, media_ids, mention_targets, entities, reply_to_message_id, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [command.clientMessageID.rawValue, command.roomID.rawValue, command.text, mediaIDs, mentionTargets, entities, replyToMessageID, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970]
            )
        }
    }

    public func nextReadyMessage(now: Date) throws -> V2PendingMessageCommand? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM v2_pending_message_commands
                WHERE state = 'pending' AND next_attempt_at <= ?
                ORDER BY created_at, client_message_id LIMIT 1
                """, arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingCommand(row)
        }
    }

    public func markMessageAccepted(clientMessageID: ClientMessageID, messageID: MessageID, roomSequence: UInt64) throws {
        guard roomSequence > 0 else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingCommand(clientMessageID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_message_commands
                SET state = 'accepted', accepted_message_id = ?, accepted_room_sequence = ?, terminal_code = NULL
                WHERE client_message_id = ?
                """, arguments: [messageID.rawValue, try Self.commandStorageInteger(roomSequence), clientMessageID.rawValue])
        }
    }

    public func scheduleMessageRetry(clientMessageID: ClientMessageID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingCommand(clientMessageID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_message_commands
                SET attempt_count = attempt_count + 1, next_attempt_at = ?
                WHERE client_message_id = ?
                """, arguments: [nextAttemptAt.timeIntervalSince1970, clientMessageID.rawValue])
        }
    }

    public func rejectMessage(clientMessageID: ClientMessageID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingCommand(clientMessageID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_message_commands
                SET state = 'rejected', terminal_code = ?
                WHERE client_message_id = ?
                """, arguments: [code, clientMessageID.rawValue])
        }
    }

    public func pendingMessageCommands() throws -> [V2PendingMessageCommand] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_commands ORDER BY created_at, client_message_id").map(Self.decodePendingCommand)
        }
    }

    /// Discards completed commands after their short local diagnostic window.
    /// Pending records are the durable source for retries and are never
    /// eligible for this cleanup.
    public func pruneTerminalCommands(olderThan cutoff: Date) throws {
        try databasePool.write { db in
            let cutoffValue = cutoff.timeIntervalSince1970
            for table in Self.terminalCommandTables where table != "v2_pending_group_room_creations" {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE state <> 'pending' AND terminal_at <= ?",
                    arguments: [cutoffValue]
                )
            }

            // `finalizing` and `cancelling` remain replay-active protocol
            // states. Only outcomes that can no longer emit a request are
            // eligible for diagnostic retention cleanup.
            try db.execute(
                sql: "DELETE FROM v2_pending_group_room_creations WHERE state IN ('cancelled', 'acknowledged', 'rejected') AND terminal_at <= ?",
                arguments: [cutoffValue]
            )

            // Forward plans own their chunks through a non-cascading foreign
            // key. Remove children first, and age terminal plans by the time
            // they became terminal rather than by their original enqueue time.
            try db.execute(
                sql: "DELETE FROM v2_forward_message_chunks WHERE plan_id IN (SELECT plan_id FROM v2_forward_message_plans WHERE state IN ('completed', 'cancelled') AND updated_at <= ?)",
                arguments: [cutoffValue]
            )
            try db.execute(
                sql: "DELETE FROM v2_forward_message_plans WHERE state IN ('completed', 'cancelled') AND updated_at <= ?",
                arguments: [cutoffValue]
            )
        }
    }

    /// Stops automatic replay before the server is allowed to discard the
    /// corresponding idempotency result. This transition runs in one local
    /// transaction and deliberately preserves the rejected rows for UI
    /// diagnosis instead of silently deleting user intent.
    public func expireStalePendingCommands(now: Date) throws {
        try databasePool.write { db in
            let cutoff = now.addingTimeInterval(-V2IdempotencyPolicy.maximumClientRetryAge)
            let cutoffValue = cutoff.timeIntervalSince1970
            for table in Self.terminalCommandTables {
                try db.execute(
                    sql: "UPDATE \(table) SET state = 'rejected', terminal_code = ?, terminal_at = ? WHERE state = 'pending' AND created_at <= ?",
                    arguments: [V2IdempotencyPolicy.expiredClientCommandCode, now.timeIntervalSince1970, cutoffValue]
                )
            }
            // A staged group creation remains replay-active while finalizing
            // or cancelling even though it is no longer named `pending`.
            try db.execute(
                sql: "UPDATE v2_pending_group_room_creations SET state = 'rejected', terminal_code = ?, terminal_at = ? WHERE state IN ('finalizing', 'cancelling') AND created_at <= ?",
                arguments: [V2IdempotencyPolicy.expiredClientCommandCode, now.timeIntervalSince1970, cutoffValue]
            )

            // Bulk forwarding has its own parent/chunk state machine. Cancel
            // the whole old plan atomically so the scheduler cannot create a
            // fresh derived operation after the protocol retry window.
            try db.execute(
                sql: "UPDATE v2_forward_message_chunks SET state = 'cancelled' WHERE state = 'pending' AND plan_id IN (SELECT plan_id FROM v2_forward_message_plans WHERE state = 'active' AND created_at <= ?)",
                arguments: [cutoffValue]
            )
            try db.execute(
                sql: "UPDATE v2_forward_message_plans SET state = 'cancelled', updated_at = ? WHERE state = 'active' AND created_at <= ?",
                arguments: [now.timeIntervalSince1970, cutoffValue]
            )
        }
    }

    public func enqueue(_ command: V2PendingMembershipCommand) throws {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMembershipRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, target_user_id, action, expected_membership_revision FROM v2_pending_membership_commands WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let roomID: String = existing["room_id"]
                let targetUserID: String = existing["target_user_id"]
                let action: String = existing["action"]
                let expectedRevision: Int64 = existing["expected_membership_revision"]
                guard roomID == command.roomID.rawValue,
                      targetUserID == command.targetUserID.rawValue,
                      action == command.action.rawValue,
                      expectedRevision == (try Self.commandStorageInteger(command.expectedMembershipRevision))
                else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_membership_commands
                    (operation_id, room_id, target_user_id, action, expected_membership_revision,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [command.operationID.rawValue, command.roomID.rawValue, command.targetUserID.rawValue,
                            command.action.rawValue, try Self.commandStorageInteger(command.expectedMembershipRevision),
                            command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970]
            )
        }
    }

    public func enqueueOrReusePendingMembershipCommand(
        _ command: V2PendingMembershipCommand
    ) throws -> V2PendingMembershipCommand {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMembershipRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            let expectedRevision = try Self.commandStorageInteger(command.expectedMembershipRevision)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_membership_commands WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMembershipCommand(existing)
                guard decoded.roomID == command.roomID,
                      decoded.targetUserID == command.targetUserID,
                      decoded.action == command.action,
                      decoded.expectedMembershipRevision == command.expectedMembershipRevision,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_membership_commands
                WHERE room_id = ? AND target_user_id = ? AND action = ?
                  AND expected_membership_revision = ? AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.action.rawValue,
                    expectedRevision
                ]
            ) {
                return try Self.decodePendingMembershipCommand(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_membership_commands
                    (operation_id, room_id, target_user_id, action, expected_membership_revision,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.action.rawValue,
                    expectedRevision,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMembershipCommand(now: Date) throws -> V2PendingMembershipCommand? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM v2_pending_membership_commands
                WHERE state = 'pending' AND next_attempt_at <= ?
                ORDER BY created_at, operation_id LIMIT 1
                """, arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingMembershipCommand(row)
        }
    }

    public func markMembershipAcknowledged(operationID: MembershipOperationID, membershipRevision: UInt64, roomSequence: UInt64) throws {
        try databasePool.write { db in
            try Self.requirePendingMembershipCommand(operationID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_membership_commands
                SET state = 'acknowledged', resulting_membership_revision = ?, resulting_room_sequence = ?, terminal_code = NULL
                WHERE operation_id = ?
                """, arguments: [try Self.commandStorageInteger(membershipRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue])
        }
    }

    public func scheduleMembershipRetry(operationID: MembershipOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingMembershipCommand(operationID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_membership_commands
                SET attempt_count = attempt_count + 1, next_attempt_at = ?
                WHERE operation_id = ?
                """, arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectMembership(operationID: MembershipOperationID, code: String, currentRevision: UInt64?) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMembershipCommand(operationID, db: db)
            try db.execute(sql: """
                UPDATE v2_pending_membership_commands
                SET state = 'rejected', terminal_code = ?, terminal_current_revision = ?
                WHERE operation_id = ?
                """, arguments: [code, try currentRevision.map(Self.commandStorageInteger), operationID.rawValue])
        }
    }

    public func pendingMembershipCommands() throws -> [V2PendingMembershipCommand] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_membership_commands ORDER BY created_at, operation_id").map(Self.decodePendingMembershipCommand)
        }
    }

    public func enqueue(_ command: V2PendingMessageWithdrawal) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0,
                  command.resultingMessageRevision == nil, command.resultingRoomSequence == nil,
                  command.terminalCode == nil, command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, message_id, expected_message_revision FROM v2_pending_message_withdrawals WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let roomID: String = existing["room_id"]; let messageID: String = existing["message_id"]; let revision: Int64 = existing["expected_message_revision"]
                guard roomID == command.roomID.rawValue, messageID == command.messageID.rawValue, revision == (try Self.commandStorageInteger(command.expectedMessageRevision)) else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: """
                INSERT INTO v2_pending_message_withdrawals
                    (operation_id, room_id, message_id, expected_message_revision, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """, arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, try Self.commandStorageInteger(command.expectedMessageRevision), command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageWithdrawal(
        _ command: V2PendingMessageWithdrawal
    ) throws -> V2PendingMessageWithdrawal {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMessageRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            let expectedRevision = try Self.commandStorageInteger(command.expectedMessageRevision)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_withdrawals WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageWithdrawal(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.expectedMessageRevision == command.expectedMessageRevision,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_withdrawals
                WHERE room_id = ? AND message_id = ?
                  AND expected_message_revision = ? AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [command.roomID.rawValue, command.messageID.rawValue, expectedRevision]
            ) {
                return try Self.decodePendingMessageWithdrawal(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_withdrawals
                    (operation_id, room_id, message_id, expected_message_revision,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    expectedRevision,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMessageWithdrawal(now: Date) throws -> V2PendingMessageWithdrawal? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_withdrawals WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingMessageWithdrawal(row)
        }
    }

    public func markMessageWithdrawalAcknowledged(operationID: MessageWithdrawalOperationID, messageRevision: UInt64, roomSequence: UInt64) throws {
        try databasePool.write { db in
            try Self.requirePendingMessageWithdrawal(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_withdrawals SET state = 'acknowledged', resulting_message_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(messageRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue])
        }
    }

    public func scheduleMessageWithdrawalRetry(operationID: MessageWithdrawalOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingMessageWithdrawal(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_withdrawals SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectMessageWithdrawal(operationID: MessageWithdrawalOperationID, code: String, currentRevision: UInt64?) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMessageWithdrawal(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_withdrawals SET state = 'rejected', terminal_code = ?, terminal_current_revision = ? WHERE operation_id = ?", arguments: [code, try currentRevision.map(Self.commandStorageInteger), operationID.rawValue])
        }
    }

    public func pendingMessageWithdrawals() throws -> [V2PendingMessageWithdrawal] {
        try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_withdrawals ORDER BY created_at, operation_id").map(Self.decodePendingMessageWithdrawal) }
    }

    public func enqueue(_ command: V2PendingMessageRedaction) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0,
                  command.resultingMessageRevision == nil, command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(db, sql: "SELECT room_id, message_id, reason_code FROM v2_pending_message_redactions WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let roomID: String = existing["room_id"]
                let messageID: String = existing["message_id"]
                let reasonCode: String = existing["reason_code"]
                guard roomID == command.roomID.rawValue, messageID == command.messageID.rawValue,
                      reasonCode == command.reasonCode.rawValue
                else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_message_redactions (operation_id, room_id, message_id, reason_code, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, command.reasonCode.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageRedaction(
        _ command: V2PendingMessageRedaction
    ) throws -> V2PendingMessageRedaction {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMessageRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_redactions WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageRedaction(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.reasonCode == command.reasonCode,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_redactions
                WHERE room_id = ? AND message_id = ? AND reason_code = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reasonCode.rawValue
                ]
            ) {
                return try Self.decodePendingMessageRedaction(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_redactions
                    (operation_id, room_id, message_id, reason_code,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reasonCode.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMessageRedaction(now: Date) throws -> V2PendingMessageRedaction? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_redactions WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingMessageRedaction(row)
        }
    }

    public func markMessageRedactionAcknowledged(operationID: ModerationOperationID, messageRevision: UInt64, roomSequence: UInt64) throws {
        guard messageRevision > 1, roomSequence > 0 else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMessageRedaction(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_redactions SET state = 'acknowledged', resulting_message_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(messageRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue])
        }
    }

    public func scheduleMessageRedactionRetry(operationID: ModerationOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingMessageRedaction(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_redactions SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectMessageRedaction(operationID: ModerationOperationID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requirePendingMessageRedaction(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_message_redactions SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue])
        }
    }

    public func pendingMessageRedactions() throws -> [V2PendingMessageRedaction] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_redactions ORDER BY created_at, operation_id").map(Self.decodePendingMessageRedaction)
        }
    }

    public func enqueue(_ command: V2PendingMemberMute) throws { try databasePool.write { db in
        guard command.muteUntil > command.nextAttemptAt, command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, target_user_id, mute_until, reason_code FROM v2_pending_member_mutes WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let room: String = row["room_id"], target: String = row["target_user_id"], until: Double = row["mute_until"], reason: String = row["reason_code"]; guard room == command.roomID.rawValue, target == command.targetUserID.rawValue, until == command.muteUntil.timeIntervalSince1970, reason == command.reasonCode.rawValue else { throw V2ClientCommandError.commandConflict }; return }
        try db.execute(sql: "INSERT INTO v2_pending_member_mutes (operation_id, room_id, target_user_id, mute_until, reason_code, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.targetUserID.rawValue, command.muteUntil.timeIntervalSince1970, command.reasonCode.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
    } }

    public func enqueueOrReusePendingMemberMute(
        _ command: V2PendingMemberMute
    ) throws -> V2PendingMemberMute {
        try databasePool.write { db in
            guard command.muteUntil > command.nextAttemptAt,
                  command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_member_mutes WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMemberMute(existing)
                guard decoded.roomID == command.roomID,
                      decoded.targetUserID == command.targetUserID,
                      decoded.muteUntil == command.muteUntil,
                      decoded.reasonCode == command.reasonCode,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_member_mutes
                WHERE room_id = ? AND target_user_id = ? AND mute_until = ?
                  AND reason_code = ? AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.muteUntil.timeIntervalSince1970,
                    command.reasonCode.rawValue
                ]
            ) {
                return try Self.decodePendingMemberMute(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_member_mutes
                    (operation_id, room_id, target_user_id, mute_until, reason_code,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.muteUntil.timeIntervalSince1970,
                    command.reasonCode.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }
    public func nextReadyMemberMute(now: Date) throws -> V2PendingMemberMute? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_member_mutes WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMemberMute(row) } }
    public func markMemberMuteAcknowledged(operationID: ModerationOperationID, roomSequence: UInt64) throws { guard roomSequence > 0 else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMemberMute(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_member_mutes SET state = 'acknowledged', resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(roomSequence), operationID.rawValue]) } }
    public func scheduleMemberMuteRetry(operationID: ModerationOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingMemberMute(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_member_mutes SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectMemberMute(operationID: ModerationOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMemberMute(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_member_mutes SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func pendingMemberMutes() throws -> [V2PendingMemberMute] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_member_mutes ORDER BY created_at, operation_id").map(Self.decodePendingMemberMute)
        }
    }

    public func enqueue(_ command: V2PendingModeratedMemberRemoval) throws { try databasePool.write { db in
        guard command.state == .pending, command.attemptCount == 0, command.resultingMembershipRevision == nil, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, target_user_id, reason_code FROM v2_pending_moderated_member_removals WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let room: String = row["room_id"], target: String = row["target_user_id"], reason: String = row["reason_code"]; guard room == command.roomID.rawValue, target == command.targetUserID.rawValue, reason == command.reasonCode.rawValue else { throw V2ClientCommandError.commandConflict }; return }
        try db.execute(sql: "INSERT INTO v2_pending_moderated_member_removals (operation_id, room_id, target_user_id, reason_code, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.targetUserID.rawValue, command.reasonCode.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
    } }

    public func enqueueOrReusePendingModeratedMemberRemoval(
        _ command: V2PendingModeratedMemberRemoval
    ) throws -> V2PendingModeratedMemberRemoval {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMembershipRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_moderated_member_removals WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingModeratedMemberRemoval(existing)
                guard decoded.roomID == command.roomID,
                      decoded.targetUserID == command.targetUserID,
                      decoded.reasonCode == command.reasonCode,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_moderated_member_removals
                WHERE room_id = ? AND target_user_id = ? AND reason_code = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.reasonCode.rawValue
                ]
            ) {
                return try Self.decodePendingModeratedMemberRemoval(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_moderated_member_removals
                    (operation_id, room_id, target_user_id, reason_code,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.targetUserID.rawValue,
                    command.reasonCode.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }
    public func nextReadyModeratedMemberRemoval(now: Date) throws -> V2PendingModeratedMemberRemoval? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_moderated_member_removals WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingModeratedMemberRemoval(row) } }
    public func markModeratedMemberRemovalAcknowledged(operationID: ModerationOperationID, membershipRevision: UInt64, roomSequence: UInt64) throws { guard membershipRevision > 0, roomSequence > 0 else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingModeratedMemberRemoval(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_moderated_member_removals SET state = 'acknowledged', resulting_membership_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(membershipRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue]) } }
    public func scheduleModeratedMemberRemovalRetry(operationID: ModerationOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingModeratedMemberRemoval(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_moderated_member_removals SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectModeratedMemberRemoval(operationID: ModerationOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingModeratedMemberRemoval(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_moderated_member_removals SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }
    public func pendingModeratedMemberRemovals() throws -> [V2PendingModeratedMemberRemoval] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_moderated_member_removals ORDER BY created_at, operation_id").map(Self.decodePendingModeratedMemberRemoval) } }

    public func enqueue(_ command: V2PendingMessageEdit) throws {
        try databasePool.write { db in
            guard !command.text.isEmpty, command.state == .pending, command.attemptCount == 0, command.resultingMessageRevision == nil, command.resultingRoomSequence == nil, command.terminalCode == nil, command.terminalCurrentRevision == nil else { throw V2ClientCommandError.commandConflict }
            if let row = try Row.fetchOne(db, sql: "SELECT room_id, message_id, expected_message_revision, text_body FROM v2_pending_message_edits WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let room: String = row["room_id"], message: String = row["message_id"], revision: Int64 = row["expected_message_revision"], text: String = row["text_body"]
                guard room == command.roomID.rawValue, message == command.messageID.rawValue, revision == (try Self.commandStorageInteger(command.expectedMessageRevision)), text == command.text else { throw V2ClientCommandError.commandConflict }; return
            }
            try db.execute(sql: "INSERT INTO v2_pending_message_edits (operation_id, room_id, message_id, expected_message_revision, text_body, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, try Self.commandStorageInteger(command.expectedMessageRevision), command.text, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageEdit(
        _ command: V2PendingMessageEdit
    ) throws -> V2PendingMessageEdit {
        try databasePool.write { db in
            guard !command.text.isEmpty,
                  command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingMessageRevision == nil,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil,
                  command.terminalCurrentRevision == nil
            else { throw V2ClientCommandError.commandConflict }
            let expectedRevision = try Self.commandStorageInteger(command.expectedMessageRevision)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_edits WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageEdit(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.expectedMessageRevision == command.expectedMessageRevision,
                      decoded.text == command.text,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_edits
                WHERE room_id = ? AND message_id = ?
                  AND expected_message_revision = ? AND text_body = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    expectedRevision,
                    command.text
                ]
            ) {
                return try Self.decodePendingMessageEdit(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_edits
                    (operation_id, room_id, message_id, expected_message_revision,
                     text_body, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    expectedRevision,
                    command.text,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }
    public func nextReadyMessageEdit(now: Date) throws -> V2PendingMessageEdit? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_edits WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMessageEdit(row) } }
    public func markMessageEditAcknowledged(operationID: MessageEditOperationID, messageRevision: UInt64, roomSequence: UInt64) throws { guard messageRevision > 0, roomSequence > 0 else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMessageEdit(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_edits SET state = 'acknowledged', resulting_message_revision = ?, resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(messageRevision), try Self.commandStorageInteger(roomSequence), operationID.rawValue]) } }
    public func scheduleMessageEditRetry(operationID: MessageEditOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingMessageEdit(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_edits SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectMessageEdit(operationID: MessageEditOperationID, code: String, currentRevision: UInt64?) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMessageEdit(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_edits SET state = 'rejected', terminal_code = ?, terminal_current_revision = ? WHERE operation_id = ?", arguments: [code, try currentRevision.map(Self.commandStorageInteger), operationID.rawValue]) } }
    public func pendingMessageEdits() throws -> [V2PendingMessageEdit] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_edits ORDER BY created_at, operation_id").map(Self.decodePendingMessageEdit) } }

    public func enqueue(_ command: V2PendingReadReceipt) throws { try databasePool.write { db in
        guard command.readThroughRoomSequence > 0, command.readThroughRoomSequence <= UInt64(Int64.max), command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let requestedSequence = Int64(command.readThroughRoomSequence)
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, read_through_room_sequence FROM v2_pending_read_receipts WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let room: String = row["room_id"], sequence: Int64 = row["read_through_room_sequence"]; guard room == command.roomID.rawValue, sequence == requestedSequence else { throw V2ClientCommandError.commandConflict }; return }
        try db.execute(sql: "INSERT INTO v2_pending_read_receipts (operation_id, room_id, read_through_room_sequence, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, requestedSequence, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
    } }
    public func enqueueIfReadReceiptAdvances(_ command: V2PendingReadReceipt) throws -> Bool { try databasePool.write { db in
        guard command.readThroughRoomSequence > 0, command.readThroughRoomSequence <= UInt64(Int64.max), command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let requestedSequence = Int64(command.readThroughRoomSequence)
        let currentHighWater: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(CASE WHEN state = 'acknowledged' THEN resulting_room_sequence ELSE read_through_room_sequence END), 0) FROM v2_pending_read_receipts WHERE room_id = ? AND state IN ('pending', 'acknowledged')",
            arguments: [command.roomID.rawValue]
        ) ?? 0
        guard requestedSequence > currentHighWater else { return false }
        try db.execute(sql: "INSERT INTO v2_pending_read_receipts (operation_id, room_id, read_through_room_sequence, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, requestedSequence, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        return true
    } }
    public func nextReadyReadReceipt(now: Date) throws -> V2PendingReadReceipt? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_read_receipts WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingReadReceipt(row) } }
    public func markReadReceiptAcknowledged(operationID: ReadReceiptOperationID, roomSequence: UInt64) throws { guard roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingReadReceipt(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_read_receipts SET state = 'acknowledged', resulting_room_sequence = ? WHERE operation_id = ?", arguments: [Int64(roomSequence), operationID.rawValue]) } }
    public func scheduleReadReceiptRetry(operationID: ReadReceiptOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingReadReceipt(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_read_receipts SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectReadReceipt(operationID: ReadReceiptOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingReadReceipt(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_read_receipts SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }
    public func pendingReadReceipts() throws -> [V2PendingReadReceipt] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_read_receipts ORDER BY created_at, operation_id").map(Self.decodePendingReadReceipt) } }

    public func enqueue(_ command: V2PendingMessageReaction) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0, command.resultingRoomSequence == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
            if let row = try Row.fetchOne(db, sql: "SELECT room_id, message_id, reaction, action FROM v2_pending_message_reactions WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let room: String = row["room_id"], message: String = row["message_id"], reaction: String = row["reaction"], action: String = row["action"]
                guard room == command.roomID.rawValue, message == command.messageID.rawValue, reaction == command.reaction, action == command.action.rawValue else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_message_reactions (operation_id, room_id, message_id, reaction, action, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, command.reaction, command.action.rawValue, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingMessageReaction(
        _ command: V2PendingMessageReaction
    ) throws -> V2PendingMessageReaction {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.resultingRoomSequence == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_message_reactions WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingMessageReaction(existing)
                guard decoded.roomID == command.roomID,
                      decoded.messageID == command.messageID,
                      decoded.reaction == command.reaction,
                      decoded.action == command.action,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_message_reactions
                WHERE room_id = ? AND message_id = ? AND reaction = ? AND action = ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reaction,
                    command.action.rawValue
                ]
            ) {
                return try Self.decodePendingMessageReaction(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_message_reactions
                    (operation_id, room_id, message_id, reaction, action,
                     state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.roomID.rawValue,
                    command.messageID.rawValue,
                    command.reaction,
                    command.action.rawValue,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyMessageReaction(now: Date) throws -> V2PendingMessageReaction? {
        try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_reactions WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMessageReaction(row) }
    }
    public func markMessageReactionAcknowledged(operationID: MessageReactionOperationID, roomSequence: UInt64) throws {
        guard roomSequence > 0 else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in try Self.requirePendingMessageReaction(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_reactions SET state = 'acknowledged', resulting_room_sequence = ? WHERE operation_id = ?", arguments: [try Self.commandStorageInteger(roomSequence), operationID.rawValue]) }
    }
    public func scheduleMessageReactionRetry(operationID: MessageReactionOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in try Self.requirePendingMessageReaction(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_reactions SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) }
    }
    public func rejectMessageReaction(operationID: MessageReactionOperationID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in try Self.requirePendingMessageReaction(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_reactions SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) }
    }

    public func pendingMessageReactions() throws -> [V2PendingMessageReaction] {
        try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_message_reactions ORDER BY created_at, operation_id").map(Self.decodePendingMessageReaction) }
    }

    public func enqueueOrReuseConversationState(_ pending: V2PendingConversationStateCommand) throws -> V2PendingConversationStateCommand { try databasePool.write { db in
        guard pending.state == .pending, pending.attemptCount == 0, pending.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let command = pending.command
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_conversation_states WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
            let existing = try Self.decodePendingConversationState(row)
            guard existing.command == command, existing.state == .pending else { throw V2ClientCommandError.commandConflict }; return existing
        }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_conversation_states WHERE room_id = ? AND is_pinned = ? AND is_archived = ? AND mute_until = ? AND state = 'pending' ORDER BY created_at, operation_id LIMIT 1", arguments: [command.roomID.rawValue, command.isPinned, command.isArchived, command.muteUntil?.timeIntervalSince1970 ?? 0]) { return try Self.decodePendingConversationState(row) }
        try db.execute(sql: "INSERT INTO v2_pending_conversation_states (operation_id, room_id, is_pinned, is_archived, mute_until, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.isPinned, command.isArchived, command.muteUntil?.timeIntervalSince1970 ?? 0, pending.nextAttemptAt.timeIntervalSince1970, pending.nextAttemptAt.timeIntervalSince1970])
        return pending
    } }
    public func nextReadyConversationState(now: Date) throws -> V2PendingConversationStateCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_conversation_states WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingConversationState(row) } }
    public func markConversationStateAcknowledged(operationID: ConversationPreferenceOperationID) throws { try databasePool.write { db in try Self.requirePendingConversationState(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_conversation_states SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID.rawValue]) } }
    public func scheduleConversationStateRetry(operationID: ConversationPreferenceOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingConversationState(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_conversation_states SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectConversationState(operationID: ConversationPreferenceOperationID, code: String) throws { guard !code.isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingConversationState(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_conversation_states SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func enqueueOrReuseMessageFavorite(_ pending: V2PendingMessageFavoriteCommand) throws -> V2PendingMessageFavoriteCommand { try databasePool.write { db in
        guard pending.state == .pending, pending.attemptCount == 0, pending.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        let command = pending.command
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_favorites WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let existing = try Self.decodePendingMessageFavorite(row); guard existing.command == command, existing.state == .pending else { throw V2ClientCommandError.commandConflict }; return existing }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_favorites WHERE room_id = ? AND message_id = ? AND is_favorited = ? AND state = 'pending' ORDER BY created_at, operation_id LIMIT 1", arguments: [command.roomID.rawValue, command.messageID.rawValue, command.isFavorited]) { return try Self.decodePendingMessageFavorite(row) }
        try db.execute(sql: "INSERT INTO v2_pending_message_favorites (operation_id, room_id, message_id, is_favorited, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.roomID.rawValue, command.messageID.rawValue, command.isFavorited, pending.nextAttemptAt.timeIntervalSince1970, pending.nextAttemptAt.timeIntervalSince1970]); return pending
    } }
    public func nextReadyMessageFavorite(now: Date) throws -> V2PendingMessageFavoriteCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_message_favorites WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingMessageFavorite(row) } }
    public func markMessageFavoriteAcknowledged(operationID: MessageFavoriteOperationID) throws { try databasePool.write { db in try Self.requirePendingMessageFavorite(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_favorites SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID.rawValue]) } }
    public func scheduleMessageFavoriteRetry(operationID: MessageFavoriteOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingMessageFavorite(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_favorites SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectMessageFavorite(operationID: MessageFavoriteOperationID, code: String) throws { guard !code.isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingMessageFavorite(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_message_favorites SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func enqueueOrReuseGroupCapability(_ command: V2PendingGroupCapabilityCommand) throws -> V2PendingGroupCapabilityCommand { try databasePool.write { db in
        guard command.state == .pending, command.attemptCount == 0, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_capabilities WHERE operation_id = ?", arguments: [command.operationID]) { let existing = try Self.decodePendingGroupCapability(row); guard existing == command else { throw V2ClientCommandError.commandConflict }; return existing }
        let permissions = String(decoding: try JSONEncoder().encode(command.permissions.map(\.rawValue).sorted()), as: UTF8.self)
        try db.execute(sql: "INSERT INTO v2_pending_group_capabilities (operation_id, kind, room_id, message_id, is_pinned, body, role, permissions, target_user_id, expected_revision, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID, command.kind.rawValue, command.roomID.rawValue, command.messageID?.rawValue, command.isPinned, command.body, command.role?.rawValue, permissions, command.targetUserID?.rawValue, try Self.storageInteger(command.expectedRevision), command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        return command
    } }
    public func nextReadyGroupCapability(now: Date) throws -> V2PendingGroupCapabilityCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_capabilities WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingGroupCapability(row) } }
    public func markGroupCapabilityAcknowledged(operationID: String) throws { try databasePool.write { db in guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_pending_group_capabilities WHERE operation_id = ? AND state = 'pending')", arguments: [operationID]) == true else { throw V2ClientCommandError.commandConflict }; try db.execute(sql: "UPDATE v2_pending_group_capabilities SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID]) } }
    public func scheduleGroupCapabilityRetry(operationID: String, nextAttemptAt: Date) throws { try databasePool.write { db in guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_pending_group_capabilities WHERE operation_id = ? AND state = 'pending')", arguments: [operationID]) == true else { throw V2ClientCommandError.commandConflict }; try db.execute(sql: "UPDATE v2_pending_group_capabilities SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID]) } }
    public func rejectGroupCapability(operationID: String, code: String) throws { guard !code.isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_pending_group_capabilities WHERE operation_id = ? AND state = 'pending')", arguments: [operationID]) == true else { throw V2ClientCommandError.commandConflict }; try db.execute(sql: "UPDATE v2_pending_group_capabilities SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID]) } }

    public func enqueueOrReuseForwardMessages(_ pending: V2PendingForwardMessagesCommand) throws -> V2PendingForwardMessagesCommand { try databasePool.write { db in let command = pending.command; if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_forward_messages WHERE operation_id = ?", arguments: [command.operationID.rawValue]) { let existing = try Self.decodePendingForwardMessages(row); guard existing.command == command else { throw V2ClientCommandError.commandConflict }; return existing }; let sources = String(decoding: try JSONEncoder().encode(command.sourceMessageIDs.map(\.rawValue)), as: UTF8.self); let targets = String(decoding: try JSONEncoder().encode(command.targetRoomIDs.map(\.rawValue)), as: UTF8.self); try db.execute(sql: "INSERT INTO v2_pending_forward_messages (operation_id, source_message_ids, target_room_ids, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, sources, targets, pending.nextAttemptAt.timeIntervalSince1970, pending.nextAttemptAt.timeIntervalSince1970]); return pending } }
    public func nextReadyForwardMessages(now: Date) throws -> V2PendingForwardMessagesCommand? { try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_forward_messages WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingForwardMessages(row) } }
    public func markForwardMessagesAcknowledged(operationID: MessageForwardOperationID) throws { try databasePool.write { db in try Self.requirePendingForwardMessages(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_forward_messages SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID.rawValue]) } }
    public func scheduleForwardMessagesRetry(operationID: MessageForwardOperationID, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingForwardMessages(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_forward_messages SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue]) } }
    public func rejectForwardMessages(operationID: MessageForwardOperationID, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingForwardMessages(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_forward_messages SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue]) } }

    public func enqueueForwardPlan(_ plan: V2ForwardMessagesPlan, sourceMessageIDs: [MessageID], targetRoomIDs: [RoomID], now: Date) throws -> V2ForwardMessagesPlan {
        try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_forward_message_plans WHERE plan_id = ?", arguments: [plan.operationID.rawValue]) {
                let existing = try Self.decodeForwardMessagesPlan(row)
                guard existing.sourceMessageCount == sourceMessageIDs.count,
                      existing.targetRoomCount == targetRoomIDs.count,
                      existing.totalForwardCount == plan.totalForwardCount
                else { throw V2ClientCommandError.commandConflict }
                return existing
            }
            let sourceJSON = String(decoding: try JSONEncoder().encode(sourceMessageIDs.map(\.rawValue)), as: UTF8.self)
            let targetJSON = String(decoding: try JSONEncoder().encode(targetRoomIDs.map(\.rawValue)), as: UTF8.self)
            let sourceChunkCount = (sourceMessageIDs.count + V2BulkForwardMessagesOutboxEngine.sourceMessagesPerChunk - 1) / V2BulkForwardMessagesOutboxEngine.sourceMessagesPerChunk
            let totalChunkCount = try Self.storageInteger(UInt64(sourceChunkCount * targetRoomIDs.count))
            try db.execute(
                sql: "INSERT INTO v2_forward_message_plans (plan_id, source_message_ids, target_room_ids, next_chunk_index, total_chunk_count, state, created_at, updated_at) VALUES (?, ?, ?, 0, ?, 'active', ?, ?)",
                arguments: [plan.operationID.rawValue, sourceJSON, targetJSON, totalChunkCount, now.timeIntervalSince1970, now.timeIntervalSince1970]
            )
            return plan
        }
    }

    public func nextReadyForwardPlanChunk(now: Date) throws -> V2PendingForwardMessagesCommand? {
        try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_forward_message_chunks WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) {
                return try Self.decodeForwardPlanChunk(row)
            }
            guard let planRow = try Row.fetchOne(db, sql: "SELECT * FROM v2_forward_message_plans WHERE state = 'active' ORDER BY created_at, plan_id LIMIT 1") else { return nil }
            let planID: String = planRow["plan_id"]
            let sourceIDs = try JSONDecoder().decode([String].self, from: Data((planRow["source_message_ids"] as String).utf8)).map(MessageID.init)
            let targetIDs = try JSONDecoder().decode([String].self, from: Data((planRow["target_room_ids"] as String).utf8)).map(RoomID.init)
            let chunkIndex: Int64 = planRow["next_chunk_index"]
            let totalChunkCount: Int64 = planRow["total_chunk_count"]
            guard chunkIndex < totalChunkCount else {
                try db.execute(sql: "UPDATE v2_forward_message_plans SET state = 'completed', updated_at = ? WHERE plan_id = ?", arguments: [now.timeIntervalSince1970, planID])
                return nil
            }
            let sourcePage = Int(chunkIndex) / targetIDs.count
            let sourceStart = sourcePage * V2BulkForwardMessagesOutboxEngine.sourceMessagesPerChunk
            let sourceEnd = min(sourceStart + V2BulkForwardMessagesOutboxEngine.sourceMessagesPerChunk, sourceIDs.count)
            guard sourceStart < sourceEnd else { throw V2ClientCommandError.commandConflict }
            let targetRoomID = targetIDs[Int(chunkIndex) % targetIDs.count]
            let operationID = try MessageForwardOperationID("\(planID)-f\(chunkIndex)")
            let command = try V2ForwardMessagesCommand(operationID: operationID, sourceMessageIDs: Array(sourceIDs[sourceStart ..< sourceEnd]), targetRoomIDs: [targetRoomID])
            let sources = String(decoding: try JSONEncoder().encode(command.sourceMessageIDs.map(\.rawValue)), as: UTF8.self)
            try db.execute(
                sql: "INSERT INTO v2_forward_message_chunks (operation_id, plan_id, chunk_index, source_message_ids, target_room_id, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)",
                arguments: [operationID.rawValue, planID, chunkIndex, sources, targetRoomID.rawValue, now.timeIntervalSince1970, now.timeIntervalSince1970]
            )
            return .init(command: command, state: .pending, attemptCount: 0, nextAttemptAt: now, terminalCode: nil)
        }
    }

    public func markForwardPlanChunkAcknowledged(operationID: MessageForwardOperationID, results: [V2ForwardMessageResult], now: Date) throws -> MessageForwardOperationID? {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_forward_message_chunks WHERE operation_id = ? AND state = 'pending'", arguments: [operationID.rawValue]) else { throw V2ClientCommandError.commandNotPending }
            let pending = try Self.decodeForwardPlanChunk(row)
            let planID: String = row["plan_id"]
            let chunkIndex: Int64 = row["chunk_index"]
            guard results.count == pending.command.sourceMessageIDs.count,
                  results.allSatisfy({ $0.targetRoomID == pending.command.targetRoomIDs[0] }),
                  Set(results.map(\.sourceMessageID)) == Set(pending.command.sourceMessageIDs)
            else { throw V2ClientCommandError.commandConflict }
            let succeeded = results.filter { $0.errorCode == nil }.count
            let failed = results.count - succeeded
            try db.execute(sql: "UPDATE v2_forward_message_chunks SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID.rawValue])
            try Self.advanceForwardPlan(planID: planID, completedChunkIndex: chunkIndex, succeeded: succeeded, failed: failed, now: now, db: db)
            return try MessageForwardOperationID(planID)
        }
    }

    public func scheduleForwardPlanChunkRetry(operationID: MessageForwardOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_forward_message_chunks WHERE operation_id = ? AND state = 'pending')", arguments: [operationID.rawValue]) == true else { throw V2ClientCommandError.commandNotPending }
            try db.execute(sql: "UPDATE v2_forward_message_chunks SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectForwardPlanChunk(operationID: MessageForwardOperationID, code: String, now: Date) throws -> MessageForwardOperationID? {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        return try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_forward_message_chunks WHERE operation_id = ? AND state = 'pending'", arguments: [operationID.rawValue]) else { throw V2ClientCommandError.commandNotPending }
            let pending = try Self.decodeForwardPlanChunk(row)
            let planID: String = row["plan_id"]
            let chunkIndex: Int64 = row["chunk_index"]
            try db.execute(sql: "UPDATE v2_forward_message_chunks SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue])
            try Self.advanceForwardPlan(planID: planID, completedChunkIndex: chunkIndex, succeeded: 0, failed: pending.command.sourceMessageIDs.count, now: now, db: db)
            return try MessageForwardOperationID(planID)
        }
    }

    public func cancelForwardPlan(operationID: MessageForwardOperationID, now: Date) throws {
        try databasePool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_forward_message_plans WHERE plan_id = ? AND state = 'active')", arguments: [operationID.rawValue]) == true else { throw V2ClientCommandError.commandConflict }
            try db.execute(sql: "UPDATE v2_forward_message_plans SET state = 'cancelled', updated_at = ? WHERE plan_id = ?", arguments: [now.timeIntervalSince1970, operationID.rawValue])
            try db.execute(sql: "UPDATE v2_forward_message_chunks SET state = 'cancelled' WHERE plan_id = ? AND state = 'pending'", arguments: [operationID.rawValue])
        }
    }

    public func forwardPlan(operationID: MessageForwardOperationID) throws -> V2ForwardMessagesPlan? {
        try databasePool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM v2_forward_message_plans WHERE plan_id = ?", arguments: [operationID.rawValue]).map(Self.decodeForwardMessagesPlan)
        }
    }

    public func enqueue(_ command: V2PendingSocialCommand) throws {
        try databasePool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT command_kind, target_user_id, relationship_action, block_action, stranger_permission, user_add_permission, allows_direct_read_receipts, allows_group_read_receipts FROM v2_pending_social_commands WHERE operation_id = ?", arguments: [command.operationID]) {
                let kind: String = row["command_kind"]
                let target: String? = row["target_user_id"]
                let relationship: String? = row["relationship_action"]
                let block: String? = row["block_action"]
                let permission: String? = row["stranger_permission"]
                let addPermission: String? = row["user_add_permission"]
                let direct: Bool? = row["allows_direct_read_receipts"], group: Bool? = row["allows_group_read_receipts"]
                guard kind == command.kind.rawValue, target == command.targetUserID?.rawValue, relationship == command.relationshipAction?.rawValue, block == command.blockAction?.rawValue, permission == command.strangerPermission?.rawValue, addPermission == command.userAddPermission?.rawValue, direct == command.allowsDirectReadReceipts, group == command.allowsGroupReadReceipts else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_social_commands (operation_id, command_kind, target_user_id, relationship_action, block_action, stranger_permission, user_add_permission, allows_direct_read_receipts, allows_group_read_receipts, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID, command.kind.rawValue, command.targetUserID?.rawValue, command.relationshipAction?.rawValue, command.blockAction?.rawValue, command.strangerPermission?.rawValue, command.userAddPermission?.rawValue, command.allowsDirectReadReceipts, command.allowsGroupReadReceipts, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingSocialCommand(
        _ command: V2PendingSocialCommand
    ) throws -> V2PendingSocialCommand {
        try databasePool.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_social_commands WHERE operation_id = ?",
                arguments: [command.operationID]
            ) {
                let decoded = try Self.decodePendingSocialCommand(existing)
                guard decoded.kind == command.kind,
                      decoded.targetUserID == command.targetUserID,
                      decoded.relationshipAction == command.relationshipAction,
                      decoded.blockAction == command.blockAction,
                      decoded.strangerPermission == command.strangerPermission,
                      decoded.userAddPermission == command.userAddPermission,
                      decoded.allowsDirectReadReceipts == command.allowsDirectReadReceipts,
                      decoded.allowsGroupReadReceipts == command.allowsGroupReadReceipts,
                      decoded.state == .pending
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_social_commands
                WHERE command_kind = ?
                  AND target_user_id IS ?
                  AND relationship_action IS ?
                  AND block_action IS ?
                  AND stranger_permission IS ?
                  AND user_add_permission IS ?
                  AND allows_direct_read_receipts IS ?
                  AND allows_group_read_receipts IS ?
                  AND state = 'pending'
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [
                    command.kind.rawValue,
                    command.targetUserID?.rawValue,
                    command.relationshipAction?.rawValue,
                    command.blockAction?.rawValue,
                    command.strangerPermission?.rawValue
                    , command.userAddPermission?.rawValue, command.allowsDirectReadReceipts, command.allowsGroupReadReceipts
                ]
            ) {
                return try Self.decodePendingSocialCommand(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_social_commands
                (operation_id, command_kind, target_user_id, relationship_action,
                 block_action, stranger_permission, user_add_permission, allows_direct_read_receipts, allows_group_read_receipts, state, attempt_count,
                 next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID,
                    command.kind.rawValue,
                    command.targetUserID?.rawValue,
                    command.relationshipAction?.rawValue,
                    command.blockAction?.rawValue,
                    command.strangerPermission?.rawValue,
                    command.userAddPermission?.rawValue,
                    command.allowsDirectReadReceipts, command.allowsGroupReadReceipts,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadySocialCommand(now: Date) throws -> V2PendingSocialCommand? {
        try databasePool.read { db in guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_social_commands WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }; return try Self.decodePendingSocialCommand(row) }
    }
    public func markSocialCommandAcknowledged(operationID: String) throws { try databasePool.write { db in try Self.requirePendingSocialCommand(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_social_commands SET state = 'acknowledged' WHERE operation_id = ?", arguments: [operationID]) } }
    public func scheduleSocialCommandRetry(operationID: String, nextAttemptAt: Date) throws { try databasePool.write { db in try Self.requirePendingSocialCommand(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_social_commands SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID]) } }
    public func rejectSocialCommand(operationID: String, code: String) throws { guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }; try databasePool.write { db in try Self.requirePendingSocialCommand(operationID, db: db); try db.execute(sql: "UPDATE v2_pending_social_commands SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID]) } }
    public func pendingSocialCommands() throws -> [V2PendingSocialCommand] { try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_social_commands ORDER BY created_at, operation_id").map(Self.decodePendingSocialCommand) } }

    public func enqueue(_ command: V2PendingGroupRoomCreation) throws {
        try databasePool.write { db in
            guard command.state == .pending, command.attemptCount == 0, command.createdRoomID == nil, command.terminalCode == nil else { throw V2ClientCommandError.commandConflict }
            let members = try Self.encodeGroupMemberUserIDs(command.initialMemberUserIDs)
            if let existing = try Row.fetchOne(db, sql: "SELECT title, delivery_mode, initial_member_user_ids FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [command.operationID.rawValue]) {
                let title: String = existing["title"]
                let deliveryMode: String = existing["delivery_mode"]
                let existingMembers: String = existing["initial_member_user_ids"]
                guard title == command.title, deliveryMode == command.deliveryMode.rawValue, existingMembers == members else { throw V2ClientCommandError.commandConflict }
                return
            }
            try db.execute(sql: "INSERT INTO v2_pending_group_room_creations (operation_id, title, delivery_mode, initial_member_user_ids, state, attempt_count, next_attempt_at, created_at) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)", arguments: [command.operationID.rawValue, command.title, command.deliveryMode.rawValue, members, command.nextAttemptAt.timeIntervalSince1970, command.nextAttemptAt.timeIntervalSince1970])
        }
    }

    public func enqueueOrReusePendingGroupRoomCreation(
        _ command: V2PendingGroupRoomCreation
    ) throws -> V2PendingGroupRoomCreation {
        try databasePool.write { db in
            guard command.state == .pending,
                  command.attemptCount == 0,
                  command.createdRoomID == nil,
                  command.terminalCode == nil
            else { throw V2ClientCommandError.commandConflict }
            let members = try Self.encodeGroupMemberUserIDs(command.initialMemberUserIDs)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM v2_pending_group_room_creations WHERE operation_id = ?",
                arguments: [command.operationID.rawValue]
            ) {
                let decoded = try Self.decodePendingGroupRoomCreation(existing)
                guard decoded.title == command.title,
                      decoded.deliveryMode == command.deliveryMode,
                      decoded.initialMemberUserIDs == command.initialMemberUserIDs,
                      decoded.state == .pending || decoded.state == .finalizing
                else { throw V2ClientCommandError.commandConflict }
                return decoded
            }
            if let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM v2_pending_group_room_creations
                WHERE title = ? AND delivery_mode = ? AND initial_member_user_ids = ? AND state IN ('pending', 'finalizing')
                ORDER BY created_at, operation_id
                LIMIT 1
                """,
                arguments: [command.title, command.deliveryMode.rawValue, members]
            ) {
                return try Self.decodePendingGroupRoomCreation(existing)
            }
            try db.execute(
                sql: """
                INSERT INTO v2_pending_group_room_creations
                (operation_id, title, delivery_mode, initial_member_user_ids, state, attempt_count, next_attempt_at, created_at)
                VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    command.operationID.rawValue,
                    command.title,
                    command.deliveryMode.rawValue,
                    members,
                    command.nextAttemptAt.timeIntervalSince1970,
                    command.nextAttemptAt.timeIntervalSince1970
                ]
            )
            return command
        }
    }

    public func nextReadyGroupRoomCreation(now: Date) throws -> V2PendingGroupRoomCreation? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_room_creations WHERE state IN ('pending', 'finalizing') AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingGroupRoomCreation(row)
        }
    }

    public func markGroupRoomCreationMembersUploaded(operationID: GroupRoomOperationID, uploadedMemberCount: Int) throws {
        try databasePool.write { db in
            guard uploadedMemberCount >= 0,
                  let row = try Row.fetchOne(
                    db,
                    sql: "SELECT initial_member_user_ids, uploaded_member_count FROM v2_pending_group_room_creations WHERE operation_id = ? AND state IN ('pending', 'finalizing')",
                    arguments: [operationID.rawValue]
                  )
            else { throw V2ClientCommandError.commandNotPending }
            let memberIDs = try Self.decodeGroupMemberUserIDs(row["initial_member_user_ids"] as String)
            let current = Int(row["uploaded_member_count"] as Int64)
            guard uploadedMemberCount >= current, uploadedMemberCount <= memberIDs.count else {
                throw V2ClientCommandError.commandConflict
            }
            try db.execute(
                sql: "UPDATE v2_pending_group_room_creations SET uploaded_member_count = ? WHERE operation_id = ?",
                arguments: [uploadedMemberCount, operationID.rawValue]
            )
        }
    }

    public func resetGroupRoomCreationUploadProgress(operationID: GroupRoomOperationID) throws {
        try databasePool.write { db in
            try Self.requireActiveGroupRoomCreation(operationID, db: db)
            try db.execute(
                sql: "UPDATE v2_pending_group_room_creations SET uploaded_member_count = 0 WHERE operation_id = ?",
                arguments: [operationID.rawValue]
            )
        }
    }

    public func markGroupRoomCreationAcknowledged(operationID: GroupRoomOperationID, roomID: RoomID) throws {
        try databasePool.write { db in
            try Self.requireActiveGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'acknowledged', created_room_id = ?, terminal_code = NULL WHERE operation_id = ?", arguments: [roomID.rawValue, operationID.rawValue])
        }
    }

    public func scheduleGroupRoomCreationRetry(operationID: GroupRoomOperationID, nextAttemptAt: Date) throws {
        try databasePool.write { db in
            guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == "pending" || state == "finalizing" || state == "cancelling" else { throw V2ClientCommandError.commandNotPending }
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET attempt_count = attempt_count + 1, next_attempt_at = ? WHERE operation_id = ?", arguments: [nextAttemptAt.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func beginCancellingGroupRoomCreation(operationID: GroupRoomOperationID, now: Date) throws {
        try databasePool.write { db in
            try Self.requirePendingGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'cancelling', next_attempt_at = ? WHERE operation_id = ?", arguments: [now.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func nextReadyGroupRoomCreationCancellation(now: Date) throws -> V2PendingGroupRoomCreation? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_pending_group_room_creations WHERE state = 'cancelling' AND next_attempt_at <= ? ORDER BY created_at, operation_id LIMIT 1", arguments: [now.timeIntervalSince1970]) else { return nil }
            return try Self.decodePendingGroupRoomCreation(row)
        }
    }

    public func markGroupRoomCreationCancelled(operationID: GroupRoomOperationID) throws {
        try databasePool.write { db in
            guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == "cancelling" else { throw V2ClientCommandError.commandNotPending }
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'cancelled', terminal_code = NULL WHERE operation_id = ?", arguments: [operationID.rawValue])
        }
    }

    public func resumeGroupRoomCreationAfterCancellationRefusal(operationID: GroupRoomOperationID, now: Date) throws {
        try databasePool.write { db in
            guard let state: String = try Row.fetchOne(db, sql: "SELECT state FROM v2_pending_group_room_creations WHERE operation_id = ?", arguments: [operationID.rawValue])?["state"], state == "cancelling" else { throw V2ClientCommandError.commandNotPending }
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'finalizing', next_attempt_at = ? WHERE operation_id = ?", arguments: [now.timeIntervalSince1970, operationID.rawValue])
        }
    }

    public func rejectGroupRoomCreation(operationID: GroupRoomOperationID, code: String) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
        try databasePool.write { db in
            try Self.requireActiveGroupRoomCreation(operationID, db: db)
            try db.execute(sql: "UPDATE v2_pending_group_room_creations SET state = 'rejected', terminal_code = ? WHERE operation_id = ?", arguments: [code, operationID.rawValue])
        }
    }

    public func pendingGroupRoomCreations() throws -> [V2PendingGroupRoomCreation] {
        try databasePool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM v2_pending_group_room_creations ORDER BY created_at, operation_id").map(Self.decodePendingGroupRoomCreation) }
    }

    public func groupRoomCreations() throws -> [V2PendingGroupRoomCreation] {
        try pendingGroupRoomCreations()
    }
}
