import Foundation
import IMV2ActorContracts
import IMV2ServerApplication
import SQLKit
import NIOCore
import Synchronization

/// One statement reads versions and facts under the same MVCC snapshot.
/// No explicit transaction, ownership claim, or business read lock is needed.
struct PostgresV2PolicyFactsSnapshotReader: Sendable {
    let schema: String
    var metrics: V2SendOperationBatchMetrics? = nil

    func read(scopes: [V2PolicyAuthorizationScope], sql: any SQLDatabase) async throws -> [V2PolicyFactsSnapshot] {
        let inputs = scopes.map { scope -> (String, UUID, UUID) in
            switch scope {
            case .account(let user): return ("account", user, user)
            case .stranger(let user): return ("stranger", user, user)
            case .pair(let first, let second): return ("pair", first, second)
            }
        }
        let trace = V2SendPathTrace.current
        let startedAt = ContinuousClock.now
        let settledAt = Mutex<ContinuousClock.Instant?>(nil)
        let future: EventLoopFuture<[Row]> = sql.raw("""
            WITH requested AS (
                SELECT * FROM unnest(\(bind: scopes.map(\.key))::text[],
                    \(bind: inputs.map { $0.0 })::text[], \(bind: inputs.map { $0.1 })::uuid[],
                    \(bind: inputs.map { $0.2 })::uuid[]) WITH ORDINALITY
                    AS input(scope_key, kind, first_user, second_user, position)
            )
            SELECT input.position, COALESCE(scope.revision,1)::bigint AS revision, scope.pending_change_key,
                CASE WHEN input.kind='account' THEN COALESCE(profile.state='active',false)
                    AND NOT EXISTS(SELECT 1 FROM \(unsafeRaw: schema).account_disables WHERE user_id=input.first_user)
                    END AS active,
                special.account_kind AS special_kind, special.status AS special_status,
                special.allows_service_messages AS service, special.allows_customer_messages AS customer,
                CASE WHEN input.kind='pair' THEN EXISTS(SELECT 1 FROM \(unsafeRaw: schema).user_blocks
                    WHERE (blocker_user_id=input.first_user AND blocked_user_id=input.second_user)
                       OR (blocker_user_id=input.second_user AND blocked_user_id=input.first_user)) END AS blocked,
                CASE WHEN input.kind='pair' THEN EXISTS(SELECT 1 FROM \(unsafeRaw: schema).user_relationships
                    WHERE lower_user_id=LEAST(input.first_user,input.second_user)
                      AND higher_user_id=GREATEST(input.first_user,input.second_user) AND state='accepted') END AS friend,
                CASE WHEN input.kind='stranger' THEN COALESCE((SELECT allows_stranger_messages
                    FROM \(unsafeRaw: schema).user_stranger_message_preferences WHERE user_id=input.first_user),true) END AS strangers
            FROM requested input
            LEFT JOIN \(unsafeRaw: schema).policy_authorization_scopes scope ON scope.scope_key=input.scope_key
            LEFT JOIN \(unsafeRaw: schema).public_user_profiles profile ON input.kind='account' AND profile.user_id=input.first_user
            LEFT JOIN \(unsafeRaw: schema).special_accounts special ON input.kind='account' AND special.account_user_id=input.first_user
            ORDER BY input.position
            """).all(decoding: Row.self)
        let observed = future.always { _ in
            let endedAt = ContinuousClock.now
            settledAt.withLock { $0 = endedAt }
            metrics?.recordCompletedStage(.policySnapshotSQLFuture, duration: startedAt.duration(to: endedAt))
            trace?.record("policy_snapshot_sql_future", from: startedAt, to: endedAt)
        }
        let rows = try await observed.get()
        if let endedAt = settledAt.withLock({ $0 }) {
            let resumedAt = ContinuousClock.now
            metrics?.recordCompletedStage(.policySnapshotSQLResume, duration: endedAt.duration(to: resumedAt))
            trace?.record("policy_snapshot_sql_resume", from: endedAt, to: resumedAt)
        }
        guard rows.count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        guard rows.allSatisfy({ $0.pending_change_key == nil }) else { throw V2PolicyAuthorizationLifecycleError.busy }
        return try zip(scopes, rows).enumerated().map { index, entry in
            let (scope, row) = entry
            guard row.position == Int64(index + 1) else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            let facts: V2PolicyOwnerFacts
            switch scope {
            case .account(let user):
                guard let active = row.active else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                facts = .account(.init(userID: user, isActive: active, specialKind: row.special_kind,
                    specialStatus: row.special_status, allowsServiceMessages: row.service, allowsCustomerMessages: row.customer))
            case .pair:
                guard let blocked = row.blocked, let friend = row.friend else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                facts = .pair(.init(blocked: blocked, isFriend: friend))
            case .stranger(let user):
                guard let strangers = row.strangers else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                facts = .stranger(.init(userID: user, allowsStrangers: strangers))
            }
            return try .init(scope: scope, version: row.revision, facts: facts)
        }
    }

    private struct Row: Decodable, Sendable {
        let position: Int64
        let revision: Int64
        let pending_change_key: String?
        let active: Bool?
        let special_kind: String?
        let special_status: String?
        let service: Bool?
        let customer: Bool?
        let blocked: Bool?
        let friend: Bool?
        let strangers: Bool?
    }
}
