import Foundation
import IMV2ActorContracts
import FluentKit
import IMV2ServerApplication
import SQLKit

/// Minted only inside the journal's policy commit transaction. Domain
/// writers consume this context rather than accepting a caller-supplied bypass.
package struct V2PolicyMutationContext: Sendable {
    package let transaction: any Database
    private let scopeKey: String
    private let operationKey: String
    private let fingerprint: Data

    fileprivate init(transaction: any Database, change: V2PolicyAuthorizationChange) {
        self.transaction = transaction; scopeKey = change.scopeKey
        operationKey = change.operationKey; fingerprint = change.fingerprint
    }

    package func require(scope: V2PolicyAuthorizationScope, operationKey: String, fingerprint: Data) throws {
        guard transaction.inTransaction, scope.key == scopeKey,
              self.operationKey == operationKey, self.fingerprint == fingerprint else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
    }
}

package struct V2PolicyMutationExecution: Sendable {
    package let receipt: Data
    package let replayed: Bool
    package let state: V2PolicyFactsSnapshot?

    package init(receipt: Data, replayed: Bool, state: V2PolicyFactsSnapshot? = nil) {
        self.receipt = receipt; self.replayed = replayed; self.state = state
    }
}

/// Durable ownership and atomic policy changes. Facts, versions, permanent
/// results and publication obligations commit together before transport or
/// snapshot publication.
package struct PostgresV2PolicyAuthorizationJournal: Sendable {
    private let database: any Database
    private let schema: String
    private let stateReadAdmission: V2DatabaseWorkAdmissionController?
    private let stateMetrics: V2SendOperationBatchMetrics?

    package init(database: any Database, schema: String = "im_v2",
                 stateReadAdmission: V2DatabaseWorkAdmissionController? = nil,
                 stateMetrics: V2SendOperationBatchMetrics? = nil) {
        v2PreconditionSQLSchema(schema)
        self.database = database; self.schema = schema
        self.stateReadAdmission = stateReadAdmission
        self.stateMetrics = stateMetrics
    }

    package func readSnapshot(scope: V2PolicyAuthorizationScope) async throws -> V2PolicyFactsSnapshot {
        try await readSnapshots(scopes: [scope])[0]
    }
    package func readSnapshots(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot] {
        let trace = V2SendPathTrace.current
        let readStartedAt = ContinuousClock.now
        defer { trace?.record("policy_local_database_read", from: readStartedAt) }
        guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
              Set(scopes.map(\.key)).count == scopes.count else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let waiting = stateMetrics?.startStage(.policyOwnerStateDatabaseAdmission)
        defer { waiting?.finish() }
        return try await v2WithAdmittedRoomDatabaseWork(stateReadAdmission, workClass: .sync,
            callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
            waiting?.finish()
            return try await v2MeasureSendOperationStage(.policyOwnerStateTransaction, metrics: self.stateMetrics) {
                try await v2MeasureSendOperationStage(.policyOwnerStateFacts, metrics: self.stateMetrics) {
                    try await PostgresV2PolicyFactsSnapshotReader(schema: self.schema, metrics: self.stateMetrics).read(scopes: scopes, sql: self.sql(self.database))
                }
            }
        }
    }

    package func acquireOwner(scope: V2PolicyAuthorizationScope, ownerID: UUID,
                              durationSeconds: Double) async throws -> V2PolicyOwnerLease {
        try validate(scope: scope, duration: durationSeconds)
        return try await database.transaction { transaction in
            let sql = try self.sql(transaction)
            return try await self.acquireOwner(scope: scope, ownerID: ownerID,
                durationSeconds: durationSeconds, sql: sql).0
        }
    }

    private func acquireOwner(scope: V2PolicyAuthorizationScope, ownerID: UUID,
                              durationSeconds: Double, sql: any SQLDatabase) async throws
        -> (V2PolicyOwnerLease, ScopeRow) {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: self.schema).policy_authorization_scopes(scope_key)
            VALUES (\(bind: scope.key)) ON CONFLICT DO NOTHING
            """).run()
        // The clock depends on the materialized locked row, so a wait consumes the
        // old lease before eligibility is decided. No cross-scope batching.
        guard let claim = try await sql.raw("""
            WITH locked AS MATERIALIZED (
                SELECT revision, owner_id, owner_epoch, owner_valid_until, pending_change_key
                FROM \(unsafeRaw: self.schema).policy_authorization_scopes
                WHERE scope_key=\(bind: scope.key) FOR UPDATE
            ), observed AS MATERIALIZED (
                SELECT clock_timestamp() AS observed_at FROM locked
            ), decision AS MATERIALIZED (
                SELECT locked.*, observed.observed_at,
                    COALESCE(locked.owner_id=\(bind: ownerID)
                        AND locked.owner_valid_until>observed.observed_at,false) AS is_current,
                    COALESCE(locked.owner_valid_until<=observed.observed_at,true) AS is_expired
                FROM locked CROSS JOIN observed
            ), renewed AS (
                UPDATE \(unsafeRaw: self.schema).policy_authorization_scopes target
                SET owner_id=\(bind: ownerID),
                    owner_epoch=CASE WHEN decision.is_current THEN decision.owner_epoch ELSE decision.owner_epoch+1 END,
                    owner_valid_until=clock_timestamp()+make_interval(secs => \(bind: durationSeconds))
                FROM decision
                WHERE target.scope_key=\(bind: scope.key)
                    AND (decision.is_current OR decision.is_expired)
                    AND (decision.is_current OR decision.owner_epoch<\(literal: Int64.max))
                RETURNING target.owner_valid_until AS renewed_until
            )
            SELECT decision.*, renewed.renewed_until FROM decision LEFT JOIN renewed ON true
            """).first(decoding: OwnerClaimRow.self) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        let row = claim.scope, current = claim.is_current
        guard current || claim.is_expired else {
            throw V2PolicyAuthorizationLifecycleError.ownerChanged
        }
        guard current || row.owner_epoch < Int64.max else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        let epoch = current ? row.owner_epoch : row.owner_epoch + 1
        guard let renewed = claim.renewed_until else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        return (.init(scope: scope, ownerID: ownerID, epoch: epoch,
                      revision: row.revision, validUntil: renewed), row)
    }

    package func committedResult(scope: V2PolicyAuthorizationScope, operationKey: String,
                                 fingerprint: Data, commandJSON: String) async throws -> Data? {
        guard scope.isValid, !operationKey.isEmpty, operationKey.utf8.count <= 512,
              fingerprint.count == 32, commandJSON.utf8.count <= 16_384,
              (try? JSONSerialization.jsonObject(with: Data(commandJSON.utf8))) != nil else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        let sql = try self.sql(database)
        guard let row = try await sql.raw("""
            SELECT scope_key = \(bind: scope.key) AND fingerprint = \(bind: fingerprint)
                AND command = \(bind: commandJSON)::jsonb AS matches, committed, receipt
            FROM \(unsafeRaw: schema).policy_authorization_changes
            WHERE operation_key = \(bind: operationKey)
            """).first(decoding: ReplayRow.self) else { return nil }
        guard row.matches else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
        guard row.committed else { return nil }
        guard let receipt = row.receipt else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        return receipt
    }

    package func mutationFacts(scope: V2PolicyAuthorizationScope, context: V2PolicyMutationContext,
                               change: V2PolicyAuthorizationChange) async throws -> V2PolicyOwnerFacts {
        try context.require(scope: scope, operationKey: change.operationKey, fingerprint: change.fingerprint)
        return try await PostgresV2PolicyOwnerStateReader(schema: schema).read(scope: scope, transaction: context.transaction)
    }

    /// Current-state changes have no room drain phase. Ownership, domain
    /// facts, version and permanent result commit together; no pending seal is
    /// persisted before this transaction and no room lease is touched.
    package func changeCurrentPolicy(scope: V2PolicyAuthorizationScope, ownerID: UUID,
        durationSeconds: Double, operationKey: String, fingerprint: Data, commandJSON: String,
        snapshot: PostgresV2PolicyOwner.Snapshot? = nil,
        apply: @escaping PostgresV2PolicyOwner.Mutation
    ) async throws -> V2PolicyMutationExecution {
        guard !operationKey.isEmpty, operationKey.utf8.count <= 512,
              fingerprint.count == 32, commandJSON.utf8.count <= 16_384,
              let json = commandJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: json)) != nil else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        try validate(scope: scope, duration: durationSeconds)
        return try await database.transaction { transaction in
            let sql = try self.sql(transaction)
            let (owner, row) = try await self.acquireOwner(scope: scope, ownerID: ownerID,
                durationSeconds: durationSeconds, sql: sql)
            if let existing = try await self.change(operationKey, sql: sql) {
                guard existing.scope_key == scope.key, existing.fingerprint == fingerprint,
                      try await sql.raw("""
                        SELECT command = \(bind: commandJSON)::jsonb AS value
                        FROM \(unsafeRaw: self.schema).policy_authorization_changes
                        WHERE operation_key = \(bind: operationKey)
                        """).first(decoding: BoolRow.self)?.value == true else {
                    throw V2PolicyAuthorizationLifecycleError.identityConflict
                }
                guard existing.committed, let receipt = existing.receipt else {
                    // An old two-phase operation requires explicit recovery;
                    // this path never silently adopts its pending contract.
                    throw V2PolicyAuthorizationLifecycleError.busy
                }
                return .init(receipt: receipt, replayed: true)
            }
            guard row.pending_change_key == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
            guard owner.revision < Int64.max else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
            guard try await sql.raw("""
                SELECT count(*)::bigint AS value
                FROM \(unsafeRaw: self.schema).policy_authorization_holders
                WHERE scope_key = \(bind: scope.key) AND NOT revoked
                """).first(decoding: CountRow.self)?.value == 0 else {
                throw V2PolicyAuthorizationLifecycleError.notDrained
            }
            let change = V2PolicyAuthorizationChange(operationKey: operationKey, scopeKey: scope.key,
                fingerprint: fingerprint, commandJSON: commandJSON, expectedRevision: owner.revision,
                nextRevision: owner.revision + 1, committed: false, receipt: nil)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: self.schema).policy_authorization_changes
                    (operation_key, scope_key, fingerprint, command, expected_revision, next_revision)
                VALUES (\(bind: operationKey), \(bind: scope.key), \(bind: fingerprint),
                    \(bind: commandJSON)::jsonb, \(bind: change.expectedRevision), \(bind: change.nextRevision))
                """).run()
            return try await self.finishMutation(transaction: transaction, sql: sql, owner: owner,
                change: change, snapshot: snapshot) { transaction, change in
                    try await apply(.init(transaction: transaction, change: change), change)
                }
        }
    }

    private func finishMutation(transaction: any Database, sql: any SQLDatabase, owner: V2PolicyOwnerLease,
        change: V2PolicyAuthorizationChange, snapshot: PostgresV2PolicyOwner.Snapshot?,
        apply: @escaping @Sendable (any Database, V2PolicyAuthorizationChange) async throws -> Data
    ) async throws -> V2PolicyMutationExecution {
        let receipt = try await apply(transaction, change)
        guard receipt.count <= 65_536 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        try await sql.raw("""
            UPDATE \(unsafeRaw: self.schema).policy_authorization_scopes
            SET revision = \(bind: change.nextRevision), pending_change_key = NULL
            WHERE scope_key = \(bind: owner.scope.key)
            """).run()
        try await sql.raw("""
            UPDATE \(unsafeRaw: self.schema).policy_authorization_changes
            SET committed = true, receipt = \(bind: receipt), committed_at = clock_timestamp()
            WHERE operation_key = \(bind: change.operationKey)
            """).run()
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: self.schema).policy_authorization_outbox(operation_key, scope_key, revision)
            VALUES (\(bind: change.operationKey), \(bind: owner.scope.key), \(bind: change.nextRevision))
            """).run()
        var state: V2PolicyFactsSnapshot?
        if let snapshot {
            // Capture the final domain facts under the mutation's scope
            // seal. The transaction future exposes this state only after
            // COMMIT succeeds; rollback cannot publish an in-memory grant.
            let facts = try await snapshot(.init(transaction: transaction, change: change), change)
            state = try .init(scope: owner.scope, version: change.nextRevision, facts: facts)
        }
        return .init(receipt: receipt, replayed: false, state: state)
    }

    package func pendingChanges(scope: V2PolicyAuthorizationScope? = nil, limit: Int = 128) async throws -> [V2PolicyAuthorizationChange] {
        guard (1...128).contains(limit) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        return try await sql(database).raw("""
            SELECT operation_key, scope_key, fingerprint, command::text AS command_json,
                expected_revision, next_revision, committed, receipt
            FROM \(unsafeRaw: schema).policy_authorization_changes
            WHERE NOT committed AND (\(bind: scope?.key)::text IS NULL OR scope_key = \(bind: scope?.key)::text)
            ORDER BY created_at, operation_key LIMIT \(bind: limit)
            """).all(decoding: ChangeRow.self).map(\.value)
    }

    package func pendingChangeHighWater() async throws -> V2PolicyJournalCursor? {
        try await sql(database).raw("""
            SELECT created_at::text AS "createdAt",operation_key AS "operationKey"
            FROM \(unsafeRaw: schema).policy_authorization_changes WHERE NOT committed
            ORDER BY created_at DESC,operation_key DESC LIMIT 1
            """).first(decoding: V2PolicyJournalCursor.self)
    }
    package func pendingPublicationHighWater() async throws -> V2PolicyJournalCursor? {
        try await sql(database).raw("""
            SELECT created_at::text AS "createdAt",operation_key AS "operationKey"
            FROM \(unsafeRaw: schema).policy_authorization_outbox WHERE published_at IS NULL
            ORDER BY created_at DESC,operation_key DESC LIMIT 1
            """).first(decoding: V2PolicyJournalCursor.self)
    }

    package func pendingChangePage(after cursor: V2PolicyJournalCursor?, through upper: V2PolicyJournalCursor? = nil, limit: Int) async throws -> V2PolicyChangeScanPage {
        guard (1...128).contains(limit) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let rows = try await sql(database).raw("""
            SELECT operation_key, scope_key, fingerprint, command::text AS command_json,
                expected_revision, next_revision, committed, receipt, created_at::text AS created_at_text
            FROM \(unsafeRaw: schema).policy_authorization_changes
            WHERE NOT committed AND (\(bind: upper?.createdAt)::timestamptz IS NULL
                OR (created_at,operation_key) <= (\(bind: upper?.createdAt)::timestamptz,\(bind: upper?.operationKey)::text))
                AND (\(bind: cursor?.createdAt)::timestamptz IS NULL
                OR (created_at, operation_key) > (\(bind: cursor?.createdAt)::timestamptz, \(bind: cursor?.operationKey)::text))
            ORDER BY created_at, operation_key LIMIT \(bind: limit + 1)
            """).all(decoding: ChangeRow.self)
        let entries = try rows.prefix(limit).map { row -> V2ScannedPolicyChange in
            guard let time = row.created_at_text else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            return .init(change: row.value, cursor: .init(createdAt: time, operationKey: row.operation_key))
        }
        return .init(entries: entries, hasMore: rows.count > limit)
    }

    package func pendingPublicationPage(after cursor: V2PolicyJournalCursor?, through upper: V2PolicyJournalCursor? = nil, limit: Int) async throws -> V2PolicyPublicationScanPage {
        guard (1...128).contains(limit) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let rows = try await sql(database).raw("""
            SELECT p.operation_key, p.scope_key, p.revision, p.created_at::text AS created_at_text
            FROM \(unsafeRaw: schema).policy_authorization_outbox p
            WHERE p.published_at IS NULL AND NOT EXISTS (
                SELECT 1 FROM \(unsafeRaw: schema).policy_authorization_outbox older
                WHERE older.scope_key=p.scope_key AND older.published_at IS NULL AND older.revision<p.revision
            ) AND (\(bind: upper?.createdAt)::timestamptz IS NULL
                OR (p.created_at,p.operation_key) <= (\(bind: upper?.createdAt)::timestamptz,\(bind: upper?.operationKey)::text))
                AND (\(bind: cursor?.createdAt)::timestamptz IS NULL
                OR (p.created_at, p.operation_key) > (\(bind: cursor?.createdAt)::timestamptz, \(bind: cursor?.operationKey)::text))
            ORDER BY p.created_at, p.operation_key LIMIT \(bind: limit + 1)
            """).all(decoding: PublicationRow.self)
        return .init(entries: rows.prefix(limit).map {
            .init(notification: .init(operationKey: $0.operation_key, scopeKey: $0.scope_key, revision: $0.revision),
                cursor: .init(createdAt: $0.created_at_text, operationKey: $0.operation_key))
        }, hasMore: rows.count > limit)
    }

    package func committedPublication(_ notification: V2PolicyCommitNotification) async throws -> V2PolicyAuthorizationChange {
        guard let row = try await change(notification.operationKey, sql: sql(database)), row.committed,
              row.scope_key == notification.scopeKey, row.next_revision == notification.revision,
              row.receipt != nil else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        return row.value
    }

    /// Only after the actual durable notification sink has acknowledged this
    /// exact immutable revision. Delivery is at least once, never permission.
    package func markPublished(_ notification: V2PolicyCommitNotification) async throws {
        let sql = try sql(database)
        guard try await sql.raw("""
            UPDATE \(unsafeRaw: schema).policy_authorization_outbox
            SET published_at=COALESCE(published_at,clock_timestamp())
            WHERE operation_key=\(bind: notification.operationKey) AND scope_key=\(bind: notification.scopeKey)
                AND revision=\(bind: notification.revision) RETURNING revision AS value
            """).first(decoding: CountRow.self)?.value == notification.revision else {
            throw V2PolicyAuthorizationLifecycleError.invalidTarget
        }
    }
    private struct PublicationRow: Decodable {
        let operation_key: String; let scope_key: String; let revision: Int64; let created_at_text: String
    }

    private func lockScope(_ key: String, sql: any SQLDatabase) async throws -> ScopeRow {
        guard let row = try await sql.raw("""
            SELECT revision, owner_id, owner_epoch, owner_valid_until, pending_change_key
            FROM \(unsafeRaw: schema).policy_authorization_scopes
            WHERE scope_key = \(bind: key) FOR UPDATE
            """).first(decoding: ScopeRow.self) else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        return row
    }

    private func change(_ key: String, sql: any SQLDatabase) async throws -> ChangeRow? {
        try await sql.raw("""
            SELECT operation_key, scope_key, fingerprint, command::text AS command_json,
                expected_revision, next_revision, committed, receipt
            FROM \(unsafeRaw: schema).policy_authorization_changes WHERE operation_key = \(bind: key)
            """).first(decoding: ChangeRow.self)
    }

    private func clock(_ sql: any SQLDatabase) async throws -> Date {
        guard let row = try await sql.raw("SELECT clock_timestamp() AS value").first(decoding: DateRow.self) else {
            throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        return row.value
    }

    private func require(_ owner: V2PolicyOwnerLease, row: ScopeRow, clock: Date) throws {
        guard owner.epoch > 0, row.owner_id == owner.ownerID, row.owner_epoch == owner.epoch,
              row.owner_valid_until.map({ $0 > clock }) == true else {
            throw V2PolicyAuthorizationLifecycleError.ownerChanged
        }
    }

    private func validate(scope: V2PolicyAuthorizationScope, duration: Double) throws {
        guard scope.isValid, duration.isFinite, duration > 0, duration <= 300 else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
    }

    private func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        return sql
    }

    private struct ReplayRow: Decodable { let matches: Bool; let committed: Bool; let receipt: Data? }

    private struct ScopeRow: Decodable, Sendable {
        let revision: Int64; let owner_id: UUID?; let owner_epoch: Int64
        let owner_valid_until: Date?; let pending_change_key: String?
    }
    private struct OwnerClaimRow: Decodable {
        let scope: ScopeRow
        let is_current: Bool
        let is_expired: Bool
        let renewed_until: Date?
        enum CodingKeys: String, CodingKey { case is_current, is_expired, renewed_until }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope = try ScopeRow(from: decoder)
            is_current = try container.decode(Bool.self, forKey: .is_current)
            is_expired = try container.decode(Bool.self, forKey: .is_expired)
            renewed_until = try container.decodeIfPresent(Date.self, forKey: .renewed_until)
        }
    }
    private struct DateRow: Decodable { let value: Date }
    private struct CountRow: Decodable { let value: Int64 }
    private struct BoolRow: Decodable { let value: Bool }
    private struct ChangeRow: Decodable {
        let created_at_text: String?
        let operation_key: String; let scope_key: String; let fingerprint: Data; let command_json: String
        let expected_revision: Int64; let next_revision: Int64; let committed: Bool; let receipt: Data?
        var value: V2PolicyAuthorizationChange {
            .init(operationKey: operation_key, scopeKey: scope_key, fingerprint: fingerprint,
                commandJSON: command_json, expectedRevision: expected_revision,
                nextRevision: next_revision, committed: committed, receipt: receipt)
        }
    }
}
