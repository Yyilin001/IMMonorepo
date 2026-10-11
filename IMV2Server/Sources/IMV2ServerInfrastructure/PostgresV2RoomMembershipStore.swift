import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit

/// RoomRef-bound operations and trusted invitation coordination share this transaction primitive.
enum PostgresV2RoomMembershipStore {
    /// 在调用方的 PostgreSQL 事务内执行成员变更。
    ///
    /// 提交与回滚由调用方负责，包括全部成员、准入、事件与发件箱写入。
    /// 若把该原语与其他归属操作组合，必须先获取操作锁再获取房间锁。
    ///
    /// - Parameters:
    ///   - sql: 调用方事务使用的数据库连接。
    ///   - command: 成员变更命令。
    ///   - identitySnapshot: 控制面提供的身份快照，可为空。
    ///   - ownerRoute: 已选定的房间归属，可为空。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 归属不符时抛出 ``V2RoomMembershipStoreError/ownerChanged``；
    ///   房间或目标不存在、无权限、修订冲突或持久化失败时抛出对应错误。
    static func change(
        in sql: any SQLDatabase,
        command: V2ChangeRoomMembershipCommand,
        identitySnapshot: V2MembershipIdentitySnapshot? = nil,
        ownerRoute: V2RoomShardRoute? = nil,
        activationScope: V2RoomActivationWriteScope? = nil,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        now: Date,
        writeOperationLedger: Bool = true
    ) async throws -> V2RoomMembershipChangeOutcome {
        let roomID = try v2PersistenceUUID(command.roomID, invalid: V2RoomMembershipStoreError.corruptPersistenceState)
        let actorID = try v2PersistenceUUID(command.actorUserID, invalid: V2RoomMembershipStoreError.corruptPersistenceState)
        let targetID = try v2PersistenceUUID(command.targetUserID, invalid: V2RoomMembershipStoreError.corruptPersistenceState)
        let operationID = try v2PersistenceUUID(command.operationID, invalid: V2RoomMembershipStoreError.corruptPersistenceState)
        let operationLockKey = actorID.uuidString + ":" + operationID.uuidString

        if activationScope != nil {
            try await v2SetRoomActivationSQLTimeouts(.default, sql: sql)
        }
        // 咨询锁会串行化此精确持久化操作键的记录缺失情形。
        // 哈希碰撞只会增加竞争，不会合并两条操作记录。
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()
        if let activationScope { try await activationScope.require([roomID], sql: sql) }
        // 先获取操作锁，再获取房间锁，与审批和恢复路径一致。
        // 即使是成功重放，也要先通过围栏，再读取回执。
        let fencedRoom: MembershipRoomRow?
        if activationScope == nil, let ownerRoute {
            guard let value = try await sql.raw("""
                SELECT room_shard_id, owner_epoch, room_sequence, membership_revision, capacity_profile_id, capacity_class
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
                """).first(decoding: MembershipRoomRow.self),
                  value.roomShardID == ownerRoute.shardID, value.ownerEpoch == ownerRoute.epoch
            else { throw V2RoomMembershipStoreError.ownerChanged }
            fencedRoom = value
        } else {
            // 房间本地组合层会在写入事务中校验成员资格。
            fencedRoom = nil
        }
        if writeOperationLedger, let prior = try await sql.raw("""
            SELECT room_id, target_user_id, action, expected_membership_revision,
                   resulting_membership_revision, room_sequence, event_id, created_at
            FROM im_v2.room_membership_operations
            WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
            """).first(decoding: MembershipOperationRow.self) {
            guard prior.matches(command: command, roomID: roomID, targetID: targetID) else { return .idempotencyConflict }
            guard v2PostgresTimestampCanEncode(prior.createdAt) else { throw V2RoomMembershipStoreError.corruptPersistenceState }
            return .idempotent(try prior.change())
        }
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        let actorIsActive = if let identitySnapshot {
            identitySnapshot.actorIsActive
        } else {
            try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.public_user_profiles AS profile WHERE profile.user_id = \(bind: actorID) AND profile.state = 'active' AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables AS disabled WHERE disabled.user_id = profile.user_id)) AS value").first(decoding: MembershipBooleanRow.self)?.value == true
        }
        guard actorIsActive else {
            throw V2RoomMembershipStoreError.actorNotOwner
        }

        let room: MembershipRoomRow
        if let fencedRoom { room = fencedRoom }
        else {
            guard let value = try await sql.raw("""
                SELECT room_shard_id, owner_epoch, room_sequence, membership_revision, capacity_profile_id, capacity_class
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR NO KEY UPDATE
                """).first(decoding: MembershipRoomRow.self) else { throw V2RoomMembershipStoreError.roomNotFound }
            room = value
        }
        guard let group = try await sql.raw("""
            SELECT owner_user_id, title, created_at
            FROM im_v2.group_rooms WHERE room_id = \(bind: roomID)
            """).first(decoding: MembershipGroupRow.self) else { throw V2RoomMembershipStoreError.roomNotFound }
        guard room.capacityProfileID == capacityProfile.id else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        guard try v2PersistenceUnsigned(room.membershipRevision, invalid: V2RoomMembershipStoreError.corruptPersistenceState) == command.expectedMembershipRevision else {
            return .revisionConflict(current: try v2PersistenceUnsigned(room.membershipRevision, invalid: V2RoomMembershipStoreError.corruptPersistenceState))
        }
        guard let actor = try await sql.raw("""
            SELECT user_id, role FROM im_v2.room_memberships
            WHERE room_id = \(bind: roomID) AND user_id = \(bind: actorID)
              AND joined_revision <= \(bind: room.membershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
            FOR UPDATE
            """).first(decoding: MembershipTargetRow.self),
            let actorRole = V2RoomMembershipRole(rawValue: actor.role)
        else { throw V2RoomMembershipStoreError.actorNotOwner }
        let requiredPermission: V2GroupPermission = command.action == .add ? .inviteMembers : .removeMembers
        if actorRole != .owner && !(command.action == .remove && actorID == targetID) {
            let configuredPermissions = try await v2ResolvedGroupPermissions(roomID: roomID, role: actorRole, sql: sql)
            guard V2GroupPermissionDefaults.allows(role: actorRole, permission: requiredPermission, configured: configuredPermissions) else { throw V2RoomMembershipStoreError.actorNotOwner }
        }
        let currentTarget = try await sql.raw("""
            SELECT user_id, role FROM im_v2.room_memberships
            WHERE room_id = \(bind: roomID) AND user_id = \(bind: targetID)
              AND joined_revision <= \(bind: room.membershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
            ORDER BY joined_revision DESC LIMIT 1
            FOR UPDATE
            """).first(decoding: MembershipTargetRow.self)

        guard let admission = try await sql.raw("""
            SELECT eligible_member_count, command_window_limit, command_window_used,
                   shard_lease_id, shard_lease_generation
            FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: MembershipAdmissionRow.self),
              let shard = try await sql.raw("""
            SELECT lease_id, generation, valid_until, command_window_limit, command_window_used
            FROM im_v2.shard_admission_pools
            WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
            FOR UPDATE
            """).first(decoding: MembershipShardRow.self) else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        guard admission.shardLeaseID == shard.leaseID,
              admission.shardLeaseGeneration == shard.generation,
              admission.eligibleMemberCount > 0
        else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        let nextEligibleCount: Int
        switch command.action {
        case .add:
            let targetIsActive = if let identitySnapshot {
                identitySnapshot.targetIsActive
            } else {
                try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.public_user_profiles AS profile WHERE profile.user_id = \(bind: targetID) AND profile.state = 'active' AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables AS disabled WHERE disabled.user_id = profile.user_id)) AS value").first(decoding: MembershipBooleanRow.self)?.value == true
            }
            guard targetIsActive else {
                throw V2RoomMembershipStoreError.targetUnavailable
            }
            guard currentTarget == nil else { return .targetAlreadyMember }
            nextEligibleCount = admission.eligibleMemberCount + 1
            let modeMaximum = V2GroupCapacityPolicy().maximumMembers(for: room.capacityClass)
            guard nextEligibleCount <= capacityProfile.limits.maxEligibleMembers,
                  nextEligibleCount <= modeMaximum
            else { return .memberLimitReached }
        case .remove:
            guard let currentTarget else { return .targetNotMember }
            // 结构群主必须先转让所有权，角色投影不能绕过此边界。
            guard group.ownerUserID != targetID, currentTarget.role != "owner" else { throw V2RoomMembershipStoreError.actorNotOwner }
            nextEligibleCount = admission.eligibleMemberCount - 1
        }
        guard v2PostgresTimestampCanEncode(group.createdAt),
              let groupCreatedAtMilliseconds = try? v2GatewayMilliseconds(group.createdAt)
        else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        let reservation = try V2CommandAdmissionEvaluator.reserve(
            profile: capacityProfile.limits,
            roomState: try admission.state(),
            shardState: try shard.state(),
            now: now
        )
        let reservedRoom: RoomAdmissionState
        let reservedShard: ShardAdmissionState
        switch reservation {
        case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): return .unavailable(reason)
        case .accepted(_, let roomState, let shardState):
            reservedRoom = try .init(
                eligibleMemberCount: nextEligibleCount,
                commandWindow: roomState.commandWindow)
            reservedShard = shardState
        }
        guard let lease = reservedShard.lease else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        guard room.membershipRevision < Int64.max, room.roomSequence < Int64.max else {
            throw V2RoomMembershipStoreError.corruptPersistenceState
        }
        let nextRevision = room.membershipRevision + 1
        let nextSequence = room.roomSequence + 1
        let eventUUID = try v2PersistenceUUID(eventID, invalid: V2RoomMembershipStoreError.corruptPersistenceState)

        // 以与操作和事件写入相同的精度解码；保持原始 Date 绑定。
        guard let timestamp = try await sql.raw("""
            UPDATE im_v2.rooms SET room_sequence = \(bind: nextSequence), membership_revision = \(bind: nextRevision)
            WHERE room_id = \(bind: roomID)
            RETURNING \(bind: now)::timestamptz AS created_at
            """).first(decoding: MembershipCommittedTimestampRow.self) else {
            throw V2RoomMembershipStoreError.corruptPersistenceState
        }
        let createdAtMilliseconds = try v2GatewayMilliseconds(timestamp.createdAt)
        try await sql.raw("""
            UPDATE im_v2.room_admission
            SET eligible_member_count = \(bind: nextEligibleCount), command_window_used = \(bind: reservedRoom.commandWindow.used), shard_lease_id = \(bind: try v2PersistenceUUID(lease.id, invalid: V2RoomMembershipStoreError.corruptPersistenceState)),
                shard_lease_generation = \(bind: try v2PersistenceSigned(lease.generation, invalid: V2RoomMembershipStoreError.corruptPersistenceState))
            WHERE room_id = \(bind: roomID)
            """).run()
        try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET command_window_used = \(bind: lease.commandWindow.used)
            WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
              AND lease_id = \(bind: try v2PersistenceUUID(lease.id, invalid: V2RoomMembershipStoreError.corruptPersistenceState)) AND generation = \(bind: try v2PersistenceSigned(lease.generation, invalid: V2RoomMembershipStoreError.corruptPersistenceState))
            """).run()
        switch command.action {
        case .add:
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision) VALUES (\(bind: roomID), \(bind: targetID), 'member', \(bind: nextRevision))").run()
            // 加入前提交的内容对新成员不可见，因此不能计入未读数。
            // 初始水位也防止从未打开房间的成员把房间日志保留下界固定在零。
            try await v2InitializeJoinedMemberReadWatermark(
                roomID: roomID, userID: targetID, now: now, sql: sql
            )
        case .remove:
            try await sql.raw("""
                UPDATE im_v2.room_memberships SET left_revision = \(bind: nextRevision)
                WHERE room_id = \(bind: roomID) AND user_id = \(bind: targetID) AND left_revision IS NULL
                """).run()
        }
        try await sql.raw("""
            INSERT INTO im_v2.room_events
                (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
            VALUES (\(bind: eventUUID), \(bind: roomID), \(bind: nextSequence), 'membership_changed', \(bind: actorID),
                    jsonb_build_object(
                        'event_type', 'membership_changed',
                        'room_id', \(bind: roomID.uuidString),
                        'room_sequence', \(bind: nextSequence),
                        'actor_user_id', \(bind: actorID.uuidString),
                        'target_user_id', \(bind: targetID.uuidString),
                        'action', \(bind: command.action.rawValue),
                        'membership_revision', \(bind: nextRevision),
                        'owner_user_id', \(bind: group.ownerUserID.uuidString),
                        'title', \(bind: group.title),
                        'capacity_class', \(bind: room.capacityClass.rawValue),
                        'created_at_ms', \(bind: groupCreatedAtMilliseconds),
                        'server_created_at_ms', \(bind: createdAtMilliseconds)
                    ), \(bind: nextRevision), \(bind: now))
            """).run()
        // 公共成员变化已写入房间日志；只给受影响用户发送个人状态，移除后仍能收到。
        try await sql.raw("""
            INSERT INTO im_v2.user_state_event_outbox
                (source_event_id, user_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
            SELECT event_id, \(bind: targetID), 'membership', payload, created_at, created_at, room_id
            FROM im_v2.room_events WHERE event_id = \(bind: eventUUID)
            """).run()
        if writeOperationLedger {
        try await sql.raw("""
            INSERT INTO im_v2.room_membership_operations
                (actor_user_id, operation_id, room_id, target_user_id, action, expected_membership_revision,
                 resulting_membership_revision, room_sequence, event_id, created_at)
            VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: targetID), \(bind: command.action.rawValue),
                    \(bind: try v2PersistenceSigned(command.expectedMembershipRevision, invalid: V2RoomMembershipStoreError.corruptPersistenceState)), \(bind: nextRevision), \(bind: nextSequence), \(bind: eventUUID), \(bind: now))
            """).run()
        }
        return .changed(try .init(roomID: command.roomID, targetUserID: command.targetUserID, action: command.action,
                                  membershipRevision: v2PersistenceUnsigned(nextRevision, invalid: V2RoomMembershipStoreError.corruptPersistenceState), roomSequence: v2PersistenceUnsigned(nextSequence, invalid: V2RoomMembershipStoreError.corruptPersistenceState),
                                  eventID: eventID, createdAt: timestamp.createdAt))
    }
}

private struct MembershipCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}

private struct MembershipRoomRow: Decodable { let roomShardID: String; let ownerEpoch: Int64; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let capacityClass: V2GroupCapacityClass; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", ownerEpoch = "owner_epoch", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", capacityClass = "capacity_class" } }
private struct MembershipGroupRow: Decodable { let ownerUserID: UUID; let title: String; let createdAt: Date; enum CodingKeys: String, CodingKey { case ownerUserID = "owner_user_id", title, createdAt = "created_at" } }
private struct MembershipTargetRow: Decodable { let userID: UUID; let role: String; enum CodingKeys: String, CodingKey { case userID = "user_id", role } }
private struct MembershipBooleanRow: Decodable { let value: Bool }
private struct MembershipOperationRow: Decodable {
    let roomID: UUID; let targetUserID: UUID; let action: String; let expectedMembershipRevision: Int64; let resultingMembershipRevision: Int64; let roomSequence: Int64; let eventID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", action, expectedMembershipRevision = "expected_membership_revision", resultingMembershipRevision = "resulting_membership_revision", roomSequence = "room_sequence", eventID = "event_id", createdAt = "created_at" }
    func matches(command: V2ChangeRoomMembershipCommand, roomID: UUID, targetID: UUID) -> Bool { self.roomID == roomID && targetUserID == targetID && action == command.action.rawValue && expectedMembershipRevision == command.expectedRevision.signedValue }
    func change() throws -> V2RoomMembershipChange { try .init(roomID: .init(roomID.uuidString), targetUserID: .init(targetUserID.uuidString), action: try .init(rawValue: action).unwrapMembership(), membershipRevision: v2PersistenceUnsigned(resultingMembershipRevision, invalid: V2RoomMembershipStoreError.corruptPersistenceState), roomSequence: v2PersistenceUnsigned(roomSequence, invalid: V2RoomMembershipStoreError.corruptPersistenceState), eventID: .init(eventID.uuidString), createdAt: createdAt) }
}
private struct MembershipAdmissionRow {
    let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64
}
extension MembershipAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed)) } }
private struct MembershipShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; }
extension MembershipShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: v2PersistenceUnsigned(generation, invalid: V2RoomMembershipStoreError.corruptPersistenceState), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed))) } }

private extension Optional where Wrapped == V2RoomMembershipAction { func unwrapMembership() throws -> Wrapped { guard let self else { throw V2RoomMembershipStoreError.corruptPersistenceState }; return self } }
