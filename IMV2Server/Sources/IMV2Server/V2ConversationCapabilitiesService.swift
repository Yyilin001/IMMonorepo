import Fluent
import Foundation
import IMV2Core
import SQLKit

public enum V2ConversationCapabilitiesOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case applied(Value), idempotent(Value), idempotencyConflict
}

public enum V2ConversationCapabilitiesStoreError: Error, Equatable, Sendable { case roomNotFound, messageNotFound, actorNotMember, invalidTimestamp, corruptPersistenceState }

public protocol V2ConversationCapabilitiesStore: Sendable {
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState>
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite>
}

public struct V2ConversationCapabilitiesService: Sendable {
    private let store: any V2ConversationCapabilitiesStore
    private let now: @Sendable () -> Date
    public init(store: any V2ConversationCapabilitiesStore, now: @escaping @Sendable () -> Date = Date.init) { self.store = store; self.now = now }
    public func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState> { try await store.setConversationState(actorUserID: actorUserID, command: command, now: now()) }
    public func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite> { try await store.setMessageFavorite(actorUserID: actorUserID, command: command, now: now()) }
}

public struct PostgresV2ConversationCapabilitiesStore: V2ConversationCapabilitiesStore {
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing
    public init(database: any Database, shadowForwarder: any V2UserShardProjectionShadowing) { self.database = database; self.shadowForwarder = shadowForwarder }

    public func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2ConversationState> {
        if let muteUntil = command.muteUntil, !v2PostgresTimestampCanEncode(muteUntil) {
            throw V2ConversationCapabilitiesStoreError.invalidTimestamp
        }
        let result: V2ConversationCapabilitiesOutcome<V2ConversationState> = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let actor = try capabilityUUID(actorUserID), room = try capabilityUUID(command.roomID), operation = try capabilityUUID(command.operationID)
            try await lockOperation(actor: actor, operation: operation, kind: "conversation", sql: sql)
            if let prior = try await sql.raw("SELECT room_id, pinned_at, archived_at, mute_until, updated_at, mute_until IS NOT DISTINCT FROM \(bind: command.muteUntil) AS mute_matches FROM im_v2.user_room_preference_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding: ConversationStateRow.self) {
                guard prior.roomID == room, (prior.pinnedAt != nil) == command.isPinned, (prior.archivedAt != nil) == command.isArchived else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(prior.updatedAt), prior.muteUntil.map(v2PostgresTimestampCanEncode) ?? true else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
                // Compare in PostgreSQL so retries use the same microsecond
                // quantization as the original bound parameter.
                guard prior.muteMatches else { return .idempotencyConflict }
                return .idempotent(try prior.value())
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            try await assertActiveMember(actor: actor, room: room, sql: sql)
            let pinnedAt = command.isPinned ? now : nil, archivedAt = command.isArchived ? now : nil
            try await sql.raw("INSERT INTO im_v2.user_room_preferences (user_id, room_id, pinned_at, archived_at, mute_until, updated_at) VALUES (\(bind: actor), \(bind: room), \(bind: pinnedAt), \(bind: archivedAt), \(bind: command.muteUntil), \(bind: now)) ON CONFLICT (user_id, room_id) DO UPDATE SET pinned_at = EXCLUDED.pinned_at, archived_at = EXCLUDED.archived_at, mute_until = EXCLUDED.mute_until, updated_at = EXCLUDED.updated_at").run()
            guard let persisted = try await sql.raw("INSERT INTO im_v2.user_room_preference_operations (actor_user_id, operation_id, room_id, pinned_at, archived_at, mute_until, updated_at) VALUES (\(bind: actor), \(bind: operation), \(bind: room), \(bind: pinnedAt), \(bind: archivedAt), \(bind: command.muteUntil), \(bind: now)) RETURNING room_id, pinned_at, archived_at, mute_until, updated_at, TRUE AS mute_matches").first(decoding: ConversationStateRow.self) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let value = try persisted.value()
            try await appendStateProjection(actor: actor, source: operation, value: value, now: now, sql: sql)
            return .applied(value)
        }
        switch result {
        case .applied, .idempotent:
            try await shadow(actor: actorUserID, operation: command.operationID.rawValue, kinds: ["conversation_state"])
        case .idempotencyConflict:
            break
        }
        return result
    }

    public func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws -> V2ConversationCapabilitiesOutcome<V2MessageFavorite> {
        let result: V2ConversationCapabilitiesOutcome<V2MessageFavorite> = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let actor = try capabilityUUID(actorUserID), room = try capabilityUUID(command.roomID), message = try capabilityUUID(command.messageID), operation = try capabilityUUID(command.operationID)
            try await lockOperation(actor: actor, operation: operation, kind: "favorite", sql: sql)
            if let prior = try await sql.raw("SELECT room_id, message_id, is_favorited, updated_at FROM im_v2.user_message_favorite_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)").first(decoding: FavoriteRow.self) {
                guard prior.roomID == room, prior.messageID == message, prior.isFavorited == command.isFavorited else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(prior.updatedAt) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
                return .idempotent(try prior.value())
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            try await assertActiveMember(actor: actor, room: room, sql: sql)
            let messageInRoom = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.messages WHERE message_id = \(bind: message) AND room_id = \(bind: room)) AS value").first(decoding: CapabilityBooleanRow.self)?.value ?? false
            guard messageInRoom else { throw V2ConversationCapabilitiesStoreError.messageNotFound }
            if command.isFavorited { try await sql.raw("INSERT INTO im_v2.user_message_favorites (user_id, message_id, room_id, created_at) VALUES (\(bind: actor), \(bind: message), \(bind: room), \(bind: now)) ON CONFLICT DO NOTHING").run() }
            else { try await sql.raw("DELETE FROM im_v2.user_message_favorites WHERE user_id = \(bind: actor) AND message_id = \(bind: message)").run() }
            guard let persisted = try await sql.raw("INSERT INTO im_v2.user_message_favorite_operations (actor_user_id, operation_id, message_id, room_id, is_favorited, updated_at) VALUES (\(bind: actor), \(bind: operation), \(bind: message), \(bind: room), \(bind: command.isFavorited), \(bind: now)) RETURNING room_id, message_id, is_favorited, updated_at").first(decoding: FavoriteRow.self) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }
            let value = try persisted.value()
            try await appendFavoriteProjection(actor: actor, source: operation, value: value, now: now, sql: sql)
            return .applied(value)
        }
        switch result {
        case .applied, .idempotent:
            try await shadow(actor: actorUserID, operation: command.operationID.rawValue, kinds: ["message_favorite"])
        case .idempotencyConflict:
            break
        }
        return result
    }

    private func lockOperation(actor: UUID, operation: UUID, kind: String, sql: any SQLDatabase) async throws {
        // Lock the ledger identity before reading it. Room/state locks alone
        // cannot make a concurrent retry observe a newly committed operation.
        let key = "personal-preference:" + kind + ":" + actor.uuidString + ":" + operation.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    private func assertActiveMember(actor: UUID, room: UUID, sql: any SQLDatabase) async throws {
        guard let revision = try await sql.raw("SELECT membership_revision FROM im_v2.rooms WHERE room_id = \(bind: room) FOR UPDATE").first(decoding: CapabilityRoomRow.self)?.membershipRevision else { throw V2ConversationCapabilitiesStoreError.roomNotFound }
        let member = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.room_memberships WHERE room_id = \(bind: room) AND user_id = \(bind: actor) AND joined_revision <= \(bind: revision) AND (left_revision IS NULL OR left_revision > \(bind: revision))) AS value").first(decoding: CapabilityBooleanRow.self)?.value ?? false
        guard member else { throw V2ConversationCapabilitiesStoreError.actorNotMember }
    }
    // Bind the original clock to storage; decoded response dates may lose another
    // microsecond if encoded again. Payload timestamps use the committed value.
    private func appendStateProjection(actor: UUID, source: UUID, value: V2ConversationState, now: Date, sql: any SQLDatabase) async throws { let sequence = try await nextSequence(actor: actor, sql: sql); try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: actor), \(bind: sequence), \(bind: source), 'conversation_state', jsonb_build_object('room_id', \(bind: value.roomID.rawValue), 'is_pinned', \(bind: value.isPinned), 'is_archived', \(bind: value.isArchived), 'mute_until_ms', \(bind: value.muteUntil.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0), 'updated_at_ms', \(bind: Int64(value.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now))").run() }
    private func appendFavoriteProjection(actor: UUID, source: UUID, value: V2MessageFavorite, now: Date, sql: any SQLDatabase) async throws { let sequence = try await nextSequence(actor: actor, sql: sql); try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: actor), \(bind: sequence), \(bind: source), 'message_favorite', jsonb_build_object('room_id', \(bind: value.roomID.rawValue), 'message_id', \(bind: value.messageID.rawValue), 'is_favorited', \(bind: value.isFavorited), 'updated_at_ms', \(bind: Int64(value.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now))").run() }
    private func nextSequence(actor: UUID, sql: any SQLDatabase) async throws -> Int64 { guard let result = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: actor), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 WHERE im_v2.user_sync_sequences.next_sequence < \(bind: Int64.max) RETURNING next_sequence").first(decoding: CapabilitySyncRow.self)?.sequence else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }; return result }
    private func shadow(actor: UserID, operation: String, kinds: Set<String>) async throws { _ = try await shadowForwarder.shadowIfForwarding(userID: actor, sourceEventID: .init(operation), projectionKinds: kinds) }
}
private struct ConversationStateRow: Decodable { let muteMatches: Bool; let roomID: UUID; let pinnedAt: Date?; let archivedAt: Date?; let muteUntil: Date?; let updatedAt: Date; enum CodingKeys: String, CodingKey { case muteMatches = "mute_matches", roomID = "room_id", pinnedAt = "pinned_at", archivedAt = "archived_at", muteUntil = "mute_until", updatedAt = "updated_at" }; func value() throws -> V2ConversationState { try .init(roomID: .init(roomID.uuidString), isPinned: pinnedAt != nil, isArchived: archivedAt != nil, muteUntil: muteUntil, updatedAt: updatedAt) } }
private struct FavoriteRow: Decodable { let roomID: UUID; let messageID: UUID; let isFavorited: Bool; let updatedAt: Date; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", isFavorited = "is_favorited", updatedAt = "updated_at" }; func value() throws -> V2MessageFavorite { try .init(roomID: .init(roomID.uuidString), messageID: .init(messageID.uuidString), isFavorited: isFavorited, updatedAt: updatedAt) } }
private struct CapabilityRoomRow: Decodable { let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case membershipRevision = "membership_revision" } }
private struct CapabilityBooleanRow: Decodable { let value: Bool }
private struct CapabilitySyncRow: Decodable { let sequence: Int64; enum CodingKeys: String, CodingKey { case sequence = "next_sequence" } }
private func capabilityUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let uuid = UUID(uuidString: id.rawValue) else { throw V2ConversationCapabilitiesStoreError.corruptPersistenceState }; return uuid }
