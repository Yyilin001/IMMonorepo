import Fluent
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

enum V2DirectAuthorizationIntentError: Error, Equatable, Sendable {
    case invalidRequest, identityConflict, generationExhausted, corruptPersistence
}

enum V2DirectAuthorizationRevocationScope: Sendable {
    case user(UUID)
    case pair(UUID, UUID)
}

/// The row is also its recovery job. A lease expires; a held authorization does
/// not. Transport failure never releases it and never creates a new generation.
struct PostgresV2DirectAuthorizationIntentStore: Sendable {
    let database: any Database
    let schema: String

    init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database; self.schema = schema
    }

    /// Only a fresh foreground request may renew a durably aborted attempt.
    /// Batch reservations, policy facts and recovery jobs commit atomically.
    /// The returned grants must never be used before this method returns.
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
                var byKey: [String: V2DirectAuthorizationGrant] = [:]
                for request in ordered {
                    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-direct-authorization:" + request.operationKey), 0))").run()
                    guard let policy = policies[request.pair] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                    let prior = try await lookup(request.attempt(generation: 1), sql: sql, lock: true)
                    if let prior {
                        guard prior.attempt.recipientID == request.recipientID, prior.attempt.fingerprint == request.fingerprint else {
                            throw V2DirectAuthorizationIntentError.identityConflict
                        }
                        // Retry the original owner, epoch, generation and facts.
                        // Do not silently transplant an uncertain attempt.
                        if prior.receipt?.disposition != .aborted {
                            byKey[request.operationKey] = prior
                            continue
                        }
                        guard prior.attempt.generation < Int64.max else { throw V2DirectAuthorizationIntentError.generationExhausted }
                        guard now >= prior.updatedAt else { throw V2DirectAuthorizationIntentError.invalidRequest }
                    }
                    let policyJSON = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
                    if let prior {
                        try await sql.raw("""
                            UPDATE \(unsafeRaw: schema).direct_authorization_intents
                            SET generation = generation + 1, owner_shard_id = \(bind: request.ownerShardID),
                                owner_epoch = \(bind: request.ownerEpoch), policy = \(bind: policyJSON)::jsonb,
                                disposition = NULL, event_id = NULL, attempt_created_at = \(bind: now),
                                updated_at = \(bind: now), next_check_at = \(bind: nextCheck),
                                lease_token = NULL, lease_until = NULL, attempt_count = 0
                            WHERE room_id = \(bind: request.roomID) AND sender_user_id = \(bind: request.senderID)
                              AND client_message_id = \(bind: request.clientMessageID) AND generation = \(bind: prior.attempt.generation)
                              AND disposition = 'aborted'
                            """).run()
                    } else {
                        try await sql.raw("""
                            INSERT INTO \(unsafeRaw: schema).direct_authorization_intents
                                (room_id, sender_user_id, client_message_id, recipient_user_id, request_fingerprint,
                                 generation, owner_shard_id, owner_epoch, policy, created_at, attempt_created_at,
                                 updated_at, next_check_at)
                            VALUES (\(bind: request.roomID), \(bind: request.senderID), \(bind: request.clientMessageID),
                                \(bind: request.recipientID), \(bind: request.fingerprint), 1, \(bind: request.ownerShardID),
                                \(bind: request.ownerEpoch), \(bind: policyJSON)::jsonb, \(bind: now), \(bind: now),
                                \(bind: now), \(bind: nextCheck))
                            """).run()
                    }
                    guard let result = try await lookup(request.attempt(generation: 1), sql: sql, lock: false) else {
                        throw V2DirectAuthorizationIntentError.corruptPersistence
                    }
                    byKey[request.operationKey] = result
                }
                return try requests.map {
                    guard let grant = byKey[$0.operationKey] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
                    return grant
                }
            }
    }

    /// Only the exact owner terminal proof settles a generation. Late workers
    /// cannot release a newer attempt or replace a different terminal result.
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

    /// The caller must already hold the control policy's exclusive lock. This
    /// bounded read does not lock intent rows while owner I/O runs: resolution
    /// on a separate control connection must survive a failed revocation txn.
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

    /// Locate a previously bound operation for terminal replay. This never
    /// reserves, renews or changes its policy; callers still need an exact owner
    /// proof before acknowledging an unresolved generation.
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
