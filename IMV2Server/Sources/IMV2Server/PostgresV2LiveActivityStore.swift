import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2LiveActivityStore: V2LiveActivityStore {
    private let database: any Database
    private let onlineLease: TimeInterval

    public init(database: any Database, onlineLease: TimeInterval = 90) {
        precondition(onlineLease > 0)
        self.database = database
        self.onlineLease = onlineLease
    }

    public func setPreferences(command: V2SetLiveActivityPreferencesCommand, now: Date) async throws -> V2SetLiveActivityPreferencesOutcome {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let actor = try liveActivityUUID(command.actorUserID), operation = try liveActivityUUID(command.operationID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: actor.uuidString + ":" + operation.uuidString), 0))").run()
            if let prior = try await sql.raw("SELECT allows_online_presence, allows_typing_indicators, updated_at FROM im_v2.user_live_activity_preference_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding: LiveActivityPreferenceRow.self) {
                guard prior.allowsOnlinePresence == command.allowsOnlinePresence, prior.allowsTypingIndicators == command.allowsTypingIndicators else { return .idempotencyConflict }
                return .idempotent(prior.preferences)
            }
            try await sql.raw("INSERT INTO im_v2.user_live_activity_preferences (user_id, allows_online_presence, allows_typing_indicators, updated_at) VALUES (\(bind: actor), \(bind: command.allowsOnlinePresence), \(bind: command.allowsTypingIndicators), \(bind: now)) ON CONFLICT (user_id) DO UPDATE SET allows_online_presence = EXCLUDED.allows_online_presence, allows_typing_indicators = EXCLUDED.allows_typing_indicators, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.user_live_activity_preference_operations (actor_user_id, operation_id, allows_online_presence, allows_typing_indicators, updated_at) VALUES (\(bind: actor), \(bind: operation), \(bind: command.allowsOnlinePresence), \(bind: command.allowsTypingIndicators), \(bind: now))").run()
            return .updated(.init(allowsOnlinePresence: command.allowsOnlinePresence, allowsTypingIndicators: command.allowsTypingIndicators, updatedAt: now))
        }
    }

    public func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences {
        guard let sql = database as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let user = try liveActivityUUID(userID)
        let preference = try await sql.raw("SELECT allows_online_presence, allows_typing_indicators, updated_at FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: user)").first(decoding: LiveActivityPreferenceRow.self)
        return preference?.preferences ?? .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: now)
    }

    public func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let room = try liveActivityUUID(roomID), viewer = try liveActivityUUID(viewerUserID)
            guard let peer = try await sql.raw("SELECT CASE WHEN lower_user_id = \(bind: viewer) THEN higher_user_id ELSE lower_user_id END AS user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: room) AND (lower_user_id = \(bind: viewer) OR higher_user_id = \(bind: viewer))").first(decoding: LiveActivityUserRow.self) else { throw V2LiveActivityStoreError.notDirectRoom }
            guard try await activeMember(room: room, user: viewer, sql: sql) else { throw V2LiveActivityStoreError.actorNotMember }
            let preference = try await sql.raw("SELECT allows_online_presence FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: peer.userID)").first(decoding: LiveActivityOnlinePreferenceRow.self)?.allowsOnlinePresence ?? true
            let expiry = try await sql.raw("SELECT MAX(expires_at) AS expires_at FROM im_v2.user_live_presence_leases WHERE user_id = \(bind: peer.userID) AND expires_at > \(bind: now)").first(decoding: LiveActivityExpiryRow.self)?.expiresAt
            return try .init(roomID: roomID, targetUserID: .init(peer.userID.uuidString), isOnline: preference && expiry != nil, expiresAt: preference ? (expiry ?? now) : now)
        }
    }

    public func authorizeTyping(roomID: RoomID, actorUserID: UserID, now _: Date) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            let room = try liveActivityUUID(roomID), actor = try liveActivityUUID(actorUserID)
            guard try await activeMember(room: room, user: actor, sql: sql) else { throw V2LiveActivityStoreError.actorNotMember }
            let allowed = try await sql.raw("SELECT allows_typing_indicators FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: actor)").first(decoding: LiveActivityTypingPreferenceRow.self)?.allowsTypingIndicators ?? true
            guard allowed else { throw V2LiveActivityStoreError.typingNotAllowed }
        }
    }

    public func allowsOnlinePresence(userID: UserID) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let user = try liveActivityUUID(userID)
        return try await sql.raw("SELECT allows_online_presence FROM im_v2.user_live_activity_preferences WHERE user_id = \(bind: user)").first(decoding: LiveActivityOnlinePreferenceRow.self)?.allowsOnlinePresence ?? true
    }

    public func refreshPresence(identity: V2AuthenticatedConnection, connectionID: UUID, now: Date) async throws -> Date {
        guard let sql = database as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
        let user = try liveActivityUUID(identity.userID), device = try liveActivityUUID(identity.deviceID)
        let expiry = now.addingTimeInterval(onlineLease)
        try await sql.raw("INSERT INTO im_v2.user_live_presence_leases (user_id, device_id, connection_id, expires_at, updated_at) VALUES (\(bind: user), \(bind: device), \(bind: connectionID), \(bind: expiry), \(bind: now)) ON CONFLICT (connection_id) DO UPDATE SET expires_at = EXCLUDED.expires_at, updated_at = EXCLUDED.updated_at").run()
        return expiry
    }

    public func removePresence(connectionID: UUID, now: Date) async throws -> Bool {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2LiveActivityStoreError.corruptPersistenceState }
            try await sql.raw("DELETE FROM im_v2.user_live_presence_leases WHERE connection_id = \(bind: connectionID)").run()
            return try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_live_presence_leases WHERE expires_at > \(bind: now)) AS exists").first(decoding: LiveActivityBooleanRow.self)?.exists ?? false
        }
    }

    private func activeMember(room: UUID, user: UUID, sql: any SQLDatabase) async throws -> Bool {
        guard let row = try await sql.raw("SELECT room.membership_revision FROM im_v2.rooms AS room WHERE room.room_id = \(bind: room)").first(decoding: LiveActivityMembershipRevisionRow.self) else { throw V2LiveActivityStoreError.roomNotFound }
        return try await sql.raw("SELECT 1 AS exists FROM im_v2.room_memberships WHERE room_id = \(bind: room) AND user_id = \(bind: user) AND joined_revision <= \(bind: row.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: row.membershipRevision))").first(decoding: LiveActivityExistsRow.self) != nil
    }
}

private struct LiveActivityPreferenceRow: Decodable { let allowsOnlinePresence: Bool; let allowsTypingIndicators: Bool; let updatedAt: Date; enum CodingKeys: String, CodingKey { case allowsOnlinePresence = "allows_online_presence", allowsTypingIndicators = "allows_typing_indicators", updatedAt = "updated_at" }; var preferences: V2LiveActivityPreferences { .init(allowsOnlinePresence: allowsOnlinePresence, allowsTypingIndicators: allowsTypingIndicators, updatedAt: updatedAt) } }
private struct LiveActivityOnlinePreferenceRow: Decodable { let allowsOnlinePresence: Bool; enum CodingKeys: String, CodingKey { case allowsOnlinePresence = "allows_online_presence" } }
private struct LiveActivityTypingPreferenceRow: Decodable { let allowsTypingIndicators: Bool; enum CodingKeys: String, CodingKey { case allowsTypingIndicators = "allows_typing_indicators" } }
private struct LiveActivityUserRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "user_id" } }
private struct LiveActivityExpiryRow: Decodable { let expiresAt: Date?; enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" } }
private struct LiveActivityMembershipRevisionRow: Decodable { let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" } }
private struct LiveActivityExistsRow: Decodable { let exists: Int }
private struct LiveActivityBooleanRow: Decodable { let exists: Bool }
private func liveActivityUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: id.rawValue) else { throw V2LiveActivityStoreError.corruptPersistenceState }; return value }
