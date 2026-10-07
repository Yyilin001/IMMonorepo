import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 这里只处理控制侧事实。房间回复标记、成员关系和配额仍属所有者事实。
/// 易变值只在持锁事务内有效；事务外使用必须绑定持久化授权尝试，
/// 或在策略依赖封口锁下原子登记的可撤销许可。
struct V2DirectSendControlPolicy: Codable, Equatable, Sendable {
    let sender: V2DirectSendControlAccount
    let recipient: V2DirectSendControlAccount
    let blocked: Bool
    let isFriend: Bool
    let allowsStrangers: Bool
    /// Scope versions distinguish a policy changed and restored between sends.
    var stateVersions: [String: Int64]? = nil
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

/// 在有序策略锁下读取控制侧事实，供持久化授权预留使用。
struct V2DirectSendControlPolicyFence: Sendable {
    let database: any Database
    let schema: String

    init(database: any Database, schema: String = "im_v2") {
        precondition(schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil)
        self.database = database
        self.schema = schema
    }

    /// 在此事务中持久化授权义务，并在启动所有者工作前提交。
    /// 仅靠控制侧锁无法跨越连接丢失。
    func withLockedPolicies<Result: Sendable>(
        pairs: [V2DirectSendControlPair],
        operation: @escaping @Sendable (any Database, [V2DirectSendControlPair: V2DirectSendControlPolicy]) async throws -> Result
    ) async throws -> Result {
        try await database.transaction { transaction in
            let policies = try await self.readLockedPolicies(pairs: pairs, transaction: transaction)
            return try await operation(transaction, policies)
        }
    }

    /// Cold-load callers supply the lease-registration transaction. Existing
    /// policy locks remain necessary until every mutation writer uses scope seals.
    func readLockedPolicies(pairs: [V2DirectSendControlPair], transaction: any Database) async throws
        -> [V2DirectSendControlPair: V2DirectSendControlPolicy] {
        guard transaction.inTransaction else { throw V2DirectSendControlPolicyError.nonSQLDatabase }
        guard !pairs.isEmpty, pairs.count <= 128 else { throw V2DirectSendControlPolicyError.invalidBatch }
        guard pairs.allSatisfy({ $0.sender != $0.recipient }) else { throw V2DirectSendControlPolicyError.invalidPair }
        let uniquePairs = Set(pairs)
        let users = Set(pairs.flatMap { [$0.sender, $0.recipient] }).sorted { $0.uuidString < $1.uuidString }
        let pairKeys = Set(pairs.map(\.canonicalKey)).sorted()
        let usersJSON = String(decoding: try JSONEncoder().encode(users.map(\.uuidString)), as: UTF8.self)
        let pairsJSON = String(decoding: try JSONEncoder().encode(uniquePairs.map {
            ["sender_id": $0.sender.uuidString, "recipient_id": $0.recipient.uuidString]
        }), as: UTF8.self)
        guard let sql = transaction as? any SQLDatabase else {
            throw V2DirectSendControlPolicyError.nonSQLDatabase
        }
        // Preserve the revocation writers' namespace and acquisition order:
        // all account locks, canonical pair locks, then preference locks.
        let lockNames = users.map { "account-state:" + $0.uuidString }
            + pairKeys + users.map { "v2-stranger-message-preference:" + $0.uuidString.lowercased() }
        try await v2AcquireOrderedDirectAuthorizationLocks(lockNames, shared: true, sql: sql)
        // Both row-lock sets are consumed, including the empty-special case.
        // The dependency retains profile -> special-account lock order.
        _ = try await sql.raw("""
            WITH profiles AS MATERIALIZED (
              SELECT user_id FROM \(unsafeRaw: schema).public_user_profiles
              WHERE user_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: usersJSON)::jsonb))
              ORDER BY user_id FOR SHARE
            ), specials AS MATERIALIZED (
              SELECT account_user_id FROM \(unsafeRaw: schema).special_accounts
              WHERE account_user_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: usersJSON)::jsonb))
                AND (SELECT count(*) FROM profiles)>=0
              ORDER BY account_user_id FOR SHARE
            )
            SELECT (SELECT count(*) FROM profiles)::bigint AS profiles,
                   (SELECT count(*) FROM specials)::bigint AS specials
            """).all()
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
        return policies
    }
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
