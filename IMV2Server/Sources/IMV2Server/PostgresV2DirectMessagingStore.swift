import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL direct-room and stranger-preference boundary. Pair-scoped
/// advisory locks make an absent direct pair serializable without inventing an
/// orphan room when two callers initiate the same conversation concurrently.
public struct PostgresV2DirectMessagingStore: V2DirectMessagingStore {
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing

    public init(database: any Database, shadowForwarder: any V2UserShardProjectionShadowing) {
        self.database = database
        self.shadowForwarder = shadowForwarder
    }

    public func open(command: V2OpenDirectRoomCommand, capacityProfile: V2CapacityProfile, roomShardID: String, roomID: RoomID, now: Date) async throws -> V2OpenDirectRoomOutcome {
        let outcome: V2OpenDirectRoomOutcome = try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let actorID = try directUUID(command.actorUserID)
            let targetID = try directUUID(command.targetUserID)
            let operationID = try directUUID(command.operationID)
            if let existing = try await sql.raw("SELECT target_user_id, room_id, created_at FROM im_v2.direct_room_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: DirectOperationRow.self) {
                let direct = try existing.directRoom(actor: command.actorUserID, target: command.targetUserID)
                return existing.targetUserID == targetID ? .idempotent(direct) : .idempotencyConflict
            }

            let pair = directPair(actorID, targetID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey), 0))").run()
            let activeAccountCount = try await sql.raw("SELECT COUNT(*)::int AS value FROM im_v2.public_user_profiles AS profile WHERE (profile.user_id = \(bind: actorID) OR profile.user_id = \(bind: targetID)) AND profile.state = 'active' AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables AS disabled WHERE disabled.user_id = profile.user_id)").first(decoding: DirectCountRow.self)?.value ?? 0
            guard activeAccountCount == 2 else { return .unavailable }
            if let existingPair = try await sql.raw("SELECT pair.room_id, pair.created_at, room.capacity_profile_id FROM im_v2.direct_room_pairs AS pair INNER JOIN im_v2.rooms AS room ON room.room_id = pair.room_id WHERE pair.lower_user_id = \(bind: pair.lower) AND pair.higher_user_id = \(bind: pair.higher) FOR SHARE OF room").first(decoding: DirectPairRow.self) {
                // A direct pair is globally unique and its room keeps the
                // immutable capacity profile selected at creation. Do not
                // return a room that this deployment cannot subsequently
                // write; callers can retry after the intended profile is
                // restored or an explicit room migration completes.
                guard existingPair.capacityProfileID == capacityProfile.id else {
                    return .unavailable
                }
                let result = try existingPair.directRoom(actor: command.actorUserID, target: command.targetUserID)
                try await insertOperation(actorID: actorID, operationID: operationID, targetID: targetID, roomID: existingPair.roomID, createdAt: existingPair.createdAt, sql: sql)
                return .opened(result)
            }

            let createdRoomID = try directUUID(roomID)
            let profiles = try await sql.raw("""
                SELECT user_id, public_handle, display_name, account_kind, revision, updated_at
                FROM im_v2.public_user_profiles
                WHERE (user_id = \(bind: actorID) OR user_id = \(bind: targetID))
                  AND state = 'active'
                """).all(decoding: DirectPublicProfileRow.self)
            guard profiles.count == 2,
                  let targetProfile = profiles.first(where: { $0.userID == targetID })
            else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            // Room creation only observes the immutable lease fence; it does
            // not mutate the shard pool. Shared row locks let independent
            // pairs create rooms concurrently while still fencing lease
            // replacement, which requires an exclusive row lock.
            guard let lease = try await sql.raw("SELECT lease_id, generation, valid_until FROM im_v2.shard_admission_pools WHERE room_shard_id = \(bind: roomShardID) AND capacity_profile_id = \(bind: capacityProfile.id) FOR SHARE").first(decoding: DirectShardLeaseRow.self), lease.validUntil > now else {
                return .unavailable
            }
            try await sql.raw("INSERT INTO im_v2.rooms (room_id, room_kind, room_shard_id, room_sequence, membership_revision, capacity_profile_id, created_at) VALUES (\(bind: createdRoomID), 'direct', \(bind: roomShardID), 0, 1, \(bind: capacityProfile.id), \(bind: now))").run()
            // Opening a room immediately projects the target's profile to the
            // actor. Persist that producer-side fact beside the pair so later
            // sends do not have to rediscover it by scanning compacted and
            // uncompacted sync history. The projection and marker share this
            // transaction, so neither can survive without the other.
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_pairs
                    (lower_user_id, higher_user_id, room_id, created_at,
                     lower_profile_visible_to_higher, higher_profile_visible_to_lower)
                VALUES
                    (\(bind: pair.lower), \(bind: pair.higher), \(bind: createdRoomID), \(bind: now),
                     \(bind: actorID == pair.higher), \(bind: actorID == pair.lower))
                """).run()
            try await sql.raw("INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision) VALUES (\(bind: createdRoomID), \(bind: actorID), 'member', 1), (\(bind: createdRoomID), \(bind: targetID), 'member', 1)").run()
            try await sql.raw("INSERT INTO im_v2.room_admission (room_id, eligible_member_count, command_window_limit, fanout_window_limit, max_outstanding_fanout_units, max_outstanding_plans, shard_lease_id, shard_lease_generation) VALUES (\(bind: createdRoomID), 2, \(bind: capacityProfile.limits.maxCommandsPerWindow), \(bind: capacityProfile.limits.maxFanoutUnitsPerWindow), \(bind: capacityProfile.limits.maxOutstandingFanoutUnits), \(bind: capacityProfile.limits.maxOutstandingPlans), \(bind: lease.leaseID), \(bind: lease.generation))").run()
            try await insertOperation(actorID: actorID, operationID: operationID, targetID: targetID, roomID: createdRoomID, createdAt: now, sql: sql)
            try await appendDirectRoomProfileProjection(recipientID: actorID, roomID: createdRoomID, profile: targetProfile, sourceEventID: operationID, createdAt: now, sql: sql)
            return .opened(.init(roomID: roomID, actorUserID: command.actorUserID, targetUserID: command.targetUserID, createdAt: now))
        }
        switch outcome {
        case .opened, .idempotent:
            let sourceEventID = try EventID(command.operationID.rawValue)
            _ = try await shadowForwarder.shadowIfForwarding(userID: command.actorUserID, sourceEventID: sourceEventID, projectionKinds: ["direct_room_profile"])
        case .idempotencyConflict, .unavailable:
            break
        }
        return outcome
    }

    public func setStrangerMessagePermission(command: V2SetStrangerMessagePermissionCommand, now: Date) async throws -> V2SetStrangerMessagePermissionOutcome {
        let outcome: V2SetStrangerMessagePermissionOutcome = try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let actorID = try directUUID(command.actorUserID)
            let operationID = try directUUID(command.operationID)
            let requested = command.permission == .allow
            if let existing = try await sql.raw("SELECT allows_stranger_messages, updated_at FROM im_v2.stranger_message_preference_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: DirectPreferenceOperationRow.self) {
                guard existing.allowsStrangerMessages == requested else { return .idempotencyConflict }
                return .idempotent(permission: existing.permission, updatedAt: existing.updatedAt)
            }
            try await sql.raw("INSERT INTO im_v2.user_stranger_message_preferences (user_id, allows_stranger_messages, updated_at) VALUES (\(bind: actorID), \(bind: requested), \(bind: now)) ON CONFLICT (user_id) DO UPDATE SET allows_stranger_messages = EXCLUDED.allows_stranger_messages, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.stranger_message_preference_operations (actor_user_id, operation_id, allows_stranger_messages, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: requested), \(bind: now))").run()
            guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: actorID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 RETURNING next_sequence").first(decoding: DirectSyncSequenceRow.self) else {
                throw V2DirectMessagingStoreError.corruptPersistenceState
            }
            try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: actorID), \(bind: sequence.nextSequence), \(bind: operationID), 'stranger_message_permission', jsonb_build_object('allows_stranger_messages', \(bind: requested), 'updated_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))), \(bind: now))").run()
            return .updated(permission: command.permission, updatedAt: now)
        }
        switch outcome {
        case .updated, .idempotent:
            _ = try await shadowForwarder.shadowIfForwarding(
                userID: command.actorUserID, sourceEventID: try .init(command.operationID.rawValue),
                projectionKinds: ["stranger_message_permission"]
            )
        case .idempotencyConflict:
            break
        }
        return outcome
    }

    public func setUserAddPermission(command: V2SetUserAddPermissionCommand, now: Date) async throws -> V2SetUserAddPermissionOutcome {
        let outcome: V2SetUserAddPermissionOutcome = try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2DirectMessagingStoreError.corruptPersistenceState }
            let actorID = try directUUID(command.actorUserID)
            let operationID = try directUUID(command.operationID)
            let requested = command.permission == .allow
            if let existing = try await sql.raw("SELECT allows_being_added, updated_at FROM im_v2.user_add_preference_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: DirectUserAddPreferenceOperationRow.self) {
                guard existing.allowsBeingAdded == requested else { return .idempotencyConflict }
                return .idempotent(permission: existing.permission, updatedAt: existing.updatedAt)
            }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: userAddPreferenceLockKey(actorID)), 0))").run()
            try await sql.raw("INSERT INTO im_v2.user_add_preferences (user_id, allows_being_added, updated_at) VALUES (\(bind: actorID), \(bind: requested), \(bind: now)) ON CONFLICT (user_id) DO UPDATE SET allows_being_added = EXCLUDED.allows_being_added, updated_at = EXCLUDED.updated_at").run()
            try await sql.raw("INSERT INTO im_v2.user_add_preference_operations (actor_user_id, operation_id, allows_being_added, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: requested), \(bind: now))").run()
            guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: actorID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 RETURNING next_sequence").first(decoding: DirectSyncSequenceRow.self) else {
                throw V2DirectMessagingStoreError.corruptPersistenceState
            }
            try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: actorID), \(bind: sequence.nextSequence), \(bind: operationID), 'user_add_permission', jsonb_build_object('allows_being_added', \(bind: requested), 'updated_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))), \(bind: now))").run()
            return .updated(permission: command.permission, updatedAt: now)
        }
        switch outcome {
        case .updated, .idempotent:
            _ = try await shadowForwarder.shadowIfForwarding(userID: command.actorUserID, sourceEventID: try .init(command.operationID.rawValue), projectionKinds: ["user_add_permission"])
        case .idempotencyConflict:
            break
        }
        return outcome
    }

    private func insertOperation(actorID: UUID, operationID: UUID, targetID: UUID, roomID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("INSERT INTO im_v2.direct_room_operations (actor_user_id, operation_id, target_user_id, room_id, created_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: targetID), \(bind: roomID), \(bind: createdAt))").run()
    }

    private func appendDirectRoomProfileProjection(recipientID: UUID, roomID: UUID, profile: DirectPublicProfileRow, sourceEventID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        guard profile.revision > 0 else { throw V2DirectMessagingStoreError.corruptPersistenceState }
        guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: recipientID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 RETURNING next_sequence").first(decoding: DirectSyncSequenceRow.self) else {
            throw V2DirectMessagingStoreError.corruptPersistenceState
        }
        // All room-event payloads use Foundation's canonical UUID spelling.
        // Do not let PostgreSQL's UUID-to-text conversion make direct-profile
        // records lexically differ from messages for the same room.
        let wireRoomID = roomID.uuidString
        let wireTargetUserID = profile.userID.uuidString
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: recipientID), \(bind: sequence.nextSequence), \(bind: sourceEventID), 'direct_room_profile', jsonb_build_object('room_id', \(bind: wireRoomID), 'target_user_id', \(bind: wireTargetUserID), 'public_handle', \(bind: profile.publicHandle), 'display_name', \(bind: profile.displayName), 'account_kind', \(bind: profile.accountKind), 'revision', \(bind: profile.revision), 'updated_at_ms', \(bind: Int64(profile.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: createdAt))").run()
    }
}

public enum V2DirectMessagingStoreError: Error, Equatable, Sendable { case corruptPersistenceState }

private struct DirectOperationRow: Decodable {
    let targetUserID: UUID; let roomID: UUID; let createdAt: Date
    enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id", roomID = "room_id", createdAt = "created_at" }
    func directRoom(actor: UserID, target: UserID) throws -> V2DirectRoom { .init(roomID: try .init(roomID.uuidString), actorUserID: actor, targetUserID: target, createdAt: createdAt) }
}
private struct DirectPairRow: Decodable {
    let roomID: UUID; let createdAt: Date; let capacityProfileID: String
    enum CodingKeys: String, CodingKey { case roomID = "room_id", createdAt = "created_at", capacityProfileID = "capacity_profile_id" }
    func directRoom(actor: UserID, target: UserID) throws -> V2DirectRoom { .init(roomID: try .init(roomID.uuidString), actorUserID: actor, targetUserID: target, createdAt: createdAt) }
}
private struct DirectCountRow: Decodable { let value: Int }
private struct DirectShardLeaseRow: Decodable {
    let leaseID: UUID; let generation: Int64; let validUntil: Date
    enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, validUntil = "valid_until" }
}
private struct DirectPreferenceOperationRow: Decodable {
    let allowsStrangerMessages: Bool; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case allowsStrangerMessages = "allows_stranger_messages", updatedAt = "updated_at" }
    var permission: V2StrangerMessagePermission { allowsStrangerMessages ? .allow : .deny }
}
private struct DirectUserAddPreferenceOperationRow: Decodable {
    let allowsBeingAdded: Bool; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case allowsBeingAdded = "allows_being_added", updatedAt = "updated_at" }
    var permission: V2UserAddPermission { allowsBeingAdded ? .allow : .deny }
}
private func userAddPreferenceLockKey(_ userID: UUID) -> String { "v2-user-add-preference:\(userID.uuidString.lowercased())" }
private struct DirectPublicProfileRow: Decodable {
    let userID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    let revision: Int64
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
        case revision
        case updatedAt = "updated_at"
    }
}
private struct DirectSyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private func directUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let result = UUID(uuidString: identifier.rawValue) else { throw V2DirectMessagingStoreError.corruptPersistenceState }; return result }
private func directPair(_ lhs: UUID, _ rhs: UUID) -> (lower: UUID, higher: UUID, lockKey: String) { let left = lhs.uuidString.lowercased(); let right = rhs.uuidString.lowercased(); return left < right ? (lhs, rhs, "\(left)|\(right)") : (rhs, lhs, "\(right)|\(left)") }
