import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import SQLKit

struct V2DirectAuthorizationRequest: Sendable {
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let recipientID: UUID
    let ownerShardID: String
    let ownerEpoch: Int64
    let fingerprint: Data

    var pair: V2DirectSendControlPair { .init(sender: senderID, recipient: recipientID) }
    var operationKey: String {
        [roomID, senderID, clientMessageID].map { $0.uuidString.lowercased() }.joined(separator: ":")
    }
    func attempt(generation: Int64) -> V2DirectAuthorizationAttempt {
        .init(roomID: roomID, senderID: senderID, clientMessageID: clientMessageID, generation: generation,
            recipientID: recipientID, ownerShardID: ownerShardID, ownerEpoch: ownerEpoch, fingerprint: fingerprint)
    }
}

struct V2DirectAuthorizationGrant: Sendable {
    let attempt: V2DirectAuthorizationAttempt
    let policy: V2DirectSendControlPolicy
    let receipt: V2DirectAuthorizationReceipt?
    let createdAt: Date
    let attemptCreatedAt: Date
    let updatedAt: Date
    let nextCheckAt: Date
    let leaseToken: UUID?
    let leaseUntil: Date?
    let attemptCount: Int64
}


enum V2DirectAuthorizationRevocationScope: Sendable {
    case user(UUID)
    case pair(UUID, UUID)
}

/// 此记录本身也是恢复任务。租约会过期，已持有的授权不会。
/// 传输故障既不释放授权，也不创建新代次。
struct PostgresV2DirectAuthorizationIntentStore: Sendable {
    let database: any Database
    let schema: String

    init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database; self.schema = schema
    }

    /// 只有新的前台请求可重启已持久化中止的尝试。
    /// 批量预留、策略事实和恢复任务原子提交。
    /// 此方法返回前，绝不能使用返回的授权许可。
    func reserve(_ requests: [V2DirectAuthorizationRequest], now: Date) async throws -> [V2DirectAuthorizationGrant] {
        guard !requests.isEmpty, requests.count <= 128,
              Set(requests.map(\.operationKey)).count == requests.count,
              let nextCheck = v2PostgresFutureTimestamp(now: now, interval: 30) else {
            throw V2DirectAuthorizationIntentError.invalidRequest
        }
        for request in requests { try request.attempt(generation: 1).validate() }
        let ordered = requests.sorted { $0.operationKey < $1.operationKey }
        return try await V2DirectSendControlPolicyFence(database: database, schema: schema)
            .withLockedPolicies(pairs: requests.map(\.pair)) { transaction, policies in
                let sql = try sqlDatabase(transaction)
                try await v2AcquireOrderedDirectAuthorizationLocks(
                    ordered.map { "v2-direct-authorization:" + $0.operationKey }, shared: false, sql: sql)
                let keysJSON = String(decoding: try JSONEncoder().encode(ordered.map(DirectIntentBatchKey.init)), as: UTF8.self)
                let priorRows = try await sql.raw("""
                    SELECT intent.*, intent.policy::text AS policy_json
                    FROM \(unsafeRaw: schema).direct_authorization_intents intent
                    JOIN jsonb_to_recordset(\(bind: keysJSON)::jsonb)
                      AS input(room_id uuid,sender_user_id uuid,client_message_id uuid)
                      ON intent.room_id=input.room_id AND intent.sender_user_id=input.sender_user_id
                     AND intent.client_message_id=input.client_message_id
                    ORDER BY intent.room_id,intent.sender_user_id,intent.client_message_id FOR UPDATE OF intent
                    """).all(decoding: IntentRow.self)
                var priorByKey: [String: V2DirectAuthorizationGrant] = [:]
                for row in priorRows {
                    let grant = try row.grant(), key = directIntentOperationKey(grant.attempt)
                    guard priorByKey.updateValue(grant, forKey: key) == nil else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                }
                var byKey: [String: V2DirectAuthorizationGrant] = [:]
                var mutations: [DirectIntentBatchMutation] = []
                for request in ordered {
                    guard let policy = policies[request.pair] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                    let prior = priorByKey[request.operationKey]
                    if let prior {
                        guard prior.attempt.recipientID == request.recipientID, prior.attempt.fingerprint == request.fingerprint else {
                            throw V2DirectAuthorizationIntentError.identityConflict
                        }
                        // An unresolved or accepted/denied attempt keeps its
                        // exact original owner, generation and frozen policy.
                        if prior.receipt?.disposition != .aborted {
                            byKey[request.operationKey] = prior
                            continue
                        }
                        guard prior.attempt.generation < Int64.max else { throw V2DirectAuthorizationIntentError.generationExhausted }
                        guard now >= prior.updatedAt else { throw V2DirectAuthorizationIntentError.invalidRequest }
                    }
                    mutations.append(.init(request: request, policy: policy, previousGeneration: prior?.attempt.generation))
                }
                if !mutations.isEmpty {
                    let mutationJSON = String(decoding: try JSONEncoder().encode(mutations), as: UTF8.self)
                    // Fresh and aborted identities form disjoint sets. No
                    // ON CONFLICT ignore can silently drop an obligation.
                    // RETURNING is the authoritative new grant; there is no
                    // per-command post-write lookup or provisional return.
                    let changedRows = try await sql.raw("""
                        WITH input AS MATERIALIZED (
                          SELECT * FROM jsonb_to_recordset(\(bind: mutationJSON)::jsonb)
                            AS item(room_id uuid,sender_user_id uuid,client_message_id uuid,recipient_user_id uuid,
                              request_fingerprint text,owner_shard_id text,owner_epoch bigint,policy jsonb,previous_generation bigint)
                        ), inserted AS (
                          INSERT INTO \(unsafeRaw: schema).direct_authorization_intents
                            (room_id,sender_user_id,client_message_id,recipient_user_id,request_fingerprint,generation,
                             owner_shard_id,owner_epoch,policy,created_at,attempt_created_at,updated_at,next_check_at)
                          SELECT room_id,sender_user_id,client_message_id,recipient_user_id,decode(request_fingerprint,'base64'),1,
                                 owner_shard_id,owner_epoch,policy,\(bind: now),\(bind: now),\(bind: now),\(bind: nextCheck)
                          FROM input WHERE previous_generation IS NULL
                          ORDER BY room_id,sender_user_id,client_message_id
                          RETURNING *
                        ), restarted AS (
                          UPDATE \(unsafeRaw: schema).direct_authorization_intents intent
                          SET generation=input.previous_generation+1,owner_shard_id=input.owner_shard_id,
                              owner_epoch=input.owner_epoch,policy=input.policy,disposition=NULL,event_id=NULL,
                              attempt_created_at=\(bind: now),updated_at=\(bind: now),next_check_at=\(bind: nextCheck),
                              lease_token=NULL,lease_until=NULL,attempt_count=0
                          FROM input
                          WHERE input.previous_generation IS NOT NULL AND intent.room_id=input.room_id
                            AND intent.sender_user_id=input.sender_user_id AND intent.client_message_id=input.client_message_id
                            AND intent.generation=input.previous_generation AND intent.disposition='aborted'
                            AND intent.recipient_user_id=input.recipient_user_id
                            AND intent.request_fingerprint=decode(input.request_fingerprint,'base64')
                          RETURNING intent.*
                        )
                        SELECT inserted.*,inserted.policy::text AS policy_json FROM inserted
                        UNION ALL SELECT restarted.*,restarted.policy::text AS policy_json FROM restarted
                        """).all(decoding: IntentRow.self)
                    guard changedRows.count == mutations.count else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                    let expected = Dictionary(uniqueKeysWithValues: mutations.map { ($0.request.operationKey, $0) })
                    for row in changedRows {
                        let grant = try row.grant(), key = directIntentOperationKey(grant.attempt)
                        guard let mutation = expected[key], byKey[key] == nil,
                              grant.attempt == mutation.request.attempt(generation: (mutation.previousGeneration ?? 0)+1),
                              grant.policy == mutation.policy, grant.receipt == nil else {
                            throw V2DirectAuthorizationIntentError.corruptPersistence
                        }
                        byKey[key] = grant
                    }
                }
                return try requests.map {
                    guard let grant = byKey[$0.operationKey] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                    return grant
                }
            }
    }

    /// 只有精确的所有者终态证明才能结算某个代次。
    /// 迟到的工作器不能释放较新的尝试，也不能替换其他终态结果。
    @discardableResult
    func resolve(_ attempt: V2DirectAuthorizationAttempt, receipt: V2DirectAuthorizationReceipt, now: Date) async throws -> Bool {
        try attempt.validate()
        guard v2PostgresTimestampCanEncode(now), (receipt.disposition == .aborted) == (receipt.eventID == nil) else {
            throw V2DirectAuthorizationIntentError.invalidRequest
        }
        return try await database.transaction { transaction in
            let sql = try sqlDatabase(transaction)
            guard let current = try await lookup(attempt, sql: sql, lock: true) else {
                throw V2DirectAuthorizationIntentError.identityConflict
            }
            guard current.attempt.generation == attempt.generation else { return false }
            guard current.attempt == attempt else { throw V2DirectAuthorizationIntentError.identityConflict }
            if let prior = current.receipt { return prior == receipt }
            guard now >= current.updatedAt else { throw V2DirectAuthorizationIntentError.invalidRequest }
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).direct_authorization_intents
                SET disposition = \(bind: receipt.disposition.rawValue), event_id = \(bind: receipt.eventID),
                    updated_at = \(bind: now), lease_token = NULL, lease_until = NULL
                WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
                  AND client_message_id = \(bind: attempt.clientMessageID) AND generation = \(bind: attempt.generation)
                  AND disposition IS NULL
                """).run()
            return true
        }
    }

    /// 调用方必须已持有控制策略独占锁。所有者 I/O 期间，
    /// 此有界读取不锁定意图记录：独立控制连接上的解析操作
    /// 必须在撤销事务失败后仍能保留结果。
    func held(in scope: V2DirectAuthorizationRevocationScope, limit: Int, transaction: any Database) async throws -> [V2DirectAuthorizationGrant] {
        guard transaction.inTransaction, (1...128).contains(limit) else { throw V2DirectAuthorizationIntentError.invalidRequest }
        let predicate: SQLQueryString
        switch scope {
        case .user(let user):
            predicate = "(sender_user_id = \(bind: user) OR recipient_user_id = \(bind: user))"
        case .pair(let first, let second):
            guard first != second else { throw V2DirectAuthorizationIntentError.invalidRequest }
            predicate = "((sender_user_id = \(bind: first) AND recipient_user_id = \(bind: second)) OR (sender_user_id = \(bind: second) AND recipient_user_id = \(bind: first)))"
        }
        let sql = try sqlDatabase(transaction)
        return try await sql.raw("""
            SELECT *, policy::text AS policy_json FROM \(unsafeRaw: schema).direct_authorization_intents
            WHERE disposition IS NULL AND \(predicate)
            ORDER BY room_id, sender_user_id, client_message_id LIMIT \(bind: limit)
            """).all(decoding: IntentRow.self).map { try $0.grant() }
    }

    func claim(limit: Int, now: Date, lease: TimeInterval = 30) async throws -> [V2DirectAuthorizationGrant] {
        guard (1...100).contains(limit), let until = v2PostgresFutureTimestamp(now: now, interval: lease) else {
            throw V2DirectAuthorizationIntentError.invalidRequest
        }
        let sql = try sqlDatabase(database), token = UUID()
        return try await sql.raw("""
            WITH candidates AS (
                SELECT room_id, sender_user_id, client_message_id
                FROM \(unsafeRaw: schema).direct_authorization_intents
                WHERE disposition IS NULL AND next_check_at <= \(bind: now)
                  AND (lease_token IS NULL OR lease_until <= \(bind: now))
                ORDER BY next_check_at, room_id, sender_user_id, client_message_id
                FOR UPDATE SKIP LOCKED LIMIT \(bind: limit)
            )
            UPDATE \(unsafeRaw: schema).direct_authorization_intents intent
            SET lease_token = \(bind: token), lease_until = \(bind: until),
                attempt_count = CASE WHEN intent.attempt_count < 9223372036854775807 THEN intent.attempt_count + 1 ELSE intent.attempt_count END
            FROM candidates
            WHERE intent.room_id = candidates.room_id AND intent.sender_user_id = candidates.sender_user_id
              AND intent.client_message_id = candidates.client_message_id
            RETURNING intent.*, intent.policy::text AS policy_json
            """).all(decoding: IntentRow.self).map { try $0.grant() }
    }

    func deferClaim(_ grant: V2DirectAuthorizationGrant, now: Date) async throws {
        guard let token = grant.leaseToken,
              let next = v2PostgresFutureTimestamp(now: now, interval: min(60, Double(min(grant.attemptCount, 6)) * 10)) else {
            throw V2DirectAuthorizationIntentError.invalidRequest
        }
        let sql = try sqlDatabase(database), attempt = grant.attempt
        try await sql.raw("""
            UPDATE \(unsafeRaw: schema).direct_authorization_intents
            SET lease_token = NULL, lease_until = NULL, next_check_at = \(bind: next)
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID) AND generation = \(bind: attempt.generation)
              AND lease_token = \(bind: token) AND disposition IS NULL
            """).run()
    }

    /// 查找此前已绑定的操作，供终态重放使用。
    /// 此方法既不预留、续期，也不修改策略；确认未解决的代次前，
    /// 调用方仍须取得精确的所有者证明。
    func existing(roomID: UUID, senderID: UUID, clientMessageID: UUID) async throws -> V2DirectAuthorizationGrant? {
        let sql = try sqlDatabase(database)
        return try await sql.raw("""
            SELECT *, policy::text AS policy_json FROM \(unsafeRaw: schema).direct_authorization_intents
            WHERE room_id = \(bind: roomID) AND sender_user_id = \(bind: senderID)
              AND client_message_id = \(bind: clientMessageID)
            """).first(decoding: IntentRow.self)?.grant()
    }

    private func lookup(_ attempt: V2DirectAuthorizationAttempt, sql: any SQLDatabase, lock: Bool) async throws -> V2DirectAuthorizationGrant? {
        try await sql.raw("""
            SELECT *, policy::text AS policy_json FROM \(unsafeRaw: schema).direct_authorization_intents
            WHERE room_id = \(bind: attempt.roomID) AND sender_user_id = \(bind: attempt.senderID)
              AND client_message_id = \(bind: attempt.clientMessageID) \(unsafeRaw: lock ? "FOR UPDATE" : "")
            """).first(decoding: IntentRow.self)?.grant()
    }
    private func sqlDatabase(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2DirectAuthorizationIntentError.corruptPersistence }
        return sql
    }
}

private struct IntentRow: Decodable {
    let roomID: UUID; let senderUserID: UUID; let clientMessageID: UUID; let recipientUserID: UUID
    let generation: Int64; let ownerShardID: String; let ownerEpoch: Int64; let requestFingerprint: Data
    let policyJSON: String; let disposition: V2DirectAuthorizationDisposition?; let eventID: UUID?
    let createdAt: Date; let attemptCreatedAt: Date; let updatedAt: Date; let nextCheckAt: Date
    let leaseToken: UUID?; let leaseUntil: Date?; let attemptCount: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", senderUserID = "sender_user_id", clientMessageID = "client_message_id"
        case recipientUserID = "recipient_user_id", generation, ownerShardID = "owner_shard_id", ownerEpoch = "owner_epoch"
        case requestFingerprint = "request_fingerprint", policyJSON = "policy_json", disposition, eventID = "event_id"
        case createdAt = "created_at", attemptCreatedAt = "attempt_created_at", updatedAt = "updated_at", nextCheckAt = "next_check_at"
        case leaseToken = "lease_token", leaseUntil = "lease_until", attemptCount = "attempt_count"
    }
    func grant() throws -> V2DirectAuthorizationGrant {
        let attempt = V2DirectAuthorizationAttempt(roomID: roomID, senderID: senderUserID, clientMessageID: clientMessageID,
            generation: generation, recipientID: recipientUserID, ownerShardID: ownerShardID, ownerEpoch: ownerEpoch,
            fingerprint: requestFingerprint)
        try attempt.validate()
        let policy = try JSONDecoder().decode(V2DirectSendControlPolicy.self, from: Data(policyJSON.utf8))
        guard policy.sender.userID == senderUserID, policy.recipient.userID == recipientUserID,
              [createdAt, attemptCreatedAt, updatedAt, nextCheckAt].allSatisfy(v2PostgresTimestampCanEncode),
              createdAt <= attemptCreatedAt, attemptCreatedAt <= updatedAt, attemptCount >= 0,
              (leaseToken == nil) == (leaseUntil == nil), leaseUntil.map(v2PostgresTimestampCanEncode) ?? true,
              (disposition == nil || disposition == .aborted) == (eventID == nil),
              disposition == nil || leaseToken == nil else { throw V2DirectAuthorizationIntentError.corruptPersistence }
        return .init(attempt: attempt, policy: policy, receipt: disposition.map { .init(disposition: $0, eventID: eventID) },
            createdAt: createdAt, attemptCreatedAt: attemptCreatedAt, updatedAt: updatedAt, nextCheckAt: nextCheckAt,
            leaseToken: leaseToken, leaseUntil: leaseUntil, attemptCount: attemptCount)
    }
}

private func directIntentOperationKey(_ attempt: V2DirectAuthorizationAttempt) -> String {
    [attempt.roomID, attempt.senderID, attempt.clientMessageID].map { $0.uuidString.lowercased() }.joined(separator: ":")
}
private struct DirectIntentBatchKey: Encodable {
    let roomID: UUID; let senderID: UUID; let clientID: UUID
    init(_ request: V2DirectAuthorizationRequest) { roomID=request.roomID; senderID=request.senderID; clientID=request.clientMessageID }
    enum CodingKeys: String, CodingKey { case roomID="room_id",senderID="sender_user_id",clientID="client_message_id" }
}
private struct DirectIntentBatchMutation: Encodable {
    let request: V2DirectAuthorizationRequest
    let policy: V2DirectSendControlPolicy
    let previousGeneration: Int64?
    enum CodingKeys: String, CodingKey {
        case roomID="room_id",senderID="sender_user_id",clientID="client_message_id",recipientID="recipient_user_id",
             fingerprint="request_fingerprint",ownerShard="owner_shard_id",ownerEpoch="owner_epoch",policy,previousGeneration="previous_generation"
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(request.roomID,forKey:.roomID)
        try values.encode(request.senderID,forKey:.senderID)
        try values.encode(request.clientMessageID,forKey:.clientID)
        try values.encode(request.recipientID,forKey:.recipientID)
        try values.encode(request.fingerprint.base64EncodedString(),forKey:.fingerprint)
        try values.encode(request.ownerShardID,forKey:.ownerShard)
        try values.encode(request.ownerEpoch,forKey:.ownerEpoch)
        try values.encode(policy,forKey:.policy)
        try values.encodeIfPresent(previousGeneration,forKey:.previousGeneration)
    }
}
