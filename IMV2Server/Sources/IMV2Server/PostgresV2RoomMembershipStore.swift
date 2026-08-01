import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Membership changes with an explicit room authority model. Only the owner
/// can add members, while either owner or admin can remove a non-owner. The
/// transaction freezes its exact audience before it changes membership, so
/// add and remove events do not depend on whichever membership rows happen to
/// exist when a worker runs.
public struct PostgresV2RoomMembershipStore: V2RoomMembershipStore {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func change(command: V2ChangeRoomMembershipCommand, capacityProfile: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) async throws -> V2RoomMembershipChangeOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomMembershipStoreError.corruptPersistenceState }
            let roomID = try membershipUUID(command.roomID)
            let actorID = try membershipUUID(command.actorUserID)
            let targetID = try membershipUUID(command.targetUserID)
            let operationID = try membershipUUID(command.operationID)
            let operationLockKey = actorID.uuidString + ":" + operationID.uuidString

            // An advisory lock serializes the absent-row case for this exact
            // durable operation key. Hash collisions can only add contention,
            // never merge two operation records.
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()
            if let prior = try await sql.raw("""
                SELECT room_id, target_user_id, action, expected_membership_revision,
                       resulting_membership_revision, room_sequence, event_id, plan_id, created_at
                FROM im_v2.room_membership_operations
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).first(decoding: MembershipOperationRow.self) {
                guard prior.matches(command: command, roomID: roomID, targetID: targetID) else { return .idempotencyConflict }
                return .idempotent(try prior.change())
            }

            guard let room = try await sql.raw("""
                SELECT room_shard_id, room_sequence, membership_revision, capacity_profile_id, delivery_mode
                FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE
            """).first(decoding: MembershipRoomRow.self) else { throw V2RoomMembershipStoreError.roomNotFound }
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
                let configured = try await sql.raw("SELECT permission FROM im_v2.group_role_permissions WHERE room_id = \(bind: roomID) AND role = \(bind: actorRole.rawValue)").all(decoding: MembershipPermissionRow.self)
                let permissions = Set(configured.compactMap { V2GroupPermission(rawValue: $0.permission) })
                guard V2GroupPermissionDefaults.allows(role: actorRole, permission: requiredPermission, configured: permissions) else { throw V2RoomMembershipStoreError.actorNotOwner }
            }
            let currentTargets = try await sql.raw("""
                SELECT user_id, role FROM im_v2.room_memberships
                WHERE room_id = \(bind: roomID) AND joined_revision <= \(bind: room.membershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))
                ORDER BY user_id
                """).all(decoding: MembershipTargetRow.self)
            let currentTarget = currentTargets.first { $0.userID == targetID }
            let audience: [UUID]
            let nextEligibleCount: Int
            switch command.action {
            case .add:
                guard currentTarget == nil else { return .targetAlreadyMember }
                let modeMaximum = V2GroupDeliveryPolicy().maximumMembers(for: room.deliveryMode)
                guard currentTargets.count + 1 <= capacityProfile.limits.maxEligibleMembers,
                      currentTargets.count + 1 <= modeMaximum
                else { return .memberLimitReached }
                audience = (currentTargets.map(\.userID) + [targetID]).sorted { $0.uuidString < $1.uuidString }
                nextEligibleCount = currentTargets.count + 1
            case .remove:
                guard let currentTarget else { return .targetNotMember }
                // V2 starts with one non-transferable owner; removing it would
                // leave the group without an authorization authority.
                guard currentTarget.role != "owner" else { throw V2RoomMembershipStoreError.actorNotOwner }
                audience = currentTargets.map(\.userID)
                nextEligibleCount = currentTargets.count - 1
            }
            // A large-group membership mutation produces a finite control
            // projection only for the added/removed user. Existing members
            // observe the ordered event through the room log, so this path
            // never reintroduces a group-wide fan-out.
            let deliveryAudience = room.deliveryMode == .largeGroupHybrid ? [targetID] : audience

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
            guard admission.shardLeaseID == shard.leaseID, admission.shardLeaseGeneration == shard.generation,
                  admission.eligibleMemberCount == currentTargets.count
            else { throw V2RoomMembershipStoreError.corruptPersistenceState }
            let reservation = try FanoutAdmissionEvaluator.reserve(
                request: .init(targetRule: .exactTargetCount(deliveryAudience.count)),
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
            let nextRevision = room.membershipRevision + 1
            let nextSequence = room.roomSequence + 1
            let eventUUID = try membershipUUID(eventID)
            let planUUID = try membershipUUID(planID)

            try await sql.raw("""
                UPDATE im_v2.rooms SET room_sequence = \(bind: nextSequence), membership_revision = \(bind: nextRevision)
                WHERE room_id = \(bind: roomID)
                """).run()
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
                            'created_at_ms', \(bind: Int64(group.createdAt.timeIntervalSince1970 * 1_000)),
                            'server_created_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))
                        ), \(bind: nextRevision), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES (\(bind: planUUID), \(bind: eventUUID), \(bind: roomID), \(bind: nextSequence), \(bind: nextRevision),
                        '{"kind":"frozen_targets"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                        \(bind: deliveryAudience.count), \(bind: deliveryAudience.count), 'planning', \(bind: now))
                """).run()
            let targetsJSON = String(data: try JSONSerialization.data(withJSONObject: deliveryAudience.map(\.uuidString)), encoding: .utf8)!
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                SELECT \(bind: eventUUID), value::uuid FROM jsonb_array_elements_text(\(bind: targetsJSON)::jsonb) AS value
                """).run()
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
                                      eventID: eventID, fanoutPlanID: planID, createdAt: now))
        }
    }
}

private struct MembershipRoomRow: Decodable { let roomShardID: String; let roomSequence: Int64; let membershipRevision: Int64; let capacityProfileID: String; let deliveryMode: V2GroupDeliveryMode; enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", roomSequence = "room_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", deliveryMode = "delivery_mode" } }
private struct MembershipGroupRow: Decodable { let ownerUserID: UUID; let title: String; let createdAt: Date; enum CodingKeys: String, CodingKey { case ownerUserID = "owner_user_id", title, createdAt = "created_at" } }
private struct MembershipTargetRow: Decodable { let userID: UUID; let role: String; enum CodingKeys: String, CodingKey { case userID = "user_id", role } }
private struct MembershipPermissionRow: Decodable { let permission: String }
private struct MembershipBooleanRow: Decodable { let value: Bool }
private struct MembershipOperationRow: Decodable {
    let roomID: UUID; let targetUserID: UUID; let action: String; let expectedMembershipRevision: Int64; let resultingMembershipRevision: Int64; let roomSequence: Int64; let eventID: UUID; let planID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case roomID = "room_id", targetUserID = "target_user_id", action, expectedMembershipRevision = "expected_membership_revision", resultingMembershipRevision = "resulting_membership_revision", roomSequence = "room_sequence", eventID = "event_id", planID = "plan_id", createdAt = "created_at" }
    func matches(command: V2ChangeRoomMembershipCommand, roomID: UUID, targetID: UUID) -> Bool { self.roomID == roomID && targetUserID == targetID && action == command.action.rawValue && expectedMembershipRevision == Int64(command.expectedMembershipRevision) }
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
