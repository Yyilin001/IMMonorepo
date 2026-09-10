import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 好友关系与拉黑状态的 PostgreSQL 权威实现。
///
/// 同一用户对的所有变更都会获取与私聊房间创建相同的咨询锁，
/// 因此拉黑、关系跃迁与私聊准入观察到的是同一份有序状态，而不是一组尽力而为的读取结果。
public struct PostgresV2SocialRelationshipStore: V2SocialRelationshipStore {
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing

    /// 组合数据库与投影影子转发器。
    ///
    /// - Parameters:
    ///   - database: 存放关系、拉黑与偏好设置的数据库。
    ///   - shadowForwarder: 用于把投影变更转发到影子用户分片的实现。
    public init(database: any Database, shadowForwarder: any V2UserShardProjectionShadowing) {
        self.database = database
        self.shadowForwarder = shadowForwarder
    }

    /// 应用一次关系变更。
    ///
    /// 先按发起者与操作标识串行化并处理幂等，再按用户对加锁。事务内会确认发起者账号有效，
    /// 对请求与接受动作额外校验目标账号有效，检查双向拉黑；发起好友请求时还会读取目标的
    /// 被添加偏好，偏好被锁定后按同一顺序继续处理。
    ///
    /// - Parameters:
    ///   - command: 关系变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 关系变更结果。
    /// - Throws: 标识非法、时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2SocialRelationshipStoreError/corruptPersistenceState``；
    ///   发起者账号无效时抛出 ``V2SocialRelationshipStoreError/actorInactive``。
    public func changeRelationship(_ command: V2ChangeRelationshipCommand, now: Date) async throws -> V2RelationshipOutcome {
        let outcome: V2RelationshipOutcome = try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let actorID = try socialUUID(command.actorUserID)
            let targetID = try socialUUID(command.targetUserID)
            let operationID = try socialUUID(command.operationID)
            try await lockOperation(actor: actorID, operation: operationID, kind: "relationship", sql: sql)
            if let existing = try await sql.raw("SELECT target_user_id, action, resulting_state, updated_at FROM im_v2.user_relationship_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: RelationshipOperationRow.self) {
                guard existing.targetUserID == targetID, existing.action == command.action.rawValue else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(existing.updatedAt) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
                return .idempotent(try existing.change(actor: command.actorUserID, target: command.targetUserID))
            }

            guard v2PostgresTimestampCanEncode(now) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let pair = socialPair(actorID, targetID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey), 0))").run()
            guard try await socialUserIsActive(actorID, sql: sql) else {
                throw V2SocialRelationshipStoreError.actorInactive
            }
            if command.action == .request || command.action == .accept {
                guard try await socialUserIsActive(targetID, sql: sql) else { return .forbidden }
            }
            let blocked = try await isBlocked(actorID, targetID, sql: sql)
            guard !blocked else { return .forbidden }
            if command.action == .request {
                try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: socialUserAddPreferenceLockKey(targetID)), 0))").run()
                let allowsBeingAdded = try await sql.raw("SELECT COALESCE((SELECT allows_being_added FROM im_v2.user_add_preferences WHERE user_id = \(bind: targetID)), TRUE) AS value").first(decoding: SocialBooleanRow.self)?.value ?? false
                guard allowsBeingAdded else { return .forbidden }
            }
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
            guard let persisted = try await sql.raw("INSERT INTO im_v2.user_relationship_operations (actor_user_id, operation_id, target_user_id, action, resulting_state, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: targetID), \(bind: command.action.rawValue), \(bind: result.state.rawValue), \(bind: now)) RETURNING target_user_id, action, resulting_state, updated_at").first(decoding: RelationshipOperationRow.self) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let updatedAtMilliseconds = try v2GatewayMilliseconds(persisted.updatedAt)
            try await bumpDirectPairPolicyRevision(pair: pair, sql: sql)
            let sequences = try await reserveSyncSequences(
                counts: [actorID: 1, targetID: 1], sql: sql
            )
            guard let actorSequence = sequences[actorID]?.firstSequence,
                  let targetSequence = sequences[targetID]?.firstSequence
            else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            try await appendRelationshipProjection(userID: actorID, sequence: actorSequence, targetID: targetID, requestedBy: result.requestedBy, state: result.state, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
            try await appendRelationshipProjection(userID: targetID, sequence: targetSequence, targetID: actorID, requestedBy: result.requestedBy, state: result.state, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
            return .changed(try persisted.change(actor: command.actorUserID, target: command.targetUserID))
        }
        switch outcome {
        case .changed, .idempotent:
            try await shadow(users: [command.actorUserID, command.targetUserID], operationID: command.operationID.rawValue, kinds: ["relationship"])
        case .idempotencyConflict, .invalidState, .forbidden:
            break
        }
        return outcome
    }

    /// 应用一次用户拉黑变更。
    ///
    /// 与关系变更共用同一用户对锁与幂等记录语义，保证拉黑与好友关系不会出现互相矛盾的提交。
    ///
    /// - Parameters:
    ///   - command: 拉黑变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 拉黑变更结果。
    /// - Throws: 标识非法、时刻不可编码或连接不支持 SQL 时抛出
    ///   ``V2SocialRelationshipStoreError/corruptPersistenceState``；
    ///   发起者账号无效时抛出 ``V2SocialRelationshipStoreError/actorInactive``。
    public func changeUserBlock(_ command: V2ChangeUserBlockCommand, now: Date) async throws -> V2UserBlockOutcome {
        let outcome: V2UserBlockOutcome = try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let actorID = try socialUUID(command.actorUserID)
            let targetID = try socialUUID(command.targetUserID)
            let operationID = try socialUUID(command.operationID)
            try await lockOperation(actor: actorID, operation: operationID, kind: "block", sql: sql)
            if let existing = try await sql.raw("SELECT target_user_id, action, is_blocked, updated_at FROM im_v2.user_block_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: BlockOperationRow.self) {
                guard existing.targetUserID == targetID, existing.action == command.action.rawValue else { return .idempotencyConflict }
                guard v2PostgresTimestampCanEncode(existing.updatedAt) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
                return .idempotent(try existing.change(actor: command.actorUserID, target: command.targetUserID))
            }

            guard v2PostgresTimestampCanEncode(now) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let pair = socialPair(actorID, targetID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey), 0))").run()
            guard try await socialUserIsActive(actorID, sql: sql) else {
                throw V2SocialRelationshipStoreError.actorInactive
            }
            var relationshipWasRemoved = false
            if command.action == .block {
                relationshipWasRemoved = try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher) RETURNING lower_user_id").first(decoding: DeletedRelationshipRow.self) != nil
                try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: actorID), \(bind: targetID), \(bind: now)) ON CONFLICT DO NOTHING").run()
            } else {
                try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id = \(bind: actorID) AND blocked_user_id = \(bind: targetID)").run()
            }
            let isBlocked = command.action == .block
            guard let persisted = try await sql.raw("INSERT INTO im_v2.user_block_operations (actor_user_id, operation_id, target_user_id, action, is_blocked, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: targetID), \(bind: command.action.rawValue), \(bind: isBlocked), \(bind: now)) RETURNING target_user_id, action, is_blocked, updated_at").first(decoding: BlockOperationRow.self) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let updatedAtMilliseconds = try v2GatewayMilliseconds(persisted.updatedAt)
            try await bumpDirectPairPolicyRevision(pair: pair, sql: sql)
            let sequences = try await reserveSyncSequences(
                counts: relationshipWasRemoved
                    ? [actorID: 2, targetID: 1]
                    : [actorID: 1],
                sql: sql
            )
            guard let actorSequence = sequences[actorID]?.firstSequence else {
                throw V2SocialRelationshipStoreError.corruptPersistenceState
            }
            try await appendBlockProjection(userID: actorID, sequence: actorSequence, targetID: targetID, isBlocked: isBlocked, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
            if relationshipWasRemoved {
                // The target observes only an ordinary relation removal; it
                // cannot distinguish it from a user-initiated unfriend.
                guard let targetSequence = sequences[targetID]?.firstSequence else {
                    throw V2SocialRelationshipStoreError.corruptPersistenceState
                }
                try await appendRelationshipProjection(userID: actorID, sequence: actorSequence + 1, targetID: targetID, requestedBy: nil, state: .none, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
                try await appendRelationshipProjection(userID: targetID, sequence: targetSequence, targetID: actorID, requestedBy: nil, state: .none, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
            }
            return .changed(try persisted.change(actor: command.actorUserID, target: command.targetUserID))
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

    private func lockOperation(actor: UUID, operation: UUID, kind: String, sql: any SQLDatabase) async throws {
        // Pair locks protect relationship state; this lock protects the
        // actor-scoped replay record before checking state or the clock.
        let key = "v2-social-operation:" + kind + ":" + actor.uuidString.lowercased() + ":" + operation.uuidString.lowercased()
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    private func isBlocked(_ lhs: UUID, _ rhs: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_blocks WHERE (blocker_user_id = \(bind: lhs) AND blocked_user_id = \(bind: rhs)) OR (blocker_user_id = \(bind: rhs) AND blocked_user_id = \(bind: lhs))) AS value").first(decoding: SocialBooleanRow.self)?.value ?? true
    }

    private func bumpDirectPairPolicyRevision(
        pair: (lower: UUID, higher: UUID, lockKey: String),
        sql: any SQLDatabase
    ) async throws {
        // Send acceptance locks the same pair row. This serializes a social
        // mutation with cached-policy admission and makes the revision a real
        // fence instead of a best-effort invalidation hint.
        guard try await sql.raw("""
            WITH candidate AS MATERIALIZED (
                SELECT room_id FROM im_v2.direct_room_pairs
                WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)
                FOR UPDATE
            ), advanced AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET direct_policy_revision = pair.direct_policy_revision + 1
                FROM candidate
                WHERE pair.room_id = candidate.room_id
                  AND pair.direct_policy_revision < \(bind: Int64.max)
                RETURNING pair.room_id
            )
            SELECT (SELECT count(*) FROM candidate) = (SELECT count(*) FROM advanced) AS value
            """).first(decoding: SocialBooleanRow.self)?.value == true else {
            throw V2SocialRelationshipStoreError.corruptPersistenceState
        }
    }

    private func appendRelationshipProjection(userID: UUID, sequence: Int64, targetID: UUID, requestedBy: UUID?, state: V2RelationshipState, sourceEventID: UUID, updatedAtMilliseconds: Int64, now: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userID), \(bind: sequence), \(bind: sourceEventID), 'relationship', jsonb_build_object('target_user_id', \(bind: targetID)::text, 'state', \(bind: state.rawValue), 'requested_by_user_id', \(bind: requestedBy)::text, 'updated_at_ms', \(bind: updatedAtMilliseconds)), \(bind: now))").run()
    }

    private func appendBlockProjection(userID: UUID, sequence: Int64, targetID: UUID, isBlocked: Bool, sourceEventID: UUID, updatedAtMilliseconds: Int64, now: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userID), \(bind: sequence), \(bind: sourceEventID), 'user_block', jsonb_build_object('target_user_id', \(bind: targetID)::text, 'is_blocked', \(bind: isBlocked), 'updated_at_ms', \(bind: updatedAtMilliseconds)), \(bind: now))").run()
    }

    /// 按 UUID 顺序预留每个用户的序号区间。
    ///
    /// 任何需要多个用户序号的事务都必须使用单条有序语句，
    /// 这样方向相反的发起者/目标命令不会以相反顺序获取同一批行，从而避免死锁。
    ///
    /// - Parameters:
    ///   - counts: 每个用户本次需要预留的序号数量。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Returns: 每个用户对应的序号预留结果。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    private func reserveSyncSequences(
        counts: [UUID: Int], sql: any SQLDatabase
    ) async throws -> [UUID: SocialSequenceReservationRow] {
        guard !counts.isEmpty, counts.values.allSatisfy({ $0 > 0 }) else {
            throw V2SocialRelationshipStoreError.corruptPersistenceState
        }
        let inputs = counts.map {
            SocialSequenceReservationInput(userID: $0.key, sequenceCount: $0.value)
        }.sorted { $0.userID.uuidString < $1.userID.uuidString }
        let data = try JSONEncoder().encode(inputs)
        guard let json = String(data: data, encoding: .utf8) else {
            throw V2SocialRelationshipStoreError.corruptPersistenceState
        }
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT user_id, sequence_count
                FROM jsonb_to_recordset(\(bind: json)::jsonb)
                     AS value(user_id uuid, sequence_count bigint)
            ), reserved AS (
                INSERT INTO im_v2.user_sync_sequences AS sequence (user_id, next_sequence)
                SELECT user_id, sequence_count
                FROM requested
                ORDER BY user_id
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = sequence.next_sequence + EXCLUDED.next_sequence
                WHERE sequence.next_sequence <= \(bind: Int64.max) - EXCLUDED.next_sequence
                RETURNING user_id, next_sequence
            )
            SELECT reserved.user_id,
                   reserved.next_sequence - requested.sequence_count + 1 AS first_sequence,
                   reserved.next_sequence AS last_sequence
            FROM reserved
            JOIN requested USING (user_id)
            """).all(decoding: SocialSequenceReservationRow.self)
        guard rows.count == inputs.count else {
            throw V2SocialRelationshipStoreError.corruptPersistenceState
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.userID, $0) })
    }

    private func shadow(users: [UserID], operationID: String, kinds: Set<String>) async throws {
        let eventID = try EventID(operationID)
        for userID in Set(users) {
            _ = try await shadowForwarder.shadowIfForwarding(userID: userID, sourceEventID: eventID, projectionKinds: kinds)
        }
    }
}

/// 社交关系存储错误。
public enum V2SocialRelationshipStoreError: Error, Equatable, Sendable {
    /// 发起者账号当前无效。
    case actorInactive
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

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
private struct SocialSequenceReservationInput: Encodable {
    let userID: UUID
    let sequenceCount: Int
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case sequenceCount = "sequence_count"
    }
}
private struct SocialSequenceReservationRow: Decodable {
    let userID: UUID
    let firstSequence: Int64
    let lastSequence: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case firstSequence = "first_sequence"
        case lastSequence = "last_sequence"
    }
}
private func socialUserIsActive(_ userID: UUID, sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.public_user_profiles AS profile WHERE profile.user_id = \(bind: userID) AND profile.state = 'active' AND NOT EXISTS (SELECT 1 FROM im_v2.account_disables AS disabled WHERE disabled.user_id = profile.user_id)) AS value").first(decoding: SocialBooleanRow.self)?.value ?? false
}
private func socialUUID<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let result = UUID(uuidString: identifier.rawValue) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }; return result }
private func socialPair(_ lhs: UUID, _ rhs: UUID) -> (lower: UUID, higher: UUID, lockKey: String) { let left = lhs.uuidString.lowercased(); let right = rhs.uuidString.lowercased(); return left < right ? (lhs, rhs, "\(left)|\(right)") : (rhs, lhs, "\(right)|\(left)") }
private func socialUserAddPreferenceLockKey(_ userID: UUID) -> String { "v2-user-add-preference:\(userID.uuidString.lowercased())" }
