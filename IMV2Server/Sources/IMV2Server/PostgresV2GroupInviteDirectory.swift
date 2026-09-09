import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2GroupInviteDirectory: V2GroupInviteDirectory, V2GroupInviteCreationRecoveryStoring {
    private let database: any Database

    public init(database: any Database) { self.database = database }

    public func prepare(_ request: V2GroupInviteCreatePersistenceRequest) async throws -> V2GroupInviteCreationIntent {
        guard let actor = request.actorUserID.uuidValue,
              let operation = request.operationID.uuidValue,
              let room = request.roomID.uuidValue,
              let invite = request.inviteID.uuidValue,
              request.tokenDigest.count == 32,
              request.requestedLifetimeSeconds > 0,
              request.maximumApprovedUses > 0,
              request.maximumActiveInvitesPerRoom > 0,
              let timestamps = request.persistedTimestamps,
              timestamps.createdAt.microseconds < timestamps.expiresAt.microseconds,
              let recoveryAt = v2PostgresFutureTimestamp(now: request.evaluatedAt, interval: 30)
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        return try await database.transaction { transaction in
            let sql = try directorySQL(transaction)
            // All unique collisions are handled deliberately, including two
            // different operations proposing the same token or invite ID.
            try await sql.raw("""
                INSERT INTO im_v2.group_invite_directory
                    (actor_user_id, operation_id, invite_id, room_id, token_digest,
                     requested_lifetime_seconds, maximum_approved_uses, created_at, expires_at, state)
                VALUES (\(bind: actor), \(bind: operation), \(bind: invite), \(bind: room),
                        \(bind: request.tokenDigest), \(bind: request.requestedLifetimeSeconds),
                        \(bind: request.maximumApprovedUses), \(bind: timestamps.createdAt),
                        \(bind: timestamps.expiresAt), 'prepared')
                ON CONFLICT DO NOTHING
                """).run()
            guard let row = try await sql.raw("""
                SELECT * FROM im_v2.group_invite_directory
                WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)
                FOR UPDATE
                """).first(decoding: DirectoryRow.self),
                  row.roomID == room, row.tokenDigest == request.tokenDigest,
                  row.requestedLifetimeSeconds == request.requestedLifetimeSeconds,
                  row.maximumApprovedUses == request.maximumApprovedUses
            else { throw V2GroupInviteDirectoryError.conflict }
            if row.state == "prepared" {
                try await sql.raw("""
                    INSERT INTO im_v2.group_invite_creation_recovery
                        (actor_user_id, operation_id, state, attempt_count, next_attempt_at, updated_at)
                    VALUES (\(bind: actor), \(bind: operation), 'pending', 0,
                            \(bind: recoveryAt), \(bind: request.evaluatedAt))
                    ON CONFLICT DO NOTHING
                    """).run()
            }
            return try row.intent(maximumActiveInvitesPerRoom: request.maximumActiveInvitesPerRoom, evaluatedAt: request.evaluatedAt)
        }
    }

    public func finalize(_ intent: V2GroupInviteCreationIntent, now: Date) async throws {
        let request = intent.request
        guard let actor = request.actorUserID.uuidValue,
              let operation = request.operationID.uuidValue,
              v2PostgresTimestampCanEncode(now)
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        try await database.transaction { transaction in
            let sql = try directorySQL(transaction)
            guard let row = try await sql.raw("""
                SELECT * FROM im_v2.group_invite_directory
                WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) FOR UPDATE
                """).first(decoding: DirectoryRow.self),
                  row.inviteID == request.inviteID.uuidValue,
                  row.roomID == request.roomID.uuidValue,
                  row.tokenDigest == request.tokenDigest,
                  row.requestedLifetimeSeconds == request.requestedLifetimeSeconds,
                  row.maximumApprovedUses == request.maximumApprovedUses,
                  row.createdAt == request.persistedTimestamps?.createdAt,
                  row.expiresAt == request.persistedTimestamps?.expiresAt
            else { throw V2GroupInviteDirectoryError.conflict }
            guard row.state == "prepared" || row.state == "ready" else {
                throw V2GroupInviteDirectoryError.corruptPersistenceState
            }
            if row.state == "prepared" {
                try await sql.raw("""
                    UPDATE im_v2.group_invite_directory SET state = 'ready', ready_at = \(bind: now)
                    WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)
                    """).run()
            }
            try await sql.raw("""
                UPDATE im_v2.group_invite_creation_recovery
                SET state = 'completed', claim_token = NULL, lease_expires_at = NULL,
                    last_error_code = NULL, completed_at = \(bind: now), updated_at = \(bind: now)
                WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND state <> 'completed'
                """).run()
        }
    }

    public func claim(limit: Int, now: Date, lease: TimeInterval, maximumActiveInvitesPerRoom: Int) async throws -> [V2GroupInviteCreationRecoveryClaim] {
        guard (1...100).contains(limit), lease > 0, lease <= 300,
              maximumActiveInvitesPerRoom > 0,
              let expiresAt = v2PostgresFutureTimestamp(now: now, interval: lease)
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        return try await database.transaction { transaction in
            let sql = try directorySQL(transaction)
            var result: [V2GroupInviteCreationRecoveryClaim] = []
            // Each branch follows its own due-time partial index. Reclaim dead
            // processes first; no broad OR scan or sorting an entire backlog.
            for (state, dateColumn) in [("claimed", "lease_expires_at"), ("pending", "next_attempt_at")] {
                let remaining = limit - result.count
                if remaining == 0 { break }
                let rows = try await sql.raw("""
                    WITH picked AS (
                        SELECT actor_user_id, operation_id FROM im_v2.group_invite_creation_recovery
                        WHERE state = \(unsafeRaw: state == "claimed" ? "'claimed'" : "'pending'") AND \(unsafeRaw: dateColumn) <= \(bind: now)
                        ORDER BY \(unsafeRaw: dateColumn), actor_user_id, operation_id
                        LIMIT \(bind: remaining) FOR UPDATE SKIP LOCKED
                    ), claimed AS (
                        UPDATE im_v2.group_invite_creation_recovery job
                        SET state = 'claimed', claim_token = gen_random_uuid(),
                            lease_expires_at = \(bind: expiresAt),
                            attempt_count = LEAST(job.attempt_count + 1, 1000), updated_at = \(bind: now)
                        FROM picked WHERE job.actor_user_id = picked.actor_user_id AND job.operation_id = picked.operation_id
                        RETURNING job.actor_user_id, job.operation_id, job.claim_token, job.attempt_count
                    )
                    SELECT directory.*, claimed.claim_token, claimed.attempt_count
                    FROM claimed JOIN im_v2.group_invite_directory directory USING (actor_user_id, operation_id)
                    """).all(decoding: InviteRecoveryClaimRow.self)
                result += try rows.map { row in
                    .init(intent: try row.directory.intent(maximumActiveInvitesPerRoom: maximumActiveInvitesPerRoom, evaluatedAt: now), claimToken: row.claimToken, attemptCount: row.attemptCount)
                }
            }
            return result
        }
    }

    public func fail(_ claim: V2GroupInviteCreationRecoveryClaim, reason: V2GroupInviteCreationRecoveryFailure, retryAt: Date?, now: Date) async throws -> Bool {
        guard v2PostgresTimestampCanEncode(now), retryAt.map({ v2PostgresTimestampPrecedes(now, $0) }) ?? true,
              let actor = claim.intent.request.actorUserID.uuidValue, let operation = claim.intent.request.operationID.uuidValue
        else { throw V2GroupInviteDirectoryError.invalidRequest }
        let sql = try directorySQL(database)
        let row = try await sql.raw("""
            UPDATE im_v2.group_invite_creation_recovery
            SET state = \(bind: retryAt == nil ? "paused" : "pending"), claim_token = NULL, lease_expires_at = NULL,
                last_error_code = \(bind: reason.rawValue), next_attempt_at = \(bind: retryAt ?? now), updated_at = \(bind: now)
            WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation)
              AND state = 'claimed' AND claim_token = \(bind: claim.claimToken) AND lease_expires_at > \(bind: now)
            RETURNING actor_user_id
            """).first()
        return row != nil
    }

    public func readyInvites(roomID: RoomID, inviteIDs: Set<GroupInviteID>) async throws -> Set<GroupInviteID> {
        guard let room = roomID.uuidValue, inviteIDs.count <= 100 else { throw V2GroupInviteDirectoryError.invalidRequest }
        if inviteIDs.isEmpty { return [] }
        let ids = try inviteIDs.map { id -> UUID in
            guard let uuid = id.uuidValue else { throw V2GroupInviteDirectoryError.invalidRequest }
            return uuid
        }
        let sql = try directorySQL(database)
        let rows = try await sql.raw("""
            SELECT invite_id, room_id FROM im_v2.group_invite_directory
            WHERE room_id = \(bind: room) AND invite_id = ANY(\(bind: ids)::uuid[]) AND state = 'ready'
            """).all(decoding: LocationRow.self)
        return Set(rows.map { .init(uuid: $0.inviteID) })
    }

    public func resolve(tokenDigest: Data) async throws -> V2GroupInviteLocation? {
        guard tokenDigest.count == 32 else { throw V2GroupInviteDirectoryError.invalidRequest }
        let sql = try directorySQL(database)
        guard let row = try await sql.raw("""
            SELECT invite_id, room_id FROM im_v2.group_invite_directory
            WHERE token_digest = \(bind: tokenDigest) AND state = 'ready'
            """).first(decoding: LocationRow.self) else { return nil }
        return .init(inviteID: .init(uuid: row.inviteID), roomID: .init(uuid: row.roomID))
    }
}

private struct LocationRow: Decodable {
    let inviteID: UUID, roomID: UUID
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", roomID = "room_id" }
}

private struct DirectoryRow: Decodable {
    let actorUserID: UUID, operationID: UUID, inviteID: UUID, roomID: UUID
    let tokenDigest: Data
    let requestedLifetimeSeconds: Int, maximumApprovedUses: Int
    let createdAt: V2PostgresTimestamp, expiresAt: V2PostgresTimestamp
    let state: String
    enum CodingKeys: String, CodingKey {
        case actorUserID = "actor_user_id", operationID = "operation_id", inviteID = "invite_id", roomID = "room_id"
        case tokenDigest = "token_digest", requestedLifetimeSeconds = "requested_lifetime_seconds"
        case maximumApprovedUses = "maximum_approved_uses", createdAt = "created_at", expiresAt = "expires_at", state
    }
    func intent(maximumActiveInvitesPerRoom: Int, evaluatedAt: Date) throws -> V2GroupInviteCreationIntent {
        guard state == "prepared" || state == "ready" else {
            throw V2GroupInviteDirectoryError.corruptPersistenceState
        }
        return .init(request: .init(
            inviteID: .init(uuid: inviteID), roomID: .init(uuid: roomID),
            actorUserID: .init(uuid: actorUserID), operationID: .init(uuid: operationID),
            tokenDigest: tokenDigest, requestedLifetimeSeconds: requestedLifetimeSeconds,
            expiresAt: expiresAt.date, maximumApprovedUses: maximumApprovedUses,
            maximumActiveInvitesPerRoom: maximumActiveInvitesPerRoom, createdAt: createdAt.date, evaluatedAt: evaluatedAt
        ).preservingTimestamps(.init(createdAt: createdAt, expiresAt: expiresAt)), isReady: state == "ready")
    }
}

private func directorySQL(_ database: any Database) throws -> any SQLDatabase {
    guard let sql = database as? any SQLDatabase else { throw V2GroupInviteDirectoryError.corruptPersistenceState }
    return sql
}

private struct InviteRecoveryClaimRow: Decodable {
    let directory: DirectoryRow
    let claimToken: UUID
    let attemptCount: Int
    enum CodingKeys: String, CodingKey { case claimToken = "claim_token", attemptCount = "attempt_count" }
    init(from decoder: any Decoder) throws {
        directory = try DirectoryRow(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claimToken = try container.decode(UUID.self, forKey: .claimToken)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
    }
}
