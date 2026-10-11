import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 消息编辑的 PostgreSQL 实现。
///
/// 受修订约束的正文替换、权威房间事件与持久化操作重放记录会在同一个事务内提交。
package struct V2PostgresMessageEditPersistence: Sendable {
    private let database: any Database
    private let contentReviewMode: V2ContentReviewMode
    private let identities: any V2MembershipIdentitySnapshotValidating

    /// 组合数据库、内容审核模式与成员身份快照校验器。
    ///
    /// - Parameters:
    ///   - transaction: 存放房间、消息、准入与事件的数据库。
    ///   - contentReviewMode: 内容审核模式。
    ///   - identities: 成员身份快照校验器；为 `nil` 时使用基于同一数据库的默认实现。
    package init(transaction: any Database, contentReviewMode: V2ContentReviewMode, identities: (any V2MembershipIdentitySnapshotValidating)? = nil) throws {
        guard transaction.inTransaction else { throw V2MessageEditStoreError.corruptPersistenceState }
        self.database = transaction
        self.contentReviewMode = contentReviewMode
        self.identities = identities ?? V2PostgresMembershipIdentitySnapshotValidator(database: transaction)
    }

    /// 执行一次消息编辑（由外层 Operation Store 校验房间归属并管理事务）。
    ///
    /// - Parameters:
    ///   - command: 消息编辑命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 编辑结果。
    /// - Throws: 无权限、状态冲突、容量不足或持久化失败时抛出。
    package func edit(command: V2EditMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageEditOutcome {
        // 在外层已取得的事务中复用控制侧身份边界。
        // 编辑只有一位操作者，因此两个快照 ID 都指向该操作者。
        let identity = try await identities.snapshot(actorUserID: command.actorUserID, targetUserID: command.actorUserID)
        guard identity.actorUserID == command.actorUserID,
              identity.targetUserID == command.actorUserID
        else { throw V2MessageEditStoreError.corruptPersistenceState }
        let transaction = database
        guard let sql = transaction as? any SQLDatabase else { throw V2MessageEditStoreError.corruptPersistenceState }
        let roomID = try v2PersistenceUUID(command.roomID, invalid: V2MessageEditStoreError.corruptPersistenceState), actorID = try v2PersistenceUUID(command.actorUserID, invalid: V2MessageEditStoreError.corruptPersistenceState)
        let operationID = try v2PersistenceUUID(command.operationID, invalid: V2MessageEditStoreError.corruptPersistenceState), messageID = try v2PersistenceUUID(command.messageID, invalid: V2MessageEditStoreError.corruptPersistenceState)
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: actorID.uuidString + ":" + operationID.uuidString), 0))").run()
        guard v2PostgresTimestampCanEncode(now) else { throw V2MessageEditStoreError.corruptPersistenceState }
        guard let room = try await sql.raw("SELECT room_kind, frozen_at, room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: EditRoomRow.self) else { throw V2MessageEditStoreError.roomNotFound }
        guard room.capacityProfileID == capacityProfile.id else { throw V2MessageEditStoreError.corruptPersistenceState }
        let actor = try await sql.raw("""
            SELECT membership.role,
                   EXISTS (SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = \(bind: roomID) AND mute.user_id = \(bind: actorID)
                             AND mute.mute_until > \(bind: now)) AS muted
            FROM im_v2.room_memberships AS membership
            WHERE membership.room_id = \(bind: roomID) AND membership.user_id = \(bind: actorID)
              AND membership.joined_revision <= \(bind: room.membershipRevision)
              AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: room.membershipRevision))
            """).first(decoding: EditActorRow.self)
        try await v2AuthorizeContentWrite(
            roomID: roomID, isGroup: room.kind == "group", frozenAt: room.frozenAt,
            actorIsActive: identity.actorIsActive, actorRole: actor?.role,
            isMuted: actor?.muted ?? false, sql: sql
        )
        guard let message = try await sql.raw("SELECT room_id, sender_user_id, content_revision, withdrawn_at FROM im_v2.messages WHERE message_id = \(bind: messageID) FOR UPDATE").first(decoding: EditMessageRow.self), message.roomID == roomID else { throw V2MessageEditStoreError.messageNotFound }
        guard message.senderUserID == actorID else { throw V2MessageEditStoreError.actorNotAuthor }
        // 墓碑是内容修改的终态。在检查修订围栏前先检查它，
        // 使并发撤回前捕获的编辑看到持久化终态，
        // 而不是被误认为可能可重试的过期写入冲突。
        guard message.withdrawnAt == nil else { return .alreadyWithdrawn }
        guard try v2PersistenceUnsigned(message.contentRevision, invalid: V2MessageEditStoreError.corruptPersistenceState) == command.expectedMessageRevision else { return .revisionConflict(current: try v2PersistenceUnsigned(message.contentRevision, invalid: V2MessageEditStoreError.corruptPersistenceState)) }
        let acceptance = try await v2MessageAcceptanceFact(messageID: messageID, roomID: roomID, sql: sql)
        guard let admission = try await sql.raw("SELECT eligible_member_count, command_window_limit, command_window_used, shard_lease_id, shard_lease_generation FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: EditAdmissionRow.self), let shard = try await sql.raw("SELECT lease_id, generation, valid_until, command_window_limit, command_window_used FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) FOR UPDATE").first(decoding: EditShardRow.self) else { throw V2MessageEditStoreError.corruptPersistenceState }
        guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2MessageEditStoreError.corruptPersistenceState }
        let reservation = try V2CommandAdmissionEvaluator.reserve(profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
        let nextRoom: RoomAdmissionState, nextShard: ShardAdmissionState
        switch reservation {
        case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): return .unavailable(reason)
        case .accepted(_, let reservedRoom, let reservedShard): nextRoom = reservedRoom; nextShard = reservedShard
        }
        guard let lease = nextShard.lease, room.roomSequence < Int64.max, message.contentRevision < Int64.max else { throw V2MessageEditStoreError.corruptPersistenceState }
        let nextSequence = room.roomSequence + 1, nextRevision = message.contentRevision + 1
        let eventUUID = try v2PersistenceUUID(eventID, invalid: V2MessageEditStoreError.corruptPersistenceState)
        let previousProjectionState = try await PostgresV2MessageProjectionStateRepository()
            .loadCurrentOrMaterialize(
                messageID: messageID,
                revision: message.contentRevision,
                sql: sql
            )
        let editedProjectionState = try previousProjectionState.state.applyingEdit(
            revision: v2PersistenceUnsigned(nextRevision, invalid: V2MessageEditStoreError.corruptPersistenceState),
            text: command.text,
            entities: []
        )
        guard previousProjectionState.originEventID == acceptance.eventID else { throw V2MessageEditStoreError.corruptPersistenceState }
        let replacementJSON = try V2MessageEditReplacement(state: editedProjectionState, acceptance: acceptance).encodedJSON()
        // 新响应和事件载荷使用 PostgreSQL 解码后的时间戳；
        // 所有存储绑定仍使用原始时钟值。
        guard let timestamp = try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: nextSequence) WHERE room_id = \(bind: roomID) RETURNING \(bind: now)::timestamptz AS created_at").first(decoding: EditCommittedTimestampRow.self) else { throw V2MessageEditStoreError.corruptPersistenceState }
        let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
        try await sql.raw("UPDATE im_v2.messages SET text_body = \(bind: command.text), rich_entities = '[]'::jsonb, content_revision = \(bind: nextRevision) WHERE message_id = \(bind: messageID)").run()
        if contentReviewMode.enqueuesJobs {
            // 审核结论只对精确内容修订有效。在同一编辑事务中替换已认领任务时，
            // 会清除其租约，因此旧工作器只能将自身标记为已被取代。
            try await sql.raw("""
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, decision, claim_token, lease_expires_at, retry_count, created_at, completed_at)
                VALUES (\(bind: messageID), \(bind: roomID), \(bind: nextRevision), 'pending', NULL, NULL, NULL, 0, \(bind: now), NULL)
                ON CONFLICT (message_id) DO UPDATE
                SET expected_content_revision = EXCLUDED.expected_content_revision, state = 'pending', decision = NULL,
                    claim_token = NULL, lease_expires_at = NULL, retry_count = 0,
                    next_attempt_at = NULL, paused_at = NULL, finding_category = NULL,
                    finding_severity = NULL, finding_confidence = NULL, completed_at = NULL
                """).run()
        }
        try await sql.raw("UPDATE im_v2.room_admission SET command_window_used = \(bind: nextRoom.commandWindow.used), shard_lease_id = \(bind: try v2PersistenceUUID(lease.id, invalid: V2MessageEditStoreError.corruptPersistenceState)), shard_lease_generation = \(bind: try v2PersistenceSigned(lease.generation, invalid: V2MessageEditStoreError.corruptPersistenceState)) WHERE room_id = \(bind: roomID)").run()
        try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try v2PersistenceUUID(lease.id, invalid: V2MessageEditStoreError.corruptPersistenceState)) AND generation = \(bind: try v2PersistenceSigned(lease.generation, invalid: V2MessageEditStoreError.corruptPersistenceState))").run()
        try await sql.raw("INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at) VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: nextSequence), 'message.edited', \(bind: actorID), jsonb_build_object('event_type', 'message.edited', 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: nextSequence), 'message_id', \(bind: messageID.uuidString), 'message_revision', \(bind: nextRevision), 'text', \(bind: command.text), 'entities', '[]'::jsonb, 'replacement', \(bind: replacementJSON)::jsonb, 'actor_user_id', \(bind: actorID.uuidString), 'server_created_at_ms', \(bind: createdAtMilliseconds)), \(bind: room.membershipRevision), \(bind: now))").run()
        try await PostgresV2MessageProjectionStateRepository().persist(
            try .init(
                state: editedProjectionState,
                originEventID: previousProjectionState.originEventID,
                stateEventID: eventUUID,
                createdAt: now
            ),
            sql: sql
        )
        return .edited(try .init(roomID: command.roomID, messageID: command.messageID, text: command.text, messageRevision: v2PersistenceUnsigned(nextRevision, invalid: V2MessageEditStoreError.corruptPersistenceState), roomSequence: v2PersistenceUnsigned(nextSequence, invalid: V2MessageEditStoreError.corruptPersistenceState), eventID: eventID, createdAt: timestamp.createdAt))
    }
}

private struct EditActorRow: Decodable { let role: String; let muted: Bool }
private struct EditRoomRow: Decodable { let kind: String; let frozenAt: Date?; let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let capacityClass: V2GroupCapacityClass; enum CodingKeys: String, CodingKey { case kind = "room_kind", frozenAt = "frozen_at", roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class" } }
private struct EditMessageRow: Decodable { let roomID: UUID; let senderUserID: UUID; let contentRevision: Int64; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", senderUserID = "sender_user_id", contentRevision = "content_revision", withdrawnAt = "withdrawn_at" } }
private struct EditCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}
private struct EditAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension EditAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)) } }
private struct EditShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; }
extension EditShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: v2PersistenceUnsigned(generation, invalid: V2MessageEditStoreError.corruptPersistenceState), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))) } }
