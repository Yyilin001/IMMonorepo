import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Control facts only. Room reply markers, membership and quota remain owner facts.
/// A volatile value is valid only inside withPolicy's callback. Persisted facts
/// may be used outside it only with their exact durable authorization attempt.
struct V2DirectSendControlPolicy: Codable, Equatable, Sendable {
    let sender: V2DirectSendControlAccount
    let recipient: V2DirectSendControlAccount
    let blocked: Bool
    let isFriend: Bool
    let allowsStrangers: Bool
}

struct V2DirectSendControlAccount: Codable, Equatable, Sendable {
    let userID: UUID
    let isActive: Bool
    let specialKind: String?
    let specialStatus: String?
    let allowsServiceMessages: Bool?
    let allowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", isActive = "is_active"
        case specialKind = "special_kind", specialStatus = "special_status"
        case allowsServiceMessages = "allows_service_messages"
        case allowsCustomerMessages = "allows_customer_messages"
    }
}

struct V2DirectSendControlPair: Hashable, Sendable {
    let sender: UUID
    let recipient: UUID

    var canonicalKey: String {
        [sender, recipient].map { $0.uuidString.lowercased() }.sorted().joined(separator: "|")
    }
}

/// With a healthy connection, hold control locks through the owner commit.
/// Connection loss can release them while the owner callback is still running;
/// this is not a durable distributed authorization boundary (D07 remains open).
/// All users and canonical pairs in a batch are locked in one stable order,
/// before entering owner transactions. Gateway binds an independent control pool.
struct V2DirectSendControlPolicyFence: Sendable {
    let database: any Database
    let schema: String

    init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    func withPolicy<Result: Sendable>(
        senderID: UserID, recipientID: UserID,
        operation: @escaping @Sendable (V2DirectSendControlPolicy) async throws -> Result
    ) async throws -> Result {
        guard let sender = senderID.uuidValue, let recipient = recipientID.uuidValue else {
            throw V2DirectSendControlPolicyError.invalidPair
        }
        let pair = V2DirectSendControlPair(sender: sender, recipient: recipient)
        return try await withPolicies(pairs: [pair]) { policies in
            guard let policy = policies[pair] else { throw V2DirectSendControlPolicyError.corruptPersistence }
            return try await operation(policy)
        }
    }

    func withPolicies<Result: Sendable>(
        pairs: [V2DirectSendControlPair],
        operation: @escaping @Sendable ([V2DirectSendControlPair: V2DirectSendControlPolicy]) async throws -> Result
    ) async throws -> Result {
        try await withLockedPolicies(pairs: pairs) { _, policies in
            try await operation(policies)
        }
    }

    /// Persist authorization obligations inside this transaction. Return only
    /// after its commit, before starting any owner work. The old withPolicies
    /// callback alone remains unsuitable as a durable cross-database boundary.
    func withLockedPolicies<Result: Sendable>(
        pairs: [V2DirectSendControlPair],
        operation: @escaping @Sendable (any Database, [V2DirectSendControlPair: V2DirectSendControlPolicy]) async throws -> Result
    ) async throws -> Result {
        guard !pairs.isEmpty, pairs.count <= 128 else { throw V2DirectSendControlPolicyError.invalidBatch }
        guard pairs.allSatisfy({ $0.sender != $0.recipient }) else { throw V2DirectSendControlPolicyError.invalidPair }
        let uniquePairs = Set(pairs)
        let users = Set(pairs.flatMap { [$0.sender, $0.recipient] }).sorted { $0.uuidString < $1.uuidString }
        let pairKeys = Set(pairs.map(\.canonicalKey)).sorted()
        let usersJSON = String(decoding: try JSONEncoder().encode(users.map(\.uuidString)), as: UTF8.self)
        let pairsJSON = String(decoding: try JSONEncoder().encode(uniquePairs.map {
            ["sender_id": $0.sender.uuidString, "recipient_id": $0.recipient.uuidString]
        }), as: UTF8.self)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2DirectSendControlPolicyError.nonSQLDatabase
            }
            // Match actual writers' exact lock names; never nest per-pair scopes.
            for user in users {
                let key = "account-state:" + user.uuidString
                try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: key), 0))").run()
            }
            for key in pairKeys {
                try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: key), 0))").run()
            }
            for user in users {
                let key = "v2-stranger-message-preference:" + user.uuidString.lowercased()
                try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: key), 0))").run()
            }
            try await sql.raw("""
                SELECT user_id FROM \(unsafeRaw: schema).public_user_profiles
                WHERE user_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: usersJSON)::jsonb))
                ORDER BY user_id FOR SHARE
                """).run()
            try await sql.raw("""
                SELECT account_user_id FROM \(unsafeRaw: schema).special_accounts
                WHERE account_user_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: usersJSON)::jsonb))
                ORDER BY account_user_id FOR SHARE
                """).run()
            let accounts = try await sql.raw("""
                SELECT input.user_id,
                    COALESCE(profile.state = 'active', false)
                        AND NOT EXISTS (SELECT 1 FROM \(unsafeRaw: schema).account_disables disabled
                            WHERE disabled.user_id = input.user_id) AS is_active,
                    special.account_kind AS special_kind, special.status AS special_status,
                    special.allows_service_messages, special.allows_customer_messages
                FROM (SELECT value::uuid AS user_id
                    FROM jsonb_array_elements_text(\(bind: usersJSON)::jsonb)) input
                LEFT JOIN \(unsafeRaw: schema).public_user_profiles profile ON profile.user_id = input.user_id
                LEFT JOIN \(unsafeRaw: schema).special_accounts special ON special.account_user_id = input.user_id
                """).all(decoding: V2DirectSendControlAccount.self)
            guard accounts.count == users.count else { throw V2DirectSendControlPolicyError.corruptPersistence }
            let byUser = Dictionary(uniqueKeysWithValues: accounts.map { ($0.userID, $0) })
            let rows = try await sql.raw("""
                SELECT input.sender_id, input.recipient_id,
                EXISTS (
                    SELECT 1 FROM \(unsafeRaw: schema).user_blocks
                    WHERE (blocker_user_id = input.sender_id AND blocked_user_id = input.recipient_id)
                       OR (blocker_user_id = input.recipient_id AND blocked_user_id = input.sender_id)
                ) AS blocked,
                EXISTS (SELECT 1 FROM \(unsafeRaw: schema).user_relationships
                    WHERE lower_user_id = LEAST(input.sender_id, input.recipient_id)
                      AND higher_user_id = GREATEST(input.sender_id, input.recipient_id)
                      AND state = 'accepted') AS is_friend,
                COALESCE((SELECT allows_stranger_messages FROM \(unsafeRaw: schema).user_stranger_message_preferences
                    WHERE user_id = input.recipient_id), true) AS allows_strangers
                FROM jsonb_to_recordset(\(bind: pairsJSON)::jsonb) AS input(sender_id uuid, recipient_id uuid)
                """).all(decoding: DirectControlPairRow.self)
            var policies: [V2DirectSendControlPair: V2DirectSendControlPolicy] = [:]
            for row in rows {
                guard let from = byUser[row.senderID], let to = byUser[row.recipientID] else {
                    throw V2DirectSendControlPolicyError.corruptPersistence
                }
                policies[.init(sender: row.senderID, recipient: row.recipientID)] = .init(
                    sender: from, recipient: to, blocked: row.blocked,
                    isFriend: row.isFriend, allowsStrangers: row.allowsStrangers)
            }
            guard Set(policies.keys) == uniquePairs else { throw V2DirectSendControlPolicyError.corruptPersistence }
            return try await operation(transaction, policies)
        }
    }
}

enum V2DirectSendControlPolicyError: Error {
    case invalidPair, invalidBatch, nonSQLDatabase, corruptPersistence
}

private struct DirectControlPairRow: Decodable {
    let senderID: UUID
    let recipientID: UUID
    let blocked: Bool
    let isFriend: Bool
    let allowsStrangers: Bool
    enum CodingKeys: String, CodingKey {
        case senderID = "sender_id", recipientID = "recipient_id"
        case blocked, isFriend = "is_friend", allowsStrangers = "allows_strangers"
    }
}
