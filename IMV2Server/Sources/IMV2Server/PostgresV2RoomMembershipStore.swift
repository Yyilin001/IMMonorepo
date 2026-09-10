import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 采用显式房间权限模型的成员变更实现。
///
/// 只有群主可以添加成员，群主或管理员可以移除非群主成员。
/// 事务会在改变成员关系之前冻结精确受众，因此添加与移除事件不依赖工作器运行时
/// 恰好存在哪些成员行。
public struct PostgresV2RoomMembershipStore:
    V2ControlValidatedRoomMembershipStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放房间、成员关系与准入状态的数据库。
    public init(database: any Database) { self.database = database }

    /// 执行一次成员变更（不做控制面身份校验）。
    ///
    /// - Parameters:
    ///   - command: 成员变更命令。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 无权限、修订冲突、容量不足或持久化失败时抛出。
    public func change(command: V2ChangeRoomMembershipCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2RoomMembershipChangeOutcome {
        try await change(
            command: command,
            identitySnapshot: nil,
            ownerRoute: nil,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }

    /// 以控制面校验过的身份快照与房间归属执行成员变更。
    ///
    /// - Parameters:
    ///   - command: 成员变更命令。
    ///   - ownerRoute: 已选定的房间归属，事务内据此校验归属。
    ///   - identitySnapshot: 控制面提供的目标身份快照。
    ///   - capacityProfile: 本次命令使用的容量档位。
    ///   - eventID: 命令幂等标识。
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 归属已变更、身份不符、无权限、修订冲突或持久化失败时抛出。
    public func changeControlValidated(
        command: V2ChangeRoomMembershipCommand,
        ownerRoute: V2RoomShardRoute,
        identitySnapshot: V2MembershipIdentitySnapshot,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome {
        guard identitySnapshot.actorUserID == command.actorUserID,
              identitySnapshot.targetUserID == command.targetUserID
        else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        return try await change(
            command: command,
            identitySnapshot: identitySnapshot,
            ownerRoute: ownerRoute,
            capacityProfile: capacityProfile,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }

    private func change(
        command: V2ChangeRoomMembershipCommand,
        identitySnapshot: V2MembershipIdentitySnapshot?,
        ownerRoute: V2RoomShardRoute?,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome {
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomMembershipStoreError.corruptPersistenceState }
            return try await Self.change(
                in: sql, command: command, identitySnapshot: identitySnapshot, ownerRoute: ownerRoute,
                capacityProfile: capacityProfile, eventID: eventID, planID: planID, now: now
            )
        }
    }

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
    ///   - planID: 本次命令关联的扇出计划标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 归属不符时抛出 ``V2RoomMembershipStoreError/ownerChanged``；
    ///   房间或目标不存在、无权限、修订冲突或持久化失败时抛出对应错误。
    static func change(
        in sql: any SQLDatabase,
        command: V2ChangeRoomMembershipCommand,
        identitySnapshot: V2MembershipIdentitySnapshot? = nil,
        ownerRoute: V2RoomShardRoute? = nil,
        capacityProfile: V2CapacityProfile,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2RoomMembershipChangeOutcome {
        let roomID = try membershipUUID(command.roomID)
        let actorID = try membershipUUID(command.actorUserID)
        let targetID = try membershipUUID(command.targetUserID)
        let operationID = try membershipUUID(command.operationID)
        let operationLockKey = actorID.uuidString + ":" + operationID.uuidString

        // An advisory lock serializes the absent-row case for this exact
        // durable operation key. Hash collisions can only add contention,
        // never merge two operation records.
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()
        // The operation lock precedes the room lock, matching approval and
        // recovery. Fence even successful replays before consulting receipts.
        let fencedRoom: MembershipRoomRow?
        if let ownerRoute {
            guard let value = try await sql.raw("""
                SELECT room_shard_id, owner_epoch, room_sequence, membership_revision, capacity_profile_id, delivery_mode
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: MembershipRoomRow.self),
                  value.roomShardID == ownerRoute.shardID, value.ownerEpoch == ownerRoute.epoch
            else { throw V2RoomMembershipStoreError.ownerChanged }
            fencedRoom = value
        } else {
            // Room-local composition (including invitation approval) already
            // owns the surrounding owner fence and transaction.
            fencedRoom = nil
        }
        guard try await !v2MembershipOperationIsFenced(actor: actorID, operation: operationID, sql: sql) else { return .idempotencyConflict }
        if let prior = try await sql.raw("""
            SELECT room_id, target_user_id, action, expected_membership_revision,
                   resulting_membership_revision, room_sequence, event_id, plan_id, created_at
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
                SELECT room_shard_id, owner_epoch, room_sequence, membership_revision, capacity_profile_id, delivery_mode
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE
                """).first(decoding: MembershipRoomRow.self) else { throw V2RoomMembershipStoreError.roomNotFound }
            room = value
        }
        guard let group = try await sql.raw("""
            SELECT owner_user_id, title, created_at
            FROM im_v2.group_rooms WHERE room_id = \(bind: roomID)
            """).first(decoding: MembershipGroupRow.self) else { throw V2RoomMembershipStoreError.roomNotFound }
        guard room.capacityProfileID == capacityProfile.id else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        guard try membershipUnsigned(room.membershipRevision) == command.expectedMembershipRevision else {
            return .revisionConflict(current: try membershipUnsigned(room.membershipRevision))
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
        if actorRole != .owner {
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
                   fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                   outstanding_fanout_units, max_outstanding_plans, outstanding_plans,
                   shard_lease_id, shard_lease_generation
            FROM im_v2.room_admission WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: MembershipAdmissionRow.self),
              let shard = try await sql.raw("""
            SELECT lease_id, generation, valid_until, command_window_limit, command_window_used,
                   fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                   outstanding_fanout_units, max_outstanding_plans, outstanding_plans
            FROM im_v2.shard_admission_pools
            WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
            FOR UPDATE
            """).first(decoding: MembershipShardRow.self) else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        guard admission.shardLeaseID == shard.leaseID,
              admission.shardLeaseGeneration == shard.generation,
              admission.eligibleMemberCount > 0
        else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        let nextEligibleCount: Int
        let deliveryTargetCount: Int
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
            let modeMaximum = V2GroupDeliveryPolicy().maximumMembers(for: room.deliveryMode)
            guard nextEligibleCount <= capacityProfile.limits.maxEligibleMembers,
                  nextEligibleCount <= modeMaximum
            else { return .memberLimitReached }
            deliveryTargetCount = room.deliveryMode == .largeGroupHybrid ? 1 : nextEligibleCount
        case .remove:
            guard let currentTarget else { return .targetNotMember }
            // V2 starts with one non-transferable owner; removing it would
            // leave the group without an authorization authority.
            guard currentTarget.role != "owner" else { throw V2RoomMembershipStoreError.actorNotOwner }
            nextEligibleCount = admission.eligibleMemberCount - 1
            deliveryTargetCount = room.deliveryMode == .largeGroupHybrid ? 1 : admission.eligibleMemberCount
        }
        guard v2PostgresTimestampCanEncode(group.createdAt),
              let groupCreatedAtMilliseconds = try? v2GatewayMilliseconds(group.createdAt)
        else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        let reservation = try FanoutAdmissionEvaluator.reserve(
            request: .init(targetRule: .exactTargetCount(deliveryTargetCount)),
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
                commandWindow: roomState.commandWindow,
                fanoutWindow: roomState.fanoutWindow,
                outstandingFanoutUnits: roomState.outstandingFanoutUnits,
                outstandingPlans: roomState.outstandingPlans
            )
            reservedShard = shardState
        }
        guard let lease = reservedShard.lease else { throw V2RoomMembershipStoreError.corruptPersistenceState }
        guard room.membershipRevision < Int64.max, room.roomSequence < Int64.max else {
            throw V2RoomMembershipStoreError.corruptPersistenceState
        }
        let nextRevision = room.membershipRevision + 1
        let nextSequence = room.roomSequence + 1
        let eventUUID = try membershipUUID(eventID)
        let planUUID = try membershipUUID(planID)

        // Decode at the same precision as the operation/event writes; keep their original Date bindings.
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
            SET eligible_member_count = \(bind: nextEligibleCount), command_window_used = \(bind: reservedRoom.commandWindow.used),
                fanout_window_used = \(bind: reservedRoom.fanoutWindow.used), outstanding_fanout_units = \(bind: reservedRoom.outstandingFanoutUnits),
                outstanding_plans = \(bind: reservedRoom.outstandingPlans), shard_lease_id = \(bind: try membershipUUID(lease.id)),
                shard_lease_generation = \(bind: try membershipSigned(lease.generation))
            WHERE room_id = \(bind: roomID)
            """).run()
        try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET command_window_used = \(bind: lease.commandWindow.used), fanout_window_used = \(bind: lease.fanoutWindow.used),
                outstanding_fanout_units = \(bind: reservedShard.outstandingFanoutUnits), outstanding_plans = \(bind: reservedShard.outstandingPlans)
            WHERE room_shard_id = \(bind: room.roomShardID) AND capacity_profile_id = \(bind: room.capacityProfileID)
              AND lease_id = \(bind: try membershipUUID(lease.id)) AND generation = \(bind: try membershipSigned(lease.generation))
            """).run()
        switch command.action {
        case .add:
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision) VALUES (\(bind: roomID), \(bind: targetID), 'member', \(bind: nextRevision))").run()
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
                        'delivery_mode', \(bind: room.deliveryMode.rawValue),
                        'created_at_ms', \(bind: groupCreatedAtMilliseconds),
                        'server_created_at_ms', \(bind: createdAtMilliseconds)
                    ), \(bind: nextRevision), \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.fanout_plans
                (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                 target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
            VALUES (\(bind: planUUID), \(bind: eventUUID), \(bind: roomID), \(bind: nextSequence), \(bind: nextRevision),
                    '{"kind":"frozen_targets"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                    \(bind: deliveryTargetCount), \(bind: deliveryTargetCount), 'planning', \(bind: now))
            """).run()
        if room.deliveryMode == .largeGroupHybrid {
            try await sql.raw("INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id) VALUES (\(bind: eventUUID), \(bind: targetID))").run()
        } else {
            // Freeze directly from the historical interval at the prior
            // revision. A removal therefore still notifies the removed
            // member; an add unions the newly joined target. No roster is
            // materialized in application memory.
            switch command.action {
            case .add:
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                    SELECT \(bind: eventUUID), membership.user_id
                    FROM im_v2.room_memberships AS membership
                    WHERE membership.room_id = \(bind: roomID)
                      AND membership.joined_revision <= \(bind: room.membershipRevision)
                      AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: room.membershipRevision))
                    UNION ALL SELECT \(bind: eventUUID), \(bind: targetID)
                    """).run()
            case .remove:
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                    SELECT \(bind: eventUUID), membership.user_id
                    FROM im_v2.room_memberships AS membership
                    WHERE membership.room_id = \(bind: roomID)
                      AND membership.joined_revision <= \(bind: room.membershipRevision)
                      AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: room.membershipRevision))
                    """).run()
            }
        }
        try await sql.raw("INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at) VALUES (\(bind: eventUUID), \(bind: planUUID), 'pending', \(bind: now))").run()
        try await sql.raw("""
            INSERT INTO im_v2.room_membership_operations
                (actor_user_id, operation_id, room_id, target_user_id, action, expected_membership_revision,
                 resulting_membership_revision, room_sequence, event_id, plan_id, created_at)
            VALUES (\(bind: actorID), \(bind: operationID), \(bind: roomID), \(bind: targetID), \(bind: command.action.rawValue),
                    \(bind: try membershipSigned(command.expectedMembershipRevision)), \(bind: nextRevision), \(bind: nextSequence), \(bind: eventUUID), \(bind: planUUID), \(bind: now))
            """).run()
        return .changed(try .init(roomID: command.roomID, targetUserID: command.targetUserID, action: command.action,
                                  membershipRevision: membershipUnsigned(nextRevision), roomSequence: membershipUnsigned(nextSequence),
                                  eventID: eventID, fanoutPlanID: planID, createdAt: timestamp.createdAt))
    }
}

private struct MembershipCommittedTimestampRow: Decodable {
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case createdAt = "created_at" }
}

private struct MembershipRoomRow: Decodable { let roomShardID: String; let ownerEpoch: Int64; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let deliveryMode: V2GroupDeliveryMode; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", ownerEpoch = "owner_epoch", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", deliveryMode = "delivery_mode" } }
private struct MembershipGroupRow: Decodable { let ownerUserID: UUID; let title: String; let createdAt: Date; enum CodingKeys: String, CodingKey { case ownerUserID = "owner_user_id", title, createdAt = "created_at" } }
private struct MembershipTargetRow: Decodable { let userID: UUID; let role: String; enum CodingKeys: String, CodingKey { case userID = "user_id", role } }
private struct MembershipBooleanRow: Decodable { let value: Bool }
private struct MembershipOperationRow: Decodable {
    let roomID: UUID; let targetUserID: UUID; let action: String; let expectedMembershipRevision: Int64; let resultingMembershipRevision: Int64; let roomSequence: Int64; let eventID: UUID; let planID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", action, expectedMembershipRevision = "expected_membership_revision", resultingMembershipRevision = "resulting_membership_revision", roomSequence = "room_sequence", eventID = "event_id", planID = "plan_id", createdAt = "created_at" }
    func matches(command: V2ChangeRoomMembershipCommand, roomID: UUID, targetID: UUID) -> Bool { self.roomID == roomID && targetUserID == targetID && action == command.action.rawValue && expectedMembershipRevision == command.expectedRevision.signedValue }
    func change() throws -> V2RoomMembershipChange { try .init(roomID: .init(roomID.uuidString), targetUserID: .init(targetUserID.uuidString), action: try .init(rawValue: action).unwrapMembership(), membershipRevision: membershipUnsigned(resultingMembershipRevision), roomSequence: membershipUnsigned(roomSequence), eventID: .init(eventID.uuidString), fanoutPlanID: .init(planID.uuidString), createdAt: createdAt) }
}
private struct MembershipAdmissionRow {
    let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64
}
extension MembershipAdmissionRow: Decodable { enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }; func state() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private struct MembershipShardRow { let leaseID: UUID; let generation: Int64; let validUntil: Date; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int }
extension MembershipShardRow: Decodable { enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans" }; func state() throws -> ShardAdmissionState { try .init(lease: .init(id: .init(leaseID.uuidString), generation: membershipUnsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) } }
private func membershipUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: value.rawValue) else { throw V2RoomMembershipStoreError.corruptPersistenceState }; return value }
private func membershipUnsigned(_ value: Int64) throws -> UInt64 { guard value >= 0 else { throw V2RoomMembershipStoreError.corruptPersistenceState }; return UInt64(value) }
private func membershipSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2RoomMembershipStoreError.corruptPersistenceState }; return Int64(value) }
private extension Optional where Wrapped == V2RoomMembershipAction { func unwrapMembership() throws -> Wrapped { guard let self else { throw V2RoomMembershipStoreError.corruptPersistenceState }; return self } }
