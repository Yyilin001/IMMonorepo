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
    package let state: V2PolicyOwnerState?

    package init(receipt: Data, replayed: Bool, state: V2PolicyOwnerState? = nil) {
        self.receipt = receipt; self.replayed = replayed; self.state = state
    }
}

/// Durable registration and policy-change ordering. All methods finish their
/// transaction before transport, revocation waits, or snapshot publication.
/// A SQL connection is never retained while awaiting a remote room's drain.
package struct PostgresV2PolicyAuthorizationJournal: Sendable {
    private let database: any Database
    private let schema: String
    private let stateReadAdmission: V2DatabaseWorkAdmissionController?
    private let stateMetrics: V2SendOperationBatchMetrics?
    package let roomDrainRequired: Bool

    package init(database: any Database, schema: String = "im_v2",
                 stateReadAdmission: V2DatabaseWorkAdmissionController? = nil,
                 stateMetrics: V2SendOperationBatchMetrics? = nil,
                 roomDrainRequired: Bool = true) {
        v2PreconditionSQLSchema(schema)
        self.database = database; self.schema = schema
        self.stateReadAdmission = stateReadAdmission
        self.stateMetrics = stateMetrics
        self.roomDrainRequired = roomDrainRequired
    }

    package func readSnapshot(scope: V2PolicyAuthorizationScope) async throws -> V2PolicyFactsSnapshot {
        try await readSnapshots(scopes: [scope])[0]
    }
    package func readSnapshots(scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot] {
        let trace = V2SendPathTrace.current
        let readStartedAt = ContinuousClock.now
        defer { trace?.record("policy_local_database_read", from: readStartedAt) }
        guard !roomDrainRequired, !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
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

    /// Cold memory initialization publishes ownership and facts together. Scope
    /// and fact locks remain held through COMMIT; failed reads publish neither.
    package func acquireOwnerState(scope: V2PolicyAuthorizationScope, ownerID: UUID,
                                   durationSeconds: Double,
                                   cachedState: V2PolicyOwnerState? = nil) async throws -> V2PolicyOwnerState {
        try validate(scope: scope, duration: durationSeconds)
        let waiting = stateMetrics?.startStage(.policyOwnerStateDatabaseAdmission)
        defer { waiting?.finish() }
        return try await v2WithAdmittedRoomDatabaseWork(stateReadAdmission, workClass: .sync,
            callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
            waiting?.finish()
            return try await v2MeasureSendOperationStage(.policyOwnerStateTransaction, metrics: self.stateMetrics) {
                try await self.acquireAdmittedOwnerState(scope: scope, ownerID: ownerID,
                    durationSeconds: durationSeconds, cachedState: cachedState)
            }
        }
    }

    private func acquireAdmittedOwnerState(scope: V2PolicyAuthorizationScope, ownerID: UUID,
        durationSeconds: Double, cachedState: V2PolicyOwnerState?) async throws -> V2PolicyOwnerState {
        try await database.transaction { transaction in
            let sql = try self.sql(transaction)
            let (owner, row): (V2PolicyOwnerLease, ScopeRow)
            if !self.roomDrainRequired, cachedState == nil {
                (owner, row) = try await self.acquireColdOwner(scope: scope, ownerID: ownerID,
                    durationSeconds: durationSeconds, sql: sql)
            } else {
                (owner, row) = try await self.acquireOwner(scope: scope, ownerID: ownerID,
                    durationSeconds: durationSeconds, sql: sql)
            }
            guard row.pending_change_key == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
            let facts: V2PolicyOwnerFacts
            // Lease expiry does not itself change policy facts. Reuse only the
            // state issued for this exact pre-renewal owner incarnation and
            // revision, under the same scope lock that checks the change seal.
            // A takeover (even one that has since expired) or version change
            // requires a complete cold read before publishing new authority.
            if let cachedState, cachedState.owner.scope == scope,
               cachedState.owner.ownerID == ownerID, row.owner_id == ownerID,
               cachedState.owner.epoch == row.owner_epoch,
               cachedState.owner.revision == row.revision {
                facts = cachedState.facts
            } else {
                facts = try await v2MeasureSendOperationStage(.policyOwnerStateFacts, metrics: self.stateMetrics) {
                    try await PostgresV2PolicyOwnerStateReader(schema: self.schema).read(scope: scope, transaction: transaction)
                }
            }
            // Fact locks may have waited beyond this lease. Observe after the
            // read, so a blocked cold load cannot return an expired capability.
            let sampled = ContinuousClock.now, clock = try await self.clock(sql)
            let remaining = owner.validUntil.timeIntervalSince(clock)
            guard remaining > 0 else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            return .init(owner: owner, facts: facts, deadline: sampled + .seconds(remaining))
        }
    }

    /// A cold read has no previous facts tuple to validate. Create or claim its
    /// scope in one statement; conflict updates compute expiry after their row
    /// lock wait, rather than reusing the INSERT's pre-wait proposed expiry.
    private func acquireColdOwner(scope: V2PolicyAuthorizationScope, ownerID: UUID,
        durationSeconds: Double, sql: any SQLDatabase
    ) async throws -> (V2PolicyOwnerLease, ScopeRow) {
        if let row = try await sql.raw("""
            /* imv2_cold_policy_owner_claim */
            INSERT INTO \(unsafeRaw: schema).policy_authorization_scopes AS scope
                (scope_key, owner_id, owner_epoch, owner_valid_until)
            VALUES (\(bind: scope.key), \(bind: ownerID), 1,
                clock_timestamp()+make_interval(secs => \(bind: durationSeconds)))
            ON CONFLICT (scope_key) DO UPDATE
            SET owner_id=\(bind: ownerID),
                owner_epoch=CASE WHEN scope.owner_id=\(bind: ownerID)
                    AND scope.owner_valid_until>clock_timestamp()
                    THEN scope.owner_epoch ELSE scope.owner_epoch+1 END,
                owner_valid_until=clock_timestamp()+make_interval(secs => \(bind: durationSeconds))
            WHERE scope.owner_epoch<\(literal: Int64.max)
                AND (scope.owner_id=\(bind: ownerID) OR scope.owner_valid_until IS NULL
                    OR scope.owner_valid_until<=clock_timestamp())
            RETURNING revision, owner_id, owner_epoch, owner_valid_until, pending_change_key
            """).first(decoding: ScopeRow.self) {
            guard row.owner_id == ownerID, row.owner_epoch > 0, let expiry = row.owner_valid_until else {
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            return (.init(scope: scope, ownerID: ownerID, epoch: row.owner_epoch,
                revision: row.revision, validUntil: expiry), row)
        }
        // Retain existing error classification and the valid MAX-epoch owner's
        // renewal behavior. No row was changed by the declined conflict update.
        return try await acquireOwner(scope: scope, ownerID: ownerID,
            durationSeconds: durationSeconds, sql: sql)
    }

    private func acquireOwner(scope: V2PolicyAuthorizationScope, ownerID: UUID,
                              durationSeconds: Double, sql: any SQLDatabase) async throws
        -> (V2PolicyOwnerLease, ScopeRow) {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: self.schema).policy_authorization_scopes(scope_key)
            VALUES (\(bind: scope.key)) ON CONFLICT DO NOTHING
            """).run()
        // Keep the pre-renewal tuple for cached-fact validation. The clock
        // depends on the materialized locked row, so a lock wait consumes the
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

    package func readOwnerState(owner: V2PolicyOwnerLease) async throws -> V2PolicyOwnerState {
        try await database.transaction { transaction in
            let sql = try self.sql(transaction)
            let row = try await self.lockScope(owner.scope.key, sql: sql)
            let sampled = ContinuousClock.now, clock = try await self.clock(sql)
            try self.require(owner, row: row, clock: clock)
            guard row.pending_change_key == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
            guard row.revision == owner.revision else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
            let facts = try await PostgresV2PolicyOwnerStateReader(schema: self.schema).read(scope: owner.scope, transaction: transaction)
            let remaining = owner.validUntil.timeIntervalSince(clock)
            guard remaining > 0 else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            return .init(owner: owner, facts: facts, deadline: sampled + .seconds(remaining))
        }
    }

    /// One registration covers all policy dependencies of a room direction.
    /// Scope locks use canonical order, so a concurrent seal either includes
    /// this registration in its target set or rejects it before installation.
    package func register(owners: [V2PolicyOwnerLease], registrationID: UUID,
                          roomID: UUID, activationID: UUID, roomOwnerEpoch: Int64,
                          endpoint: String, durationSeconds: Double) async throws -> V2PolicyAuthorizationHolder {
        try await registerSnapshot(owners: owners, registrationID: registrationID, roomID: roomID,
            activationID: activationID, roomOwnerEpoch: roomOwnerEpoch, endpoint: endpoint,
            durationSeconds: durationSeconds) { _, holder in holder }
    }

    /// The reader runs inside the registration transaction while every dependency
    /// scope remains locked. A seal cannot commit between snapshot read and
    /// registration; reader failure rolls back the entire registration.
    package func registerSnapshot<Snapshot: Sendable>(owners: [V2PolicyOwnerLease], registrationID: UUID,
        roomID: UUID, activationID: UUID, roomOwnerEpoch: Int64, endpoint: String, durationSeconds: Double,
        read: @escaping @Sendable (any Database, V2PolicyAuthorizationHolder) async throws -> Snapshot
    ) async throws -> Snapshot {
        guard roomDrainRequired, !owners.isEmpty, owners.count <= 4,
              Set(owners.map { $0.scope.key }).count == owners.count,
              roomOwnerEpoch >= 0, !endpoint.isEmpty, endpoint.utf8.count <= 512 else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        for owner in owners { try validate(scope: owner.scope, duration: durationSeconds) }
        let ordered = owners.sorted { $0.scope.key < $1.scope.key }
        return try await database.transaction { transaction in
            let sql = try self.sql(transaction)
            let (rows, clock) = try await self.lockRegistrationScopes(ordered, sql: sql)
            for (owner, row) in zip(ordered, rows) {
                try self.require(owner, row: row, clock: clock)
                guard row.pending_change_key == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
                guard row.revision == owner.revision else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
            }
            let existing = try await sql.raw("""
                SELECT scope_key, registration_id, room_id, activation_id, room_owner_epoch,
                    generation, endpoint, policy_revision, policy_owner_epoch, valid_until, revoked
                FROM \(unsafeRaw: self.schema).policy_authorization_holders
                WHERE registration_id = \(bind: registrationID) LIMIT 4
                """).all(decoding: RegistrationRow.self)
            if !existing.isEmpty {
                guard existing.count == ordered.count,
                      Set(existing.map(\.scope_key)) == Set(ordered.map { $0.scope.key }),
                      existing.allSatisfy({ row in
                          row.room_id == roomID && row.activation_id == activationID
                          && row.room_owner_epoch == roomOwnerEpoch && row.endpoint == endpoint
                          && !row.revoked && row.valid_until > clock
                          && row.generation == existing[0].generation && row.valid_until == existing[0].valid_until
                          && ordered.contains(where: { $0.scope.key == row.scope_key
                              && $0.revision == row.policy_revision && $0.epoch == row.policy_owner_epoch })
                      }) else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
                return try await read(transaction, existing[0].value)
            }
            guard let timing = try await sql.raw("""
                SELECT nextval('\(unsafeRaw: self.schema).policy_authorization_holder_generation') AS generation,
                    clock_timestamp() + make_interval(secs => \(bind: durationSeconds)) AS valid_until
                """).first(decoding: RegistrationTiming.self) else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            let expiry = min(timing.valid_until, rows.compactMap(\.owner_valid_until).min()!)
            guard expiry > clock else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            let scopeKeys = String(decoding: try JSONEncoder().encode(ordered.map { $0.scope.key }), as: UTF8.self)
            // All rows remain UPDATE-locked from validation through COMMIT.
            // No conflict update may replace a prior registration's identity.
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: self.schema).policy_authorization_holders
                    (scope_key, registration_id, room_id, activation_id, room_owner_epoch,
                     generation, endpoint, policy_revision, policy_owner_epoch, valid_until)
                SELECT scope.scope_key, \(bind: registrationID), \(bind: roomID), \(bind: activationID),
                    \(bind: roomOwnerEpoch), \(bind: timing.generation), \(bind: endpoint),
                    scope.revision, scope.owner_epoch, \(bind: expiry)
                FROM (SELECT value AS scope_key FROM jsonb_array_elements_text(\(bind: scopeKeys)::jsonb)
                      LIMIT \(literal: ordered.count)) AS input
                JOIN \(unsafeRaw: self.schema).policy_authorization_scopes scope USING(scope_key)
                ORDER BY scope.scope_key COLLATE "C"
                """).run()
            let holder = V2PolicyAuthorizationHolder(registrationID: registrationID, roomID: roomID,
                activationID: activationID, roomOwnerEpoch: roomOwnerEpoch, generation: timing.generation,
                endpoint: endpoint, validUntil: expiry)
            return try await read(transaction, holder)
        }
    }

    /// Permanent results survive ownership migration. This read never grants
    /// mutation authority and does not need to acquire the current owner's lease.
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

    package func beginChange(owner: V2PolicyOwnerLease, operationKey: String,
                             fingerprint: Data, commandJSON: String) async throws -> V2PolicyAuthorizationChange {
        guard owner.scope.isValid, !operationKey.isEmpty, operationKey.utf8.count <= 512,
              fingerprint.count == 32, commandJSON.utf8.count <= 16_384,
              let json = commandJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: json)) != nil else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        return try await database.transaction { transaction in
            let sql = try self.sql(transaction)
            let scope = try await self.lockScope(owner.scope.key, sql: sql)
            if let existing = try await self.change(operationKey, sql: sql) {
                guard existing.scope_key == owner.scope.key, existing.fingerprint == fingerprint else {
                    throw V2PolicyAuthorizationLifecycleError.identityConflict
                }
                guard try await sql.raw("""
                    SELECT command = \(bind: commandJSON)::jsonb AS value
                    FROM \(unsafeRaw: self.schema).policy_authorization_changes
                    WHERE operation_key = \(bind: operationKey)
                    """).first(decoding: BoolRow.self)?.value == true else {
                    throw V2PolicyAuthorizationLifecycleError.identityConflict
                }
                if existing.committed { return existing.value }
                try self.require(owner, row: scope, clock: try await self.clock(sql))
                guard scope.pending_change_key == operationKey else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
                return existing.value
            }
            try self.require(owner, row: scope, clock: try await self.clock(sql))
            guard scope.pending_change_key == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
            guard scope.revision == owner.revision, scope.revision < Int64.max else {
                throw V2PolicyAuthorizationLifecycleError.staleVersion
            }
            if !self.roomDrainRequired {
                // Do not silently change the contract of a room that still
                // holds a legacy registered snapshot. Fresh current-state
                // sends create no holders; legacy holders must retire first.
                guard try await sql.raw("SELECT count(*)::bigint AS value FROM \(unsafeRaw: self.schema).policy_authorization_holders WHERE scope_key=\(bind: owner.scope.key) AND NOT revoked")
                    .first(decoding: CountRow.self)?.value == 0 else {
                    throw V2PolicyAuthorizationLifecycleError.notDrained
                }
            }
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: self.schema).policy_authorization_changes
                    (operation_key, scope_key, fingerprint, command, expected_revision, next_revision)
                VALUES (\(bind: operationKey), \(bind: owner.scope.key), \(bind: fingerprint),
                    \(bind: commandJSON)::jsonb, \(bind: scope.revision), \(bind: scope.revision + 1))
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: self.schema).policy_authorization_scopes
                SET pending_change_key = \(bind: operationKey) WHERE scope_key = \(bind: owner.scope.key)
                """).run()
            // Include expired registrations too. Their expiry is not proof of
            // physical SQL settlement or a reason to omit their durable fence.
            if self.roomDrainRequired { try await sql.raw("""
                INSERT INTO \(unsafeRaw: self.schema).policy_authorization_revocations
                    (operation_key, registration_id, room_id, activation_id,
                     room_owner_epoch, generation, endpoint, valid_until)
                SELECT \(bind: operationKey), registration_id, room_id, activation_id,
                    room_owner_epoch, generation, endpoint, valid_until
                FROM \(unsafeRaw: self.schema).policy_authorization_holders
                WHERE scope_key = \(bind: owner.scope.key) AND NOT revoked
                """).run() }
            guard let recorded = try await self.change(operationKey, sql: sql) else {
                throw V2PolicyAuthorizationLifecycleError.corruptPersistence
            }
            return recorded.value
        }
    }

    package func targets(operationKey: String, limit: Int = 128) async throws -> [V2PolicyAuthorizationHolder] {
        guard (1...128).contains(limit) else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let sql = try sql(database)
        return try await sql.raw("""
            SELECT registration_id, room_id, activation_id, room_owner_epoch, generation, endpoint, valid_until
            FROM \(unsafeRaw: schema).policy_authorization_revocations
            WHERE operation_key = \(bind: operationKey) AND resolved_at IS NULL
            ORDER BY registration_id LIMIT \(bind: limit)
            """).all(decoding: HolderRow.self).map(\.value)
    }

    /// Call only after the room's durable tombstone and actual SQL settlement
    /// are confirmed. A missed notification or expired clock is not a proof.
    package func acknowledge(operationKey: String, proof: V2PolicyAuthorizationRevocationProof) async throws {
        let holder = proof.holder
        let sql = try sql(database)
        guard try await sql.raw("""
            UPDATE \(unsafeRaw: schema).policy_authorization_revocations
            SET resolved_at = COALESCE(resolved_at, clock_timestamp())
            WHERE operation_key = \(bind: operationKey) AND registration_id = \(bind: holder.registrationID)
                AND room_id = \(bind: holder.roomID) AND activation_id = \(bind: holder.activationID)
                AND room_owner_epoch = \(bind: holder.roomOwnerEpoch) AND generation = \(bind: holder.generation)
                AND endpoint = \(bind: holder.endpoint) AND valid_until = \(bind: holder.validUntil)
            RETURNING registration_id
            """).first() != nil else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
    }

    package func commitPolicyChange(owner: V2PolicyOwnerLease, operationKey: String,
        apply: @escaping @Sendable (V2PolicyMutationContext, V2PolicyAuthorizationChange) async throws -> Data
    ) async throws -> Data {
        try await commitPolicyExecution(owner: owner, operationKey: operationKey, apply: apply).receipt
    }

    package func commitPolicyExecution(owner: V2PolicyOwnerLease, operationKey: String,
        snapshot: PostgresV2PolicyOwner.Snapshot? = nil,
        apply: @escaping @Sendable (V2PolicyMutationContext, V2PolicyAuthorizationChange) async throws -> Data
    ) async throws -> V2PolicyMutationExecution {
        try await commitExecution(owner: owner, operationKey: operationKey, snapshot: snapshot) { transaction, change in
            try await apply(.init(transaction: transaction, change: change), change)
        }
    }

    package func mutationFacts(scope: V2PolicyAuthorizationScope, context: V2PolicyMutationContext,
                               change: V2PolicyAuthorizationChange) async throws -> V2PolicyOwnerFacts {
        try context.require(scope: scope, operationKey: change.operationKey, fingerprint: change.fingerprint)
        return try await PostgresV2PolicyOwnerStateReader(schema: schema).read(scope: scope, transaction: context.transaction)
    }

    /// Apply policy facts, revision, permanent operation result and publication
    /// obligation in one short transaction. Transport/drain must finish first.
    package func commitChange(owner: V2PolicyOwnerLease, operationKey: String,
        apply: @escaping @Sendable (any Database, V2PolicyAuthorizationChange) async throws -> Data
    ) async throws -> Data {
        try await commitExecution(owner: owner, operationKey: operationKey, apply: apply).receipt
    }

    private func commitExecution(owner: V2PolicyOwnerLease, operationKey: String,
        snapshot: PostgresV2PolicyOwner.Snapshot? = nil,
        apply: @escaping @Sendable (any Database, V2PolicyAuthorizationChange) async throws -> Data
    ) async throws -> V2PolicyMutationExecution {
        return try await database.transaction { transaction in
            let sql = try self.sql(transaction)
            let scope = try await self.lockScope(owner.scope.key, sql: sql)
            guard let change = try await self.change(operationKey, sql: sql), change.scope_key == owner.scope.key else {
                throw V2PolicyAuthorizationLifecycleError.identityConflict
            }
            if let receipt = change.receipt, change.committed { return .init(receipt: receipt, replayed: true) }
            try self.require(owner, row: scope, clock: try await self.clock(sql))
            guard scope.pending_change_key == operationKey, scope.revision == change.expected_revision else {
                throw V2PolicyAuthorizationLifecycleError.staleVersion
            }
            guard try await sql.raw("""
                SELECT count(*)::bigint AS value FROM \(unsafeRaw: self.schema).policy_authorization_revocations
                WHERE operation_key = \(bind: operationKey) AND resolved_at IS NULL
                """).first(decoding: CountRow.self)?.value == 0 else { throw V2PolicyAuthorizationLifecycleError.notDrained }
            return try await self.finishMutation(transaction: transaction, sql: sql, owner: owner,
                change: change.value, snapshot: snapshot, apply: apply)
        }
    }

    /// Current-state changes have no room drain phase. Ownership, domain
    /// facts, version and permanent result commit together; no pending seal is
    /// persisted before this transaction and no room lease is touched.
    package func changeCurrentPolicy(scope: V2PolicyAuthorizationScope, ownerID: UUID,
        durationSeconds: Double, operationKey: String, fingerprint: Data, commandJSON: String,
        snapshot: PostgresV2PolicyOwner.Snapshot? = nil,
        apply: @escaping PostgresV2PolicyOwner.Mutation
    ) async throws -> V2PolicyMutationExecution {
        guard !roomDrainRequired, !operationKey.isEmpty, operationKey.utf8.count <= 512,
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
        if roomDrainRequired {
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).policy_authorization_holders SET revoked = true
                WHERE scope_key = \(bind: owner.scope.key) AND NOT revoked
                """).run()
        }
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
        var state: V2PolicyOwnerState?
        if let snapshot {
            // Capture the final domain facts under the mutation's scope
            // seal. The transaction future exposes this state only after
            // COMMIT succeeds; rollback cannot publish an in-memory grant.
            let facts = try await snapshot(.init(transaction: transaction, change: change), change)
            let sampled = ContinuousClock.now, clock = try await self.clock(sql)
            let remaining = owner.validUntil.timeIntervalSince(clock)
            // Expired authority must not authorize a send, but its exact
            // committed facts still belong in memory. registrationState
            // renews under the scope lock and reuses these facts only if
            // the pre-renewal owner incarnation and revision still match.
            state = .init(owner: .init(scope: owner.scope, ownerID: owner.ownerID, epoch: owner.epoch,
                revision: change.nextRevision, validUntil: owner.validUntil), facts: facts,
                deadline: sampled + .seconds(remaining))
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

    /// A registration owns at most four distinct scopes. Materialization plus
    /// count consumes all ordered locks before clock_timestamp is sampled.
    private func lockRegistrationScopes(_ owners: [V2PolicyOwnerLease], sql: any SQLDatabase) async throws
        -> ([ScopeRow], Date) {
        let input = String(decoding: try JSONEncoder().encode(owners.map { $0.scope.key }), as: UTF8.self)
        let locked = try await sql.raw("""
            WITH locked AS MATERIALIZED (
                SELECT scope_key, revision, owner_id, owner_epoch, owner_valid_until, pending_change_key
                FROM \(unsafeRaw: schema).policy_authorization_scopes
                WHERE scope_key IN (SELECT value FROM jsonb_array_elements_text(\(bind: input)::jsonb)
                                    LIMIT \(literal: owners.count))
                ORDER BY scope_key COLLATE "C" FOR UPDATE
            ), observation AS MATERIALIZED (
                SELECT clock_timestamp() AS observed_at
                FROM (SELECT count(*) AS count FROM locked) AS completed WHERE count>0
            )
            SELECT locked.*, observation.observed_at FROM locked CROSS JOIN observation
            ORDER BY scope_key COLLATE "C"
            """).all(decoding: RegistrationScopeRow.self)
        guard locked.map(\.scope_key) == owners.map({ $0.scope.key }), let clock = locked.first?.observed_at else {
            throw V2PolicyAuthorizationLifecycleError.ownerChanged
        }
        return (locked.map(\.scope), clock)
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
    private struct RegistrationScopeRow: Decodable {
        let scope_key: String
        let observed_at: Date
        let scope: ScopeRow
        enum CodingKeys: String, CodingKey { case scope_key, observed_at }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scope_key = try container.decode(String.self, forKey: .scope_key)
            observed_at = try container.decode(Date.self, forKey: .observed_at)
            scope = try ScopeRow(from: decoder)
        }
    }
    private struct DateRow: Decodable { let value: Date }
    private struct CountRow: Decodable { let value: Int64 }
    private struct BoolRow: Decodable { let value: Bool }
    private struct RegistrationTiming: Decodable { let generation: Int64; let valid_until: Date }
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
    private struct HolderRow: Decodable {
        let registration_id: UUID; let room_id: UUID; let activation_id: UUID; let room_owner_epoch: Int64
        let generation: Int64; let endpoint: String; let valid_until: Date
        var value: V2PolicyAuthorizationHolder {
            .init(registrationID: registration_id, roomID: room_id, activationID: activation_id,
                  roomOwnerEpoch: room_owner_epoch, generation: generation, endpoint: endpoint, validUntil: valid_until)
        }
    }
    private struct RegistrationRow: Decodable {
        let scope_key: String; let registration_id: UUID; let room_id: UUID; let activation_id: UUID
        let room_owner_epoch: Int64; let generation: Int64; let endpoint: String
        let policy_revision: Int64; let policy_owner_epoch: Int64; let valid_until: Date; let revoked: Bool
        var value: V2PolicyAuthorizationHolder {
            .init(registrationID: registration_id, roomID: room_id, activationID: activation_id,
                  roomOwnerEpoch: room_owner_epoch, generation: generation, endpoint: endpoint, validUntil: valid_until)
        }
    }
}
