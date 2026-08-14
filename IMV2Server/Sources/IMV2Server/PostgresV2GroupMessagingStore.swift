import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL group bootstrap transaction. It creates the room, initial
/// membership, admission state, fan-out plan and operation ledger atomically.
/// Staged audiences stay relational throughout this transaction, so a 100k
/// group never becomes a Swift array or a giant PostgreSQL operation array.
public struct PostgresV2GroupMessagingStore: V2GroupMessagingStore, V2StagedGroupMessagingStore {
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
        let actorID = try groupUUID(command.actorUserID)
        let requestedMembers = try command.initialMemberUserIDs.map(groupUUID)
        let memberCount = requestedMembers.count + 1
        guard memberCount <= capacityProfile.limits.maxEligibleMembers else {
            return .memberLimitReached
        }
        let input = GroupCreationInput(
            actorUserID: command.actorUserID,
            actorID: actorID,
            operationID: try groupUUID(command.operationID),
            title: command.title,
            deliveryMode: command.deliveryMode,
            memberCount: memberCount,
            audience: .inline(
                requestedMembers: requestedMembers,
                materializedMembers: command.allMemberUserIDs
            )
        )
        return try await createGroup(
            input: input,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }

    public func createStaged(
        command: V2StagedGroupRoomCommand,
        capacityProfile: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome {
        guard command.allMemberCount <= capacityProfile.limits.maxEligibleMembers else {
            return .memberLimitReached
        }
        let input = GroupCreationInput(
            actorUserID: command.actorUserID,
            actorID: try groupUUID(command.actorUserID),
            operationID: try groupUUID(command.operationID),
            title: command.title,
            deliveryMode: command.deliveryMode,
            memberCount: command.allMemberCount,
            audience: .staged
        )
        return try await createGroup(
            input: input,
            capacityProfile: capacityProfile,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }

    private func createGroup(
        input: GroupCreationInput,
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
            let operationLockKey = input.actorID.uuidString + ":" + input.operationID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: operationLockKey), 0))").run()

            if let previous = try await sql.raw("""
                SELECT room_id, title, delivery_mode, audience_kind,
                       initial_member_count, initial_member_user_ids, created_at
                FROM im_v2.group_room_operations
                WHERE actor_user_id = \(bind: input.actorID)
                  AND operation_id = \(bind: input.operationID)
                """).first(decoding: GroupOperationRow.self) {
                guard previous.matches(input) else { return .idempotencyConflict }
                return .idempotent(try previous.group(ownerUserID: input.actorUserID))
            }

            switch input.audience {
            case .inline(let requestedMembers, _):
                let allMembers = [input.actorID] + requestedMembers
                let encoded = try groupUUIDJSON(allMembers)
                let activeMemberCount = try await sql.raw("""
                    WITH requested AS (
                        SELECT value::uuid AS user_id
                        FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                    )
                    SELECT COUNT(*)::bigint AS value
                    FROM requested
                    INNER JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = requested.user_id AND profile.state = 'active'
                    LEFT JOIN im_v2.account_disables AS disabled
                      ON disabled.user_id = requested.user_id
                    WHERE disabled.user_id IS NULL
                    """).first(decoding: GroupCountRow.self)?.value ?? -1
                guard activeMemberCount == Int64(input.memberCount) else { return .invalidMembers }

            case .staged:
                guard let draft = try await sql.raw("""
                    SELECT draft.title, draft.state,
                           (SELECT COUNT(*)::bigint
                            FROM im_v2.group_room_creation_draft_members AS member
                            WHERE member.actor_user_id = draft.actor_user_id
                              AND member.operation_id = draft.operation_id) AS member_count
                    FROM im_v2.group_room_creation_drafts AS draft
                    WHERE draft.actor_user_id = \(bind: input.actorID)
                      AND draft.operation_id = \(bind: input.operationID)
                    FOR SHARE
                    """).first(decoding: GroupStagedDraftRow.self),
                      draft.state == "finalizing",
                      draft.title == input.title,
                      draft.memberCount == Int64(input.memberCount - 1)
                else { return .idempotencyConflict }

                let activeMemberCount = try await sql.raw("""
                    WITH requested AS (
                        SELECT \(bind: input.actorID) AS user_id
                        UNION ALL
                        SELECT member.user_id
                        FROM im_v2.group_room_creation_draft_members AS member
                        WHERE member.actor_user_id = \(bind: input.actorID)
                          AND member.operation_id = \(bind: input.operationID)
                    )
                    SELECT COUNT(*)::bigint AS value
                    FROM requested
                    INNER JOIN im_v2.public_user_profiles AS profile
                      ON profile.user_id = requested.user_id AND profile.state = 'active'
                    LEFT JOIN im_v2.account_disables AS disabled
                      ON disabled.user_id = requested.user_id
                    WHERE disabled.user_id IS NULL
                    """).first(decoding: GroupCountRow.self)?.value ?? -1
                guard activeMemberCount == Int64(input.memberCount) else { return .invalidMembers }
            }

            let createdRoomID = try groupUUID(roomID)
            let createdEventID = try groupUUID(eventID)
            let createdPlanID = try groupUUID(planID)
            try await sql.raw("""
                INSERT INTO im_v2.rooms
                    (room_id, room_kind, room_shard_id, room_sequence, membership_revision,
                     capacity_profile_id, delivery_mode, created_at)
                VALUES (\(bind: createdRoomID), 'group', \(bind: roomShardID), 1, 1,
                        \(bind: capacityProfile.id), \(bind: input.deliveryMode.rawValue), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
                VALUES (\(bind: createdRoomID), \(bind: input.actorID), \(bind: input.title), \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                VALUES (\(bind: createdRoomID), \(bind: input.actorID), 'owner', 1)
                """).run()

            switch input.audience {
            case .inline(let requestedMembers, _):
                if !requestedMembers.isEmpty {
                    let encoded = try groupUUIDJSON(requestedMembers)
                    try await sql.raw("""
                        INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                        SELECT \(bind: createdRoomID), value::uuid, 'member', 1
                        FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                        """).run()
                }
            case .staged:
                try await sql.raw("""
                    INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
                    SELECT \(bind: createdRoomID), member.user_id, 'member', 1
                    FROM im_v2.group_room_creation_draft_members AS member
                    WHERE member.actor_user_id = \(bind: input.actorID)
                      AND member.operation_id = \(bind: input.operationID)
                    """).run()
            }

            try await sql.raw("""
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                VALUES (\(bind: createdEventID), \(bind: createdRoomID), 1, 'room.created', \(bind: input.actorID),
                        jsonb_build_object('event_type', 'room.created', 'room_id', \(bind: createdRoomID.uuidString),
                                           'owner_user_id', \(bind: input.actorID.uuidString), 'title', \(bind: input.title),
                                           'delivery_mode', \(bind: input.deliveryMode.rawValue),
                                           'membership_revision', 1,
                                           'created_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))),
                        1, \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence,
                     committed_membership_revision, target_rule, enumeration_checkpoint,
                     target_count, reserved_fanout_cost, state, created_at)
                VALUES (\(bind: createdPlanID), \(bind: createdEventID), \(bind: createdRoomID), 1, 1,
                        '{"kind":"frozen_targets"}'::jsonb,
                        jsonb_build_object('after_user_id', NULL),
                        \(bind: input.memberCount), \(bind: input.memberCount), 'planning', \(bind: now))
                """).run()

            switch input.audience {
            case .inline(let requestedMembers, _):
                let encoded = try groupUUIDJSON([input.actorID] + requestedMembers)
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                    SELECT \(bind: createdEventID), value::uuid
                    FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                    """).run()
            case .staged:
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                    SELECT \(bind: createdEventID), \(bind: input.actorID)
                    UNION ALL
                    SELECT \(bind: createdEventID), member.user_id
                    FROM im_v2.group_room_creation_draft_members AS member
                    WHERE member.actor_user_id = \(bind: input.actorID)
                      AND member.operation_id = \(bind: input.operationID)
                    """).run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at)
                VALUES (\(bind: createdEventID), \(bind: createdPlanID), 'pending', \(bind: now))
                """).run()

            // Reserve after the private bulk rows are prepared. Rejection
            // still rolls the transaction back, while the shared shard row is
            // not locked throughout the potentially large set-based inserts.
            guard let lease = try await sql.raw("""
                SELECT lease_id, generation, valid_until, command_window_limit,
                       command_window_used, fanout_window_limit, fanout_window_used,
                       max_outstanding_fanout_units, outstanding_fanout_units,
                       max_outstanding_plans, outstanding_plans
                FROM im_v2.shard_admission_pools
                WHERE room_shard_id = \(bind: roomShardID)
                  AND capacity_profile_id = \(bind: capacityProfile.id)
                FOR UPDATE
                """).first(decoding: GroupShardLeaseRow.self) else {
                return .unavailable
            }
            let initialAdmission = try RoomAdmissionState(
                eligibleMemberCount: input.memberCount,
                commandWindow: .init(limit: capacityProfile.limits.maxCommandsPerWindow),
                fanoutWindow: .init(limit: capacityProfile.limits.maxFanoutUnitsPerWindow),
                outstandingFanoutUnits: 0,
                outstandingPlans: 0
            )
            let reservation = try FanoutAdmissionEvaluator.reserve(
                request: .init(targetRule: .exactTargetCount(input.memberCount)),
                profile: capacityProfile.limits,
                roomState: initialAdmission,
                shardState: try lease.state(),
                now: now
            )
            let reservedRoom: RoomAdmissionState
            let reservedShard: ShardAdmissionState
            switch reservation {
            case .accepted(_, let roomState, let shardState):
                reservedRoom = roomState
                reservedShard = shardState
            case .rateLimited(let seconds):
                return .rateLimited(retryAfterSeconds: seconds)
            case .unavailable:
                return .unavailable
            }
            guard let reservedLease = reservedShard.lease else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            try await sql.raw("""
                INSERT INTO im_v2.room_admission
                    (room_id, eligible_member_count, command_window_limit, fanout_window_limit,
                     max_outstanding_fanout_units, max_outstanding_plans,
                     shard_lease_id, shard_lease_generation)
                VALUES (\(bind: createdRoomID), \(bind: input.memberCount),
                        \(bind: capacityProfile.limits.maxCommandsPerWindow),
                        \(bind: capacityProfile.limits.maxFanoutUnitsPerWindow),
                        \(bind: capacityProfile.limits.maxOutstandingFanoutUnits),
                        \(bind: capacityProfile.limits.maxOutstandingPlans),
                        \(bind: try groupUUID(reservedLease.id)),
                        \(bind: try groupSigned(reservedLease.generation)))
                """).run()
            try await sql.raw("""
                UPDATE im_v2.room_admission
                SET command_window_used = \(bind: reservedRoom.commandWindow.used),
                    fanout_window_used = \(bind: reservedRoom.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: reservedRoom.outstandingFanoutUnits),
                    outstanding_plans = \(bind: reservedRoom.outstandingPlans)
                WHERE room_id = \(bind: createdRoomID)
                """).run()
            try await sql.raw("""
                UPDATE im_v2.shard_admission_pools
                SET command_window_used = \(bind: reservedLease.commandWindow.used),
                    fanout_window_used = \(bind: reservedLease.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: reservedShard.outstandingFanoutUnits),
                    outstanding_plans = \(bind: reservedShard.outstandingPlans)
                WHERE room_shard_id = \(bind: roomShardID)
                  AND capacity_profile_id = \(bind: capacityProfile.id)
                  AND lease_id = \(bind: try groupUUID(reservedLease.id))
                  AND generation = \(bind: try groupSigned(reservedLease.generation))
                """).run()

            switch input.audience {
            case .inline(let requestedMembers, _):
                let encoded = try groupUUIDJSON(requestedMembers)
                try await sql.raw("""
                    INSERT INTO im_v2.group_room_operations
                        (actor_user_id, operation_id, room_id, title, delivery_mode,
                         audience_kind, initial_member_count, initial_member_user_ids, created_at)
                    VALUES (\(bind: input.actorID), \(bind: input.operationID), \(bind: createdRoomID),
                            \(bind: input.title), \(bind: input.deliveryMode.rawValue), 'inline',
                            \(bind: input.memberCount),
                            ARRAY(SELECT value::uuid
                                  FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
                                  ORDER BY value::uuid),
                            \(bind: now))
                    """).run()
            case .staged:
                try await sql.raw("""
                    INSERT INTO im_v2.group_room_operations
                        (actor_user_id, operation_id, room_id, title, delivery_mode,
                         audience_kind, initial_member_count, initial_member_user_ids, created_at)
                    VALUES (\(bind: input.actorID), \(bind: input.operationID), \(bind: createdRoomID),
                            \(bind: input.title), \(bind: input.deliveryMode.rawValue), 'staged',
                            \(bind: input.memberCount), ARRAY[]::uuid[], \(bind: now))
                    """).run()
            }
            return .created(try input.group(roomID: roomID, createdAt: now))
        }
    }
}

public enum V2GroupMessagingStoreError: Error, Equatable, Sendable {
    case corruptPersistenceState
}

private enum GroupCreationAudience: Sendable {
    case inline(requestedMembers: [UUID], materializedMembers: [UserID])
    case staged

    var kind: String {
        switch self {
        case .inline: "inline"
        case .staged: "staged"
        }
    }
}

private struct GroupCreationInput: Sendable {
    let actorUserID: UserID
    let actorID: UUID
    let operationID: UUID
    let title: String
    let deliveryMode: V2GroupDeliveryMode
    let memberCount: Int
    let audience: GroupCreationAudience

    func group(roomID: RoomID, createdAt: Date) throws -> V2GroupRoom {
        let materializedMembers: [UserID]
        switch audience {
        case .inline(_, let members): materializedMembers = members
        case .staged: materializedMembers = [actorUserID]
        }
        return .init(
            roomID: roomID,
            ownerUserID: actorUserID,
            title: title,
            deliveryMode: deliveryMode,
            memberUserIDs: materializedMembers,
            memberCount: memberCount,
            createdAt: createdAt
        )
    }
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
            lease: .init(
                id: .init(leaseID.uuidString),
                generation: try groupUnsigned(generation),
                validUntil: validUntil,
                commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed),
                fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed),
                maxOutstandingFanoutUnits: maxOutstandingFanoutUnits,
                maxOutstandingPlans: maxOutstandingPlans
            ),
            outstandingFanoutUnits: outstandingFanoutUnits,
            outstandingPlans: outstandingPlans
        )
    }
}

private struct GroupCountRow: Decodable { let value: Int64 }

private struct GroupStagedDraftRow: Decodable {
    let title: String
    let state: String
    let memberCount: Int64
    enum CodingKeys: String, CodingKey {
        case title, state
        case memberCount = "member_count"
    }
}

private struct GroupOperationRow: Decodable {
    let roomID: UUID
    let title: String
    let deliveryMode: V2GroupDeliveryMode
    let audienceKind: String
    let initialMemberCount: Int
    let initialMemberUserIDs: [UUID]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case title
        case deliveryMode = "delivery_mode"
        case audienceKind = "audience_kind"
        case initialMemberCount = "initial_member_count"
        case initialMemberUserIDs = "initial_member_user_ids"
        case createdAt = "created_at"
    }

    func matches(_ input: GroupCreationInput) -> Bool {
        guard title == input.title,
              deliveryMode == input.deliveryMode,
              audienceKind == input.audience.kind,
              initialMemberCount == input.memberCount
        else { return false }
        switch input.audience {
        case .inline(let requestedMembers, _):
            return initialMemberUserIDs == requestedMembers.sorted()
        case .staged:
            return initialMemberUserIDs.isEmpty
        }
    }

    func group(ownerUserID: UserID) throws -> V2GroupRoom {
        guard initialMemberCount > 0 else {
            throw V2GroupMessagingStoreError.corruptPersistenceState
        }
        let materializedMembers: [UserID]
        switch audienceKind {
        case "inline":
            materializedMembers = [ownerUserID] + (try initialMemberUserIDs.map { try UserID($0.uuidString) })
        case "staged":
            guard initialMemberUserIDs.isEmpty else {
                throw V2GroupMessagingStoreError.corruptPersistenceState
            }
            materializedMembers = [ownerUserID]
        default:
            throw V2GroupMessagingStoreError.corruptPersistenceState
        }
        return .init(
            roomID: try .init(roomID.uuidString),
            ownerUserID: ownerUserID,
            title: title,
            deliveryMode: deliveryMode,
            memberUserIDs: materializedMembers,
            memberCount: initialMemberCount,
            createdAt: createdAt
        )
    }
}

private func groupUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2GroupMessagingStoreError.corruptPersistenceState
    }
    return value
}

private func groupUUIDJSON(_ values: [UUID]) throws -> String {
    guard let encoded = String(
        data: try JSONEncoder().encode(values.map(\.uuidString)),
        encoding: .utf8
    ) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return encoded
}

private func groupUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return UInt64(value)
}

private func groupSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2GroupMessagingStoreError.corruptPersistenceState }
    return Int64(value)
}
