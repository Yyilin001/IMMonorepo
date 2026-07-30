import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL group bootstrap transaction.  It creates the room, title,
/// initial owner/member intervals, admission row and durable operation ledger
/// together.  No partially created group can be observed after a retry.
public struct PostgresV2GroupMessagingStore: V2GroupMessagingStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func create(
        command: V2CreateGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            let actorID = try groupUUID(command.actorUserID)
            let operationID = try groupUUID(command.operationID)
            let requestedMembers = try command.initialMemberUserIDs.map(groupUUID)
            let allMembers = try command.allMemberUserIDs.map(groupUUID)
            guard allMembers.count <= capacityProfile.limits.maxEligibleMembers else {
                return .memberLimitReached
            }

            let operationLockKey = actorID.uuidString + ":" + operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()
            if let previous = try await sql.raw("""
                SELECT room_id, title, delivery_mode, initial_member_user_ids, created_at
                FROM im_v2.group_room_operations
                WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)
                """).first(decoding: GroupOperationRow.self) {
                guard previous.title == command.title,
                      previous.deliveryMode == command.deliveryMode,
                      previous.initialMemberUserIDs == requestedMembers
                else {
                    return .idempotencyConflict
                }
                return .idempotent(try previous.group(ownerUserID: command.actorUserID))
            }

            guard let lease = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit, command_window_used,
                       fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                       outstanding_fanout_units, max_outstanding_plans, outstanding_plans
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: roomShardID) AND capacity_profile_id = \(bind: capacityProfile.id)
                FOR UPDATE
                """).first(decoding: GroupShardLeaseRow.self) else {
                return .unavailable
            }
            let initialAdmission = try RoomAdmissionState(
                eligibleMemberCount: allMembers.count,
                commandWindow: .init(limit: capacityProfile.limits.maxCommandsPerWindow),
                fanoutWindow: .init(limit: capacityProfile.limits.maxFanoutUnitsPerWindow),
                outstandingFanoutUnits: 0,
                outstandingPlans: 0
            )
            let reservation = try FanoutAdmissionEvaluator.reserve(
                request: .init(targetRule: .exactTargetCount(allMembers.count)),
                profile: capacityProfile.limits,
                roomState: initialAdmission,
                shardState: try lease.state(),
                now: now
            )
            let reservedRoom: RoomAdmissionState
            let reservedShard: ShardAdmissionState
            switch reservation {
            case .accepted(_, let roomState, let shardState): reservedRoom = roomState; reservedShard = shardState
            case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable: return .unavailable
            }
            guard let reservedLease = reservedShard.lease else { throw V2GroupMessagingStoreError.corruptPersistenceState }

            let createdRoomID = try groupUUID(roomID)
            let createdEventID = try groupUUID(eventID)
            let createdPlanID = try groupUUID(planID)
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_kind, room_shard_id, room_sequence, membership_revision, capacity_profile_id, delivery_mode, created_at)
                VALUES (\(bind: createdRoomID), 'group', \(bind: roomShardID), 1, 1, \(bind: capacityProfile.id), \(bind: command.deliveryMode.rawValue), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: createdRoomID), \(bind: actorID), \(bind: command.title), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                VALUES (\(bind: createdRoomID), \(bind: actorID), 'owner', 1)
                """).run()
            if !requestedMembers.isEmpty {
                let membersJSON = try String(data: JSONEncoder().encode(requestedMembers.map(\.uuidString)), encoding: .utf8).unwrapGroup()
                try await sql.raw("""
                    INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                    SELECT \(bind: createdRoomID), value::uuid, 'member', 1
                    FROM jsonb_array_elements_text(\(bind: membersJSON)::jsonb) AS value
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans, shard_lease_id, shard_lease_generation)
                VALUES (\(bind: createdRoomID), \(bind: allMembers.count), \(bind: capacityProfile.limits.maxCommandsPerWindow),
                        \(bind: capacityProfile.limits.maxFanoutUnitsPerWindow), \(bind: capacityProfile.limits.maxOutstandingFanoutUnits),
                        \(bind: capacityProfile.limits.maxOutstandingPlans), \(bind: try groupUUID(reservedLease.id)), \(bind: try groupSigned(reservedLease.generation)))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_admission
                SET command_window_used = \(bind: reservedRoom.commandWindow.used), fanout_window_used = \(bind: reservedRoom.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: reservedRoom.outstandingFanoutUnits), outstanding_plans = \(bind: reservedRoom.outstandingPlans)
                WHERE room_id = \(bind: createdRoomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_used = \(bind: reservedLease.commandWindow.used), fanout_window_used = \(bind: reservedLease.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: reservedShard.outstandingFanoutUnits), outstanding_plans = \(bind: reservedShard.outstandingPlans)
                WHERE room_shard_id = \(bind: roomShardID) AND capacity_profile_id = \(bind: capacityProfile.id)
                  AND lease_id = \(bind: try groupUUID(reservedLease.id)) AND generation = \(bind: try groupSigned(reservedLease.generation))
                """).run()
            let allMembersJSON = try String(data: JSONEncoder().encode(allMembers.map(\.uuidString)), encoding: .utf8).unwrapGroup()
            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
                VALUES (\(bind: createdEventID), \(bind: createdRoomID), 1, 'room.created', \(bind: actorID),
                        jsonb_build_object('event_type', 'room.created', 'room_id', \(bind: createdRoomID.uuidString),
                                           'owner_user_id', \(bind: actorID.uuidString), 'title', \(bind: command.title),
                                           'delivery_mode', \(bind: command.deliveryMode.rawValue),
                                           'membership_revision', 1,
                                           'created_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))),
                        1, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES (\(bind: createdPlanID), \(bind: createdEventID), \(bind: createdRoomID), 1, 1,
                        '{"kind":"frozen_targets"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                        \(bind: allMembers.count), \(bind: allMembers.count), 'planning', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                SELECT \(bind: createdEventID), value::uuid FROM jsonb_array_elements_text(\(bind: allMembersJSON)::jsonb) AS value
                """).run()
            try await sql.raw("INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at) VALUES (\(bind: createdEventID), \(bind: createdPlanID), 'pending', \(bind: now))").run()
            let initialMembersJSON = try String(data: JSONEncoder().encode(requestedMembers.map(\.uuidString)), encoding: .utf8).unwrapGroup()
            try await sql.raw("""
                INSERT INTO im_v2.group_room_operations
                    (actor_user_id, operation_id, room_id, title, delivery_mode, initial_member_user_ids, created_at)
                VALUES (\(bind: actorID), \(bind: operationID), \(bind: createdRoomID), \(bind: command.title), \(bind: command.deliveryMode.rawValue),
                        ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(\(bind: initialMembersJSON)::jsonb) AS value ORDER BY value::uuid),
                        \(bind: now))
                """).run()
            return .created(.init(roomID: roomID, ownerUserID: command.actorUserID, title: command.title, deliveryMode: command.deliveryMode, memberUserIDs: command.allMemberUserIDs, createdAt: now))
        }
    }
}

public enum V2GroupMessagingStoreError: Error, Equatable, Sendable {
    case corruptPersistenceState
}

private struct GroupShardLeaseRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let commandWindowLimit: Int
    let commandWindowUsed: Int
    let fanoutWindowLimit: Int
    let fanoutWindowUsed: Int
    let maxOutstandingFanoutUnits: Int
    let outstandingFanoutUnits: Int
    let maxOutstandingPlans: Int
    let outstandingPlans: Int
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case generation
        case validUntil = "valid_until"
        case commandWindowLimit = "command_window_limit"
        case commandWindowUsed = "command_window_used"
        case fanoutWindowLimit = "fanout_window_limit"
        case fanoutWindowUsed = "fanout_window_used"
        case maxOutstandingFanoutUnits = "max_outstanding_fanout_units"
        case outstandingFanoutUnits = "outstanding_fanout_units"
        case maxOutstandingPlans = "max_outstanding_plans"
        case outstandingPlans = "outstanding_plans"
    }

    func state() throws -> ShardAdmissionState {
        try .init(
            lease: .init(id: .init(leaseID.uuidString), generation: try groupUnsigned(generation), validUntil: validUntil,
                         commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed),
                         fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed),
                         maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans),
            outstandingFanoutUnits: outstandingFanoutUnits,
            outstandingPlans: outstandingPlans
        )
    }
}

private struct GroupOperationRow: Decodable {
    let roomID: UUID
    let title: String
    let deliveryMode: V2GroupDeliveryMode
    let initialMemberUserIDs: [UUID]
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case title
        case deliveryMode = "delivery_mode"
        case initialMemberUserIDs = "initial_member_user_ids"
        case createdAt = "created_at"
    }

    func group(ownerUserID: UserID) throws -> V2GroupRoom {
        let members = try initialMemberUserIDs.map { try UserID($0.uuidString) }
        return try .init(roomID: .init(roomID.uuidString), ownerUserID: ownerUserID, title: title, deliveryMode: deliveryMode, memberUserIDs: [ownerUserID] + members, createdAt: createdAt)
    }
}

private func groupUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2GroupMessagingStoreError.corruptPersistenceState
    }
    return value
}

private func groupUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return UInt64(value)
}

private func groupSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return Int64(value)
}

private extension Optional where Wrapped == String {
    func unwrapGroup() throws -> String {
        guard let self else { throw V2GroupMessagingStoreError.corruptPersistenceState }
        return self
    }
}
