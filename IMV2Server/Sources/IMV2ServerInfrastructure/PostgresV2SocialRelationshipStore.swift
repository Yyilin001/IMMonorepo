import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 好友关系与拉黑状态的 PostgreSQL 权威实现。
///
/// 同一用户对的所有变更都会获取与私聊房间创建相同的咨询锁，
/// 因此拉黑、关系跃迁与私聊准入观察到的是同一份有序状态，而不是一组尽力而为的读取结果。
public struct PostgresV2SocialRelationshipStore: Sendable {
    private let database: any Database
    private let authorizationCoordinator: V2DirectAuthorizationCoordinator?
    private let projectionDelivery: any V2UserShardProjectionDelivering

    /// 组合数据库与当前用户分片投影投递器。
    ///
    /// - Parameters:
    ///   - database: 存放关系、拉黑与偏好设置的数据库。
    ///   - projectionDelivery: 用于把控制面投影投递到当前用户分片的实现。
    public init(database: any Database, projectionDelivery: any V2UserShardProjectionDelivering,
        authorizationCoordinator: V2DirectAuthorizationCoordinator? = nil) {
        self.database = database
        self.authorizationCoordinator = authorizationCoordinator
        self.projectionDelivery = projectionDelivery
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
    private func applyRelationship(_ command:V2ChangeRelationshipCommand,transaction:any Database,now:Date) async throws -> V2RelationshipOutcome {
            guard let sql = transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let actorID = try socialUUID(command.actorUserID)
            let targetID = try socialUUID(command.targetUserID)
            let operationID = try socialUUID(command.operationID)
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
                try await v2DrainDirectAuthorizations(.pair(actorID, targetID), coordinator: authorizationCoordinator, transaction: transaction, now: now)
                try await sql.raw("INSERT INTO im_v2.user_relationships (lower_user_id, higher_user_id, state, requested_by_user_id, updated_at) VALUES (\(bind: pair.lower), \(bind: pair.higher), 'pending', \(bind: actorID), \(bind: now))").run()
                result = (.pending, actorID)
            case .accept:
                guard let existing, existing.state == "pending", existing.requestedByUserID == targetID else { return .invalidState }
                try await v2DrainDirectAuthorizations(.pair(actorID, targetID), coordinator: authorizationCoordinator, transaction: transaction, now: now)
                try await sql.raw("UPDATE im_v2.user_relationships SET state = 'accepted', updated_at = \(bind: now) WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)").run()
                result = (.accepted, nil)
            case .reject:
                guard let existing, existing.state == "pending", existing.requestedByUserID == targetID else { return .invalidState }
                try await v2DrainDirectAuthorizations(.pair(actorID, targetID), coordinator: authorizationCoordinator, transaction: transaction, now: now)
                try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)").run()
                result = (.none, nil)
            case .remove:
                guard existing != nil else { return .invalidState }
                try await v2DrainDirectAuthorizations(.pair(actorID, targetID), coordinator: authorizationCoordinator, transaction: transaction, now: now)
                try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher)").run()
                result = (.none, nil)
            }
            try await advanceRevision(kind:.relationship,actor:actorID,target:targetID,sql:sql)
            let updatedAtMilliseconds = try v2GatewayMilliseconds(now)
            try await bumpDirectPairPolicyRevision(pair: pair, sql: sql)
            let sequences = try await reserveSyncSequences(
                counts: [actorID: 1, targetID: 1], sql: sql
            )
            guard let actorSequence = sequences[actorID]?.firstSequence,
                  let targetSequence = sequences[targetID]?.firstSequence
            else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            try await appendRelationshipProjection(userID: actorID, sequence: actorSequence, targetID: targetID, requestedBy: result.requestedBy, state: result.state, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
            try await appendRelationshipProjection(userID: targetID, sequence: targetSequence, targetID: actorID, requestedBy: result.requestedBy, state: result.state, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
            return .changed(.init(actorUserID:command.actorUserID,targetUserID:command.targetUserID,action:command.action,resultingState:result.state,updatedAt:now))
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
    private func applyUserBlock(_ command:V2ChangeUserBlockCommand,transaction:any Database,now:Date) async throws -> V2UserBlockOutcome {
            guard let sql = transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let actorID = try socialUUID(command.actorUserID)
            let targetID = try socialUUID(command.targetUserID)
            let operationID = try socialUUID(command.operationID)
            guard v2PostgresTimestampCanEncode(now) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let pair = socialPair(actorID, targetID)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: pair.lockKey), 0))").run()
            guard try await socialUserIsActive(actorID, sql: sql) else {
                throw V2SocialRelationshipStoreError.actorInactive
            }
            try await v2DrainDirectAuthorizations(.pair(actorID, targetID), coordinator: authorizationCoordinator, transaction: transaction, now: now)
            var relationshipWasRemoved = false
            if command.action == .block {
                relationshipWasRemoved = try await sql.raw("DELETE FROM im_v2.user_relationships WHERE lower_user_id = \(bind: pair.lower) AND higher_user_id = \(bind: pair.higher) RETURNING lower_user_id").first(decoding: DeletedRelationshipRow.self) != nil
                try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id, blocked_user_id, created_at) VALUES (\(bind: actorID), \(bind: targetID), \(bind: now)) ON CONFLICT DO NOTHING").run()
            } else {
                try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id = \(bind: actorID) AND blocked_user_id = \(bind: targetID)").run()
            }
            let isBlocked = command.action == .block
            try await advanceRevision(kind:.userBlock,actor:actorID,target:targetID,sql:sql)
            if relationshipWasRemoved { try await advanceRevision(kind:.relationship,actor:actorID,target:targetID,sql:sql) }
            let updatedAtMilliseconds = try v2GatewayMilliseconds(now)
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
                // 目标方只观察到普通的关系移除，
                // 无法将其与用户主动解除好友区分开。
                guard let targetSequence = sequences[targetID]?.firstSequence else {
                    throw V2SocialRelationshipStoreError.corruptPersistenceState
                }
                try await appendRelationshipProjection(userID: actorID, sequence: actorSequence + 1, targetID: targetID, requestedBy: nil, state: .none, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
                try await appendRelationshipProjection(userID: targetID, sequence: targetSequence, targetID: actorID, requestedBy: nil, state: .none, sourceEventID: operationID, updatedAtMilliseconds: updatedAtMilliseconds, now: now, sql: sql)
            }
            return .changed(.init(actorUserID:command.actorUserID,targetUserID:command.targetUserID,action:command.action,isBlocked:isBlocked,updatedAt:now))
    }

    private func isBlocked(_ lhs: UUID, _ rhs: UUID, sql: any SQLDatabase) async throws -> Bool {
        try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_blocks WHERE (blocker_user_id = \(bind: lhs) AND blocked_user_id = \(bind: rhs)) OR (blocker_user_id = \(bind: rhs) AND blocked_user_id = \(bind: lhs))) AS value").first(decoding: SocialBooleanRow.self)?.value ?? true
    }

    private func bumpDirectPairPolicyRevision(
        pair: (lower: UUID, higher: UUID, lockKey: String),
        sql: any SQLDatabase
    ) async throws {
        // 活跃的同址房间保留其修订围栏。冻结的源副本不可变：
        // 配置的目标发送会直接读取控制策略，因此撤销不能依赖修改该副本。
        // 与所有者写入一致，先取得房间锁，再取得关系锁。
        guard try await sql.raw("""
            WITH writable_room AS MATERIALIZED (
                SELECT room.room_id FROM im_v2.rooms room
                JOIN im_v2.direct_room_pairs pair ON pair.room_id = room.room_id
                WHERE pair.lower_user_id = \(bind: pair.lower) AND pair.higher_user_id = \(bind: pair.higher)

                FOR SHARE OF room
            ), candidate AS MATERIALIZED (
                SELECT pair.room_id FROM im_v2.direct_room_pairs pair
                JOIN writable_room ON writable_room.room_id = pair.room_id
                FOR UPDATE OF pair
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

    private func deliverProjection(users: [UserID], operationID: String, kinds: Set<String>) async throws {
        let eventID = try EventID(operationID)
        for userID in Set(users) {
            _ = try await projectionDelivery.deliverToCurrentShard(userID: userID, sourceEventID: eventID, projectionKinds: kinds)
        }
    }
}


private struct RelationshipRow: Decodable { let state: String; let requestedByUserID: UUID; let updatedAt: Date; enum CodingKeys: String, CodingKey { case state; case requestedByUserID = "requested_by_user_id"; case updatedAt = "updated_at" } }


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

extension PostgresV2SocialRelationshipStore {
    public func socialOperationSnapshot(actorUserID:UserID,targetUserID:UserID) async throws -> V2SocialOperationSnapshot {
        guard actorUserID != targetUserID else { throw V2SocialOperationValidationError.invalidSnapshot }
        return try await v2WithPostgresTransactionRetry(database:database) { transaction in
            guard let sql=transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let actor=try socialUUID(actorUserID),target=try socialUUID(targetUserID),pair=socialPair(actor,target)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:pair.lockKey),0))").run()
            guard try await socialUserIsActive(actor,sql:sql) else { throw V2SocialRelationshipStoreError.actorInactive }
            let relation=try await sql.raw("SELECT state,requested_by_user_id,updated_at FROM im_v2.user_relationships WHERE lower_user_id=\(bind:pair.lower) AND higher_user_id=\(bind:pair.higher)").first(decoding:RelationshipRow.self)
            let state=relation.flatMap{V2RelationshipState(rawValue:$0.state)} ?? .none
            if relation != nil,state == .none { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let blocked=try await sql.raw("SELECT EXISTS(SELECT 1 FROM im_v2.user_blocks WHERE blocker_user_id=\(bind:actor) AND blocked_user_id=\(bind:target)) AS value").first(decoding:SocialBooleanRow.self)?.value ?? false
            return try await V2SocialOperationSnapshot(actorUserID:actorUserID,targetUserID:targetUserID,relationshipState:state,requestedByUserID:state == .pending ? relation.map{UserID(uuid:$0.requestedByUserID)}:nil,relationshipRevision:revision(kind:.relationship,actor:actor,target:target,sql:sql),isBlocked:blocked,blockRevision:revision(kind:.userBlock,actor:actor,target:target,sql:sql))
        }
    }
    public func submitSocialOperation(_ command:V2SocialOperationCommand,now:Date) async throws -> V2SocialOperationRecoveryResult {
        let started=ContinuousClock.now
        let result:V2SocialOperationRecoveryResult = try await v2WithPostgresTransactionRetry(database:database) { transaction in
            guard let sql=transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            try await lockSocialOperation(command.identity,sql:sql)
            if let prior=try await socialOriginal(command.identity,fingerprint:command.fingerprint,sql:sql) { return prior }
            guard v2PostgresTimestampCanEncode(now),let normalized=try await sql.raw("SELECT \(bind:now)::timestamptz AS value").first(decoding:SocialDateRow.self) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            var clock=normalized.value
            var ms=try v2GatewayMilliseconds(clock)
            guard ms>0 else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            let window=V2CommandPolicy.registered(for:command.identity.kind).firstSubmissionWindowMilliseconds!
            if command.firstSubmissionDeadlineMilliseconds<=UInt64(ms) { return .receipt(try await socialPersist(command.identity,command.fingerprint,.rejected(.firstSubmissionExpired),at:UInt64(ms),sql:sql)) }
            if command.firstSubmissionDeadlineMilliseconds-UInt64(ms)>window { return .receipt(try await socialPersist(command.identity,command.fingerprint,.rejected(.invalidDeadline),at:UInt64(ms),sql:sql)) }
            let actor=try socialUUID(command.actorUserID),target=try socialUUID(command.targetUserID),pair=socialPair(actor,target)
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:pair.lockKey),0))").run()
            let elapsed=started.duration(to:.now).components
            clock=now.addingTimeInterval(Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18)
            ms=try v2GatewayMilliseconds(clock)
            guard ms>0 else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            if command.firstSubmissionDeadlineMilliseconds<=UInt64(ms) { return .receipt(try await socialPersist(command.identity,command.fingerprint,.rejected(.firstSubmissionExpired),at:UInt64(ms),sql:sql)) }
            guard try await socialUserIsActive(actor,sql:sql) else { return .receipt(try await socialPersist(command.identity,command.fingerprint,.rejected(.permissionDenied),at:UInt64(ms),sql:sql)) }
            let observed=try await revision(kind:command.identity.kind,actor:actor,target:target,sql:sql)
            guard observed==command.expectedRevision else { return .receipt(try await socialPersist(command.identity,command.fingerprint,.rejected(.revisionConflict(currentRevision:observed)),at:UInt64(ms),sql:sql)) }
            let outcome:V2SocialOperationTerminalOutcome
            switch command.action {
            case .relationship(let action):
                switch try await applyRelationship(.init(actorUserID:command.actorUserID,operationID:.init(command.identity.operation.rawOperationID),targetUserID:command.targetUserID,action:action),transaction:transaction,now:clock) {
                case .changed(let value):outcome = .applied(.relationship(state:value.resultingState,revision:observed+1))
                case .invalidState:outcome = .rejected(.invalidState)
                case .forbidden:outcome = .rejected(.permissionDenied)
                case .idempotent,.idempotencyConflict:throw V2SocialRelationshipStoreError.corruptPersistenceState
                }
            case .userBlock(let action):
                switch try await applyUserBlock(.init(actorUserID:command.actorUserID,operationID:.init(command.identity.operation.rawOperationID),targetUserID:command.targetUserID,action:action),transaction:transaction,now:clock) {
                case .changed(let value):outcome = .applied(.userBlock(isBlocked:value.isBlocked,revision:observed+1))
                case .idempotent,.idempotencyConflict:throw V2SocialRelationshipStoreError.corruptPersistenceState
                }
            }
            let receipt=try await socialPersist(command.identity,command.fingerprint,outcome,at:UInt64(ms),sql:sql)
            guard receipt.validates(command:command) else { throw V2SocialOperationValidationError.invalidReceipt }
            return .receipt(receipt)
        }
        if case .receipt(let receipt)=result,case .applied=receipt.outcome {
            try await deliverProjection(users:[command.actorUserID,command.targetUserID],operationID:command.identity.operation.rawOperationID,kinds:["relationship","user_block"])
        }
        return result
    }
    public func recoverSocialOperation(_ request:V2SocialOperationRecoveryRequest,now:Date) async throws -> V2SocialOperationRecoveryResult {
        let result:V2SocialOperationRecoveryResult = try await v2WithPostgresTransactionRetry(database:database) { transaction in
            guard let sql=transaction as? any SQLDatabase else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            try await lockSocialOperation(request.identity,sql:sql)
            if let prior=try await socialOriginal(request.identity,fingerprint:request.fingerprint,sql:sql) { return prior }
            guard request.action == .closeIfAbsent else { return .unresolved }
            let ms=try v2GatewayMilliseconds(now)
            guard ms>0 else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
            return .receipt(try await socialPersist(request.identity,request.fingerprint,.closed,at:UInt64(ms),sql:sql))
        }
        if case .receipt(let receipt)=result,case .applied=receipt.outcome,case .userPair(let actor,let target)=request.identity.scope {
            try await deliverProjection(users:[actor,target],operationID:request.identity.operation.rawOperationID,kinds:["relationship","user_block"])
        }
        return result
    }
    private func lockSocialOperation(_ identity:V2OperationIdentity,sql:any SQLDatabase) async throws {
        guard case .userPair(let actor,let target)=identity.scope,actor==identity.accountID,actor != target,actor.uuidValue != nil,target.uuidValue != nil,let op=UUID(uuidString:identity.operation.rawOperationID) else { throw V2SocialOperationValidationError.invalidCommand }
        let key="v2-social-operation:"+identity.kind.rawValue+":"+actor.uuidValue!.uuidString.lowercased()+":"+op.uuidString.lowercased()
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind:key),0))").run()
    }
    private func socialOriginal(_ identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,sql:any SQLDatabase) async throws -> V2SocialOperationRecoveryResult? {
        guard let row=try await sql.raw("SELECT receipt::text AS payload FROM im_v2.social_operation_receipts WHERE actor_user_id=\(bind:identity.accountID.uuidValue!) AND operation_id=\(bind:UUID(uuidString:identity.operation.rawOperationID)!) AND kind=\(bind:identity.kind.rawValue)").first(decoding:SocialReceiptRow.self) else { return nil }
        let receipt=try JSONDecoder().decode(V2SocialOperationReceipt.self,from:Data(row.payload.utf8))
        guard receipt.identity==identity,receipt.fingerprint==fingerprint else { return .fingerprintConflict };return .receipt(receipt)
    }
    private func socialPersist(_ identity:V2OperationIdentity,_ fingerprint:V2OperationFingerprint,_ outcome:V2SocialOperationTerminalOutcome,at:UInt64,sql:any SQLDatabase) async throws -> V2SocialOperationReceipt {
        let receipt=try V2SocialOperationReceipt(identity:identity,fingerprint:fingerprint,outcome:outcome,resolvedAtMilliseconds:at)
        let json=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        try await sql.raw("INSERT INTO im_v2.social_operation_receipts(actor_user_id,operation_id,kind,receipt) VALUES(\(bind:identity.accountID.uuidValue!),\(bind:UUID(uuidString:identity.operation.rawOperationID)!),\(bind:identity.kind.rawValue),\(bind:json)::jsonb)").run();return receipt
    }
    private func revision(kind:V2OperationKind,actor:UUID,target:UUID,sql:any SQLDatabase) async throws -> UInt64 {
        let pair=socialPair(actor,target)
        let value:Int64
        if kind == .relationship { value=try await sql.raw("SELECT revision AS value FROM im_v2.social_relationship_revisions WHERE lower_user_id=\(bind:pair.lower) AND higher_user_id=\(bind:pair.higher)").first(decoding:SocialRevisionRow.self)?.value ?? 0 }
        else { value=try await sql.raw("SELECT revision AS value FROM im_v2.social_block_revisions WHERE actor_user_id=\(bind:actor) AND target_user_id=\(bind:target)").first(decoding:SocialRevisionRow.self)?.value ?? 0 }
        guard value>=0 else { throw V2SocialRelationshipStoreError.corruptPersistenceState };return UInt64(value)
    }
    private func advanceRevision(kind:V2OperationKind,actor:UUID,target:UUID,sql:any SQLDatabase) async throws {
        let pair=socialPair(actor,target)
        if kind == .relationship { try await sql.raw("INSERT INTO im_v2.social_relationship_revisions(lower_user_id,higher_user_id,revision) VALUES(\(bind:pair.lower),\(bind:pair.higher),1) ON CONFLICT(lower_user_id,higher_user_id) DO UPDATE SET revision=im_v2.social_relationship_revisions.revision+1").run() }
        else { try await sql.raw("INSERT INTO im_v2.social_block_revisions(actor_user_id,target_user_id,revision) VALUES(\(bind:actor),\(bind:target),1) ON CONFLICT(actor_user_id,target_user_id) DO UPDATE SET revision=im_v2.social_block_revisions.revision+1").run() }
    }
}
private struct SocialDateRow:Decodable { let value:Date }
private struct SocialRevisionRow:Decodable { let value:Int64 }
private struct SocialReceiptRow:Decodable { let payload:String }
