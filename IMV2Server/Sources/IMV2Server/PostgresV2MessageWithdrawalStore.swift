import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 消息撤回的 PostgreSQL 实现。
///
/// 消息墓碑与其投递工作在同一个事务内持久化。加锁顺序为
/// 操作咨询锁 → 房间 → 消息 → 房间准入 → 分片池，
/// 因此一次被接受的撤回不会留下部分可见的墓碑。
public struct PostgresV2MessageWithdrawalStore: V2MessageWithdrawalStore, V2OwnerValidatedMessageWithdrawalStore {
    private let database: any Database
    private var activationScope: V2RoomActivationWriteScope?

    public func usingActivationScope(_ scope: V2RoomActivationWriteScope) -> Self {
        var copy = self
        copy.activationScope = scope
        return copy
    }

    /// 组合数据库。
    ///
    /// - Parameter database: 存放消息、房间、准入与撤回记录的数据库。
    public init(database: any Database) { self.database = database }

    /// 执行一次消息撤回（不校验房间归属）。
    ///
    /// - Parameters:
    ///   - command: 撤回命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果。
    /// - Throws: 无权限、修订冲突或持久化失败时抛出。
    public func withdraw(command: V2WithdrawMessageCommand, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome {
        try await withdraw(command: command, ownerRoute: nil, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    /// 按房间归属执行一次消息撤回。
    ///
    /// - Parameters:
    ///   - command: 撤回命令。
    ///   - ownerRoute: 已选定的房间归属，事务内据此校验归属。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果。
    /// - Throws: 归属已变更、无权限、修订冲突或持久化失败时抛出。
    public func withdrawOwnerValidated(command: V2WithdrawMessageCommand, ownerRoute: V2RoomShardRoute, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome {
        try await withdraw(command: command, ownerRoute: ownerRoute, capacityProfile: capacityProfile, eventID: eventID, now: now)
    }

    /// 在单个事务内完成归属校验、幂等判定、作者校验、墓碑写入与投递登记。
    ///
    /// - Parameters:
    ///   - command: 撤回命令。
    ///   - ownerRoute: 已选定的房间归属；为 `nil` 时跳过归属校验。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 撤回结果或不需要变更的结论。
    /// - Throws: 房间或消息不存在、发起者非作者、状态冲突或持久化失败时抛出。
    private func withdraw(command: V2WithdrawMessageCommand, ownerRoute: V2RoomShardRoute?, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) async throws -> V2MessageWithdrawalOutcome {
        return try await v2WithPostgresTransactionRetry(database: database,
            maximumRetryCount: 0, classifyCommitFailure: activationScope != nil, useRoomDeadline: activationScope != nil) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
            if activationScope != nil { try await v2SetRoomActivationSQLTimeouts(.default, sql: sql) }
            let roomID = try withdrawalUUID(command.roomID)
            let actorID = try withdrawalUUID(command.actorUserID)
            let operationID = try withdrawalUUID(command.operationID)
            let messageID = try withdrawalUUID(command.messageID)
            let lockKey = actorID.uuidString + ":" + operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let ownerRoute { try await v2RequireRoomOwner(roomID: roomID, route: ownerRoute, sql: sql) }
            try await activationScope?.require([roomID], sql: sql)

            if let prior = try await sql.raw("""
                SELECT room_id, message_id, expected_message_revision, resulting_message_revision,
                       room_sequence, event_id, created_at
                FROM im_v2.message_withdrawal_operations
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).first(decoding: WithdrawalOperationRow.self) {
                guard prior.matches(command: command, roomID: roomID, messageID: messageID) else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(prior.createdAt) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
                return .idempotent(try prior.result())
            }

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
            guard try withdrawalUnsigned(message.contentRevision) == command.expectedMessageRevision else {
                return .revisionConflict(current: try withdrawalUnsigned(message.contentRevision))
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
            let eventUUID = try withdrawalUUID(eventID)
            let previousProjectionState = try await PostgresV2MessageProjectionStateRepository()
                .loadCurrentOrMaterialize(
                    messageID: messageID,
                    revision: message.contentRevision,
                    sql: sql
                )
            guard previousProjectionState.originEventID == acceptance.eventID,
                  previousProjectionState.roomID == roomID,
                  try previousProjectionState.state.acceptedRoomSequence == withdrawalUnsigned(acceptance.roomSequence)
            else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }
            let removedProjectionState = try previousProjectionState.state.applyingRemoval(
                revision: withdrawalUnsigned(nextMessageRevision)
            )

            // Use PostgreSQL's decoded timestamp for the fresh response and event
            // payload. Keep the original clock for every storage binding.
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
                    shard_lease_id = \(bind: try withdrawalUUID(lease.id)), shard_lease_generation = \(bind: try withdrawalSigned(lease.generation))
                WHERE room_id = \(bind: roomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_used = \(bind: lease.commandWindow.used)
                WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
                  AND lease_id = \(bind: try withdrawalUUID(lease.id)) AND generation = \(bind: try withdrawalSigned(lease.generation))
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
            try await sql.raw("""
                INSERT INTO im_v2.message_withdrawal_operations
                    (actor_user_id, operation_id, room_id, message_id, expected_message_revision,
                     resulting_message_revision, room_sequence, event_id, created_at)
                VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: messageID), \(bind: try withdrawalSigned(command.expectedMessageRevision)),
                        \(bind: nextMessageRevision), \(bind: nextRoomSequence), \(bind: eventUUID), \(bind: now))
                """).run()
            return .withdrawn(try .init(roomID: command.roomID, messageID: command.messageID,
                                        messageRevision: withdrawalUnsigned(nextMessageRevision), roomSequence: withdrawalUnsigned(nextRoomSequence),
                                        eventID: eventID, createdAt: timestamp.createdAt))
        }
    }
}

private struct WithdrawalRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let capacityClass: V2GroupCapacityClass; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class" } }
private struct WithdrawalMessageRow: Decodable { let roomID: UUID; let senderUserID: UUID; let contentRevision: Int64; let withdrawnAt: Date?; enum CodingKeys: String, CodingKey { case roomID = "room_id", senderUserID = "sender_user_id", contentRevision = "content_revision", withdrawnAt = "withdrawn_at" } }
private struct WithdrawalCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}
private struct WithdrawalOperationRow: Decodable {
    let roomID: UUID; let messageID: UUID; let expectedMessageRevision: Int64; let resultingMessageRevision: Int64; let roomSequence: Int64; let eventID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", expectedMessageRevision = "expected_message_revision", resultingMessageRevision = "resulting_message_revision", roomSequence = "room_sequence", eventID = "event_id", createdAt = "created_at" }
    func matches(command: V2WithdrawMessageCommand, roomID: UUID, messageID: UUID) -> Bool { self.roomID == roomID && self.messageID == messageID && expectedMessageRevision == command.expectedRevision.signedValue }
    func result() throws -> V2MessageWithdrawal { try .init(roomID: .init(roomID.uuidString), messageID: .init(messageID.uuidString), messageRevision: withdrawalUnsigned(resultingMessageRevision), roomSequence: withdrawalUnsigned(roomSequence), eventID: .init(eventID.uuidString), createdAt: createdAt) }
}
private struct WithdrawalAdmissionRow { let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64 }
extension WithdrawalAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)) } }
private struct WithdrawalShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; }
extension WithdrawalShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: withdrawalUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))) } }
/// 把标识原始值解析为 UUID。
///
/// - Parameter identifier: 已校验的标识类型。
/// - Returns: 对应的 UUID。
/// - Throws: 原始值不是合法 UUID 时抛出
///   ``V2MessageWithdrawalStoreError/corruptPersistenceState``。
private func withdrawalUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: identifier.rawValue) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }; return value }

/// 把非负的 64 位整数转换为无符号表示。
///
/// - Parameter value: 待转换整数。
/// - Returns: 无符号值。
/// - Throws: 值为负时抛出 ``V2MessageWithdrawalStoreError/corruptPersistenceState``。
private func withdrawalUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }; return UInt64(value) }

/// 把无符号整数转换为可持久化的有符号表示。
///
/// - Parameter value: 待转换整数。
/// - Returns: 有符号值。
/// - Throws: 超出 `Int64` 表示范围时抛出
///   ``V2MessageWithdrawalStoreError/corruptPersistenceState``。
private func withdrawalSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2MessageWithdrawalStoreError.corruptPersistenceState }; return Int64(value) }
