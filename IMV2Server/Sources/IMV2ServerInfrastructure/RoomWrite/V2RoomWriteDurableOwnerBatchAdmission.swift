import Foundation
import IMV2ServerContracts
import SQLKit
import NIOCore

/// Cohort-only tail reservation. The room work has already been accepted, and
/// the caller retains its transaction until this entire set has been reserved.
/// This does not consume process credits or change the ordinary scalar path.
func v2ReserveDurableOwnerBatchAdmission(_ reservations: [ShardAdmissionReservation],
    retryAfterSeconds: Int, now: Date, sql: any SQLDatabase
) async throws {
    guard !reservations.isEmpty else { return }
    let admissionTrace = V2OwnerAdmissionHandoffObservation.current
    admissionTrace?.beginQuota()
    guard reservations.count <= 256, v2PostgresTimestampCanEncode(now) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    var groups: [DurableAdmissionKey: DurableAdmissionInput] = [:]
    for reservation in reservations {
        guard let shard = reservation.roomShardID, !shard.isEmpty,
              let profile = reservation.capacityProfileID, !profile.isEmpty,
              reservation.commandDelta > 0, reservation.generation > 0,
              let delta = Int64(exactly: reservation.commandDelta) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let key = DurableAdmissionKey(shard: shard, profile: profile)
        if let previous = groups[key] {
            guard previous.leaseID == reservation.leaseID, previous.generation == reservation.generation else {
                throw LateShardAdmissionRejection.unavailable(.missingShardLease)
            }
            let (sum, overflow) = previous.delta.addingReportingOverflow(delta)
            guard !overflow else { throw V2RoomWriteStoreError.corruptPersistenceState }
            groups[key] = .init(shard: shard, profile: profile, leaseID: reservation.leaseID,
                generation: reservation.generation, delta: sum)
        } else {
            groups[key] = .init(shard: shard, profile: profile, leaseID: reservation.leaseID,
                generation: reservation.generation, delta: delta)
        }
    }
    let ordered = groups.values.sorted { lhs, rhs in
        lhs.shard == rhs.shard ? lhs.profile < rhs.profile : lhs.shard < rhs.shard
    }
    if ordered.count == 1, let group = ordered.first {
        // One predetermined quota row needs no preceding lock SELECT. UPDATE
        // waits for its current version and rechecks the complete WHERE under
        // READ COMMITTED EPQ; SET must use that version's counter, not preflight.
        // Only a successfully settled zero-row statement may use the original
        // fresh-snapshot path below (e.g. a concurrent window reset/refresh).
        let updateFuture: EventLoopFuture<[any SQLRow]> = sql.raw("""
            /* imv2_admission_fast_update */
            UPDATE im_v2.shard_admission_pools AS pool
            SET command_window_used=pool.command_window_used+\(bind: group.delta)
            WHERE pool.room_shard_id=\(bind: group.shard)
              AND pool.capacity_profile_id=\(bind: group.profile)
              AND pool.lease_id=\(bind: group.leaseID)
              AND pool.generation=\(bind: group.generation)
              AND pool.valid_until>\(bind: now)
              AND pool.command_window_used<=pool.command_window_limit-\(bind: group.delta)
            RETURNING pool.room_shard_id,pool.capacity_profile_id,pool.lease_id,pool.generation,
                      pool.valid_until,pool.command_window_used,pool.command_window_limit
            """).all()
        let updateRows = try await updateFuture.map { rows in
            admissionTrace?.resultReady()
            return rows
        }.get()
        let updated = try updateRows.map { try $0.decode(model: DurableAdmissionUpdatedRow.self) }
        if !updated.isEmpty {
            // A mutation followed by decoding/validation failure cannot enter
            // fallback and charge again. Fail closed for the outer rollback.
            guard updated.count == 1, let row = updated.first,
                  row.shard == group.shard, row.profile == group.profile,
                  row.leaseID == group.leaseID, row.generation == group.generation,
                  row.validUntil > now, row.used >= group.delta,
                  row.limit >= group.delta, row.used <= row.limit else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            admissionTrace?.validated(path: .singleSuccess)
            return
        }
    }
    let input = String(decoding: try JSONEncoder().encode(ordered), as: UTF8.self)
    // Complete the ordered lock SELECT before constructing the UPDATE's
    // READ COMMITTED snapshot. Both statements belong to the same actual
    // owner transaction; no quota is reserved before the final gate below.
    let lockedRows = try await sql.raw("""
        /* imv2_admission_lock_select */
        WITH input AS MATERIALIZED (
          SELECT * FROM jsonb_to_recordset(\(bind: input)::jsonb)
            AS item(room_shard_id text, capacity_profile_id text, lease_id uuid, generation bigint, delta bigint)
        )
        SELECT pool.room_shard_id, pool.capacity_profile_id
        FROM im_v2.shard_admission_pools pool
        JOIN input ON input.room_shard_id=pool.room_shard_id AND input.capacity_profile_id=pool.capacity_profile_id
        ORDER BY pool.room_shard_id, pool.capacity_profile_id FOR NO KEY UPDATE OF pool
        """).all(decoding: DurableAdmissionLockedKey.self)
    let lockedKeys = lockedRows.map { DurableAdmissionKey(shard: $0.shard, profile: $0.profile) }
    guard Set(lockedKeys).count == lockedKeys.count, lockedKeys.count <= ordered.count else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    // A missing row cannot be silently discovered in the next statement:
    // a concurrent insertion would not be protected by our first lock set.
    guard lockedKeys.count == ordered.count, Set(lockedKeys) == Set(groups.keys) else {
        throw LateShardAdmissionRejection.unavailable(.missingShardLease)
    }
    // Only the non-key used counter changes. NO KEY UPDATE serializes quota
    // writers and fences lease/key changes while allowing FK KEY SHARE locks.
    // The following read observes the fresh snapshot under the acquired locks;
    // missing/changed leases and quota failures retain the whole-cohort gate.
    let gateFuture: EventLoopFuture<[any SQLRow]> = sql.raw("""
        /* imv2_admission_gate_update */
        WITH input AS MATERIALIZED (
          SELECT * FROM jsonb_to_recordset(\(bind: input)::jsonb)
            AS item(room_shard_id text, capacity_profile_id text, lease_id uuid, generation bigint, delta bigint)
        ), locked AS MATERIALIZED (
          SELECT pool.* FROM im_v2.shard_admission_pools pool
          JOIN input ON input.room_shard_id=pool.room_shard_id AND input.capacity_profile_id=pool.capacity_profile_id
          ORDER BY pool.room_shard_id, pool.capacity_profile_id
        ), checked AS MATERIALIZED (
          SELECT input.*, CASE
            WHEN locked.room_shard_id IS NULL OR locked.lease_id<>input.lease_id OR locked.generation<>input.generation THEN 'missing'
            WHEN locked.valid_until<=\(bind: now) THEN 'expired'
            WHEN locked.command_window_used>locked.command_window_limit-input.delta THEN 'rate'
            ELSE NULL END AS failure
          FROM input LEFT JOIN locked USING (room_shard_id, capacity_profile_id)
        ), gate AS MATERIALIZED (
          SELECT count(*)::bigint AS expected_count,
                 count(*) FILTER (WHERE failure IS NOT NULL)::bigint AS failed_count,
                 CASE WHEN bool_or(failure='missing') THEN 'missing'
                      WHEN bool_or(failure='expired') THEN 'expired'
                      WHEN bool_or(failure='rate') THEN 'rate' ELSE NULL END AS failure
          FROM checked
        ), applied AS (
          UPDATE im_v2.shard_admission_pools pool
          SET command_window_used=pool.command_window_used+checked.delta
          FROM checked CROSS JOIN gate
          WHERE gate.failed_count=0 AND pool.room_shard_id=checked.room_shard_id
            AND pool.capacity_profile_id=checked.capacity_profile_id
            AND pool.lease_id=checked.lease_id AND pool.generation=checked.generation
            AND pool.valid_until>\(bind: now)
            AND pool.command_window_used<=pool.command_window_limit-checked.delta
          RETURNING pool.room_shard_id
        )
        SELECT gate.expected_count, (SELECT count(*)::bigint FROM applied) AS applied_count, gate.failure FROM gate
        """).all()
    let gateRows = try await gateFuture.map { rows in
        admissionTrace?.resultReady()
        return rows
    }.get()
    guard gateRows.count == 1, let gateRow = gateRows.first else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    let result = try gateRow.decode(model: DurableAdmissionResult.self)
    guard result.expectedCount == Int64(ordered.count) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    switch result.failure {
    case "missing": throw LateShardAdmissionRejection.unavailable(.missingShardLease)
    case "expired": throw LateShardAdmissionRejection.unavailable(.expiredShardLease)
    case "rate": throw LateShardAdmissionRejection.rateLimited(retryAfterSeconds: retryAfterSeconds)
    case nil:
        guard result.appliedCount == result.expectedCount else {
            throw LateShardAdmissionRejection.unavailable(.missingShardLease)
        }
    default: throw V2RoomWriteStoreError.corruptPersistenceState
    }
    admissionTrace?.validated(path: ordered.count == 1 ? .singleFallback : .multiGroup)
}

private struct DurableAdmissionKey: Hashable { let shard: String; let profile: String }
private struct DurableAdmissionInput: Encodable {
    let shard: String; let profile: String; let leaseID: UUID; let generation: Int64; let delta: Int64
    enum CodingKeys: String, CodingKey {
        case shard = "room_shard_id", profile = "capacity_profile_id", leaseID = "lease_id", generation, delta
    }
}
private struct DurableAdmissionLockedKey: Decodable {
    let shard: String
    let profile: String
    enum CodingKeys: String, CodingKey {
        case shard = "room_shard_id", profile = "capacity_profile_id"
    }
}
private struct DurableAdmissionResult: Decodable {
    let expectedCount: Int64; let appliedCount: Int64; let failure: String?
    enum CodingKeys: String, CodingKey { case expectedCount = "expected_count", appliedCount = "applied_count", failure }
}

private struct DurableAdmissionUpdatedRow: Decodable {
    let shard: String
    let profile: String
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let used: Int64
    let limit: Int64
    enum CodingKeys: String, CodingKey {
        case shard = "room_shard_id", profile = "capacity_profile_id", leaseID = "lease_id"
        case generation, validUntil = "valid_until", used = "command_window_used", limit = "command_window_limit"
    }
}
