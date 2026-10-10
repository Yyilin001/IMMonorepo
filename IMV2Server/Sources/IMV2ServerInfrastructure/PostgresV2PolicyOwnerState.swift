import Foundation
import FluentKit
import IMV2ServerApplication
import SQLKit

package struct V2PolicyAccountFacts: Codable, Equatable, Sendable {
    package let userID: UUID
    package let isActive: Bool
    package let specialKind: String?
    package let specialStatus: String?
    package let allowsServiceMessages: Bool?
    package let allowsCustomerMessages: Bool?
    var controlAccount: V2DirectSendControlAccount {
        .init(userID: userID, isActive: isActive, specialKind: specialKind, specialStatus: specialStatus,
            allowsServiceMessages: allowsServiceMessages, allowsCustomerMessages: allowsCustomerMessages)
    }
}
package struct V2PolicyPairFacts: Codable, Equatable, Sendable {
    package let blocked: Bool
    package let isFriend: Bool
}
package struct V2PolicyStrangerFacts: Codable, Equatable, Sendable {
    package let userID: UUID
    package let allowsStrangers: Bool
}
package enum V2PolicyOwnerFacts: Codable, Equatable, Sendable {
    case account(V2PolicyAccountFacts)
    case stranger(V2PolicyStrangerFacts)
    case pair(V2PolicyPairFacts)
}
/// Mutation facts are read while holding the scope and domain locks.
struct PostgresV2PolicyOwnerStateReader: Sendable {
    let schema: String
    func read(scope: V2PolicyAuthorizationScope, transaction: any Database) async throws -> V2PolicyOwnerFacts {
        guard transaction.inTransaction, let sql = transaction as? any SQLDatabase else {
            throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        switch scope {
        case .account(let user):
            try await v2AcquireOrderedDirectAuthorizationLocks(["account-state:" + user.uuidString], shared: true, sql: sql)
            // One round trip acquires both row-lock sets in the established
            // profile -> special-account order. Consume both CTEs, including
            // an empty special-account set. Facts are deliberately read by
            // the next statement, with a fresh snapshot after any lock wait.
            _ = try await sql.raw("""
                WITH profiles AS MATERIALIZED (
                    SELECT user_id FROM \(unsafeRaw: schema).public_user_profiles
                    WHERE user_id=\(bind: user) FOR SHARE
                ), specials AS MATERIALIZED (
                    SELECT account_user_id FROM \(unsafeRaw: schema).special_accounts
                    WHERE account_user_id=\(bind: user)
                        AND (SELECT count(*) FROM profiles)>=0
                    FOR SHARE
                )
                SELECT (SELECT count(*) FROM profiles)::bigint AS profiles,
                       (SELECT count(*) FROM specials)::bigint AS specials
                """).all()
            guard let row = try await sql.raw("""
                SELECT COALESCE(profile.state='active',false)
                    AND NOT EXISTS(SELECT 1 FROM \(unsafeRaw: schema).account_disables WHERE user_id=\(bind: user)) AS active,
                    special.account_kind AS kind, special.status,
                    special.allows_service_messages AS service, special.allows_customer_messages AS customer
                FROM (SELECT \(bind: user)::uuid AS user_id) input
                LEFT JOIN \(unsafeRaw: schema).public_user_profiles profile ON profile.user_id=input.user_id
                LEFT JOIN \(unsafeRaw: schema).special_accounts special ON special.account_user_id=input.user_id
                """).first(decoding: AccountRow.self) else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            return .account(.init(userID: user, isActive: row.active, specialKind: row.kind, specialStatus: row.status,
                allowsServiceMessages: row.service, allowsCustomerMessages: row.customer))
        case .stranger(let user):
            try await v2AcquireOrderedDirectAuthorizationLocks(["v2-stranger-message-preference:" + user.uuidString.lowercased()], shared: true, sql: sql)
            guard let row = try await sql.raw("SELECT COALESCE((SELECT allows_stranger_messages FROM \(unsafeRaw: schema).user_stranger_message_preferences WHERE user_id=\(bind: user)),true) AS strangers").first(decoding: StrangerRow.self) else {
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            return .stranger(.init(userID: user, allowsStrangers: row.strangers))
        case .pair(let first, let second):
            let key = [first, second].map { $0.uuidString.lowercased() }.sorted().joined(separator: "|")
            try await v2AcquireOrderedDirectAuthorizationLocks([key], shared: true, sql: sql)
            guard let row = try await sql.raw("""
                SELECT EXISTS(SELECT 1 FROM \(unsafeRaw: schema).user_blocks
                    WHERE (blocker_user_id=\(bind: first) AND blocked_user_id=\(bind: second))
                       OR (blocker_user_id=\(bind: second) AND blocked_user_id=\(bind: first))) AS blocked,
                    EXISTS(SELECT 1 FROM \(unsafeRaw: schema).user_relationships
                    WHERE lower_user_id=LEAST(\(bind: first)::uuid,\(bind: second)::uuid)
                      AND higher_user_id=GREATEST(\(bind: first)::uuid,\(bind: second)::uuid) AND state='accepted') AS friend
                """).first(decoding: PairRow.self) else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            return .pair(.init(blocked: row.blocked, isFriend: row.friend))
        }
    }
    private struct AccountRow: Decodable {
        let active: Bool; let kind: String?; let status: String?; let service: Bool?; let customer: Bool?
    }
    private struct StrangerRow: Decodable { let strangers: Bool }
    private struct PairRow: Decodable { let blocked: Bool; let friend: Bool }
}
