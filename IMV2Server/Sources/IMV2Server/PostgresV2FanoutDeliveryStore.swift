import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Commits a target's user-sync projection and advances the completion unit in
/// the same transaction. A consumer-inbox row makes broker redelivery safe.
public struct PostgresV2FanoutDeliveryStore: V2FanoutDeliveryStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID
    private let consumerName = "v2-fanout-delivery"

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func claimPending(bucket: String?, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease] {
        guard leaseDuration > 0, limit > 0 else { return [] }
        let token = makeUUID()
        let expiry = now.addingTimeInterval(leaseDuration)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows: [ClaimedDeliveryRow]
            if let bucket {
                rows = try await sql.raw("""
                    WITH candidates AS (
                        SELECT delivery.source_event_id, delivery.target_user_id, delivery.projection_kind
                        FROM im_v2.fanout_deliveries AS delivery
                        JOIN im_v2.fanout_plans AS plan
                          ON plan.source_event_id = delivery.source_event_id
                        WHERE delivery.target_shard_bucket = \(bind: bucket) AND delivery.state = 'pending'
                          AND plan.state = 'planned'
                          AND (delivery.next_attempt_at IS NULL OR delivery.next_attempt_at <= \(bind: now))
                          AND (delivery.lease_expires_at IS NULL OR delivery.lease_expires_at <= \(bind: now))
                        ORDER BY delivery.source_event_id, delivery.target_user_id
                        LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                    )
                    UPDATE im_v2.fanout_deliveries AS delivery
                    SET claim_token = \(bind: token), lease_expires_at = \(bind: expiry), retry_count = delivery.retry_count + 1
                    FROM candidates
                    WHERE delivery.source_event_id = candidates.source_event_id
                      AND delivery.target_user_id = candidates.target_user_id
                      AND delivery.projection_kind = candidates.projection_kind
                    RETURNING delivery.source_event_id, delivery.target_user_id, delivery.projection_kind, delivery.completion_unit_id,
                              delivery.target_shard_bucket, delivery.observed_router_epoch, delivery.retry_count
                    """).all(decoding: ClaimedDeliveryRow.self)
            } else {
                rows = try await sql.raw("""
                    WITH candidates AS (
                        SELECT delivery.source_event_id, delivery.target_user_id, delivery.projection_kind
                        FROM im_v2.fanout_deliveries AS delivery
                        JOIN im_v2.fanout_plans AS plan
                          ON plan.source_event_id = delivery.source_event_id
                        WHERE delivery.state = 'pending' AND plan.state = 'planned'
                          AND (delivery.next_attempt_at IS NULL OR delivery.next_attempt_at <= \(bind: now))
                          AND (delivery.lease_expires_at IS NULL OR delivery.lease_expires_at <= \(bind: now))
                        ORDER BY delivery.source_event_id, delivery.target_user_id
                        LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                    )
                    UPDATE im_v2.fanout_deliveries AS delivery
                    SET claim_token = \(bind: token), lease_expires_at = \(bind: expiry), retry_count = delivery.retry_count + 1
                    FROM candidates
                    WHERE delivery.source_event_id = candidates.source_event_id
                      AND delivery.target_user_id = candidates.target_user_id
                      AND delivery.projection_kind = candidates.projection_kind
                    RETURNING delivery.source_event_id, delivery.target_user_id, delivery.projection_kind, delivery.completion_unit_id,
                              delivery.target_shard_bucket, delivery.observed_router_epoch, delivery.retry_count
                    """).all(decoding: ClaimedDeliveryRow.self)
            }
            return try rows.map {
                .init(
                    sourceEventID: try EventID($0.sourceEventID.uuidString),
                    targetUserID: try UserID($0.targetUserID.uuidString),
                    projectionKind: $0.projectionKind,
                    completionUnitID: try CompletionUnitID($0.completionUnitID.uuidString),
                    observedRoute: try .init(bucket: $0.targetShardBucket, observedRouterEpoch: $0.observedRouterEpoch),
                    claimToken: token,
                    attempt: try deliveryRetryAttempt($0.retryCount)
                )
            }
        }
    }

    public func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit {
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let delivery = try await claimedDelivery(
                sql: sql, sourceEventID: sourceEventID, targetUserID: targetUserID, lease: lease
            )
            else { return .staleLease }

            let insertedInbox = try await sql.raw("""
                INSERT INTO im_v2.consumer_inbox
                    (consumer_name, source_event_id, target_user_id, projection_kind, committed_at)
                VALUES (\(bind: consumerName), \(bind: sourceEventID), \(bind: targetUserID), \(bind: lease.projectionKind), \(bind: now))
                ON CONFLICT DO NOTHING
                RETURNING source_event_id
                """).first(decoding: InboxInsertRow.self) != nil
            guard insertedInbox else { throw V2FanoutDeliveryError.inboxAlreadyCommitted }

            guard let sequence = try await sql.raw("""
                INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence)
                VALUES (\(bind: targetUserID), 1)
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1
                RETURNING next_sequence
                """).first(decoding: SyncSequenceRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            try await sql.raw("""
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                SELECT \(bind: targetUserID), \(bind: sequence.nextSequence), event.event_id, \(bind: lease.projectionKind),
                       jsonb_build_object('source_event_id', event.event_id::text,
                                          'projection_kind', \(bind: lease.projectionKind)) || event.payload,
                       \(bind: now)
                FROM im_v2.room_events AS event WHERE event.event_id = \(bind: sourceEventID)
                """).run()
            return try await completeClaimedDelivery(
                sql: sql, delivery: delivery, sourceEventID: sourceEventID,
                targetUserID: targetUserID, projectionKind: lease.projectionKind,
                userSyncSequence: try unsigned(sequence.nextSequence), now: now
            )
        }
    }

    /// Reads a claimed delivery's immutable event payload from the control
    /// store. The result contains no physical address and is safe to hand to
    /// a target-store projector after the claim has been fenced.
    public func projectionInput(for lease: V2FanoutDeliveryLease) async throws -> V2FanoutProjectionInput? {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        let row = try await sql.raw("""
            SELECT event.payload::text AS event_payload_json
            FROM im_v2.fanout_deliveries AS delivery
            JOIN im_v2.room_events AS event ON event.event_id = delivery.source_event_id
            WHERE delivery.source_event_id = \(bind: sourceEventID)
              AND delivery.target_user_id = \(bind: targetUserID)
              AND delivery.projection_kind = \(bind: lease.projectionKind)
              AND delivery.state = 'pending' AND delivery.claim_token = \(bind: lease.claimToken)
            """).first(decoding: ProjectionInputRow.self)
        guard let row else { return nil }
        return .init(
            sourceEventID: lease.sourceEventID, targetUserID: lease.targetUserID,
            projectionKind: lease.projectionKind, eventPayloadJSON: row.eventPayloadJSON
        )
    }

    /// Commits only the control-store completion side after a target store has
    /// durably projected the exact inbox effect. The lease fence turns a late
    /// target acknowledgement into `staleLease`, leaving no way to double
    /// increment a completion unit.
    public func completeExternal(
        _ lease: V2FanoutDeliveryLease, userSyncSequence: UInt64, now: Date
    ) async throws -> V2FanoutDeliveryCommit {
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let delivery = try await claimedDelivery(
                sql: sql, sourceEventID: sourceEventID, targetUserID: targetUserID, lease: lease
            )
            else { return .staleLease }
            return try await completeClaimedDelivery(
                sql: sql, delivery: delivery, sourceEventID: sourceEventID,
                targetUserID: targetUserID, projectionKind: lease.projectionKind,
                userSyncSequence: userSyncSequence, now: now
            )
        }
    }

    public func release(_ lease: V2FanoutDeliveryLease) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        try await sql.raw("""
            UPDATE im_v2.fanout_deliveries
            SET claim_token = NULL, lease_expires_at = NULL, next_attempt_at = NULL
            WHERE source_event_id = \(bind: sourceEventID)
              AND target_user_id = \(bind: targetUserID)
              AND projection_kind = \(bind: lease.projectionKind)
              AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
        """).run()
    }

    public func handoff(_ lease: V2FanoutDeliveryLease, to route: V2UserShardRoute) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        try await sql.raw("""
            UPDATE im_v2.fanout_deliveries
            SET target_shard_bucket = \(bind: route.bucket),
                observed_router_epoch = \(bind: route.observedRouterEpoch),
                claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, paused_at = NULL,
                last_failure_code = NULL
            WHERE source_event_id = \(bind: sourceEventID)
              AND target_user_id = \(bind: targetUserID)
              AND projection_kind = \(bind: lease.projectionKind)
              AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
        """).run()
    }

    public func scheduleRetry(_ lease: V2FanoutDeliveryLease, disposition: V2DurableRetryDisposition, now: Date) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        switch disposition {
        case .retry(let retryAt):
            try await sql.raw("""
                UPDATE im_v2.fanout_deliveries
                SET claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = \(bind: retryAt), paused_at = NULL,
                    last_failure_code = 'worker_failure'
                WHERE source_event_id = \(bind: sourceEventID)
                  AND target_user_id = \(bind: targetUserID)
                  AND projection_kind = \(bind: lease.projectionKind)
                  AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
                """).run()
        case .pause:
            try await sql.raw("""
                UPDATE im_v2.fanout_deliveries
                SET state = 'paused', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = \(bind: now),
                    last_failure_code = 'retry_exhausted'
                WHERE source_event_id = \(bind: sourceEventID)
                  AND target_user_id = \(bind: targetUserID)
                  AND projection_kind = \(bind: lease.projectionKind)
                  AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
                """).run()
        }
    }

    public func requeuePaused(sourceEventID: EventID, targetUserID: UserID, projectionKind: String) async throws {
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.fanout_deliveries
            SET state = 'pending', claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL,
                retry_count = 0
            WHERE source_event_id = \(bind: try uuid(sourceEventID))
              AND target_user_id = \(bind: try uuid(targetUserID))
              AND projection_kind = \(bind: projectionKind)
              AND state = 'paused'
        """).run()
    }

    private func claimedDelivery(
        sql: any SQLDatabase, sourceEventID: UUID, targetUserID: UUID,
        lease: V2FanoutDeliveryLease
    ) async throws -> ClaimedDeliveryRow? {
        try await sql.raw("""
            SELECT source_event_id, target_user_id, projection_kind, completion_unit_id,
                   target_shard_bucket, observed_router_epoch, retry_count
            FROM im_v2.fanout_deliveries
            WHERE source_event_id = \(bind: sourceEventID)
              AND target_user_id = \(bind: targetUserID)
              AND projection_kind = \(bind: lease.projectionKind)
              AND state = 'pending' AND claim_token = \(bind: lease.claimToken)
            FOR UPDATE
            """).first(decoding: ClaimedDeliveryRow.self)
    }

    private func completeClaimedDelivery(
        sql: any SQLDatabase, delivery: ClaimedDeliveryRow, sourceEventID: UUID,
        targetUserID: UUID, projectionKind: String, userSyncSequence: UInt64, now: Date
    ) async throws -> V2FanoutDeliveryCommit {
        guard userSyncSequence <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            UPDATE im_v2.fanout_deliveries
            SET state = 'terminal', claim_token = NULL, lease_expires_at = NULL,
                next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL
            WHERE source_event_id = \(bind: sourceEventID)
              AND target_user_id = \(bind: targetUserID)
              AND projection_kind = \(bind: projectionKind)
            """).run()
        guard let unit = try await sql.raw("""
            UPDATE im_v2.fanout_completion_units
            SET committed_target_count = committed_target_count + 1,
                state = CASE
                    WHEN committed_target_count + policy_skipped_target_count + 1 = target_count THEN 'terminal'
                    ELSE 'pending'
                END,
                lease_expires_at = NULL
            WHERE source_event_id = \(bind: delivery.sourceEventID)
              AND completion_unit_id = \(bind: delivery.completionUnitID)
              AND state = 'pending'
            RETURNING target_count, state
            """).first(decoding: CompletionUnitRow.self)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard unit.state == "terminal" else {
            return .committed(userSyncSequence: userSyncSequence, releasedCompletionUnit: false, closedPlan: false)
        }
        let closesPlan = try await releaseTerminalUnit(
            sql: sql, sourceEventID: sourceEventID,
            completionUnitID: delivery.completionUnitID, targetCount: unit.targetCount, now: now
        )
        return .committed(userSyncSequence: userSyncSequence, releasedCompletionUnit: true, closedPlan: closesPlan)
    }

    private func releaseTerminalUnit(
        sql: any SQLDatabase,
        sourceEventID: UUID,
        completionUnitID: UUID,
        targetCount: Int,
        now: Date
    ) async throws -> Bool {
        guard let plan = try await sql.raw("""
            SELECT room_id, state FROM im_v2.fanout_plans
            WHERE source_event_id = \(bind: sourceEventID) FOR UPDATE
            """).first(decoding: ReleasePlanRow.self), plan.state == "planned"
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let hasOtherUnreleasedUnits = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM im_v2.fanout_completion_units
                WHERE source_event_id = \(bind: sourceEventID)
                  AND completion_unit_id <> \(bind: completionUnitID)
                  AND state <> 'released'
            ) AS value
            """).first(decoding: BooleanRow.self)?.value ?? true
        guard let room = try await sql.raw("""
            SELECT room_shard_id, capacity_profile_id FROM im_v2.rooms WHERE room_id = \(bind: plan.roomID) FOR UPDATE
            """).first(decoding: ReleaseRoomRow.self),
            let admission = try await sql.raw("""
            SELECT eligible_member_count, command_window_limit, command_window_used,
                   fanout_window_limit, fanout_window_used, outstanding_fanout_units, outstanding_plans,
                   shard_lease_id, shard_lease_generation
            FROM im_v2.room_admission WHERE room_id = \(bind: plan.roomID) FOR UPDATE
            """).first(decoding: ReleaseAdmissionRow.self),
            let shard = try await sql.raw("""
            SELECT lease_id, generation, pool.capacity_profile_id, command_window_limit, command_window_used,
                   fanout_window_limit, fanout_window_used, max_outstanding_fanout_units,
                   outstanding_fanout_units, max_outstanding_plans, outstanding_plans
            FROM im_v2.shard_admission_pools AS pool
            JOIN im_v2.rooms AS room ON room.room_shard_id = pool.room_shard_id
            WHERE room.room_id = \(bind: plan.roomID)
              AND pool.capacity_profile_id = room.capacity_profile_id
            FOR UPDATE OF pool
            """).first(decoding: ReleaseShardRow.self)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard room.capacityProfileID == shard.capacityProfileID,
              admission.shardLeaseID == shard.leaseID,
              admission.shardLeaseGeneration == shard.generation
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        let reduced = try FanoutAdmissionEvaluator.release(
            completedUnit: try FanoutCost(targetCount: targetCount),
            roomState: try admission.roomState(),
            shardState: try shard.shardState(),
            closesPlan: !hasOtherUnreleasedUnits
        )
        try await sql.raw("""
            UPDATE im_v2.room_admission
            SET outstanding_fanout_units = \(bind: reduced.roomState.outstandingFanoutUnits),
                outstanding_plans = \(bind: reduced.roomState.outstandingPlans)
            WHERE room_id = \(bind: plan.roomID)
            """).run()
        try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET outstanding_fanout_units = \(bind: reduced.shardState.outstandingFanoutUnits),
                outstanding_plans = \(bind: reduced.shardState.outstandingPlans)
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND lease_id = \(bind: shard.leaseID) AND generation = \(bind: shard.generation)
            """).run()
        try await sql.raw("""
            UPDATE im_v2.fanout_completion_units
            SET state = 'released', released_at = \(bind: now)
            WHERE source_event_id = \(bind: sourceEventID) AND completion_unit_id = \(bind: completionUnitID)
              AND state = 'terminal'
            """).run()
        if !hasOtherUnreleasedUnits {
            try await sql.raw("""
                UPDATE im_v2.fanout_plans SET state = 'terminal', terminal_at = \(bind: now)
                WHERE source_event_id = \(bind: sourceEventID)
                """).run()
            // A source outbox row is complete only after the immutable plan
            // and every completion unit have a durable terminal outcome. Do
            // this in the final unit-release transaction so a crashed worker
            // cannot leave a plan terminal while its source work is still
            // advertised as pending/published. This also safely closes tests
            // and recovery paths that progress a persisted plan directly,
            // without first sending a broker hint.
            try await sql.raw("""
                UPDATE im_v2.room_outbox
                SET state = 'terminal', claim_token = NULL,
                    lease_expires_at = NULL, next_attempt_at = NULL,
                    paused_at = NULL, last_failure_code = NULL,
                    terminal_at = \(bind: now)
                WHERE source_event_id = \(bind: sourceEventID)
                  AND state <> 'terminal'
                """).run()
        }
        return !hasOtherUnreleasedUnits
    }
}

public enum V2FanoutDeliveryError: Error, Equatable, Sendable { case inboxAlreadyCommitted }

private struct ClaimedDeliveryRow: Decodable {
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let completionUnitID: UUID
    let targetShardBucket: String
    let observedRouterEpoch: Int64
    let retryCount: Int64
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", targetUserID = "target_user_id", projectionKind = "projection_kind", completionUnitID = "completion_unit_id", targetShardBucket = "target_shard_bucket", observedRouterEpoch = "observed_router_epoch", retryCount = "retry_count" }
}
private struct ProjectionInputRow: Decodable {
    let eventPayloadJSON: String
    enum CodingKeys: String, CodingKey { case eventPayloadJSON = "event_payload_json" }
}
private struct InboxInsertRow: Decodable { let sourceEventID: UUID; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" } }
private struct SyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private struct CompletionUnitRow: Decodable { let targetCount: Int; let state: String; enum CodingKeys: String, CodingKey { case targetCount = "target_count", state } }
private struct ReleasePlanRow: Decodable { let roomID: UUID; let state: String; enum CodingKeys: String, CodingKey { case roomID = "room_id", state } }
private struct ReleaseRoomRow: Decodable {
    let roomShardID: String; let capacityProfileID: String
    enum CodingKeys: String, CodingKey { case roomShardID = "room_shard_id", capacityProfileID = "capacity_profile_id" }
}
private struct BooleanRow: Decodable { let value: Bool }

private func deliveryRetryAttempt(_ value: Int64) throws -> Int {
    guard value > 0, value <= Int64(Int.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int(value)
}

private struct ReleaseAdmissionRow: Decodable {
    let eligibleMemberCount: Int; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let outstandingFanoutUnits: Int; let outstandingPlans: Int; let shardLeaseID: UUID; let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey { case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", outstandingFanoutUnits = "outstanding_fanout_units", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation" }
    func roomState() throws -> RoomAdmissionState { try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) }
}

private struct ReleaseShardRow: Decodable {
    let leaseID: UUID; let generation: Int64; let capacityProfileID: String; let commandWindowLimit: Int; let commandWindowUsed: Int; let fanoutWindowLimit: Int; let fanoutWindowUsed: Int; let maxOutstandingFanoutUnits: Int; let outstandingFanoutUnits: Int; let maxOutstandingPlans: Int; let outstandingPlans: Int
    enum CodingKeys: String, CodingKey { case leaseID = "lease_id", generation, capacityProfileID = "capacity_profile_id", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans" }
    func shardState() throws -> ShardAdmissionState { try .init(lease: .init(id: try .init(leaseID.uuidString), generation: try unsigned(generation), validUntil: .distantFuture, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans) }
}

private func uuid<Tag>(_ identifier: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = UUID(uuidString: identifier.rawValue) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}
private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
