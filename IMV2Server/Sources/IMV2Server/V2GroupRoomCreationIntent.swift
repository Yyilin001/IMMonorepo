import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2GroupRoomCreationIntentState: String, Equatable, Sendable {
    case prepared
    case committed
}

/// Immutable control-plane identity for one group-creation operation. The
/// generated IDs and owner are fixed before cross-database work starts; only
/// `state` may advance from prepared to committed.
public struct V2GroupRoomCreationIntent: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: GroupRoomOperationID
    public let roomID: RoomID
    public let eventID: EventID
    public let planID: FanoutPlanID
    public let roomShardID: String
    public let routeEpoch: Int64
    public let requestFingerprint: Data
    public let audienceMemberCount: Int
    public let state: V2GroupRoomCreationIntentState

    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        roomShardID: String,
        routeEpoch: Int64,
        requestFingerprint: Data,
        audienceMemberCount: Int,
        state: V2GroupRoomCreationIntentState = .prepared
    ) throws {
        let shard = roomShardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shard.isEmpty, routeEpoch >= 0, requestFingerprint.count == 32,
              (1 ... 100_000).contains(audienceMemberCount)
        else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.roomID = roomID
        self.eventID = eventID
        self.planID = planID
        self.roomShardID = shard
        self.routeEpoch = routeEpoch
        self.requestFingerprint = requestFingerprint
        self.audienceMemberCount = audienceMemberCount
        self.state = state
    }

    fileprivate func withState(
        _ state: V2GroupRoomCreationIntentState
    ) throws -> Self {
        try .init(
            actorUserID: actorUserID,
            operationID: operationID,
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            roomShardID: roomShardID,
            routeEpoch: routeEpoch,
            requestFingerprint: requestFingerprint,
            audienceMemberCount: audienceMemberCount,
            state: state
        )
    }
}

public enum V2PrepareGroupRoomCreationIntentOutcome: Equatable, Sendable {
    case prepared(V2GroupRoomCreationIntent)
    case idempotent(V2GroupRoomCreationIntent)
    case idempotencyConflict
    case invalidMembers
}

public protocol V2GroupRoomCreationIntentStore: Sendable {
    func prepare(
        _ candidate: V2GroupRoomCreationIntent,
        memberUserIDs: [UserID],
        now: Date
    ) async throws -> V2PrepareGroupRoomCreationIntentOutcome

    func prepareStaged(
        _ candidate: V2GroupRoomCreationIntent,
        command: V2StagedGroupRoomCommand,
        now: Date
    ) async throws -> V2PrepareGroupRoomCreationIntentOutcome

    /// Reads the exact audience frozen by `prepare`. A retry or recovery
    /// worker must use this relation rather than reconstructing membership
    /// from a later client request.
    func memberUserIDs(
        for intent: V2GroupRoomCreationIntent
    ) async throws -> [UserID]

    func memberUserIDSlice(
        for intent: V2GroupRoomCreationIntent,
        afterUserID: UserID?,
        limit: Int
    ) async throws -> V2GroupRoomCreationManifestSlice

    /// Records the canonical room route only after the owner transaction has
    /// committed. Repeating this operation with the same immutable intent is
    /// safe; a conflicting route is a durable topology error.
    func finalizeCommitted(
        _ intent: V2GroupRoomCreationIntent,
        now: Date
    ) async throws -> V2GroupRoomCreationIntent
}

public enum V2GroupRoomCreationIntentStoreError: Error, Equatable, Sendable {
    case invalidIntent
    case routeConflict
    case corruptPersistenceState
}

public struct PostgresV2GroupRoomCreationIntentStore:
    V2GroupRoomCreationIntentStore
{
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func prepare(
        _ candidate: V2GroupRoomCreationIntent,
        memberUserIDs: [UserID],
        now: Date
    ) async throws -> V2PrepareGroupRoomCreationIntentOutcome {
        guard v2PostgresTimestampCanEncode(now) else { throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState }
        guard candidate.state == .prepared else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        let canonicalMembers = memberUserIDs.sorted()
        guard canonicalMembers.count == candidate.audienceMemberCount,
              Set(canonicalMembers).count == canonicalMembers.count,
              canonicalMembers.contains(candidate.actorUserID)
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        let values = try IntentValues(candidate)
        let encodedMembers = try intentUUIDJSON(canonicalMembers)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
            }
            let operationLockKey = values.actorUserID.uuidString
                + ":" + values.operationID.uuidString
            try await sql.raw("""
                SELECT pg_advisory_xact_lock(
                    hashtextextended(\(bind: operationLockKey), 0)
                )
                """).run()

            if let existing = try await persistedIntent(
                actorUserID: values.actorUserID,
                operationID: values.operationID,
                sql: sql
            ) {
                let intent = try existing.intent()
                guard intent.requestFingerprint == candidate.requestFingerprint else {
                    return .idempotencyConflict
                }
                guard try await persistedAudienceCount(
                    actorUserID: values.actorUserID,
                    operationID: values.operationID,
                    sql: sql
                ) == intent.audienceMemberCount
                else {
                    throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
                }
                return .idempotent(intent)
            }

            // This snapshot is the command's global-identity linearization
            // point. Disabled/inactive users never enter the durable manifest;
            // retries reuse the exact already-validated set rather than
            // trusting another client payload or an owner-local stale cache.
            let activeMemberCount = try await sql.raw("""
                WITH requested AS (
                    SELECT value::uuid AS user_id
                    FROM jsonb_array_elements_text(
                        \(bind: encodedMembers)::jsonb
                    ) AS value
                )
                SELECT COUNT(*)::bigint AS value
                FROM requested
                INNER JOIN im_v2.public_user_profiles AS profile
                  ON profile.user_id = requested.user_id
                 AND profile.state = 'active'
                LEFT JOIN im_v2.account_disables AS disabled
                  ON disabled.user_id = requested.user_id
                WHERE disabled.user_id IS NULL
                """).first(decoding: IntentCountRow.self)?.value ?? -1
            guard activeMemberCount == Int64(candidate.audienceMemberCount) else {
                return .invalidMembers
            }

            guard let inserted = try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_intents
                    (actor_user_id, operation_id, room_id, event_id, plan_id,
                     room_shard_id, route_epoch, request_fingerprint,
                     audience_member_count, state, created_at, updated_at)
                VALUES (
                    \(bind: values.actorUserID), \(bind: values.operationID),
                    \(bind: values.roomID), \(bind: values.eventID),
                    \(bind: values.planID), \(bind: candidate.roomShardID),
                    \(bind: candidate.routeEpoch),
                    \(bind: candidate.requestFingerprint),
                    \(bind: candidate.audienceMemberCount), 'prepared',
                    \(bind: now), \(bind: now)
                )
                ON CONFLICT DO NOTHING
                RETURNING actor_user_id, operation_id, room_id, event_id,
                          plan_id, room_shard_id, route_epoch,
                          request_fingerprint, audience_member_count, state
                """).first(decoding: IntentRow.self) else {
                // The operation key is advisory-locked. A missing returned
                // row therefore means a generated-ID uniqueness collision
                // with another operation, not an ordinary retry.
                throw V2GroupRoomCreationIntentStoreError.routeConflict
            }
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_intent_members
                    (actor_user_id, operation_id, user_id, created_at)
                SELECT \(bind: values.actorUserID),
                       \(bind: values.operationID), value::uuid, \(bind: now)
                FROM jsonb_array_elements_text(
                    \(bind: encodedMembers)::jsonb
                ) AS value
                """).run()
            return .prepared(try inserted.intent())
        }
    }

    public func prepareStaged(
        _ candidate: V2GroupRoomCreationIntent,
        command: V2StagedGroupRoomCommand,
        now: Date
    ) async throws -> V2PrepareGroupRoomCreationIntentOutcome {
        guard v2PostgresTimestampCanEncode(now) else { throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState }
        guard candidate.state == .prepared,
              candidate.actorUserID == command.actorUserID,
              candidate.operationID == command.operationID,
              candidate.audienceMemberCount == command.allMemberCount
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        let values = try IntentValues(candidate)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
            }
            let operationLockKey = values.actorUserID.uuidString
                + ":" + values.operationID.uuidString
            try await sql.raw("""
                SELECT pg_advisory_xact_lock(
                    hashtextextended(\(bind: operationLockKey), 0)
                )
                """).run()
            if let existing = try await persistedIntent(
                actorUserID: values.actorUserID,
                operationID: values.operationID,
                sql: sql
            ) {
                let intent = try existing.intent()
                guard intent.requestFingerprint == candidate.requestFingerprint else {
                    return .idempotencyConflict
                }
                guard try await persistedAudienceCount(
                    actorUserID: values.actorUserID,
                    operationID: values.operationID,
                    sql: sql
                ) == intent.audienceMemberCount
                else {
                    throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
                }
                return .idempotent(intent)
            }

            guard let draft = try await sql.raw("""
                SELECT title, state,
                       (SELECT COUNT(*)::bigint
                        FROM im_v2.group_room_creation_draft_members AS member
                        WHERE member.actor_user_id = draft.actor_user_id
                          AND member.operation_id = draft.operation_id
                       ) AS member_count
                FROM im_v2.group_room_creation_drafts AS draft
                WHERE actor_user_id = \(bind: values.actorUserID)
                  AND operation_id = \(bind: values.operationID)
                FOR SHARE
                """).first(decoding: IntentDraftRow.self),
                  draft.state == "finalizing",
                  draft.title == command.title,
                  draft.memberCount == Int64(command.stagedMemberCount)
            else { return .idempotencyConflict }

            let activeMemberCount = try await sql.raw("""
                WITH requested AS (
                    SELECT \(bind: values.actorUserID) AS user_id
                    UNION ALL
                    SELECT member.user_id
                    FROM im_v2.group_room_creation_draft_members AS member
                    WHERE member.actor_user_id = \(bind: values.actorUserID)
                      AND member.operation_id = \(bind: values.operationID)
                )
                SELECT COUNT(*)::bigint AS value
                FROM requested
                INNER JOIN im_v2.public_user_profiles AS profile
                  ON profile.user_id = requested.user_id
                 AND profile.state = 'active'
                LEFT JOIN im_v2.account_disables AS disabled
                  ON disabled.user_id = requested.user_id
                WHERE disabled.user_id IS NULL
                """).first(decoding: IntentCountRow.self)?.value ?? -1
            guard activeMemberCount == Int64(candidate.audienceMemberCount) else {
                return .invalidMembers
            }

            guard let inserted = try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_intents
                    (actor_user_id, operation_id, room_id, event_id, plan_id,
                     room_shard_id, route_epoch, request_fingerprint,
                     audience_member_count, state, created_at, updated_at)
                VALUES (
                    \(bind: values.actorUserID), \(bind: values.operationID),
                    \(bind: values.roomID), \(bind: values.eventID),
                    \(bind: values.planID), \(bind: candidate.roomShardID),
                    \(bind: candidate.routeEpoch),
                    \(bind: candidate.requestFingerprint),
                    \(bind: candidate.audienceMemberCount), 'prepared',
                    \(bind: now), \(bind: now)
                )
                ON CONFLICT DO NOTHING
                RETURNING actor_user_id, operation_id, room_id, event_id,
                          plan_id, room_shard_id, route_epoch,
                          request_fingerprint, audience_member_count, state
                """).first(decoding: IntentRow.self) else {
                throw V2GroupRoomCreationIntentStoreError.routeConflict
            }
            try await sql.raw("""
                INSERT INTO im_v2.group_room_creation_intent_members
                    (actor_user_id, operation_id, user_id, created_at)
                SELECT \(bind: values.actorUserID),
                       \(bind: values.operationID), requested.user_id,
                       \(bind: now)
                FROM (
                    SELECT \(bind: values.actorUserID) AS user_id
                    UNION ALL
                    SELECT member.user_id
                    FROM im_v2.group_room_creation_draft_members AS member
                    WHERE member.actor_user_id = \(bind: values.actorUserID)
                      AND member.operation_id = \(bind: values.operationID)
                ) AS requested
                """).run()
            return .prepared(try inserted.intent())
        }
    }

    public func finalizeCommitted(
        _ intent: V2GroupRoomCreationIntent,
        now: Date
    ) async throws -> V2GroupRoomCreationIntent {
        guard v2PostgresTimestampCanEncode(now) else { throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState }
        let expected = try IntentValues(intent)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
            }
            guard let persistedRow = try await sql.raw("""
                SELECT actor_user_id, operation_id, room_id, event_id, plan_id,
                       room_shard_id, route_epoch, request_fingerprint,
                       audience_member_count, state
                FROM im_v2.group_room_creation_intents
                WHERE actor_user_id = \(bind: expected.actorUserID)
                  AND operation_id = \(bind: expected.operationID)
                FOR UPDATE
                """).first(decoding: IntentRow.self) else {
                throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
            }
            let persisted = try persistedRow.intent()
            guard persisted.actorUserID == intent.actorUserID,
                  persisted.operationID == intent.operationID,
                  persisted.roomID == intent.roomID,
                  persisted.eventID == intent.eventID,
                  persisted.planID == intent.planID,
                  persisted.roomShardID == intent.roomShardID,
                  persisted.routeEpoch == intent.routeEpoch,
                  persisted.requestFingerprint == intent.requestFingerprint,
                  persisted.audienceMemberCount == intent.audienceMemberCount
            else { throw V2GroupRoomCreationIntentStoreError.routeConflict }

            if let route = try await sql.raw("""
                SELECT room_shard_id, route_epoch
                FROM im_v2.room_owner_routes
                WHERE room_id = \(bind: expected.roomID)
                FOR UPDATE
                """).first(decoding: PersistedRouteRow.self) {
                guard route.roomShardID == intent.roomShardID,
                      route.routeEpoch == intent.routeEpoch
                else { throw V2GroupRoomCreationIntentStoreError.routeConflict }
            } else {
                try await sql.raw("""
                    INSERT INTO im_v2.room_owner_routes
                        (room_id, room_shard_id, route_epoch, created_at, updated_at)
                    VALUES (
                        \(bind: expected.roomID), \(bind: intent.roomShardID),
                        \(bind: intent.routeEpoch), \(bind: now), \(bind: now)
                    )
                    """).run()
            }
            if persisted.state != .committed {
                try await sql.raw("""
                    UPDATE im_v2.group_room_creation_intents
                    SET state = 'committed', updated_at = \(bind: now)
                    WHERE actor_user_id = \(bind: expected.actorUserID)
                      AND operation_id = \(bind: expected.operationID)
                    """).run()
            }
            return try persisted.withState(.committed)
        }
    }

    public func memberUserIDs(
        for intent: V2GroupRoomCreationIntent
    ) async throws -> [UserID] {
        guard let sql = database as? any SQLDatabase else {
            throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
        }
        let values = try IntentValues(intent)
        let rows = try await sql.raw("""
            SELECT user_id
            FROM im_v2.group_room_creation_intent_members
            WHERE actor_user_id = \(bind: values.actorUserID)
              AND operation_id = \(bind: values.operationID)
            ORDER BY user_id
            """).all(decoding: IntentMemberRow.self)
        guard rows.count == intent.audienceMemberCount else {
            throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
        }
        return try rows.map { try UserID($0.userID.uuidString) }
    }

    public func memberUserIDSlice(
        for intent: V2GroupRoomCreationIntent,
        afterUserID: UserID?,
        limit: Int
    ) async throws -> V2GroupRoomCreationManifestSlice {
        guard (1 ... V2GroupRoomCreationManifestPage.maximumMemberCount)
            .contains(limit),
              let sql = database as? any SQLDatabase
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        let values = try IntentValues(intent)
        let rows: [IntentMemberRow]
        if let afterUserID {
            guard let afterUUID = afterUserID.uuidValue else {
                throw V2GroupRoomCreationIntentStoreError.invalidIntent
            }
            rows = try await sql.raw("""
                SELECT user_id
                FROM im_v2.group_room_creation_intent_members
                WHERE actor_user_id = \(bind: values.actorUserID)
                  AND operation_id = \(bind: values.operationID)
                  AND user_id > \(bind: afterUUID)
                ORDER BY user_id
                LIMIT \(bind: limit + 1)
                """).all(decoding: IntentMemberRow.self)
        } else {
            rows = try await sql.raw("""
                SELECT user_id
                FROM im_v2.group_room_creation_intent_members
                WHERE actor_user_id = \(bind: values.actorUserID)
                  AND operation_id = \(bind: values.operationID)
                ORDER BY user_id
                LIMIT \(bind: limit + 1)
                """).all(decoding: IntentMemberRow.self)
        }
        let hasMore = rows.count > limit
        let selected = hasMore ? Array(rows.prefix(limit)) : rows
        return .init(
            memberUserIDs: try selected.map { try UserID($0.userID.uuidString) },
            hasMore: hasMore
        )
    }
}

private struct IntentValues {
    let actorUserID: UUID
    let operationID: UUID
    let roomID: UUID
    let eventID: UUID
    let planID: UUID

    init(_ intent: V2GroupRoomCreationIntent) throws {
        guard let actorUserID = UUID(uuidString: intent.actorUserID.rawValue),
              let operationID = UUID(uuidString: intent.operationID.rawValue),
              let roomID = UUID(uuidString: intent.roomID.rawValue),
              let eventID = UUID(uuidString: intent.eventID.rawValue),
              let planID = UUID(uuidString: intent.planID.rawValue)
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.roomID = roomID
        self.eventID = eventID
        self.planID = planID
    }
}

private struct IntentRow: Decodable {
    let actorUserID: UUID
    let operationID: UUID
    let roomID: UUID
    let eventID: UUID
    let planID: UUID
    let roomShardID: String
    let routeEpoch: Int64
    let requestFingerprint: Data
    let audienceMemberCount: Int
    let state: String

    enum CodingKeys: String, CodingKey {
        case actorUserID = "actor_user_id"
        case operationID = "operation_id"
        case roomID = "room_id"
        case eventID = "event_id"
        case planID = "plan_id"
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
        case requestFingerprint = "request_fingerprint"
        case audienceMemberCount = "audience_member_count"
        case state
    }

    func intent() throws -> V2GroupRoomCreationIntent {
        guard let state = V2GroupRoomCreationIntentState(rawValue: state) else {
            throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
        }
        return try .init(
            actorUserID: .init(actorUserID.uuidString),
            operationID: .init(operationID.uuidString),
            roomID: .init(roomID.uuidString),
            eventID: .init(eventID.uuidString),
            planID: .init(planID.uuidString),
            roomShardID: roomShardID,
            routeEpoch: routeEpoch,
            requestFingerprint: requestFingerprint,
            audienceMemberCount: audienceMemberCount,
            state: state
        )
    }
}

private struct IntentCountRow: Decodable { let value: Int64 }
private struct IntentDraftRow: Decodable {
    let title: String
    let state: String
    let memberCount: Int64
    enum CodingKeys: String, CodingKey {
        case title, state
        case memberCount = "member_count"
    }
}
private struct IntentMemberRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}

private func persistedIntent(
    actorUserID: UUID,
    operationID: UUID,
    sql: any SQLDatabase
) async throws -> IntentRow? {
    try await sql.raw("""
        SELECT actor_user_id, operation_id, room_id, event_id, plan_id,
               room_shard_id, route_epoch, request_fingerprint,
               audience_member_count, state
        FROM im_v2.group_room_creation_intents
        WHERE actor_user_id = \(bind: actorUserID)
          AND operation_id = \(bind: operationID)
        """).first(decoding: IntentRow.self)
}

private func persistedAudienceCount(
    actorUserID: UUID,
    operationID: UUID,
    sql: any SQLDatabase
) async throws -> Int {
    let count = try await sql.raw("""
        SELECT COUNT(*)::bigint AS value
        FROM im_v2.group_room_creation_intent_members
        WHERE actor_user_id = \(bind: actorUserID)
          AND operation_id = \(bind: operationID)
        """).first(decoding: IntentCountRow.self)?.value ?? -1
    guard count >= 0, count <= Int64(Int.max) else {
        throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState
    }
    return Int(count)
}

private func intentUUIDJSON(_ userIDs: [UserID]) throws -> String {
    let values = try userIDs.map { userID -> String in
        guard let value = UUID(uuidString: userID.rawValue) else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        return value.uuidString
    }
    guard let encoded = String(
        data: try JSONEncoder().encode(values),
        encoding: .utf8
    ) else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
    return encoded
}

private struct PersistedRouteRow: Decodable {
    let roomShardID: String
    let routeEpoch: Int64

    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id"
        case routeEpoch = "route_epoch"
    }
}
