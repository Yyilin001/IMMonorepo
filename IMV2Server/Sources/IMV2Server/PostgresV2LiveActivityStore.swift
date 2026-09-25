import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 在线状态活动的配置错误分类。
public enum V2LiveActivityConfigurationError: Error, Equatable, Sendable {
    /// 在线租约时长非法：必须为正，且可被编码为 PostgreSQL 时间。
    case invalidOnlineLease
}

/// 在线状态、输入状态与连接租约的 PostgreSQL 持久化实现。
///
/// 隐私偏好、围观授权与连接租约都通过同一批咨询锁串行化，
/// 使同一用户/设备的竞争不会形成锁序环。
public struct PostgresV2LiveActivityStore: V2LiveActivityStore {
    private let database: any Database
    private let onlineLease: TimeInterval

    /// 创建在线状态存储。
    ///
    /// - Parameters:
    ///   - database: 控制面数据库连接。
    ///   - onlineLease: 在线租约时长，必须为正且可编码。
    /// - Throws: 租约时长非法时抛出 `invalidOnlineLease`。
    public init(database: any Database, onlineLease: TimeInterval = 90) throws {
        guard onlineLease > 0, Int64(exactly: (onlineLease * 1_000_000).rounded(.up)) != nil else {
            throw V2LiveActivityConfigurationError.invalidOnlineLease
        }
        self.database = database
        self.onlineLease = onlineLease
    }

    /// 设置用户的实时活动隐私偏好。
    ///
    /// 以操作台账保证幂等：相同操作标识的相同载荷返回幂等结果，
    /// 载荷不同则返回冲突。
    ///
    /// - Parameters:
    ///   - command: 偏好设置命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 偏好设置结果。
    /// - Throws: 时间戳非法或持久化失败时抛出。
    public func setPreferences(command: V2SetLiveActivityPreferencesCommand, now: Date) async throws -> V2SetLiveActivityPreferencesOutcome {
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let actor = try liveActivityUUID(command.actorUserID), operation = try liveActivityUUID(command.operationID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: actor.uuidString + ":" + operation.uuidString), 0))").run()
            if let prior = try await sql.raw("SELECT allows_online_presence, allows_typing_indicators, updated_at FROM im_v2.user_live_activity_preference_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding: LiveActivityPreferenceRow.self) {
                guard prior.allowsOnlinePresence == command.allowsOnlinePresence, prior.allowsTypingIndicators == command.allowsTypingIndicators else { return .idempotencyConflict }
                return .idempotent(try prior.validatedPreferences())
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2LiveActivityStoreError.corruptPersistenceState }
            try await sql.raw("INSERT INTO im_v2.user_live_activity_preferences (user_id, allows_online_presence, allows_typing_indicators, updated_at) VALUES (\(bind: actor), \(bind: command.allowsOnlinePresence), \(bind: command.allowsTypingIndicators), \(bind: now)) ON CONFLICT (user_id) DO UPDATE SET allows_online_presence = EXCLUDED.allows_online_presence, allows_typing_indicators = EXCLUDED.allows_typing_indicators, updated_at = EXCLUDED.updated_at").run()
            guard let persisted = try await sql.raw("INSERT INTO im_v2.user_live_activity_preference_operations (actor_user_id, operation_id, allows_online_presence, allows_typing_indicators, updated_at) VALUES (\(bind: actor), \(bind: operation), \(bind: command.allowsOnlinePresence), \(bind: command.allowsTypingIndicators), \(bind: now)) RETURNING allows_online_presence, allows_typing_indicators, updated_at").first(decoding: LiveActivityPreferenceRow.self) else { throw V2LiveActivityStoreError.corruptPersistenceState }
            return .updated(try persisted.validatedPreferences())
        }
    }

    /// 读取用户的实时活动隐私偏好。
    ///
    /// 无持久记录时返回全开启的默认偏好，并使用传入的 `now` 作为更新时间。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - now: 无记录时的默认更新时间。
    /// - Returns: 该用户的隐私偏好。
    /// - Throws: 时间戳无法编码或持久化状态损坏时抛出。
    public func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences {
        guard let sql = database as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let user = try liveActivityUUID(userID)
        let preference = try await sql.raw("SELECT allows_online_presence, allows_typing_indicators, updated_at FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: user)").first(decoding: LiveActivityPreferenceRow.self)
        if let preference { return try preference.validatedPreferences() }
        guard v2PostgresTimestampCanEncode(now) else { throw V2LiveActivityStoreError.corruptPersistenceState }
        return .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: now)
    }

    /// 读取单聊房间中对方的在线状态。
    ///
    /// 结果同时受对方在线偏好、当前有效租约与双方拉黑关系约束；
    /// 任一不满足时都会返回离线的安全结果。
    ///
    /// - Parameters:
    ///   - roomID: 目标单聊房间。
    ///   - viewerUserID: 发起查询的成员。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 目标用户的在线状态。
    /// - Throws: 非单聊房间、非成员或已拉黑时抛出。
    public func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState {
        guard v2PostgresTimestampCanEncode(now) else { throw V2LiveActivityStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let room = try liveActivityUUID(roomID), viewer = try liveActivityUUID(viewerUserID)
            guard let peer = try await sql.raw("SELECT CASE WHEN lower_user_id = \(bind: viewer) THEN higher_user_id ELSE lower_user_id END AS user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: room) AND (lower_user_id = \(bind: viewer) OR higher_user_id = \(bind: viewer))").first(decoding: LiveActivityUserRow.self) else { throw V2LiveActivityStoreError.notDirectRoom }
            guard try await activeMember(room: room, user: viewer, sql: sql) else { throw V2LiveActivityStoreError.actorNotMember }
            guard !(try await usersAreBlocked(viewer, peer.userID, sql: sql)) else { throw V2LiveActivityStoreError.interactionBlocked }
            let preference = try await sql.raw("SELECT allows_online_presence FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: peer.userID)").first(decoding: LiveActivityOnlinePreferenceRow.self)?.allowsOnlinePresence ?? true
            let expiry = try await sql.raw("SELECT MAX(expires_at) AS expires_at FROM im_v2.user_live_presence_leases WHERE user_id = \(bind: peer.userID) AND expires_at > \(bind: now)").first(decoding: LiveActivityExpiryRow.self)?.expiresAt
            let responseExpiry = preference ? (expiry ?? now) : now
            guard v2PostgresTimestampCanEncode(responseExpiry) else { throw V2LiveActivityStoreError.corruptPersistenceState }
            return try .init(roomID: roomID, targetUserID: .init(peer.userID.uuidString), isOnline: preference && expiry != nil, expiresAt: responseExpiry)
        }
    }

    /// 校验发起者可以在该房间内发送输入状态。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起输入状态的成员。
    ///   - now: 服务端统一授时时刻（当前实现不使用）。
    /// - Throws: 非成员、已拉黑或关闭了输入状态偏好时抛出。
    public func authorizeTyping(roomID: RoomID, actorUserID: UserID, now _: Date) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let room = try liveActivityUUID(roomID), actor = try liveActivityUUID(actorUserID)
            guard try await activeMember(room: room, user: actor, sql: sql) else { throw V2LiveActivityStoreError.actorNotMember }
            if let peer = try await directPeer(room: room, user: actor, sql: sql) {
                guard !(try await usersAreBlocked(actor, peer, sql: sql)) else { throw V2LiveActivityStoreError.interactionBlocked }
            }
            let allowed = try await sql.raw("SELECT allows_typing_indicators FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: actor)").first(decoding: LiveActivityTypingPreferenceRow.self)?.allowsTypingIndicators ?? true
            guard allowed else { throw V2LiveActivityStoreError.typingNotAllowed }
        }
    }

    /// 校验观察者可以订阅某成员的在线活动。
    ///
    /// 在被观察者确实是该单聊房间内的对端且双方未拉黑时才放行。
    ///
    /// - Parameters:
    ///   - roomID: 目标单聊房间。
    ///   - viewerUserID: 发起订阅的成员。
    ///   - subjectUserID: 被观察的成员。
    ///   - now: 服务端统一授时时刻（当前实现不使用）。
    /// - Throws: 非成员、目标不匹配或已拉黑时抛出。
    public func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now _: Date) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let room = try liveActivityUUID(roomID)
            let viewer = try liveActivityUUID(viewerUserID)
            let subject = try liveActivityUUID(subjectUserID)
            guard try await activeMember(room: room, user: viewer, sql: sql) else { throw V2LiveActivityStoreError.actorNotMember }
            guard let peer = try await directPeer(room: room, user: viewer, sql: sql) else { return }
            guard peer == subject else { throw V2LiveActivityStoreError.actorNotMember }
            guard !(try await usersAreBlocked(viewer, subject, sql: sql)) else { throw V2LiveActivityStoreError.interactionBlocked }
        }
    }

    /// 判断用户是否允许展示在线状态。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 是否允许展示；无持久记录时视为允许。
    /// - Throws: 持久化状态损坏时抛出。
    public func allowsOnlinePresence(userID: UserID) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let user = try liveActivityUUID(userID)
        return try await sql.raw("SELECT allows_online_presence FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: user)").first(decoding: LiveActivityOnlinePreferenceRow.self)?.allowsOnlinePresence ?? true
    }

    private func validatedLeaseExpiry(now: Date) throws -> Date {
        let expiry = now.addingTimeInterval(onlineLease)
        // 线路协议截断会把负的 Unix 时间戳向未来方向移动，
        // 因此无法证明持久化租约间隔在编码后仍得到保留。
        guard v2PostgresTimestampPrecedes(now, expiry),
              let milliseconds = try? v2GatewayMilliseconds(expiry),
              Double(milliseconds) > now.timeIntervalSince1970 * 1_000 else {
            throw V2LiveActivityStoreError.corruptPersistenceState
        }
        return expiry
    }

    /// 接纳一条新连接，并按用户/设备上限裁决。
    ///
    /// 同一用户的竞争者先取同一把用户锁，再取设备锁，
    /// 从而把更窄的上限串行化而不形成用户/设备锁序环。
    /// 已过期的租约会先被清理；被拒绝时返回 `.rejected` 而不写入任何行。
    ///
    /// - Parameters:
    ///   - identity: 已认证的连接身份。
    ///   - connectionID: 本次连接标识。
    ///   - policy: 连接准入策略。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 租约接纳结果。
    /// - Throws: 租约时间无法编码或持久化状态损坏时抛出。
    public func admitConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        policy: V2AuthenticatedConnectionAdmissionPolicy,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome {
        let expiry = try validatedLeaseExpiry(now: now)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2LiveActivityStoreError.corruptPersistenceState
            }
            let user = try liveActivityUUID(identity.userID)
            let device = try liveActivityUUID(identity.deviceID)
            // 同一用户的所有竞争者都先取得同一把锁；
            // 设备锁再串行化更窄的限制，避免用户锁与设备锁形成顺序循环。
            try await lockConnectionIdentity(user: user, device: device, sql: sql)
            // `auth_devices.device_id` 全局唯一，租约又有复合所有者外键，
            // 因此此设备只能属于 `user`。查询条件只限定用户，
            // 使 PostgreSQL 可使用既有的 `(user_id, expires_at)` 索引。
            try await sql.raw("""
                DELETE FROM im_v2.user_live_presence_leases
                WHERE expires_at <= \(bind: now)
                  AND user_id = \(bind: user)
                """).run()
            guard let counts = try await sql.raw("""
                SELECT COUNT(*) FILTER (WHERE device_id = \(bind: device))::integer AS device_count,
                       COUNT(*) FILTER (WHERE user_id = \(bind: user))::integer AS user_count
                FROM im_v2.user_live_presence_leases
                WHERE user_id = \(bind: user)
                  AND expires_at > \(bind: now)
                  AND connection_id <> \(bind: connectionID)
                """).first(decoding: LiveActivityConnectionCountRow.self)
            else { throw V2LiveActivityStoreError.corruptPersistenceState }
            guard counts.deviceCount < policy.maximumConnectionsPerDevice,
                  counts.userCount < policy.maximumConnectionsPerUser
            else { return .rejected }
            guard let admitted = try await sql.raw("""
                INSERT INTO im_v2.user_live_presence_leases
                    (user_id, device_id, connection_id, expires_at, updated_at)
                VALUES
                    (\(bind: user), \(bind: device), \(bind: connectionID), \(bind: expiry), \(bind: now))
                ON CONFLICT (connection_id) DO UPDATE
                SET expires_at = GREATEST(im_v2.user_live_presence_leases.expires_at, EXCLUDED.expires_at),
                    updated_at = GREATEST(im_v2.user_live_presence_leases.updated_at, EXCLUDED.updated_at)
                WHERE im_v2.user_live_presence_leases.user_id = EXCLUDED.user_id
                  AND im_v2.user_live_presence_leases.device_id = EXCLUDED.device_id
                RETURNING expires_at
                """).first(decoding: LiveActivityExpiryRow.self), let acceptedExpiry = admitted.expiresAt
            else { throw V2LiveActivityStoreError.corruptPersistenceState }
            return .accepted(expiresAt: acceptedExpiry)
        }
    }

    /// 续租一条已存在的连接租约。
    ///
    /// 只有连接标识、用户与设备三者都匹配且租约尚未过期时才会续租；
    /// 否则返回 `.rejected`。
    ///
    /// - Parameters:
    ///   - identity: 已认证的连接身份。
    ///   - connectionID: 本次连接标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 租约续租结果。
    /// - Throws: 租约时间无法编码或持久化状态损坏时抛出。
    public func renewConnection(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) async throws -> V2AuthenticatedConnectionLeaseOutcome {
        let expiry = try validatedLeaseExpiry(now: now)
        guard let sql = database as? any SQLDatabase else {
            throw V2LiveActivityStoreError.corruptPersistenceState
        }
        let user = try liveActivityUUID(identity.userID)
        let device = try liveActivityUUID(identity.deviceID)
        let renewed = try await sql.raw("""
            UPDATE im_v2.user_live_presence_leases
            SET expires_at = GREATEST(expires_at, \(bind: expiry)), updated_at = GREATEST(updated_at, \(bind: now))
            WHERE connection_id = \(bind: connectionID)
              AND user_id = \(bind: user)
              AND device_id = \(bind: device)
              AND expires_at > \(bind: now)
            RETURNING expires_at
            """).first(decoding: LiveActivityExpiryRow.self)
        guard let renewed else { return .rejected }
        guard let acceptedExpiry = renewed.expiresAt else { throw V2LiveActivityStoreError.corruptPersistenceState }
        return .accepted(expiresAt: acceptedExpiry)
    }

    /// 批量续租多条连接租约。
    ///
    /// 同一连接在一个物理批次中最多续租一次；若调用方竞态地提交了重复心跳，以最新观测时间为准。
    /// 被拒绝的连接会保留在结果中，成功续租的结果会覆盖同名拒绝项。
    ///
    /// - Parameter requests: 本批续租请求。
    /// - Returns: 按连接标识索引的续租结果。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    public func renewConnections(
        _ requests: [V2LivePresenceLeaseRenewalRequest]
    ) async throws -> [UUID: V2LivePresenceLeaseRefresh] {
        guard !requests.isEmpty else { return [:] }
        guard let sql = database as? any SQLDatabase else {
            throw V2LiveActivityStoreError.corruptPersistenceState
        }

        // 同一连接在一个物理批次中最多续租一次。
        // 若调用方并发发出重复心跳，以最新观测时间为准。
        var unique: [UUID: V2LivePresenceLeaseRenewalRequest] = [:]
        unique.reserveCapacity(requests.count)
        var rejected: [UUID: V2LivePresenceLeaseRefresh] = [:]
        for request in requests {
            guard (try? validatedLeaseExpiry(now: request.now)) != nil else {
                rejected[request.connectionID] = .init(outcome: .rejected, allowsOnlinePresence: false)
                continue
            }
            if let previous = unique[request.connectionID], previous.now > request.now { continue }
            unique[request.connectionID] = request
        }
        guard !unique.isEmpty else { return rejected }
        let rows = try unique.values.map { request in
            LiveActivityLeaseRenewalInput(
                connectionID: request.connectionID,
                userID: try liveActivityUUID(request.identity.userID),
                deviceID: try liveActivityUUID(request.identity.deviceID),
                expiresAt: request.now.addingTimeInterval(onlineLease),
                updatedAt: request.now
            )
        }
        // 原生 Date 数组与逐条续租使用相同的微秒编码。
        // 通过 to_timestamp 转换浮点 Unix 秒，可能舍入越过租约的严格过期边界。
        let query: SQLQueryString = """
            WITH requested AS MATERIALIZED (
                SELECT *
                FROM unnest(
                    \(bind: rows.map(\.connectionID))::uuid[],
                    \(bind: rows.map(\.userID))::uuid[],
                    \(bind: rows.map(\.deviceID))::uuid[],
                    \(bind: rows.map(\.expiresAt))::timestamptz[],
                    \(bind: rows.map(\.updatedAt))::timestamptz[]
                ) AS input(connection_id, user_id, device_id, expires_at, updated_at)
            ), renewed AS (
                UPDATE im_v2.user_live_presence_leases AS lease
                SET expires_at = GREATEST(lease.expires_at, requested.expires_at),
                    updated_at = GREATEST(lease.updated_at, requested.updated_at)
                FROM requested
                WHERE lease.connection_id = requested.connection_id
                  AND lease.user_id = requested.user_id
                  AND lease.device_id = requested.device_id
                  AND lease.expires_at > requested.updated_at
                RETURNING lease.connection_id, lease.expires_at
            )
            SELECT requested.connection_id,
                   renewed.expires_at,
                   COALESCE(preference.allows_online_presence, TRUE) AS allows_online_presence
            FROM requested
            LEFT JOIN renewed USING (connection_id)
            LEFT JOIN im_v2.user_live_activity_preferences AS preference
              ON preference.user_id = requested.user_id
            """

        let resultRows = try await sql.raw(query).all(decoding: LiveActivityLeaseRefreshRow.self)
        let refreshed: [UUID: V2LivePresenceLeaseRefresh] = Dictionary(uniqueKeysWithValues: resultRows.map { row in
            let outcome: V2AuthenticatedConnectionLeaseOutcome = row.expiresAt.map {
                .accepted(expiresAt: $0)
            } ?? .rejected
            return (
                row.connectionID,
                .init(outcome: outcome, allowsOnlinePresence: row.allowsOnlinePresence)
            )
        })
        return rejected.merging(refreshed) { _, valid in valid }
    }

    /// 移除一条连接租约，并报告该用户是否仍有其他活跃租约。
    ///
    /// 调用方的已认证身份始终是权威：即使租约已过期、甚至已被其他副本删除，
    /// 删除仍会按连接标识与用户、设备三者匹配执行，
    /// 从而避免过期的生命周期误删归属他人的同名连接。
    ///
    /// - Parameters:
    ///   - identity: 已认证的连接身份。
    ///   - connectionID: 待移除的连接标识。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 该用户当前是否仍存在有效租约。
    /// - Throws: 时间戳无法编码或持久化失败时抛出。
    public func removePresence(
        identity: V2AuthenticatedConnection,
        connectionID: UUID,
        now: Date
    ) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now) else { throw V2LiveActivityStoreError.corruptPersistenceState }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let user = try liveActivityUUID(identity.userID)
            let device = try liveActivityUUID(identity.deviceID)
            try await lockConnectionIdentity(user: user, device: device, sql: sql)
            // 即使租约已过期且被其他副本删除，调用方经认证的身份仍是权威。
            // 同时匹配两个所有者字段，还可防止旧生命周期删除
            // 属于其他用户、但连接 ID 碰撞的记录。
            try await sql.raw("""
                DELETE FROM im_v2.user_live_presence_leases
                WHERE connection_id = \(bind: connectionID)
                  AND user_id = \(bind: user)
                  AND device_id = \(bind: device)
                """).run()
            return try await sql.raw("""
                SELECT EXISTS (
                    SELECT 1
                    FROM im_v2.user_live_presence_leases
                    WHERE user_id = \(bind: user)
                      AND expires_at > \(bind: now)
                ) AS exists
                """).first(decoding: LiveActivityBooleanRow.self)?.exists ?? false
        }
    }

    private func activeMember(room: UUID, user: UUID, sql: any SQLDatabase) async throws -> Bool {
        guard let row = try await sql.raw("SELECT room.membership_revision FROM im_v2.rooms AS room WHERE room.room_id = \(bind: room)").first(decoding: LiveActivityMembershipRevisionRow.self) else { throw V2LiveActivityStoreError.roomNotFound }
        return try await sql.raw("SELECT 1 AS exists FROM im_v2.room_memberships WHERE room_id = \(bind: room) AND user_id = \(bind: user) AND joined_revision <= \(bind: row.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: row.membershipRevision))").first(decoding: LiveActivityExistsRow.self) != nil
    }

    private func lockConnectionIdentity(user: UUID, device: UUID, sql: any SQLDatabase) async throws {
        try await sql.raw("""
            SELECT pg_advisory_xact_lock(
                hashtextextended(\(bind: "v2-live-user:" + user.uuidString.lowercased()), 0)
            )
            """).run()
        try await sql.raw("""
            SELECT pg_advisory_xact_lock(
                hashtextextended(\(bind: "v2-live-device:" + device.uuidString.lowercased()), 0)
            )
            """).run()
    }

    private func directPeer(room: UUID, user: UUID, sql: any SQLDatabase) async throws -> UUID? {
        try await sql.raw("SELECT CASE WHEN lower_user_id = \(bind: user) THEN higher_user_id ELSE lower_user_id END AS user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: room) AND (lower_user_id = \(bind: user) OR higher_user_id = \(bind: user))").first(decoding: LiveActivityUserRow.self)?.userID
    }

    private func usersAreBlocked(_ lhs: UUID, _ rhs: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_blocks WHERE (blocker_user_id = \(bind: lhs) AND blocked_user_id = \(bind: rhs)) OR (blocker_user_id = \(bind: rhs) AND blocked_user_id = \(bind: lhs))) AS exists").first(decoding: LiveActivityBooleanRow.self)?.exists ?? true
    }
}

private struct LiveActivityPreferenceRow: Decodable { let allowsOnlinePresence: Bool; let allowsTypingIndicators: Bool; let updatedAt: Date; enum CodingKeys: String, CodingKey { case allowsOnlinePresence = "allows_online_presence", allowsTypingIndicators = "allows_typing_indicators", updatedAt = "updated_at" }; func validatedPreferences() throws -> V2LiveActivityPreferences { guard v2PostgresTimestampCanEncode(updatedAt) else { throw V2LiveActivityStoreError.corruptPersistenceState }; return .init(allowsOnlinePresence: allowsOnlinePresence, allowsTypingIndicators: allowsTypingIndicators, updatedAt: updatedAt) } }
private struct LiveActivityLeaseRefreshRow: Decodable {
    let connectionID: UUID
    let expiresAt: Date?
    let allowsOnlinePresence: Bool
    enum CodingKeys: String, CodingKey {
        case connectionID = "connection_id"
        case expiresAt = "expires_at"
        case allowsOnlinePresence = "allows_online_presence"
    }
}
private struct LiveActivityLeaseRenewalInput {
    let connectionID: UUID
    let userID: UUID
    let deviceID: UUID
    let expiresAt: Date
    let updatedAt: Date
}
private struct LiveActivityOnlinePreferenceRow: Decodable { let allowsOnlinePresence: Bool; enum CodingKeys: String, CodingKey { case allowsOnlinePresence = "allows_online_presence" } }
private struct LiveActivityTypingPreferenceRow: Decodable { let allowsTypingIndicators: Bool; enum CodingKeys: String, CodingKey { case allowsTypingIndicators = "allows_typing_indicators" } }
private struct LiveActivityUserRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "user_id" } }
private struct LiveActivityExpiryRow: Decodable { let expiresAt: Date?; enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" } }
private struct LiveActivityMembershipRevisionRow: Decodable { let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" } }
private struct LiveActivityExistsRow: Decodable { let exists: Int }
private struct LiveActivityBooleanRow: Decodable { let exists: Bool }
private struct LiveActivityConnectionCountRow: Decodable {
    let deviceCount: Int
    let userCount: Int
    enum CodingKeys: String, CodingKey {
        case deviceCount = "device_count"
        case userCount = "user_count"
    }
}
private struct LiveActivityConnectionIDRow: Decodable {
    let connectionID: UUID
    enum CodingKeys: String, CodingKey { case connectionID = "connection_id" }
}
private func liveActivityUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: id.rawValue) else { throw V2LiveActivityStoreError.corruptPersistenceState }; return value }
