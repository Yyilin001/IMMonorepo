import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 消息撤回的 PostgreSQL 实现。
///
/// 消息墓碑与其投递工作在同一个事务内持久化。加锁顺序为
/// 操作咨询锁 → 房间 → 消息 → 房间准入 → 分片池，
/// 因此一次被接受的撤回不会留下部分可见的墓碑。
package struct V2PostgresMessageWithdrawalPersistence: Sendable {
    private let database: any Database
    /// 组合数据库。
    ///
    /// - Parameter transaction: 存放消息、房间、准入与撤回记录的数据库。
    package init(transaction: any Database) throws {
        guard transaction.inTransaction else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        self.database = transaction
    }

    /// 执行一次消息撤回（由外层 Operation Store 校验房间归属并管理事务）。
    ///
    /// - Parameters:
    ///   - command: 撤回命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果。
    /// - Throws: 无权限、修订冲突或持久化失败时抛出。
    package func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome {
        let transaction = database
        guard let sql = transaction as? any SQLDatabase else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        let roomID = try v2PersistenceUUID(command.roomID, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)
        let actorID = try v2PersistenceUUID(command.actorUserID, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)
        let operationID = try v2PersistenceUUID(command.operationID, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)
        let messageID = try v2PersistenceUUID(command.messageID, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)
        let lockKey = actorID.uuidString + ":" + operationID.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()

        guard v2PostgresTimestampCanEncode(now) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        guard let room = try await sql.raw("""
            SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class
            FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: WithdrawalRoomRow.self) else { throw V2MessageWithdrawalStoreError.roomNotFound }
        guard room.capacityProfileID == capacityProfile.id else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        guard let message = try await sql.raw("""
            SELECT room_id, sender_user_id, content_revision, withdrawn_at
            FROM im_v2.messages WHERE message_id = \(bind: messageID) FOR UPDATE
            """).first(decoding: WithdrawalMessageRow.self) else { throw V2MessageWithdrawalStoreError.messageNotFound }
        guard message.roomID == roomID else { throw V2MessageWithdrawalStoreError.messageNotFound }
        guard message.senderUserID == actorID else { throw V2MessageWithdrawalStoreError.actorNotAuthor }
        guard try v2PersistenceUnsigned(message.contentRevision, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState) == command.expectedMessageRevision else {
            return .revisionConflict(current: try v2PersistenceUnsigned(message.contentRevision, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState))
        }
        guard message.withdrawnAt == nil else { return .alreadyWithdrawn }

        let acceptance = try await v2MessageAcceptanceFact(messageID: messageID, roomID: roomID, sql: sql)
        guard let admission = try await sql.raw("""
            SELECT eligible_member_count, command_window_limit, command_window_used,
                   shard_lease_id, shard_lease_generation
            FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: WithdrawalAdmissionRow.self),
              let shard = try await sql.raw("""
            SELECT lease_id, generation, valid_until, command_window_limit, command_window_used
            FROM im_v2.shard_admission_pools
            WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
            FOR UPDATE
            """).first(decoding: WithdrawalShardRow.self) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else {
            throw V2MessageWithdrawalStoreError.corruptPersistenceState
        }

        let reservation = try V2CommandAdmissionEvaluator.reserve(
            profile: capacityProfile.limits,
            roomState: try admission.state(),
            shardState: try shard.state(),
            now: now
        )
        let nextRoom: RoomAdmissionState
        let nextShard: ShardAdmissionState
        switch reservation {
        case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): return .unavailable(reason)
        case .accepted(_, let reservedRoom, let reservedShard):
            nextRoom = reservedRoom
            nextShard = reservedShard
        }
        guard let lease = nextShard.lease,
              room.roomSequence < Int64.max,
              message.contentRevision < Int64.max
        else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        let nextRoomSequence = room.roomSequence + 1
        let nextMessageRevision = message.contentRevision + 1
        let eventUUID = try v2PersistenceUUID(eventID, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)
        let previousProjectionState = try await PostgresV2MessageProjectionStateRepository()
            .loadCurrentOrMaterialize(
                messageID: messageID,
                revision: message.contentRevision,
                sql: sql
            )
        guard previousProjectionState.originEventID == acceptance.eventID,
              previousProjectionState.roomID == roomID,
              try previousProjectionState.state.acceptedRoomSequence == v2PersistenceUnsigned(acceptance.roomSequence, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)
        else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        let removedProjectionState = try previousProjectionState.state.applyingRemoval(
            revision: v2PersistenceUnsigned(nextMessageRevision, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)
        )

        // 新响应和事件载荷使用 PostgreSQL 解码后的时间戳；
        // 所有存储绑定仍使用原始时钟值。
        guard let timestamp = try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: nextRoomSequence) WHERE room_id = \(bind: roomID) RETURNING \(bind: now)::timestamptz AS created_at").first(decoding: WithdrawalCommittedTimestampRow.self) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
        let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
        try await sql.raw("""
            UPDATE im_v2.messages
            SET content_revision = \(bind: nextMessageRevision), withdrawn_at = \(bind: now), withdrawn_by_user_id = \(bind: actorID)
            WHERE message_id = \(bind: messageID)
            """).run()
        try await sql.raw("""
            UPDATE im_v2.room_admission
            SET command_window_used = \(bind: nextRoom.commandWindow.used),
                shard_lease_id = \(bind: try v2PersistenceUUID(lease.id, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)), shard_lease_generation = \(bind: try v2PersistenceSigned(lease.generation, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState))
            WHERE room_id = \(bind: roomID)
            """).run()
        try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET command_window_used = \(bind: lease.commandWindow.used)
            WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
              AND lease_id = \(bind: try v2PersistenceUUID(lease.id, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState)) AND generation = \(bind: try v2PersistenceSigned(lease.generation, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.room_events
                (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
            VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: nextRoomSequence), 'message.withdrawn', \(bind: actorID),
                    jsonb_build_object('event_type', 'message.withdrawn', 'room_id', \(bind: roomID.uuidString),
                                       'room_sequence', \(bind: nextRoomSequence), 'message_id', \(bind: messageID.uuidString),
                                       'message_revision', \(bind: nextMessageRevision), 'actor_user_id', \(bind: actorID.uuidString),
                                       'server_created_at_ms', \(bind: createdAtMilliseconds),
                                       'is_withdrawn', true), \(bind: room.membershipRevision), \(bind: now))
            """).run()
        try await PostgresV2MessageProjectionStateRepository().persist(
            try .init(
                state: removedProjectionState,
                originEventID: previousProjectionState.originEventID,
                stateEventID: eventUUID,
                createdAt: now
            ),
            sql: sql
        )
        return .withdrawn(try .init(roomID: command.roomID, messageID: command.messageID,
                                    messageRevision: v2PersistenceUnsigned(nextMessageRevision, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState), roomSequence: v2PersistenceUnsigned(nextRoomSequence, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState),
                                    eventID: eventID, createdAt: timestamp.createdAt))
    }
}

private struct WithdrawalRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let capacityClass: V2GroupCapacityClass; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class" } }
private struct WithdrawalMessageRow: Decodable { let roomID: UUID; let senderUserID: UUID; let contentRevision: Int64; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", senderUserID = "sender_user_id", contentRevision = "content_revision", withdrawnAt = "withdrawn_at" } }
private struct WithdrawalCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}
private struct WithdrawalAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension WithdrawalAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)) } }
private struct WithdrawalShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; }
extension WithdrawalShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: v2PersistenceUnsigned(generation, invalid: V2MessageWithdrawalStoreError.corruptPersistenceState), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))) } }
