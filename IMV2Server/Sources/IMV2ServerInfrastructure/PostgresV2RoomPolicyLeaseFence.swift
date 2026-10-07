import Foundation
import FluentKit
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorCluster
import SQLKit

/// Minted after a local revocation commit or an authenticated exact remote
/// confirmation. Expiry, a UUID and an unverified wire ACK cannot mint it.
package struct V2PolicyAuthorizationRevocationProof: Sendable {
    package let holder: V2PolicyAuthorizationHolder
    fileprivate init(holder: V2PolicyAuthorizationHolder) { self.holder = holder }

    /// The remote capability can only be produced by the Cluster client after
    /// authenticated exchange and full target equality, never from a raw ACK.
    package init(verifiedRemote: V2VerifiedRoomPolicyRevocation) {
        let target = verifiedRemote.target
        holder = .init(registrationID: target.registrationID, roomID: target.roomID.uuidValue!,
            activationID: target.activationID, roomOwnerEpoch: target.roomOwnerEpoch,
            generation: target.generation, endpoint: target.endpoint, validUntil: target.validUntil)
    }
}

/// A room database fence survives process loss. A tombstone is installed even
/// if a revoke precedes install; a delayed transport response cannot undo it.
/// Active sends hold SHARE until their whole message/receipt transaction ends.
package struct PostgresV2RoomPolicyLeaseFence: Sendable {
    private let database: any Database
    private let schema: String
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?

    package init(database: any Database, schema: String = "im_v2",
                 databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil) {
        v2PreconditionSQLSchema(schema)
        self.database = database; self.schema = schema
        self.databaseWorkAdmission = databaseWorkAdmission
    }

    package func install(_ holder: V2PolicyAuthorizationHolder) async throws {
        try validate(holder)
        try await v2WithAdmittedRoomDatabaseWork(databaseWorkAdmission, workClass: .sync,
            callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
            try await self.database.transaction { transaction in
                let sql = try self.sql(transaction)
                try await self.insert(holder, revoked: false, sql: sql)
                let row = try await self.lock(holder.registrationID, mode: "UPDATE", sql: sql)
                try self.match(holder, row: row)
                guard !row.revoked, holder.validUntil > (try await self.clock(sql)) else {
                    throw V2PolicyAuthorizationLifecycleError.staleVersion
                }
            }
        }
    }

    @discardableResult
    package func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        try validate(holder)
        try await v2WithAdmittedRoomDatabaseWork(databaseWorkAdmission, workClass: .sync,
            callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
            try await self.database.transaction { transaction in
                let sql = try self.sql(transaction)
                try await self.insert(holder, revoked: true, sql: sql)
                // Waits for actual message transactions, not their caller tasks.
                let row = try await self.lock(holder.registrationID, mode: "UPDATE", sql: sql)
                try self.match(holder, row: row)
                try await sql.raw("""
                    UPDATE \(unsafeRaw: self.schema).room_policy_authorization_leases SET revoked = true
                    WHERE registration_id = \(bind: holder.registrationID)
                    """).run()
            }
        }
        return .init(holder: holder)
    }

    package func requireActive(_ holder: V2PolicyAuthorizationHolder, transaction: any Database) async throws {
        try await requireActive([holder], transaction: transaction)
    }

    /// One ordered lock read with a post-lock database clock for a whole cohort.
    /// Repeated commands sharing a holder never add per-message round trips.
    package func requireActive(_ holders: [V2PolicyAuthorizationHolder], transaction: any Database) async throws {
        guard !holders.isEmpty, holders.count <= 256 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        guard transaction.inTransaction else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        var expected: [UUID: V2PolicyAuthorizationHolder] = [:]
        for holder in holders {
            try validate(holder)
            if let prior = expected[holder.registrationID], prior != holder {
                throw V2PolicyAuthorizationLifecycleError.identityConflict
            }
            expected[holder.registrationID] = holder
        }
        let sql = try sql(transaction)
        let input = String(decoding: try JSONEncoder().encode(expected.keys.map { $0.uuidString.lowercased() }), as: UTF8.self)
        V2RoomSQLContinuationObservation.current?.willDispatch()
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT registration_id FROM jsonb_array_elements_text(\(bind: input)::jsonb) AS item(registration_id)
                LIMIT \(literal: expected.count)
            ), locked AS MATERIALIZED (
            SELECT lease.registration_id, lease.room_id, lease.activation_id,
                   lease.room_owner_epoch, lease.generation, lease.valid_until, lease.revoked
            FROM input
            JOIN \(unsafeRaw: schema).room_policy_authorization_leases AS lease
              ON lease.registration_id=input.registration_id::uuid
            ORDER BY lease.registration_id
            FOR SHARE OF lease
            ), observation AS MATERIALIZED (
                -- count consumes every locked row before sampling the clock.
                -- Evaluating time in the lock query's projection would be too
                -- early when a later holder blocks or the lock node waits.
                SELECT clock_timestamp() AS observed_at
                FROM (SELECT count(*) AS count FROM locked) AS completed
                WHERE completed.count > 0
            )
            SELECT locked.*, observation.observed_at
            FROM locked CROSS JOIN observation
            """).all(decoding: LeaseRow.self)
        try validateLocked(expected: expected, rows: rows)
    }

    private func validateLocked(expected: [UUID: V2PolicyAuthorizationHolder], rows: [LeaseRow]) throws {
        guard rows.count == expected.count else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
        // Sample only after all locks have actually been obtained. Time spent
        // waiting for any row must consume every holder's remaining lease.
        guard let observed = rows.first?.observed_at else {
            throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        for row in rows {
            guard let holder = expected[row.registration_id] else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
            try match(holder, row: row)
            guard !row.revoked, holder.validUntil > observed else {
                throw V2PolicyAuthorizationLifecycleError.staleVersion
            }
        }
    }

    /// The durable owner fence can acquire these locks in its existing SQL.
    /// The count dependency preserves activation-before-policy lock ordering.
    struct CombinedCheck: Sendable {
        private let fence: PostgresV2RoomPolicyLeaseFence
        private let expected: [UUID: V2PolicyAuthorizationHolder]
        let stages: SQLQueryString

        fileprivate init(fence: PostgresV2RoomPolicyLeaseFence,
            expected: [UUID: V2PolicyAuthorizationHolder], stages: SQLQueryString) {
            self.fence = fence; self.expected = expected; self.stages = stages
        }

        func validate(json: String) throws {
            let rows = try JSONDecoder().decode([CombinedLeaseRow].self, from: Data(json.utf8))
            guard rows.count == expected.count else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
            for row in rows {
                guard let holder = expected[row.registration_id] else {
                    throw V2PolicyAuthorizationLifecycleError.corruptPersistence
                }
                try fence.match(holder, registrationID: row.registration_id, roomID: row.room_id,
                    activationID: row.activation_id, roomOwnerEpoch: row.room_owner_epoch,
                    generation: row.generation, validUntilMicroseconds: row.valid_until_microseconds)
                guard !row.revoked, row.valid_until_microseconds > row.observed_at_microseconds else {
                    throw V2PolicyAuthorizationLifecycleError.staleVersion
                }
            }
        }
    }

    func combinedCheck(_ holders: [V2PolicyAuthorizationHolder]) throws -> CombinedCheck {
        guard !holders.isEmpty, holders.count <= 256 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        var expected: [UUID: V2PolicyAuthorizationHolder] = [:]
        for holder in holders {
            try validate(holder)
            if let prior = expected[holder.registrationID], prior != holder {
                throw V2PolicyAuthorizationLifecycleError.identityConflict
            }
            expected[holder.registrationID] = holder
        }
        let input = String(decoding: try JSONEncoder().encode(expected.keys.map(\.uuidString)), as: UTF8.self)
        let stages: SQLQueryString = """
            , policy_requested AS MATERIALIZED (
                SELECT value::uuid AS registration_id FROM jsonb_array_elements_text(\(bind: input)::jsonb)
                LIMIT \(literal: expected.count)
            ), locked_policies AS MATERIALIZED (
                SELECT policy.* FROM \(unsafeRaw: schema).room_policy_authorization_leases policy
                JOIN policy_requested USING(registration_id) CROSS JOIN leases_done
                WHERE leases_done.locked_count>=0
                ORDER BY policy.registration_id FOR SHARE OF policy
            ), policies_done AS MATERIALIZED (
                SELECT count(*) AS locked_count FROM locked_policies
            )
            """
        return .init(fence: self, expected: expected, stages: stages)
    }

    private func insert(_ holder: V2PolicyAuthorizationHolder, revoked: Bool, sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO \(unsafeRaw: schema).room_policy_authorization_leases
                (registration_id, room_id, activation_id, room_owner_epoch, generation, valid_until, revoked)
            VALUES (\(bind: holder.registrationID), \(bind: holder.roomID), \(bind: holder.activationID),
                \(bind: holder.roomOwnerEpoch), \(bind: holder.generation), \(bind: holder.validUntil), \(bind: revoked))
            ON CONFLICT (registration_id) DO NOTHING
            """).run()
    }

    private func lock(_ id: UUID, mode: String, sql: any SQLDatabase) async throws -> LeaseRow {
        precondition(mode == "SHARE" || mode == "UPDATE")
        guard let row = try await sql.raw("""
            SELECT registration_id, room_id, activation_id, room_owner_epoch, generation, valid_until, revoked
            FROM \(unsafeRaw: schema).room_policy_authorization_leases
            WHERE registration_id = \(bind: id) FOR \(unsafeRaw: mode)
            """).first(decoding: LeaseRow.self) else { throw V2PolicyAuthorizationLifecycleError.staleVersion }
        return row
    }

    private func match(_ holder: V2PolicyAuthorizationHolder, row: LeaseRow) throws {
        try match(holder, registrationID: row.registration_id, roomID: row.room_id,
            activationID: row.activation_id, roomOwnerEpoch: row.room_owner_epoch, generation: row.generation,
            validUntilMicroseconds: roomWritePostgresMicroseconds(row.valid_until))
    }

    private func match(_ holder: V2PolicyAuthorizationHolder, registrationID: UUID, roomID: UUID,
        activationID: UUID, roomOwnerEpoch: Int64, generation: Int64, validUntilMicroseconds: Int64) throws {
        guard registrationID == holder.registrationID, roomID == holder.roomID, activationID == holder.activationID,
              roomOwnerEpoch == holder.roomOwnerEpoch, generation == holder.generation,
              try validUntilMicroseconds == roomWritePostgresMicroseconds(holder.validUntil) else {
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
    }

    private func validate(_ holder: V2PolicyAuthorizationHolder) throws {
        guard holder.roomOwnerEpoch >= 0, holder.generation > 0,
              v2PostgresTimestampCanEncode(holder.validUntil) else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
    }

    private func clock(_ sql: any SQLDatabase) async throws -> Date {
        guard let clock = try await sql.raw("SELECT clock_timestamp() AS value").first(decoding: ClockRow.self) else {
            throw V2PolicyAuthorizationLifecycleError.corruptPersistence
        }
        return clock.value
    }

    private func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw V2PolicyAuthorizationLifecycleError.corruptPersistence }
        return sql
    }

    private struct ClockRow: Decodable { let value: Date }
    private struct LeaseRow: Decodable {
        let registration_id: UUID
        let room_id: UUID; let activation_id: UUID; let room_owner_epoch: Int64
        let generation: Int64; let valid_until: Date; let revoked: Bool
        let observed_at: Date?
    }
    private struct CombinedLeaseRow: Decodable {
        let registration_id: UUID, room_id: UUID, activation_id: UUID
        let room_owner_epoch: Int64, generation: Int64
        let valid_until_microseconds: Int64, observed_at_microseconds: Int64
        let revoked: Bool
    }
}
