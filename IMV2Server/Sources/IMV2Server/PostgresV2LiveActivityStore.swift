import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2LiveActivityConfigurationError: Error, Equatable, Sendable {
    case invalidOnlineLease
}

public struct PostgresV2LiveActivityStore: V2LiveActivityStore {
    private let database: any Database
    private let onlineLease: TimeInterval

    public init(database: any Database, onlineLease: TimeInterval = 90) throws {
        guard onlineLease > 0, Int64(exactly: (onlineLease * 1_000_000).rounded(.up)) != nil else {
            throw V2LiveActivityConfigurationError.invalidOnlineLease
        }
        self.database = database
        self.onlineLease = onlineLease
    }

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

    public func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences {
        guard let sql = database as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let user = try liveActivityUUID(userID)
        let preference = try await sql.raw("SELECT allows_online_presence, allows_typing_indicators, updated_at FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: user)").first(decoding: LiveActivityPreferenceRow.self)
        if let preference { return try preference.validatedPreferences() }
        guard v2PostgresTimestampCanEncode(now) else { throw V2LiveActivityStoreError.corruptPersistenceState }
        return .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: now)
    }

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

    public func allowsOnlinePresence(userID: UserID) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let user = try liveActivityUUID(userID)
        return try await sql.raw("SELECT allows_online_presence FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: user)").first(decoding: LiveActivityOnlinePreferenceRow.self)?.allowsOnlinePresence ?? true
    }

    private func validatedLeaseExpiry(now: Date) throws -> Date {
        let expiry = now.addingTimeInterval(onlineLease)
        // Wire truncation moves negative Unix timestamps toward the future.
        // It cannot prove that the durable lease interval survived encoding.
        guard v2PostgresTimestampPrecedes(now, expiry),
              let milliseconds = try? v2GatewayMilliseconds(expiry),
              Double(milliseconds) > now.timeIntervalSince1970 * 1_000 else {
            throw V2LiveActivityStoreError.corruptPersistenceState
        }
        return expiry
    }

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
            // All contenders for one user take the same first lock; the
            // device lock then serializes the narrower limit without a
            // user/device lock-order cycle.
            try await lockConnectionIdentity(user: user, device: device, sql: sql)
            // `auth_devices.device_id` is globally unique and the lease has a
            // composite owner foreign key, so this device can only occur under
            // `user`. Keeping the predicate user-only lets PostgreSQL use the
            // existing `(user_id, expires_at)` index.
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

    public func renewConnections(
        _ requests: [V2LivePresenceLeaseRenewalRequest]
    ) async throws -> [UUID: V2LivePresenceLeaseRefresh] {
        guard !requests.isEmpty else { return [:] }
        guard let sql = database as? any SQLDatabase else {
            throw V2LiveActivityStoreError.corruptPersistenceState
        }

        // A connection can have at most one renewal in a physical batch. If a
        // caller races duplicate heartbeats, the newest observed time wins.
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
        // Native Date arrays use the same microsecond encoding as scalar
        // renewals. Converting floating Unix seconds with to_timestamp can
        // round across a lease's strict expiry boundary.
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
            // The caller's authenticated identity remains authoritative even
            // if this lease expired and another replica already deleted it.
            // Matching both owner fields also prevents an obsolete lifecycle
            // from deleting a colliding connection ID owned by another user.
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
