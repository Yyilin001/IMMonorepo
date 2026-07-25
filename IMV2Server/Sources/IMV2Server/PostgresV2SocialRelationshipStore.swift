import Fluent
import Foundation
import IMV2Core
import SQLKit

/// PostgreSQL authority for friendship and block state. All mutations for a
/// pair take the same advisory lock used by direct-room creation, so a block,
/// relationship transition and direct-message admission observe one coherent
/// ordering rather than a best-effort collection of reads.
public struct PostgresV2SocialRelationshipStore: V2SocialRelationshipStore {
    private let database: any Database
    private let shadowForwarder: (any V2UserShardProjectionShadowing)?

    public init(database: any Database, shadowForwarder: (any V2UserShardProjectionShadowing)? = nil) {
        self.database = database
        self.shadowForwarder = shadowForwarder
    }

    public func changeRelationship(_ command: V2ChangeRelationshipCommand, now: Date) async throws -> V2RelationshipOutcome {
        let outcome: V2RelationshipOutcome = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let actorID = try socialUUID(command.actorUserID)
            let targetID = try socialUUID(command.targetUserID)
            let operationID = try socialUUID(command.operationID)
            if let existing = try await sql.raw("SELECT target_user_id, action, resulting_state, updated_at FROM im_v2.user_relationship_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: RelationshipOperationRow.self) {
                guard existing.targetUserID == targetID, existing.action == command.action.rawValue else { return .idempotencyConflict }
                return .idempotent(try existing.change(actor: command.actorUserID, target: command.targetUserID))
            }

            let pair = socialPair(actorID, targetID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey), 0))").run()
            let blocked = try await isBlocked(actorID, targetID, sql: sql)
            guard !blocked else { return .forbidden }
            let existing = try await sql.raw("SELECT state, requested_by_user_id, updated_at FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher) FOR UPDATE").first(decoding: RelationshipRow.self)
            let result: (state: V2RelationshipState, requestedBy: UUID?)
            switch command.action {
            case .request:
                guard existing == nil else { return .invalidState }
                try await sql.raw("INSERT INTO im_v2.user_relationships (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at) VALUES (\(bind: pair.lower), \(bind: pair.higher), 'pending', \(bind: actorID), \(bind: now))").run()
                result = (.pending, actorID)
            case .accept:
                guard let existing, existing.state == "pending", existing.requestedByUserID == targetID else { return .invalidState }
                try await sql.raw("UPDATE im_v2.user_relationships SET state = 'accepted', updated_at = \(bind: now) WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)").run()
                result = (.accepted, nil)
            case .reject:
                guard let existing, existing.state == "pending", existing.requestedByUserID == targetID else { return .invalidState }
                try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)").run()
                result = (.none, nil)
            case .remove:
                guard existing != nil else { return .invalidState }
                try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)").run()
                result = (.none, nil)
            }
            try await sql.raw("INSERT INTO im_v2.user_relationship_operations (actor_user_id, operation_id, target_user_id, action, resulting_state, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: targetID), \(bind: command.action.rawValue), \(bind: result.state.rawValue), \(bind: now))").run()
            try await appendRelationshipProjection(userID: actorID, targetID: targetID, requestedBy: result.requestedBy, state: result.state, sourceEventID: operationID, now: now, sql: sql)
            try await appendRelationshipProjection(userID: targetID, targetID: actorID, requestedBy: result.requestedBy, state: result.state, sourceEventID: operationID, now: now, sql: sql)
            return .changed(.init(actorUserID: command.actorUserID, targetUserID: command.targetUserID, action: command.action, resultingState: result.state, updatedAt: now))
        }
        switch outcome {
        case .changed, .idempotent:
            try await shadow(users: [command.actorUserID, command.targetUserID], operationID: command.operationID.rawValue, kinds: ["relationship"])
        case .idempotencyConflict, .invalidState, .forbidden:
            break
        }
        return outcome
    }

    public func changeUserBlock(_ command: V2ChangeUserBlockCommand, now: Date) async throws -> V2UserBlockOutcome {
        let outcome: V2UserBlockOutcome = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let actorID = try socialUUID(command.actorUserID)
            let targetID = try socialUUID(command.targetUserID)
            let operationID = try socialUUID(command.operationID)
            if let existing = try await sql.raw("SELECT target_user_id, action, is_blocked, updated_at FROM im_v2.user_block_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: BlockOperationRow.self) {
                guard existing.targetUserID == targetID, existing.action == command.action.rawValue else { return .idempotencyConflict }
                return .idempotent(try existing.change(actor: command.actorUserID, target: command.targetUserID))
            }

            let pair = socialPair(actorID, targetID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey), 0))").run()
            var relationshipWasRemoved = false
            if command.action == .block {
                relationshipWasRemoved = try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher) RETURNING lower_user_id").first(decoding: DeletedRelationshipRow.self) != nil
                try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: actorID), \(bind: targetID), \(bind: now)) ON CONFLICT DO NOTHING").run()
            } else {
                try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id = \(bind: actorID) AND blocked_user_id = \(bind: targetID)").run()
            }
            let isBlocked = command.action == .block
            try await sql.raw("INSERT INTO im_v2.user_block_operations (actor_user_id, operation_id, target_user_id, action, is_blocked, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: targetID), \(bind: command.action.rawValue), \(bind: isBlocked), \(bind: now))").run()
            try await appendBlockProjection(userID: actorID, targetID: targetID, isBlocked: isBlocked, sourceEventID: operationID, now: now, sql: sql)
            if relationshipWasRemoved {
                // The target observes only an ordinary relation removal; it
                // cannot distinguish it from a user-initiated unfriend.
                try await appendRelationshipProjection(userID: actorID, targetID: targetID, requestedBy: nil, state: .none, sourceEventID: operationID, now: now, sql: sql)
                try await appendRelationshipProjection(userID: targetID, targetID: actorID, requestedBy: nil, state: .none, sourceEventID: operationID, now: now, sql: sql)
            }
            return .changed(.init(actorUserID: command.actorUserID, targetUserID: command.targetUserID, action: command.action, isBlocked: isBlocked, updatedAt: now))
        }
        switch outcome {
        case .changed, .idempotent:
            // A block may have also removed the relationship. Querying both
            // kinds is safe: the forwarder mirrors only rows actually written
            // by this source event for the named user.
            try await shadow(users: [command.actorUserID, command.targetUserID], operationID: command.operationID.rawValue, kinds: ["user_block", "relationship"])
        case .idempotencyConflict:
            break
        }
        return outcome
    }

    private func isBlocked(_ lhs: UUID, _ rhs: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_blocks WHERE (blocker_user_id = \(bind: lhs) AND blocked_user_id = \(bind: rhs)) OR (blocker_user_id = \(bind: rhs) AND blocked_user_id = \(bind: lhs))) AS value").first(decoding: SocialBooleanRow.self)?.value ?? true
    }

    private func appendRelationshipProjection(userID: UUID, targetID: UUID, requestedBy: UUID?, state: V2RelationshipState, sourceEventID: UUID, now: Date, sql: any SQLDatabase) async throws {
        guard let sequence = try await nextSyncSequence(userID: userID, sql: sql) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userID), \(bind: sequence), \(bind: sourceEventID), 'relationship', jsonb_build_object('target_user_id', \(bind: targetID)::text, 'state', \(bind: state.rawValue), 'requested_by_user_id', \(bind: requestedBy)::text, 'updated_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))), \(bind: now))").run()
    }

    private func appendBlockProjection(userID: UUID, targetID: UUID, isBlocked: Bool, sourceEventID: UUID, now: Date, sql: any SQLDatabase) async throws {
        guard let sequence = try await nextSyncSequence(userID: userID, sql: sql) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userID), \(bind: sequence), \(bind: sourceEventID), 'user_block', jsonb_build_object('target_user_id', \(bind: targetID)::text, 'is_blocked', \(bind: isBlocked), 'updated_at_ms', \(bind: Int64(now.timeIntervalSince1970 * 1_000))), \(bind: now))").run()
    }

    private func nextSyncSequence(userID: UUID, sql: any SQLDatabase) async throws -> Int64? {
        try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 RETURNING next_sequence").first(decoding: SocialSyncSequenceRow.self)?.nextSequence
    }

    private func shadow(users: [UserID], operationID: String, kinds: Set<String>) async throws {
        guard let shadowForwarder else { return }
        let eventID = try EventID(operationID)
        for userID in Set(users) {
            _ = try await shadowForwarder.shadowIfForwarding(userID: userID, sourceEventID: eventID, projectionKinds: kinds)
        }
    }
}

public enum V2SocialRelationshipStoreError: Error, Equatable, Sendable { case corruptPersistenceState }

private struct RelationshipRow: Decodable { let state: String; let requestedByUserID: UUID; let updatedAt: Date; enum CodingKeys: String, CodingKey { case state; case requestedByUserID = "requested_by_user_id"; case updatedAt = "updated_at" } }
private struct RelationshipOperationRow: Decodable {
    let targetUserID: UUID; let action: String; let resultingState: String; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case action; case resultingState = "resulting_state"; case updatedAt = "updated_at" }
    func change(actor: UserID, target: UserID) throws -> V2RelationshipChange { guard let action = V2RelationshipAction(rawValue: action), let state = V2RelationshipState(rawValue: resultingState) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }; return .init(actorUserID: actor, targetUserID: target, action: action, resultingState: state, updatedAt: updatedAt) }
}
private struct BlockOperationRow: Decodable {
    let targetUserID: UUID; let action: String; let isBlocked: Bool; let updatedAt: Date
    enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case action; case isBlocked = "is_blocked"; case updatedAt = "updated_at" }
    func change(actor: UserID, target: UserID) throws -> V2UserBlockChange { guard let action = V2UserBlockAction(rawValue: action) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }; return .init(actorUserID: actor, targetUserID: target, action: action, isBlocked: isBlocked, updatedAt: updatedAt) }
}
private struct DeletedRelationshipRow: Decodable { let lowerUserID: UUID; enum CodingKeys: String, CodingKey { case lowerUserID = "lower_user_id" } }
private struct SocialBooleanRow: Decodable { let value: Bool }
private struct SocialSyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private func socialUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let result = UUID(uuidString: identifier.rawValue) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }; return result }
private func socialPair(_ lhs: UUID, _ rhs: UUID) -> (lower: UUID, higher: UUID, lockKey: String) { let left = lhs.uuidString.lowercased(); let right = rhs.uuidString.lowercased(); return left < right ? (lhs, rhs, "\(left)|\(right)") : (rhs, lhs, "\(right)|\(left)") }
