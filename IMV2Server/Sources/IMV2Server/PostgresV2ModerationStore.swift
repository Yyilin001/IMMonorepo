import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// 审核功能的第一条纵向实现：审核员显式屏蔽消息。
///
/// 它使用独立的幂等与审计记录，但写入与撤回相同的可见墓碑投影形态，
/// 因此较旧的本地时间线不会把未知的审核事件当成一次有效的消息接受。
public struct PostgresV2ModerationStore: V2TrustedSafetyModerationStore, V2OwnerValidatedModerationStore {
    private let database: any Database
    private let activationScope: V2RoomActivationWriteScope?
    private var existingMemberAdministrationTransaction=false
    private var existingMessageModerationTransaction=false
    public init(database: any Database) {
        self.database = database
        activationScope = nil
    }
    public init(database: any Database, activationScope: V2RoomActivationWriteScope) {
        self.database = database
        self.activationScope = activationScope
    }

    func usingMemberAdministrationTransaction() -> Self {
        var value=self;value.existingMemberAdministrationTransaction=true;return value
    }

    func usingMessageModerationTransaction() -> Self {
        var value=self;value.existingMessageModerationTransaction=true;return value
    }

    func apply(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        try await apply(command: command, ownerRoute: nil, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    private func apply(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        switch command.action {
        case .redactMessage:
            guard existingMessageModerationTransaction else { throw V2ModerationStoreError.unsupportedAction }
            return try await redact(command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
        case .muteMember:
            guard existingMemberAdministrationTransaction else { throw V2ModerationStoreError.unsupportedAction }
            return try await mute(command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
        case .removeMember:
            guard existingMemberAdministrationTransaction else { throw V2ModerationStoreError.unsupportedAction }
            return try await removeMember(command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
        case .freezeRoom, .unfreezeRoom:
            throw V2ModerationStoreError.unsupportedAction
        }
    }

    public func applyTrustedSafety(command: V2ModerationCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        try await applyTrustedSafety(command: command, ownerRoute: nil, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    public func applyTrustedSafetyOwnerValidated(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        try await applyTrustedSafety(command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    private func applyTrustedSafety(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        switch command.action {
        case .redactMessage:
            return try await redact(command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now, isTrustedSafety: true)
        case .freezeRoom, .unfreezeRoom:
            return try await controlRoom(command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
        case .removeMember, .muteMember:
            throw V2ModerationStoreError.unsupportedAction
        }
    }

    private func validatedAuditRetention(now: Date) throws -> Date {
        let retainUntil = now.addingTimeInterval(180 * 86_400)
        guard v2PostgresTimestampCanEncode(now), v2PostgresTimestampCanEncode(retainUntil) else {
            throw V2ModerationStoreError.corruptPersistenceState
        }
        return retainUntil
    }

    private func controlRoom(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        return try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil
        ) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ModerationStoreError.corruptPersistenceState }
            let roomID = try moderationUUID(command.roomID)
            let actorID = try moderationUUID(command.actorUserID)
            let operationID = try moderationUUID(command.operationID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let activationScope { try await activationScope.require([roomID], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: roomID, route: ownerRoute, sql: sql) }
            if let prior = try await sql.raw("""
                SELECT room_id, action, target_user_id, message_id, resulting_message_revision, mute_until, reason_code,
                       room_sequence, event_id, created_at
                FROM im_v2.moderation_operations
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).first(decoding: ModerationOperationRow.self) {
                guard prior.matchesRoomControl(command, roomID: roomID) else { return .idempotencyConflict }
                return .idempotent(try prior.result(operationID: command.operationID))
            }
            let retainUntil = try validatedAuditRetention(now: now)
            guard let room = try await sql.raw("""
                SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class, frozen_at
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
                """).first(decoding: ModerationControlRoomRow.self) else { throw V2ModerationStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2ModerationStoreError.corruptPersistenceState }
            switch command.action {
            case .freezeRoom:
                guard room.frozenAt == nil else { return .actionAlreadyInDesiredState }
            case .unfreezeRoom:
                guard room.frozenAt != nil else { return .actionAlreadyInDesiredState }
            default:
                throw V2ModerationStoreError.unsupportedAction
            }
            guard let admission = try await sql.raw("""
                SELECT eligible_member_count, command_window_limit, command_window_used,
                       shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: ModerationAdmissionRow.self),
                let shard = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit, command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
                FOR UPDATE
                """).first(decoding: ModerationShardRow.self) else { throw V2ModerationStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2ModerationStoreError.corruptPersistenceState }
            let reservation = try V2CommandAdmissionEvaluator.reserve(profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
            let nextRoom: RoomAdmissionState; let nextShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let reservedRoom, let reservedShard): nextRoom = reservedRoom; nextShard = reservedShard
            }
            guard let lease = nextShard.lease, room.roomSequence < Int64.max else { throw V2ModerationStoreError.corruptPersistenceState }
            let roomSequence = room.roomSequence + 1
            let eventUUID = try moderationUUID(eventID)
            let eventType = command.action == .freezeRoom ? "room.frozen" : "room.unfrozen"
            let frozenAt = command.action == .freezeRoom ? now : nil
            let frozenBy = command.action == .freezeRoom ? actorID : nil
            guard let timestamp = try await sql.raw("""
                UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence),
                    frozen_at = \(bind: frozenAt), frozen_by_user_id = \(bind: frozenBy)
                WHERE room_id = \(bind: roomID)
                RETURNING \(bind: now)::timestamptz AS created_at
                """).first(decoding: ModerationCommittedTimestampRow.self) else {
                throw V2ModerationStoreError.corruptPersistenceState
            }
            let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
            try await sql.raw("""
                UPDATE im_v2.room_admission SET command_window_used = \(bind: nextRoom.commandWindow.used), shard_lease_id = \(bind: try moderationUUID(lease.id)), shard_lease_generation = \(bind: try moderationSigned(lease.generation)) WHERE room_id = \(bind: roomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try moderationUUID(lease.id)) AND generation = \(bind: try moderationSigned(lease.generation))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: roomSequence), \(bind: eventType), \(bind: actorID),
                        jsonb_build_object('event_type', \(bind: eventType), 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: roomSequence), 'actor_user_id', \(bind: actorID.uuidString), 'server_created_at_ms', \(bind: createdAtMilliseconds)), \(bind: room.membershipRevision), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.moderation_operations (actor_user_id, operation_id, room_id, action, target_user_id, message_id, resulting_message_revision, mute_until, reason_code, room_sequence, event_id, created_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: command.action == .freezeRoom ? "freeze_room" : "unfreeze_room"), NULL, NULL, NULL, NULL, \(bind: command.reasonCode.rawValue), \(bind: roomSequence), \(bind: eventUUID), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.moderation_audit_entries (actor_user_id, operation_id, room_id, action, target_user_id, message_id, reason_code, occurred_at, retain_until) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: command.action == .freezeRoom ? "freeze_room" : "unfreeze_room"), NULL, NULL, \(bind: command.reasonCode.rawValue), \(bind: now), \(bind: retainUntil))
                """).run()
            return .applied(try .init(roomID: command.roomID, operationID: command.operationID, action: command.action, targetUserID: nil, messageID: nil, muteUntil: nil, roomSequence: moderationUnsigned(roomSequence), eventID: eventID, createdAt: timestamp.createdAt))
        }
    }

    private func redact(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date, isTrustedSafety: Bool = false) async throws -> V2ModerationOutcome {
        return try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil, existingTransaction: existingMessageModerationTransaction
        ) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ModerationStoreError.corruptPersistenceState }
            let roomID = try moderationUUID(command.roomID)
            let actorID = try moderationUUID(command.actorUserID)
            let operationID = try moderationUUID(command.operationID)
            guard let commandMessageID = command.messageID else { throw V2ModerationStoreError.corruptPersistenceState }
            let messageID = try moderationUUID(commandMessageID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let activationScope { try await activationScope.require([roomID], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: roomID, route: ownerRoute, sql: sql) }
            if !existingMessageModerationTransaction, let prior = try await sql.raw("""
                SELECT room_id, action, target_user_id, message_id, resulting_message_revision, mute_until, reason_code,
                       room_sequence, event_id, created_at
                FROM im_v2.moderation_operations
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).first(decoding: ModerationOperationRow.self) {
                guard prior.matchesRedaction(command, roomID: roomID, messageID: messageID) else { return .idempotencyConflict }
                return .idempotent(try prior.result(operationID: command.operationID))
            }
            let retainUntil = try validatedAuditRetention(now: now)
            guard let room = try await sql.raw("""
                SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
                """).first(decoding: ModerationRoomRow.self) else { throw V2ModerationStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2ModerationStoreError.corruptPersistenceState }
            if !isTrustedSafety && !existingMessageModerationTransaction {
                guard let role = try await sql.raw("""
                    SELECT role FROM im_v2.room_memberships
                    WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID)
                      AND joined_revision <= \(bind: room.membershipRevision)
                      AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                    FOR UPDATE
                    """).first(decoding: ModerationRoleRow.self),
                    let roleValue = V2RoomMembershipRole(rawValue: role.role)
                else { throw V2ModerationStoreError.actorNotAuthorized }
                try V2ModerationAuthorization.authorize(actorRole: roleValue, action: command.action, now: now, command: command)
            }
            guard let message = try await sql.raw("""
                SELECT room_id, content_revision, withdrawn_at FROM im_v2.messages
                WHERE message_id = \(bind: messageID) FOR UPDATE
                """).first(decoding: ModerationMessageRow.self), message.roomID == roomID
            else { throw V2ModerationStoreError.messageNotFound }
            guard message.withdrawnAt == nil else { return .messageAlreadyRedacted }
            if let expectedRevision = command.expectedMessageRevision {
                let expectedRevisionValue = try moderationSigned(expectedRevision)
                guard message.contentRevision == expectedRevisionValue else {
                // 此结果在特权边界有意保持不透明。审核工作器复查租约，
                // 并将过期发现标记为已被取代；绝不处理较新的编辑。
                    return .messageAlreadyRedacted
                }
            }
            guard let admission = try await sql.raw("""
                SELECT eligible_member_count, command_window_limit, command_window_used,
                       shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: ModerationAdmissionRow.self),
                let shard = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit, command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
                FOR UPDATE
                """).first(decoding: ModerationShardRow.self) else { throw V2ModerationStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2ModerationStoreError.corruptPersistenceState }
            let reservation = try V2CommandAdmissionEvaluator.reserve(profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
            let nextRoom: RoomAdmissionState; let nextShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let reservedRoom, let reservedShard): nextRoom = reservedRoom; nextShard = reservedShard
            }
            guard let lease = nextShard.lease, room.roomSequence < Int64.max, message.contentRevision < Int64.max else { throw V2ModerationStoreError.corruptPersistenceState }
            let roomSequence = room.roomSequence + 1; let messageRevision = message.contentRevision + 1
            let eventUUID = try moderationUUID(eventID)
            let previousProjectionState = try await PostgresV2MessageProjectionStateRepository()
                .loadCurrentOrMaterialize(
                    messageID: messageID,
                    revision: message.contentRevision,
                    sql: sql
                )
            let redactedProjectionState = try previousProjectionState.state.applyingRemoval(
                revision: moderationUnsigned(messageRevision)
            )
            // 只有响应使用解码后的时间戳；持久化仍保留原始 Date。
            guard let timestamp = try await sql.raw("""
                UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence) WHERE room_id = \(bind: roomID)
                RETURNING \(bind: now)::timestamptz AS created_at
                """).first(decoding: ModerationCommittedTimestampRow.self) else {
                throw V2ModerationStoreError.corruptPersistenceState
            }
            let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
            try await sql.raw("UPDATE im_v2.messages SET content_revision = \(bind: messageRevision), withdrawn_at = \(bind: now), withdrawn_by_user_id = \(bind: actorID) WHERE message_id = \(bind: messageID)").run()
            // 现有授权许可通过消息撤回失效。此次显式撤销还会防止之后复用引用，
            // 并为保留期清理提供确定性的处置标记。
            try await sql.raw("UPDATE im_v2.message_media_references SET revoked_at = \(bind: now) WHERE message_id = \(bind: messageID) AND revoked_at IS NULL").run()
            try await sql.raw("""
                UPDATE im_v2.room_admission SET command_window_used = \(bind: nextRoom.commandWindow.used), shard_lease_id = \(bind: try moderationUUID(lease.id)), shard_lease_generation = \(bind: try moderationSigned(lease.generation)) WHERE room_id = \(bind: roomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try moderationUUID(lease.id)) AND generation = \(bind: try moderationSigned(lease.generation))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: roomSequence), 'message.redacted', \(bind: actorID),
                        jsonb_build_object('event_type', 'message.redacted', 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: roomSequence), 'message_id', \(bind: messageID.uuidString), 'message_revision', \(bind: messageRevision), 'actor_user_id', \(bind: actorID.uuidString), 'server_created_at_ms', \(bind: createdAtMilliseconds), 'is_withdrawn', true), \(bind: room.membershipRevision), \(bind: now))
                """).run()
            try await PostgresV2MessageProjectionStateRepository().persist(
                try .init(
                    state: redactedProjectionState,
                    originEventID: previousProjectionState.originEventID,
                    stateEventID: eventUUID,
                    createdAt: now
                ),
                sql: sql
            )
            if !existingMessageModerationTransaction { try await sql.raw("""
                INSERT INTO im_v2.moderation_operations (actor_user_id, operation_id, room_id, action, target_user_id, message_id, resulting_message_revision, mute_until, reason_code, room_sequence, event_id, created_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), 'redact_message', NULL, \(bind: messageID), \(bind: messageRevision), NULL, \(bind: command.reasonCode.rawValue), \(bind: roomSequence), \(bind: eventUUID), \(bind: now))
                """).run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.moderation_audit_entries (actor_user_id, operation_id, room_id, action, target_user_id, message_id, reason_code, occurred_at, retain_until) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), 'redact_message', NULL, \(bind: messageID), \(bind: command.reasonCode.rawValue), \(bind: now), \(bind: retainUntil))
                """).run()
            return .applied(try .init(roomID: command.roomID, operationID: command.operationID, action: .redactMessage, targetUserID: nil, messageID: commandMessageID, messageRevision: moderationUnsigned(messageRevision), muteUntil: nil, roomSequence: moderationUnsigned(roomSequence), eventID: eventID, createdAt: timestamp.createdAt))
        }
    }

    private func removeMember(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        return try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil, existingTransaction: existingMemberAdministrationTransaction
        ) { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let commandTargetID = command.targetUserID
            else { throw V2ModerationStoreError.corruptPersistenceState }
            let roomID = try moderationUUID(command.roomID)
            let actorID = try moderationUUID(command.actorUserID)
            let targetID = try moderationUUID(commandTargetID)
            let operationID = try moderationUUID(command.operationID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let activationScope { try await activationScope.require([roomID], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: roomID, route: ownerRoute, sql: sql) }

            let retainUntil = try validatedAuditRetention(now: now)
            guard let room = try await sql.raw("""
                SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
                """).first(decoding: ModerationRoomRow.self) else { throw V2ModerationStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2ModerationStoreError.corruptPersistenceState }
            guard let actor = try await sql.raw("""
                SELECT role FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID)
                  AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                FOR UPDATE
                """).first(decoding: ModerationRoleRow.self),
                let actorRole = V2RoomMembershipRole(rawValue: actor.role)
            else { throw V2ModerationStoreError.actorNotAuthorized }
            try V2ModerationAuthorization.authorize(actorRole: actorRole, configuredPermissions: try await v2ResolvedGroupPermissions(roomID:roomID,role:actorRole,sql:sql), action: .removeMember, now: now, command: command)
            let target = try await sql.raw("""
                SELECT user_id, role FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID) AND user_id = \(bind: targetID)
                  AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                ORDER BY joined_revision DESC LIMIT 1 FOR UPDATE
                """).first(decoding: ModerationMemberRow.self)
            guard let target else { return .targetNotMember }
            // 单一且不可转让的所有者是当前 V2 权限模型。
            guard target.role != "owner" else { throw V2ModerationStoreError.actorNotAuthorized }
            guard let admission = try await sql.raw("""
                SELECT eligible_member_count, command_window_limit, command_window_used,
                       shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: ModerationAdmissionRow.self),
                let shard = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit, command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
                FOR UPDATE
                """).first(decoding: ModerationShardRow.self) else { throw V2ModerationStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation,
                  admission.eligibleMemberCount > 1
            else { throw V2ModerationStoreError.corruptPersistenceState }
            let reservation = try V2CommandAdmissionEvaluator.reserve(profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
            guard let group = try await sql.raw("""
                SELECT profile.owner_user_id, profile.title, profile.created_at
                FROM im_v2.group_rooms AS profile JOIN im_v2.rooms AS room USING (room_id)
                WHERE profile.room_id = \(bind: roomID)
                """).first(decoding: ModerationGroupProfileRow.self),
                  let groupCreatedAtMilliseconds = try? v2GatewayMilliseconds(group.createdAt)
            else { throw V2ModerationStoreError.corruptPersistenceState }
            let reservedRoom: RoomAdmissionState; let reservedShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let roomState, let shardState):
                reservedRoom = try .init(eligibleMemberCount: admission.eligibleMemberCount - 1, commandWindow: roomState.commandWindow)
                reservedShard = shardState
            }
            guard let lease = reservedShard.lease, room.membershipRevision < Int64.max, room.roomSequence < Int64.max else { throw V2ModerationStoreError.corruptPersistenceState }
            let membershipRevision = room.membershipRevision + 1
            let roomSequence = room.roomSequence + 1
            let eventUUID = try moderationUUID(eventID)
            guard let timestamp = try await sql.raw("""
                UPDATE im_v2.rooms SET membership_revision = \(bind: membershipRevision), room_sequence = \(bind: roomSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING \(bind: now)::timestamptz AS created_at
                """).first(decoding: ModerationCommittedTimestampRow.self) else {
                throw V2ModerationStoreError.corruptPersistenceState
            }
            let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
            try await sql.raw("""
                UPDATE im_v2.room_admission SET eligible_member_count = \(bind: admission.eligibleMemberCount - 1), command_window_used = \(bind: reservedRoom.commandWindow.used), shard_lease_id = \(bind: try moderationUUID(lease.id)), shard_lease_generation = \(bind: try moderationSigned(lease.generation)) WHERE room_id = \(bind: roomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try moderationUUID(lease.id)) AND generation = \(bind: try moderationSigned(lease.generation))
                """).run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = \(bind: membershipRevision) WHERE room_id = \(bind: roomID) AND user_id = \(bind: targetID) AND left_revision IS NULL").run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: roomSequence), 'membership_changed', \(bind: actorID),
                        jsonb_build_object('event_type', 'membership_changed', 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: roomSequence), 'actor_user_id', \(bind: actorID.uuidString), 'target_user_id', \(bind: targetID.uuidString), 'action', 'remove', 'membership_revision', \(bind: membershipRevision), 'capacity_class', \(bind: room.capacityClass.rawValue),  'owner_user_id', \(bind: group.ownerUserID.uuidString), 'title', \(bind: group.title),
                                           'created_at_ms', \(bind: groupCreatedAtMilliseconds), 'moderation_reason_code', \(bind: command.reasonCode.rawValue), 'server_created_at_ms', \(bind: createdAtMilliseconds)), \(bind: membershipRevision), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.user_state_event_outbox
                    (source_event_id, user_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
                SELECT event_id, \(bind: targetID), 'membership', payload, created_at, created_at, room_id
                FROM im_v2.room_events WHERE event_id = \(bind: eventUUID)
                """).run()

            try await sql.raw("INSERT INTO im_v2.moderation_audit_entries (actor_user_id, operation_id, room_id, action, target_user_id, message_id, reason_code, occurred_at, retain_until) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), 'remove_member', \(bind: targetID), NULL, \(bind: command.reasonCode.rawValue), \(bind: now), \(bind: retainUntil))").run()
            return .applied(try .init(roomID: command.roomID, operationID: command.operationID, action: .removeMember, targetUserID: commandTargetID, messageID: nil, membershipRevision: moderationUnsigned(membershipRevision), muteUntil: nil, roomSequence: moderationUnsigned(roomSequence), eventID: eventID, createdAt: timestamp.createdAt))
        }
    }

    private func mute(command: V2ModerationCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2ModerationOutcome {
        if let muteUntil = command.muteUntil, !v2PostgresTimestampCanEncode(muteUntil) {
            throw V2ModerationValidationError.invalidMuteExpiry
        }
        return try await v2WithPostgresTransactionRetry(
            database: database, maximumRetryCount: 0,
            classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil, existingTransaction: existingMemberAdministrationTransaction
        ) { transaction in
            guard let sql = transaction as? any SQLDatabase,
                  let commandTargetID = command.targetUserID,
                  let commandMuteUntil = command.muteUntil
            else { throw V2ModerationStoreError.corruptPersistenceState }
            let roomID = try moderationUUID(command.roomID)
            let actorID = try moderationUUID(command.actorUserID)
            let operationID = try moderationUUID(command.operationID)
            let targetID = try moderationUUID(commandTargetID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let activationScope { try await activationScope.require([roomID], sql: sql) }
            if activationScope == nil, let ownerRoute { try await v2RequireRoomOwner(roomID: roomID, route: ownerRoute, sql: sql) }

            let retainUntil = try validatedAuditRetention(now: now)
            guard v2PostgresTimestampPrecedes(now, commandMuteUntil) else { throw V2ModerationValidationError.invalidMuteExpiry }
            guard let room = try await sql.raw("""
                SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
                """).first(decoding: ModerationRoomRow.self) else { throw V2ModerationStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2ModerationStoreError.corruptPersistenceState }
            guard let role = try await sql.raw("""
                SELECT role FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID)
                  AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                FOR UPDATE
                """).first(decoding: ModerationRoleRow.self),
                let roleValue = V2RoomMembershipRole(rawValue: role.role)
            else { throw V2ModerationStoreError.actorNotAuthorized }
            try V2ModerationAuthorization.authorize(actorRole: roleValue, configuredPermissions: try await v2ResolvedGroupPermissions(roomID:roomID,role:roleValue,sql:sql), action: command.action, now: now, command: command)
            let targetIsMember = try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1 FROM im_v2.room_memberships
                    WHERE room_id = \(bind: roomID) AND user_id = \(bind: targetID)
                      AND joined_revision <= \(bind: room.membershipRevision)
                      AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                ) AS value
                """).first(decoding: ModerationBooleanRow.self)?.value ?? false
            guard targetIsMember else { return .targetNotMember }
            if let activeMute = try await sql.raw("SELECT mute_until >= \(bind: commandMuteUntil) AS value FROM im_v2.room_member_mutes WHERE room_id = \(bind: roomID) AND user_id = \(bind: targetID) FOR UPDATE").first(decoding: ModerationBooleanRow.self), activeMute.value {
                return .actionAlreadyInDesiredState
            }
            guard let admission = try await sql.raw("""
                SELECT eligible_member_count, command_window_limit, command_window_used,
                       shard_lease_id, shard_lease_generation
                FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: ModerationAdmissionRow.self),
                let shard = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit, command_window_used
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
                FOR UPDATE
                """).first(decoding: ModerationShardRow.self) else { throw V2ModerationStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2ModerationStoreError.corruptPersistenceState }
            let reservation = try V2CommandAdmissionEvaluator.reserve(profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
            let nextRoom: RoomAdmissionState; let nextShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let reservedRoom, let reservedShard): nextRoom = reservedRoom; nextShard = reservedShard
            }
            guard let lease = nextShard.lease, room.roomSequence < Int64.max else { throw V2ModerationStoreError.corruptPersistenceState }
            let roomSequence = room.roomSequence + 1
            let eventUUID = try moderationUUID(eventID)
            guard let timestamp = try await sql.raw("""
                UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence) WHERE room_id = \(bind: roomID)
                RETURNING \(bind: now)::timestamptz AS created_at, \(bind: commandMuteUntil)::timestamptz AS mute_until
                """).first(decoding: ModerationMuteTimestampRow.self) else {
                throw V2ModerationStoreError.corruptPersistenceState
            }
            let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
            let muteUntilMilliseconds = try v2GatewayMilliseconds(timestamp.muteUntil)
            try await sql.raw("""
                INSERT INTO im_v2.room_member_mutes (room_id, user_id, mute_until, actor_user_id, operation_id, created_at)
                VALUES (\(bind: roomID), \(bind: targetID), \(bind: commandMuteUntil), \(bind: actorID), \(bind: operationID), \(bind: now))
                ON CONFLICT (room_id, user_id) DO UPDATE
                SET mute_until = EXCLUDED.mute_until, actor_user_id = EXCLUDED.actor_user_id,
                    operation_id = EXCLUDED.operation_id, created_at = EXCLUDED.created_at
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_admission SET command_window_used = \(bind: nextRoom.commandWindow.used), shard_lease_id = \(bind: try moderationUUID(lease.id)), shard_lease_generation = \(bind: try moderationSigned(lease.generation)) WHERE room_id = \(bind: roomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try moderationUUID(lease.id)) AND generation = \(bind: try moderationSigned(lease.generation))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: roomSequence), 'member.muted', \(bind: actorID),
                        jsonb_build_object('event_type', 'member.muted', 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: roomSequence), 'actor_user_id', \(bind: actorID.uuidString), 'target_user_id', \(bind: targetID.uuidString), 'mute_until_ms', \(bind: muteUntilMilliseconds), 'server_created_at_ms', \(bind: createdAtMilliseconds)), \(bind: room.membershipRevision), \(bind: now))
                """).run()

            try await sql.raw("""
                INSERT INTO im_v2.moderation_audit_entries (actor_user_id, operation_id, room_id, action, target_user_id, message_id, reason_code, occurred_at, retain_until) VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), 'mute_member', \(bind: targetID), NULL, \(bind: command.reasonCode.rawValue), \(bind: now), \(bind: retainUntil))
                """).run()
            return .applied(try .init(roomID: command.roomID, operationID: command.operationID, action: .muteMember, targetUserID: commandTargetID, messageID: nil, muteUntil: timestamp.muteUntil, roomSequence: moderationUnsigned(roomSequence), eventID: eventID, createdAt: timestamp.createdAt))
        }
    }
}

private struct ModerationCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}

private struct ModerationMuteTimestampRow: Decodable {
    let createdAt: Date
    let muteUntil: Date
    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case muteUntil = "mute_until"
    }
}

private struct ModerationRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let capacityClass: V2GroupCapacityClass; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class" } }
private struct ModerationControlRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let capacityClass: V2GroupCapacityClass; let frozenAt: Date?; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class", frozenAt = "frozen_at" } }
private struct ModerationRoleRow: Decodable { let role: String }
private struct ModerationBooleanRow: Decodable { let value: Bool }
private struct ModerationMessageRow: Decodable { let roomID: UUID; let contentRevision: Int64; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", contentRevision = "content_revision", withdrawnAt = "withdrawn_at" } }
private struct ModerationMemberRow: Decodable { let userID: UUID; let role: String; enum CodingKeys: String, CodingKey { case userID = "user_id", role } }
private struct ModerationOperationRow: Decodable {
    let muteMatches: Bool?
    let roomID: UUID; let action: String; let targetUserID: UUID?; let messageID: UUID?; let resultingMessageRevision: Int64?; let resultingMembershipRevision: Int64?; let muteUntil: Date?; let reasonCode: String; let roomSequence: Int64; let eventID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case muteMatches = "mute_matches", roomID = "room_id", action, targetUserID = "target_user_id", messageID = "message_id", resultingMessageRevision = "resulting_message_revision", resultingMembershipRevision = "resulting_membership_revision", muteUntil = "mute_until", reasonCode = "reason_code", roomSequence = "room_sequence", eventID = "event_id", createdAt = "created_at" }
    func matchesRedaction(_ command: V2ModerationCommand, roomID: UUID, messageID: UUID) -> Bool { self.roomID == roomID && action == "redact_message" && command.action == .redactMessage && targetUserID == nil && self.messageID == messageID && muteUntil == nil && reasonCode == command.reasonCode.rawValue }
    func matchesRoomControl(_ command: V2ModerationCommand, roomID: UUID) -> Bool {
        let expectedAction = command.action == .freezeRoom ? "freeze_room" : "unfreeze_room"
        return self.roomID == roomID && action == expectedAction && targetUserID == nil && messageID == nil && resultingMessageRevision == nil && muteUntil == nil && reasonCode == command.reasonCode.rawValue
    }
    func result(operationID: ModerationOperationID) throws -> V2ModerationResult {
        guard v2PostgresTimestampCanEncode(createdAt), muteUntil.map(v2PostgresTimestampCanEncode) ?? true else { throw V2ModerationStoreError.corruptPersistenceState }
        switch action {
        case "redact_message":
            guard targetUserID == nil, let messageID, let resultingMessageRevision, muteUntil == nil else { throw V2ModerationStoreError.corruptPersistenceState }
            return try .init(roomID: .init(roomID.uuidString), operationID: operationID, action: .redactMessage, targetUserID: nil, messageID: .init(messageID.uuidString), messageRevision: moderationUnsigned(resultingMessageRevision), muteUntil: nil, roomSequence: moderationUnsigned(roomSequence), eventID: .init(eventID.uuidString), createdAt: createdAt)
        case "freeze_room", "unfreeze_room":
            guard targetUserID == nil, messageID == nil, resultingMessageRevision == nil, muteUntil == nil else { throw V2ModerationStoreError.corruptPersistenceState }
            return try .init(roomID: .init(roomID.uuidString), operationID: operationID, action: action == "freeze_room" ? .freezeRoom : .unfreezeRoom, targetUserID: nil, messageID: nil, muteUntil: nil, roomSequence: moderationUnsigned(roomSequence), eventID: .init(eventID.uuidString), createdAt: createdAt)
        default:
            throw V2ModerationStoreError.corruptPersistenceState
        }
    }
}
private struct ModerationAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension ModerationAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)) } }
private struct ModerationShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; }
extension ModerationShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: moderationUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))) } }
private func moderationUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: identifier.rawValue) else { throw V2ModerationStoreError.corruptPersistenceState }; return value }
private func moderationUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2ModerationStoreError.corruptPersistenceState }; return UInt64(value) }
private func moderationSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2ModerationStoreError.corruptPersistenceState }; return Int64(value) }

private struct ModerationGroupProfileRow: Decodable {
    let ownerUserID: UUID
    let title: String
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case ownerUserID = "owner_user_id", title, createdAt = "created_at"
    }
}
