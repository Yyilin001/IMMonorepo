import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 群房间创建意图的状态。
public enum V2GroupRoomCreationIntentState: String, Equatable, Sendable {
    /// 已准备，尚未提交归属事务。
    case prepared
    /// 归属事务已提交，路由已确定。
    case committed
}

/// 一次建群操作不可变的控制面身份。
///
/// 生成的标识与归属会在跨库工作开始之前固定；此后只有状态可以从已准备推进到已提交。
public struct V2GroupRoomCreationIntent: Equatable, Sendable {
    /// 发起建群的用户。
    public let actorUserID: UserID
    /// 建群操作标识。
    public let operationID: GroupRoomOperationID
    /// 预分配的房间标识。
    public let roomID: RoomID
    /// 建群事件标识。
    public let eventID: EventID
    /// 逻辑房间分片标识，已去除首尾空白。
    public let roomShardID: String
    /// 路由代次。
    public let routeEpoch: Int64
    /// 请求指纹，需为 32 字节。
    public let requestFingerprint: Data
    /// 受众成员数量，含群主。
    public let audienceMemberCount: Int
    /// 当前状态。
    public let state: V2GroupRoomCreationIntentState

    /// 校验并保存建群意图。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起建群的用户。
    ///   - operationID: 建群操作标识。
    ///   - roomID: 预分配的房间标识。
    ///   - eventID: 建群事件标识。
    ///   - roomShardID: 逻辑分片标识，去除首尾空白后需非空。
    ///   - routeEpoch: 非负的路由代次。
    ///   - requestFingerprint: 请求指纹，需为 32 字节。
    ///   - audienceMemberCount: 受众成员数量，需落在 `1...100000`。
    ///   - state: 初始状态，默认已准备。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    public init(
        actorUserID: UserID,
        operationID: GroupRoomOperationID,
        roomID: RoomID,
        eventID: EventID,

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
        self.roomShardID = shard
        self.routeEpoch = routeEpoch
        self.requestFingerprint = requestFingerprint
        self.audienceMemberCount = audienceMemberCount
        self.state = state
    }

    /// 以同一身份派生指定状态的新意图。
    ///
    /// - Parameter state: 目标状态。
    /// - Returns: 除状态外字段完全一致的意图。
    /// - Throws: 字段校验失败时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    fileprivate func withState(
        _ state: V2GroupRoomCreationIntentState
    ) throws -> Self {
        try .init(
            actorUserID: actorUserID,
            operationID: operationID,
            roomID: roomID,
            eventID: eventID,

            roomShardID: roomShardID,
            routeEpoch: routeEpoch,
            requestFingerprint: requestFingerprint,
            audienceMemberCount: audienceMemberCount,
            state: state
        )
    }
}

/// 准备建群意图的结果。
public enum V2PrepareGroupRoomCreationIntentOutcome: Equatable, Sendable {
    /// 本次调用新准备了意图。
    case prepared(V2GroupRoomCreationIntent)
    case idempotent(V2GroupRoomCreationIntent)
    case idempotencyConflict
    case invalidMembers
}

/// 群房间创建意图的持久化能力。
public protocol V2GroupRoomCreationIntentStore: Sendable {
    /// 以显式成员列表准备建群意图。
    ///
    /// - Parameters:
    ///   - candidate: 候选意图。
    ///   - memberUserIDs: 初始成员列表。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 准备结果。
    /// - Throws: 意图冲突或持久化失败时抛出。
    func prepare(
        _ candidate: V2GroupRoomCreationIntent,
        memberUserIDs: [UserID],
        now: Date
    ) async throws -> V2PrepareGroupRoomCreationIntentOutcome

    /// 以分阶段建群命令准备建群意图。
    ///
    /// - Parameters:
    ///   - candidate: 候选意图。
    ///   - command: 分阶段建群命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 准备结果。
    /// - Throws: 意图冲突或持久化失败时抛出。
    func prepareStaged(
        _ candidate: V2GroupRoomCreationIntent,
        command: V2StagedGroupRoomCommand,
        now: Date
    ) async throws -> V2PrepareGroupRoomCreationIntentOutcome

    /// 读取由 `prepare` 冻结的精确受众。
    ///
    /// 重试或恢复工作器必须使用这份关系，而不是依据之后到达的客户端请求重建成员集合。
    ///
    /// - Parameter intent: 建群意图。
    /// - Returns: 冻结的成员列表。
    /// - Throws: 意图不存在或持久化失败时抛出。
    func memberUserIDs(
        for intent: V2GroupRoomCreationIntent
    ) async throws -> [UserID]

    /// 分页读取冻结的受众成员。
    ///
    /// - Parameters:
    ///   - intent: 建群意图。
    ///   - afterUserID: 上一页最后一位成员；为空表示从头开始。
    ///   - limit: 本页最多返回的成员数。
    /// - Returns: 成员清单分片。
    /// - Throws: 意图不存在或持久化失败时抛出。
    func memberUserIDSlice(
        for intent: V2GroupRoomCreationIntent,
        afterUserID: UserID?,
        limit: Int
    ) async throws -> V2GroupRoomCreationManifestSlice

    /// 仅在归属事务提交之后记录规范房间路由。
    ///
    /// 以同一不可变意图重复调用是安全的；若路由冲突则视为持久化的拓扑错误。
    ///
    /// - Parameters:
    ///   - intent: 建群意图。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 已提交的意图。
    /// - Throws: 路由冲突时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/routeConflict``；其余失败抛出
    ///   ``V2GroupRoomCreationIntentStoreError/corruptPersistenceState``。
    func finalizeCommitted(
        _ intent: V2GroupRoomCreationIntent,
        now: Date
    ) async throws -> V2GroupRoomCreationIntent
}

/// 建群意图存储错误。
public enum V2GroupRoomCreationIntentStoreError: Error, Equatable, Sendable {
    /// 意图字段不满足约束。
    case invalidIntent
    /// 房间路由与既有记录冲突。
    case routeConflict
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 基于 PostgreSQL 的建群意图存储。
public struct PostgresV2GroupRoomCreationIntentStore:
    V2GroupRoomCreationIntentStore
{
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放建群意图与冻结受众的数据库。
    public init(database: any Database) { self.database = database }

    /// 以显式成员列表准备建群意图。
    ///
    /// 同一操作标识与相同请求指纹会返回已有的意图，指纹不同则判定冲突。
    ///
    /// - Parameters:
    ///   - candidate: 候选意图。
    ///   - memberUserIDs: 初始成员列表。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 准备结果。
    /// - Throws: 意图不合法时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``；指纹冲突时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/routeConflict``；持久化异常时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/corruptPersistenceState``。
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
                    (actor_user_id, operation_id, room_id, event_id,
                     room_shard_id, route_epoch, request_fingerprint,
                     audience_member_count, state, created_at, updated_at)
                VALUES (
                    \(bind: values.actorUserID), \(bind: values.operationID),
                    \(bind: values.roomID), \(bind: values.eventID),
                    \(bind: candidate.roomShardID),
                    \(bind: candidate.routeEpoch),
                    \(bind: candidate.requestFingerprint),
                    \(bind: candidate.audienceMemberCount), 'prepared',
                    \(bind: now), \(bind: now)
                )
                ON CONFLICT DO NOTHING
                RETURNING actor_user_id, operation_id, room_id, event_id,
                          room_shard_id, route_epoch,
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

    /// 以分阶段建群命令准备建群意图，并冻结受众草稿关系。
    ///
    /// - Parameters:
    ///   - candidate: 候选意图。
    ///   - command: 分阶段建群命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 准备结果。
    /// - Throws: 与 ``prepare(_:memberUserIDs:now:)`` 相同的错误。
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
                    (actor_user_id, operation_id, room_id, event_id,
                     room_shard_id, route_epoch, request_fingerprint,
                     audience_member_count, state, created_at, updated_at)
                VALUES (
                    \(bind: values.actorUserID), \(bind: values.operationID),
                    \(bind: values.roomID), \(bind: values.eventID),
                    \(bind: candidate.roomShardID),
                    \(bind: candidate.routeEpoch),
                    \(bind: candidate.requestFingerprint),
                    \(bind: candidate.audienceMemberCount), 'prepared',
                    \(bind: now), \(bind: now)
                )
                ON CONFLICT DO NOTHING
                RETURNING actor_user_id, operation_id, room_id, event_id,
                          room_shard_id, route_epoch,
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

    /// 记录规范房间路由并推进意图状态。
    ///
    /// 只有归属事务提交之后才应调用；重复调用返回已提交意图，路由冲突则判定为拓扑错误。
    ///
    /// - Parameters:
    ///   - intent: 建群意图。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 已提交的意图。
    /// - Throws: 路由冲突时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/routeConflict``；其余失败抛出
    ///   ``V2GroupRoomCreationIntentStoreError/corruptPersistenceState``。
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
                SELECT actor_user_id, operation_id, room_id, event_id,
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

    /// 读取冻结的受众成员列表。
    ///
    /// - Parameter intent: 建群意图。
    /// - Returns: 冻结的成员列表。
    /// - Throws: 意图不存在或持久化失败时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/corruptPersistenceState``。
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

    /// 分页读取冻结的受众成员。
    ///
    /// - Parameters:
    ///   - intent: 建群意图。
    ///   - afterUserID: 上一页最后一位成员；为空表示从头开始。
    ///   - limit: 本页最多返回的成员数。
    /// - Returns: 成员清单分片。
    /// - Throws: 意图不存在、分页参数非法或持久化失败时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/corruptPersistenceState``。
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

    init(_ intent: V2GroupRoomCreationIntent) throws {
        guard let actorUserID = UUID(uuidString: intent.actorUserID.rawValue),
              let operationID = UUID(uuidString: intent.operationID.rawValue),
              let roomID = UUID(uuidString: intent.roomID.rawValue),
              let eventID = UUID(uuidString: intent.eventID.rawValue)
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.roomID = roomID
        self.eventID = eventID
    }
}

private struct IntentRow: Decodable {
    let actorUserID: UUID
    let operationID: UUID
    let roomID: UUID
    let eventID: UUID
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
        SELECT actor_user_id, operation_id, room_id, event_id,
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
