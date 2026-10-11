import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 消息表情变更的 PostgreSQL 实现。
///
/// 先串行化同一发起者的表情操作，再把集合变更与房间派生的传播工作放在同一个事务内提交。
/// 加锁顺序与其他房间变更一致：操作 → 房间 → 消息 → 准入 → 分片。
public struct PostgresV2MessageReactionStore: V2MessageReactionStore {
    private let database: any Database
    private var existingOperationTransaction = false
    func usingOperationTransaction() -> Self { var copy = self; copy.existingOperationTransaction = true; return copy }
    private var activationScope: V2RoomActivationWriteScope?

    public func usingActivationScope(_ scope: V2RoomActivationWriteScope) -> Self {
        var copy = self
        copy.activationScope = scope
        return copy
    }
    /// 组合数据库。
    ///
    /// - Parameter database: 存放房间、消息、表情与准入状态的数据库。
    public init(database: any Database) { self.database = database }

    /// 执行一次表情变更（不校验房间归属）。
    ///
    /// - Parameters:
    ///   - command: 表情变更命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 表情变更结果。
    /// - Throws: 无权限、状态冲突、容量不足或持久化失败时抛出。
    public func change(command: V2ChangeMessageReactionCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageReactionOutcome {
        return try await v2WithPostgresTransactionRetry(database: database,
            maximumRetryCount: 0, classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil, existingTransaction: existingOperationTransaction) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageReactionStoreError.corruptPersistenceState }
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            let roomID = try reactionUUID(command.roomID), actorID = try reactionUUID(command.actorUserID)
            let operationID = try reactionUUID(command.operationID), messageID = try reactionUUID(command.messageID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            try await activationScope?.require([roomID], sql: sql)
            guard v2PostgresTimestampCanEncode(now) else { throw V2MessageReactionStoreError.corruptPersistenceState }
            guard let room = try await sql.raw("SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, capacity_class FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReactionRoomRow.self) else { throw V2MessageReactionStoreError.roomNotFound }
            guard room.capacityProfileID == capacityProfile.id else { throw V2MessageReactionStoreError.corruptPersistenceState }
            guard let message = try await sql.raw("SELECT room_id, withdrawn_at FROM im_v2.messages WHERE message_id = \(bind: messageID) FOR UPDATE").first(decoding: ReactionMessageRow.self), message.roomID == roomID else { throw V2MessageReactionStoreError.messageNotFound }
            guard message.withdrawnAt == nil else { throw V2MessageReactionStoreError.messageWithdrawn }
            let member = try await sql.raw("SELECT 1 AS exists FROM im_v2.room_memberships WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID) AND joined_revision <= \(bind: room.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))").first(decoding: ReactionExistsRow.self)
            guard member != nil else { throw V2MessageReactionStoreError.actorNotMember }
            let acceptance = try await v2MessageAcceptanceFact(messageID: messageID, roomID: roomID, sql: sql)
            let acceptedMember = try await sql.raw("""
                SELECT 1 AS exists FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID)
                  AND joined_revision <= \(bind: acceptance.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: acceptance.membershipRevision))
                """).first(decoding: ReactionExistsRow.self)
            guard acceptedMember != nil else { throw V2MessageReactionStoreError.actorNotMember }
            let exists = try await sql.raw("SELECT 1 AS exists FROM im_v2.message_reactions WHERE message_id = \(bind: messageID) AND actor_user_id = \(bind: actorID) AND reaction = \(bind: command.reaction) FOR UPDATE").first(decoding: ReactionExistsRow.self) != nil
            guard (command.action == .add && !exists) || (command.action == .remove && exists) else { return .alreadyInDesiredState }
            if command.action == .add {
                guard let counts = try await sql.raw("""
                    SELECT COUNT(*)::bigint AS total_count,
                           COUNT(*) FILTER (WHERE actor_user_id = \(bind: actorID))::bigint AS actor_count
                    FROM im_v2.message_reactions
                    WHERE message_id = \(bind: messageID)
                    """).first(decoding: ReactionCountRow.self) else {
                    throw V2MessageReactionStoreError.corruptPersistenceState
                }
                guard counts.totalCount < V2MessageReactionLimits.maximumReactionsPerMessage,
                      counts.actorCount < V2MessageReactionLimits.maximumReactionsPerActorPerMessage
                else { throw V2MessageReactionStoreError.reactionLimitReached }
            }

            guard let admission = try await sql.raw("SELECT eligible_member_count, command_window_limit, command_window_used, shard_lease_id, shard_lease_generation FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReactionAdmissionRow.self),
                  let shard = try await sql.raw("SELECT lease_id, generation, valid_until, command_window_limit, command_window_used FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) FOR UPDATE").first(decoding: ReactionShardRow.self) else { throw V2MessageReactionStoreError.corruptPersistenceState }
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation else { throw V2MessageReactionStoreError.corruptPersistenceState }
            let reservation = try V2CommandAdmissionEvaluator.reserve(profile: capacityProfile.limits, roomState: try admission.state(), shardState: try shard.state(), now: now)
            let nextRoom: RoomAdmissionState, nextShard: ShardAdmissionState
            switch reservation {
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable(let reason): return .unavailable(reason)
            case .accepted(_, let reservedRoom, let reservedShard): nextRoom = reservedRoom; nextShard = reservedShard
            }
            guard let lease = nextShard.lease, room.roomSequence < Int64.max else { throw V2MessageReactionStoreError.corruptPersistenceState }
            let nextSequence = room.roomSequence + 1, eventUUID = try reactionUUID(eventID)
            // 新响应和事件载荷使用 PostgreSQL 解码后的时间戳；
            // 所有存储绑定仍使用原始时钟值。
            guard let timestamp = try await sql.raw("UPDATE im_v2.rooms SET room_sequence = \(bind: nextSequence) WHERE room_id = \(bind: roomID) RETURNING \(bind: now)::timestamptz AS created_at").first(decoding: ReactionCommittedTimestampRow.self) else { throw V2MessageReactionStoreError.corruptPersistenceState }
            let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
            if command.action == .add {
                try await sql.raw("INSERT INTO im_v2.message_reactions (message_id, actor_user_id, reaction, created_at) VALUES (\(bind: messageID), \(bind: actorID), \(bind: command.reaction), \(bind: now))").run()
            } else {
                try await sql.raw("DELETE FROM im_v2.message_reactions WHERE message_id = \(bind: messageID) AND actor_user_id = \(bind: actorID) AND reaction = \(bind: command.reaction)").run()
            }
            try await sql.raw("UPDATE im_v2.room_admission SET command_window_used = \(bind: nextRoom.commandWindow.used), shard_lease_id = \(bind: try reactionUUID(lease.id)), shard_lease_generation = \(bind: try reactionSigned(lease.generation)) WHERE room_id = \(bind: roomID)").run()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET command_window_used = \(bind: lease.commandWindow.used) WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID) AND lease_id = \(bind: try reactionUUID(lease.id)) AND generation = \(bind: try reactionSigned(lease.generation))").run()
            try await sql.raw("INSERT INTO im_v2.room_events (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at) VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: nextSequence), 'message.reaction_changed', \(bind: actorID), jsonb_build_object('event_type', 'message.reaction_changed', 'room_id', \(bind: roomID.uuidString), 'room_sequence', \(bind: nextSequence), 'message_id', \(bind: messageID.uuidString), 'actor_user_id', \(bind: actorID.uuidString), 'reaction', \(bind: command.reaction), 'action', \(bind: command.action.rawValue), 'server_created_at_ms', \(bind: createdAtMilliseconds)), \(bind: room.membershipRevision), \(bind: now))").run()
            return .changed(try .init(roomID: command.roomID, messageID: command.messageID, actorUserID: command.actorUserID, reaction: command.reaction, action: command.action, roomSequence: reactionUnsigned(nextSequence), eventID: eventID, createdAt: timestamp.createdAt))
        }
    }
}

private struct ReactionRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let capacityClass: V2GroupCapacityClass; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class" } }
private struct ReactionMessageRow: Decodable { let roomID: UUID; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", withdrawnAt = "withdrawn_at" } }
private struct ReactionExistsRow: Decodable { let exists: Int }
private struct ReactionCountRow: Decodable {
    let totalCount: Int
    let actorCount: Int
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case actorCount = "actor_count"
    }
}
private struct ReactionCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}
private struct ReactionAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension ReactionAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)) } }
private struct ReactionShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; }
extension ReactionShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: reactionUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))) } }
/// 把标识原始值解析为 UUID。
///
/// - Parameter identifier: 已校验的标识类型。
/// - Returns: 对应的 UUID。
/// - Throws: 原始值不是合法 UUID 时抛出
///   ``V2MessageReactionStoreError/corruptPersistenceState``。
private func reactionUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: identifier.rawValue) else { throw V2MessageReactionStoreError.corruptPersistenceState }; return value }

/// 把非负的 64 位整数转换为无符号表示。
///
/// - Parameter value: 待转换整数。
/// - Returns: 无符号值。
/// - Throws: 值为负时抛出 ``V2MessageReactionStoreError/corruptPersistenceState``。
private func reactionUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2MessageReactionStoreError.corruptPersistenceState }; return UInt64(value) }

/// 把无符号整数转换为可持久化的有符号表示。
///
/// - Parameter value: 待转换整数。
/// - Returns: 有符号值。
/// - Throws: 超出 `Int64` 表示范围时抛出
///   ``V2MessageReactionStoreError/corruptPersistenceState``。
private func reactionSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2MessageReactionStoreError.corruptPersistenceState }; return Int64(value) }

/// 把持久化字符串解析为表情动作。
///
/// - Parameter rawValue: 持久化取值。
/// - Returns: 对应的表情动作。
/// - Throws: 取值未知时抛出 ``V2MessageReactionStoreError/corruptPersistenceState``。
