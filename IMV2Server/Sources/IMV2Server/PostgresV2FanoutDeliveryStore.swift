import Fluent
import Foundation
import IMV2Core
import SQLKit

/// A target-store projection acknowledged back to the authoritative fan-out
/// control store. The sequence is already durable in the user shard; this
/// value is used only for the resulting worker report after the lease-fenced
/// control completion commits.
public struct V2ExternalFanoutDeliveryAcknowledgement: Sendable {
    public let lease: V2FanoutDeliveryLease
    public let userSyncSequence: UInt64

    public init(lease: V2FanoutDeliveryLease, userSyncSequence: UInt64) {
        self.lease = lease
        self.userSyncSequence = userSyncSequence
    }
}

/// Commits a target's user-sync projection and advances the completion unit in
/// the same transaction. A consumer-inbox row makes broker redelivery safe.
public struct PostgresV2FanoutDeliveryStore: V2FanoutDeliveryStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID
    private let batchSequenceReservationStrategy: V2FanoutBatchSequenceReservationStrategy
    private let consumerName = "v2-fanout-delivery"

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
        batchSequenceReservationStrategy = .automatic
    }

    /// Internal only so the isolated capacity regression can compare the
    /// general repeated-user query with its standard fan-out fast path. The
    /// running server always uses `.automatic` through the public initializer.
    init(
        database: any Database,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        batchSequenceReservationStrategy: V2FanoutBatchSequenceReservationStrategy
    ) {
        self.database = database
        self.makeUUID = makeUUID
        self.batchSequenceReservationStrategy = batchSequenceReservationStrategy
    }

    public func claimPending(bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease] {
        return try await claimPendingRows(
            bucket: bucket, lane: lane, now: now, leaseDuration: leaseDuration,
            limit: limit
        )
    }

    /// Cross-store delivery inlines a bounded immutable source payload on
    /// every claimed lease. A larger payload is emitted once per source event
    /// in that same lease-fenced result; the cross-store worker then expands
    /// it in memory for the other leases of that event. This prevents a
    /// member-count-scaled response without adding a second control-store
    /// query. It is deliberately separate from the protocol-level claim
    /// method: co-located fan-out never needs a payload in process memory
    /// before its one-database transaction.
    public func claimPendingIncludingProjectionPayload(
        bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date,
        leaseDuration: TimeInterval, limit: Int,
        maximumInlinePayloadBytes: Int
    ) async throws -> [V2FanoutDeliveryLease] {
        precondition(maximumInlinePayloadBytes > 0)
        return try await claimPendingRows(
            bucket: bucket, lane: lane, now: now, leaseDuration: leaseDuration,
            limit: limit, maximumInlinePayloadBytes: maximumInlinePayloadBytes
        )
    }

    private func claimPendingRows(
        bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date,
        leaseDuration: TimeInterval, limit: Int, maximumInlinePayloadBytes: Int? = nil
    ) async throws -> [V2FanoutDeliveryLease] {
        guard leaseDuration > 0, limit > 0 else { return [] }
        let token = makeUUID()
        let expiry = now.addingTimeInterval(leaseDuration)
        let eligibility = lane.sqlEligibilityPredicate(now: now)
        let ordering = lane.sqlOrdering
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows: [ClaimedDeliveryRow]
            if let bucket {
                if let maximumInlinePayloadBytes {
                    rows = try await sql.raw("""
                        WITH candidates AS (
                            SELECT delivery.source_event_id, delivery.target_user_id, delivery.projection_kind
                            FROM im_v2.fanout_deliveries AS delivery
                            JOIN im_v2.fanout_plans AS plan
                              ON plan.source_event_id = delivery.source_event_id
                            WHERE delivery.target_shard_bucket = \(bind: bucket) AND delivery.state = 'pending'
                              AND plan.state = 'planned'
                              AND \(eligibility)
                            ORDER BY \(ordering)
                            LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                        ), claimed AS (
                            UPDATE im_v2.fanout_deliveries AS delivery
                            SET claim_token = \(bind: token), lease_expires_at = \(bind: expiry), retry_count = delivery.retry_count + 1
                            FROM candidates
                            WHERE delivery.source_event_id = candidates.source_event_id
                              AND delivery.target_user_id = candidates.target_user_id
                              AND delivery.projection_kind = candidates.projection_kind
                            RETURNING delivery.source_event_id, delivery.target_user_id, delivery.projection_kind, delivery.completion_unit_id,
                                      delivery.target_shard_bucket, delivery.observed_router_epoch, delivery.retry_count
                        ), source_events AS MATERIALIZED (
                            SELECT DISTINCT source_event_id FROM claimed
                        ), source_payloads AS MATERIALIZED (
                            SELECT source_events.source_event_id, event.payload::text AS event_payload_json
                            FROM source_events
                            JOIN im_v2.room_events AS event ON event.event_id = source_events.source_event_id
                        ), numbered AS MATERIALIZED (
                            SELECT claimed.*, ROW_NUMBER() OVER (
                                PARTITION BY source_event_id
                                ORDER BY target_user_id, projection_kind
                            ) AS payload_ordinal
                            FROM claimed
                        )
                        SELECT numbered.source_event_id, numbered.target_user_id, numbered.projection_kind,
                               numbered.completion_unit_id, numbered.target_shard_bucket,
                               numbered.observed_router_epoch, numbered.retry_count,
                               CASE WHEN octet_length(payload.event_payload_json) <= \(bind: maximumInlinePayloadBytes)
                                          OR numbered.payload_ordinal = 1
                                    THEN payload.event_payload_json ELSE NULL::text END AS event_payload_json
                        FROM numbered
                        LEFT JOIN source_payloads AS payload
                          ON payload.source_event_id = numbered.source_event_id
                        ORDER BY numbered.source_event_id, numbered.target_user_id, numbered.projection_kind
                        """).all(decoding: ClaimedDeliveryRow.self)
                } else {
                    rows = try await sql.raw("""
                    WITH candidates AS (
                        SELECT delivery.source_event_id, delivery.target_user_id, delivery.projection_kind
                        FROM im_v2.fanout_deliveries AS delivery
                        JOIN im_v2.fanout_plans AS plan
                          ON plan.source_event_id = delivery.source_event_id
                        WHERE delivery.target_shard_bucket = \(bind: bucket) AND delivery.state = 'pending'
                          AND plan.state = 'planned'
                          AND \(eligibility)
                        ORDER BY \(ordering)
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
            } else {
                if let maximumInlinePayloadBytes {
                    rows = try await sql.raw("""
                        WITH candidates AS (
                            SELECT delivery.source_event_id, delivery.target_user_id, delivery.projection_kind
                            FROM im_v2.fanout_deliveries AS delivery
                            JOIN im_v2.fanout_plans AS plan
                              ON plan.source_event_id = delivery.source_event_id
                            WHERE delivery.state = 'pending' AND plan.state = 'planned'
                              AND \(eligibility)
                            ORDER BY \(ordering)
                            LIMIT \(bind: limit) FOR UPDATE SKIP LOCKED
                        ), claimed AS (
                            UPDATE im_v2.fanout_deliveries AS delivery
                            SET claim_token = \(bind: token), lease_expires_at = \(bind: expiry), retry_count = delivery.retry_count + 1
                            FROM candidates
                            WHERE delivery.source_event_id = candidates.source_event_id
                              AND delivery.target_user_id = candidates.target_user_id
                              AND delivery.projection_kind = candidates.projection_kind
                            RETURNING delivery.source_event_id, delivery.target_user_id, delivery.projection_kind, delivery.completion_unit_id,
                                      delivery.target_shard_bucket, delivery.observed_router_epoch, delivery.retry_count
                        ), source_events AS MATERIALIZED (
                            SELECT DISTINCT source_event_id FROM claimed
                        ), source_payloads AS MATERIALIZED (
                            SELECT source_events.source_event_id, event.payload::text AS event_payload_json
                            FROM source_events
                            JOIN im_v2.room_events AS event ON event.event_id = source_events.source_event_id
                        ), numbered AS MATERIALIZED (
                            SELECT claimed.*, ROW_NUMBER() OVER (
                                PARTITION BY source_event_id
                                ORDER BY target_user_id, projection_kind
                            ) AS payload_ordinal
                            FROM claimed
                        )
                        SELECT numbered.source_event_id, numbered.target_user_id, numbered.projection_kind,
                               numbered.completion_unit_id, numbered.target_shard_bucket,
                               numbered.observed_router_epoch, numbered.retry_count,
                               CASE WHEN octet_length(payload.event_payload_json) <= \(bind: maximumInlinePayloadBytes)
                                          OR numbered.payload_ordinal = 1
                                    THEN payload.event_payload_json ELSE NULL::text END AS event_payload_json
                        FROM numbered
                        LEFT JOIN source_payloads AS payload
                          ON payload.source_event_id = numbered.source_event_id
                        ORDER BY numbered.source_event_id, numbered.target_user_id, numbered.projection_kind
                        """).all(decoding: ClaimedDeliveryRow.self)
                } else {
                    rows = try await sql.raw("""
                    WITH candidates AS (
                        SELECT delivery.source_event_id, delivery.target_user_id, delivery.projection_kind
                        FROM im_v2.fanout_deliveries AS delivery
                        JOIN im_v2.fanout_plans AS plan
                          ON plan.source_event_id = delivery.source_event_id
                        WHERE delivery.state = 'pending' AND plan.state = 'planned'
                          AND \(eligibility)
                        ORDER BY \(ordering)
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
            }
            return try rows.map {
                .init(
                    sourceEventID: try EventID($0.sourceEventID.uuidString),
                    targetUserID: try UserID($0.targetUserID.uuidString),
                    projectionKind: $0.projectionKind,
                    completionUnitID: try CompletionUnitID($0.completionUnitID.uuidString),
                    observedRoute: try .init(bucket: $0.targetShardBucket, observedRouterEpoch: $0.observedRouterEpoch),
                    claimToken: token,
                    attempt: try deliveryRetryAttempt($0.retryCount),
                    eventPayloadJSON: $0.eventPayloadJSON
                )
            }
        }
    }

    public func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit {
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return try await commit(sql: sql, lease: lease, now: now)
        }
    }

    /// Writes a small, deterministic group of user projections and their
    /// completion accounting in one PostgreSQL transaction. No work is
    /// partially committed: a failure rolls back every inbox, sequence, sync
    /// log and delivery-terminal update in the group. The worker then retries
    /// the whole group under the usual lease fence.
    public func commitBatch(_ leases: [V2FanoutDeliveryLease], now: Date) async throws -> [V2FanoutDeliveryCommit] {
        try await commitBatch(leases, fenceCurrentRoutes: false, now: now)
    }

    /// Production cross-store composition uses this path even when the target
    /// happens to be co-located with the control schema. The route comparison
    /// and projection/terminalization share one control transaction, so a
    /// cutover either waits for this old-owner commit or atomically reroutes
    /// the delivery before any old-owner projection is created.
    public func commitBatchFencedToCurrentRoutes(
        _ leases: [V2FanoutDeliveryLease], now: Date
    ) async throws -> [V2FanoutDeliveryCommit] {
        try await commitBatch(leases, fenceCurrentRoutes: true, now: now)
    }

    private func commitBatch(
        _ leases: [V2FanoutDeliveryLease], fenceCurrentRoutes: Bool, now: Date
    ) async throws -> [V2FanoutDeliveryCommit] {
        guard !leases.isEmpty else { return [] }
        let ordered = try leases.enumerated().map { index, lease in
            BatchFanoutDeliveryLease(index: index, lease: lease, key: try deliveryKey(for: lease))
        }.sorted { lhs, rhs in
            lhs.key < rhs.key
        }
        guard Set(ordered.map(\.key)).count == ordered.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            var results = Array<V2FanoutDeliveryCommit?>(repeating: nil, count: leases.count)
            let committable: [BatchFanoutDeliveryLease]
            if fenceCurrentRoutes {
                let routes = try await currentRoutes(
                    for: ordered.map { $0.lease.targetUserID }, sql: sql
                )
                var accepted: [BatchFanoutDeliveryLease] = []
                accepted.reserveCapacity(ordered.count)
                for (item, route) in zip(ordered, routes) {
                    guard route.writeIdentity != item.lease.observedRoute.writeIdentity else {
                        accepted.append(item)
                        continue
                    }
                    results[item.index] = try await handoffClaimed(
                        item.lease, to: route, sql: sql
                    ) ? .rerouted(route) : .staleLease
                }
                committable = accepted
            } else {
                committable = ordered
            }
            let prepared = try await projectAndTerminalizeBatch(sql: sql, ordered: committable, now: now)
            let committedIndexes = Set(prepared.map(\.index))
            for item in committable where !committedIndexes.contains(item.index) {
                results[item.index] = .staleLease
            }
            for (index, commit) in try await completeBatch(sql: sql, prepared: prepared, now: now) {
                results[index] = commit
            }
            guard results.allSatisfy({ $0 != nil }) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return results.map { $0! }
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

    /// Reads immutable event payloads for a bounded lease batch with one
    /// control-store statement. A missing item is a stale lease, exactly as
    /// `projectionInput(for:)` reports. The caller must still complete the
    /// target projection through the control-store lease fence: this read is
    /// intentionally not a distributed transaction with the target shard.
    public func projectionInputs(for leases: [V2FanoutDeliveryLease]) async throws -> [V2FanoutProjectionInput?] {
        guard !leases.isEmpty else { return [] }
        let input = try leases.enumerated().map { index, lease in
            LeasedProjectionInput(
                ordinal: index,
                sourceEventID: try uuid(lease.sourceEventID),
                targetUserID: try uuid(lease.targetUserID),
                projectionKind: lease.projectionKind,
                claimToken: lease.claimToken
            )
        }
        let identities = input.map {
            "\($0.sourceEventID.uuidString)|\($0.targetUserID.uuidString)|\($0.projectionKind)"
        }
        guard Set(identities).count == input.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let sql = database as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let inputJSON = try batchJSON(input)
        let rows = try await sql.raw("""
            WITH input AS (
                SELECT ordinal, source_event_id, target_user_id, projection_kind, claim_token
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    ordinal integer, source_event_id uuid, target_user_id uuid,
                    projection_kind text, claim_token uuid
                )
            ), valid AS MATERIALIZED (
                SELECT input.ordinal, input.source_event_id
                FROM input
                JOIN im_v2.fanout_deliveries AS delivery
                  ON delivery.source_event_id = input.source_event_id
                 AND delivery.target_user_id = input.target_user_id
                 AND delivery.projection_kind = input.projection_kind
                WHERE delivery.state = 'pending' AND delivery.claim_token = input.claim_token
            ), first_payload_rows AS MATERIALIZED (
                SELECT DISTINCT ON (valid.source_event_id)
                       valid.source_event_id, valid.ordinal,
                       event.payload::text AS event_payload_json
                FROM valid
                JOIN im_v2.room_events AS event ON event.event_id = valid.source_event_id
                ORDER BY valid.source_event_id, valid.ordinal
            )
            SELECT valid.ordinal, valid.source_event_id, payload.event_payload_json
            FROM valid
            LEFT JOIN first_payload_rows AS payload ON payload.ordinal = valid.ordinal
            ORDER BY valid.ordinal
            """).all(decoding: LeasedProjectionInputRow.self)
        var payloadsBySourceEvent: [UUID: String] = [:]
        for row in rows {
            guard let payload = row.eventPayloadJSON else { continue }
            guard payloadsBySourceEvent[row.sourceEventID] == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            payloadsBySourceEvent[row.sourceEventID] = payload
        }
        var results = Array<V2FanoutProjectionInput?>(repeating: nil, count: leases.count)
        for row in rows {
            guard results.indices.contains(row.ordinal), results[row.ordinal] == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let lease = leases[row.ordinal]
            guard try uuid(lease.sourceEventID) == row.sourceEventID,
                  let payload = payloadsBySourceEvent[row.sourceEventID]
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            results[row.ordinal] = .init(
                sourceEventID: lease.sourceEventID, targetUserID: lease.targetUserID,
                projectionKind: lease.projectionKind, eventPayloadJSON: payload
            )
        }
        return results
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
            let currentRoute = try await currentRoutes(for: [lease.targetUserID], sql: sql)[0]
            if currentRoute.writeIdentity != lease.observedRoute.writeIdentity {
                return try await handoffClaimed(lease, to: currentRoute, sql: sql)
                    ? .rerouted(currentRoute) : .staleLease
            }
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

    /// Completes a bounded set of target-store acknowledgements in one
    /// control-store transaction. This deliberately owns no target-store
    /// writes: a cross-database crash can leave an inbox effect committed
    /// before this control acknowledgement, and the next attempt must replay
    /// that idempotent target effect before trying this fence again.
    ///
    /// A stale lease is reported per item. Valid items terminalize their
    /// delivery rows together, then reuse the same completion-unit accounting
    /// and admission-release rules as the co-located batch path.
    public func completeExternalBatch(
        _ acknowledgements: [V2ExternalFanoutDeliveryAcknowledgement], now: Date
    ) async throws -> [V2FanoutDeliveryCommit] {
        guard !acknowledgements.isEmpty else { return [] }
        let ordered = try externalBatchAcknowledgementInputs(acknowledgements)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let currentRoutes = try await currentRoutes(
                for: acknowledgements.map { $0.lease.targetUserID }, sql: sql
            )
            var results = Array<V2FanoutDeliveryCommit?>(repeating: nil, count: acknowledgements.count)
            var committable: [ExternalBatchAcknowledgementInput] = []
            committable.reserveCapacity(ordered.count)
            for (input, route) in zip(ordered, currentRoutes) {
                let lease = acknowledgements[input.ordinal].lease
                guard route.writeIdentity != lease.observedRoute.writeIdentity else {
                    committable.append(input)
                    continue
                }
                results[input.ordinal] = try await handoffClaimed(
                    lease, to: route, sql: sql
                ) ? .rerouted(route) : .staleLease
            }
            let committableJSON = try batchJSON(committable)
            let terminalized = try await sql.raw("""
                WITH input AS (
                    SELECT ordinal, source_event_id, target_user_id, projection_kind,
                           claim_token, user_sync_sequence
                    FROM jsonb_to_recordset(\(bind: committableJSON)::jsonb) AS value(
                        ordinal integer, source_event_id uuid, target_user_id uuid,
                        projection_kind text, claim_token uuid, user_sync_sequence bigint
                    )
                ), claimed AS MATERIALIZED (
                    SELECT input.ordinal, input.source_event_id, input.target_user_id,
                           input.projection_kind, input.claim_token, input.user_sync_sequence,
                           delivery.completion_unit_id, delivery.target_shard_bucket,
                           delivery.observed_router_epoch, delivery.retry_count
                    FROM input
                    JOIN im_v2.fanout_deliveries AS delivery
                      ON delivery.source_event_id = input.source_event_id
                     AND delivery.target_user_id = input.target_user_id
                     AND delivery.projection_kind = input.projection_kind
                    WHERE delivery.state = 'pending' AND delivery.claim_token = input.claim_token
                    FOR UPDATE OF delivery
                )
                UPDATE im_v2.fanout_deliveries AS delivery
                SET state = 'terminal', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL
                FROM claimed
                WHERE delivery.source_event_id = claimed.source_event_id
                  AND delivery.target_user_id = claimed.target_user_id
                  AND delivery.projection_kind = claimed.projection_kind
                  AND delivery.state = 'pending' AND delivery.claim_token = claimed.claim_token
                RETURNING claimed.ordinal, claimed.source_event_id, claimed.target_user_id,
                          claimed.projection_kind, claimed.completion_unit_id,
                          claimed.target_shard_bucket, claimed.observed_router_epoch,
                          claimed.retry_count, claimed.user_sync_sequence
                """).all(decoding: ExternalBatchTerminalizedRow.self)
            let terminalizedIndexes = Set(terminalized.map(\.ordinal))
            for input in committable where !terminalizedIndexes.contains(input.ordinal) {
                results[input.ordinal] = .staleLease
            }
            var prepared: [PreparedFanoutDeliveryCommit] = []
            prepared.reserveCapacity(terminalized.count)
            for row in terminalized {
                guard ordered.indices.contains(row.ordinal) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let acknowledgement = acknowledgements[row.ordinal]
                let expectedSourceEventID = try uuid(acknowledgement.lease.sourceEventID)
                let expectedTargetUserID = try uuid(acknowledgement.lease.targetUserID)
                guard row.sourceEventID == expectedSourceEventID,
                      row.targetUserID == expectedTargetUserID,
                      row.projectionKind == acknowledgement.lease.projectionKind,
                      row.userSyncSequence == Int64(acknowledgement.userSyncSequence)
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                prepared.append(.init(
                    index: row.ordinal,
                    lease: acknowledgement.lease,
                    delivery: .init(
                        sourceEventID: row.sourceEventID, targetUserID: row.targetUserID,
                        projectionKind: row.projectionKind, completionUnitID: row.completionUnitID,
                        targetShardBucket: row.targetShardBucket,
                        observedRouterEpoch: row.observedRouterEpoch,
                        retryCount: row.retryCount,
                        eventPayloadJSON: nil
                    ),
                    userSyncSequence: try unsigned(row.userSyncSequence)
                ))
            }
            for (index, commit) in try await completeBatch(sql: sql, prepared: prepared, now: now) {
                results[index] = commit
            }
            guard results.allSatisfy({ $0 != nil }) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return results.map { $0! }
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
        _ = try await handoffClaimed(lease, to: route, sql: sql)
    }

    /// Per-user advisory share locks are the cutover barrier. Route control
    /// takes the exclusive form before changing that user's override. The
    /// global configuration row remains readable so an unrelated user's
    /// routed operation never serializes every user in the deployment.
    private func currentRoutes(
        for users: [UserID], sql: any SQLDatabase
    ) async throws -> [V2UserShardRoute] {
        guard !users.isEmpty else { return [] }
        let requested = try users.enumerated().map { index, user in
            guard let userID = UUID(uuidString: user.rawValue) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return RouterFenceInput(ordinal: index, userID: userID)
        }
        // The global configuration lock prevents an epoch change. Per-user
        // advisory locks let unrelated users continue while serializing this
        // batch with route finalization/cutover for exactly these identities.
        let lockUsers = Array(Set(users.map(\.rawValue))).sorted()
        for user in lockUsers {
            try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: user), 0))").run()
        }
        guard try await sql.raw("""
            SELECT router_epoch
            FROM im_v2.user_shard_router_configuration
            WHERE configuration_key = TRUE
            """).first(decoding: RouterFenceConfigurationRow.self) != nil
        else { throw V2UserShardRouteControlError.missingRouterConfiguration }
        let inputJSON = try batchJSON(requested)
        let rows = try await sql.raw("""
            WITH input AS (
                SELECT ordinal, user_id
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    ordinal integer, user_id uuid
                )
            )
            SELECT input.ordinal,
                   COALESCE(route.write_bucket, config.default_write_bucket) AS write_bucket,
                   COALESCE(route.router_epoch, config.router_epoch) AS router_epoch,
                   COALESCE(route.read_fallback_bucket, config.default_read_fallback_bucket) AS read_fallback_bucket
            FROM input
            CROSS JOIN im_v2.user_shard_router_configuration AS config
            LEFT JOIN im_v2.user_shard_route_overrides AS route ON route.user_id = input.user_id
            WHERE config.configuration_key = TRUE
            ORDER BY input.ordinal
            """).all(decoding: RouterFenceRouteRow.self)
        guard rows.count == users.count else { throw V2UserShardRouterError.resultCountMismatch }
        return try rows.enumerated().map { index, row in
            guard row.ordinal == index else { throw V2UserShardRouterError.resultCountMismatch }
            return try .init(
                bucket: row.writeBucket, observedRouterEpoch: row.routerEpoch,
                readFallbackBucket: row.readFallbackBucket
            )
        }
    }

    @discardableResult
    private func handoffClaimed(
        _ lease: V2FanoutDeliveryLease, to route: V2UserShardRoute,
        sql: any SQLDatabase
    ) async throws -> Bool {
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        return try await sql.raw("""
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
            RETURNING source_event_id
        """).first(decoding: HandoffClaimedRow.self) != nil
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

    private func commit(
        sql: any SQLDatabase, lease: V2FanoutDeliveryLease, now: Date
    ) async throws -> V2FanoutDeliveryCommit {
        guard let projection = try await prepareCommit(sql: sql, lease: lease, now: now) else {
            return .staleLease
        }
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        return try await completeClaimedDelivery(
            sql: sql, delivery: projection.delivery, sourceEventID: sourceEventID,
            targetUserID: targetUserID, projectionKind: lease.projectionKind,
            userSyncSequence: projection.userSyncSequence, now: now
        )
    }

    /// Creates the inbox-backed user projection but deliberately leaves the
    /// fan-out delivery pending. The batch finisher terminalizes all prepared
    /// deliveries and updates each completion unit exactly once.
    private func prepareCommit(
        sql: any SQLDatabase, lease: V2FanoutDeliveryLease, now: Date
    ) async throws -> PreparedFanoutDeliveryProjection? {
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        guard let delivery = try await claimedDelivery(
            sql: sql, sourceEventID: sourceEventID, targetUserID: targetUserID, lease: lease
        )
        else { return nil }

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
            INSERT INTO im_v2.fanout_sync_payloads
                (source_event_id, projection_kind, payload, created_at)
            SELECT event.event_id, \(bind: lease.projectionKind), event.payload, \(bind: now)
            FROM im_v2.room_events AS event WHERE event.event_id = \(bind: sourceEventID)
            ON CONFLICT DO NOTHING
            """).run()
        guard try await sql.raw("""
            INSERT INTO im_v2.user_sync_log
                (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at)
            SELECT \(bind: targetUserID), \(bind: sequence.nextSequence), event.event_id, \(bind: lease.projectionKind),
                   NULL, 'fanout_shared',
                   \(bind: now)
            FROM im_v2.room_events AS event
            JOIN im_v2.fanout_sync_payloads AS shared
              ON shared.source_event_id = event.event_id
             AND shared.projection_kind = \(bind: lease.projectionKind)
             AND shared.payload = event.payload
            WHERE event.event_id = \(bind: sourceEventID)
            RETURNING user_sync_sequence
            """).first(decoding: UserSyncSequenceRow.self) != nil else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        try await sql.raw("""
            UPDATE im_v2.consumer_inbox
            SET user_sync_sequence = \(bind: sequence.nextSequence)
            WHERE consumer_name = \(bind: consumerName)
              AND source_event_id = \(bind: sourceEventID)
              AND target_user_id = \(bind: targetUserID)
              AND projection_kind = \(bind: lease.projectionKind)
            """).run()
        return .init(delivery: delivery, userSyncSequence: try unsigned(sequence.nextSequence))
    }

    /// Projects a colocated batch with one set-based SQL statement.  The CTEs
    /// deliberately follow the durable effect order: fence/lock delivery,
    /// insert inbox, reserve one sequence range per user, append sync rows,
    /// then terminalize the fenced deliveries.  Any error rolls back the
    /// entire statement and its encompassing transaction.
    private func projectAndTerminalizeBatch(
        sql: any SQLDatabase,
        ordered: [BatchFanoutDeliveryLease],
        now: Date
    ) async throws -> [PreparedFanoutDeliveryCommit] {
        let inputJSON = try batchJSON(try ordered.enumerated().map { offset, item in
            try BatchProjectionInput(ordinal: offset, item: item)
        })
        // A normal claim is ordered by source event then target user. Its
        // batch therefore contains at most one projection per user, so each
        // inbox row reserves exactly one sequence. Avoid the grouping/window
        // machinery in that common case, but retain the general CTE whenever
        // a caller presents more than one source event for a user.
        let hasDistinctTargetUsers = Set(ordered.map(\.lease.targetUserID.rawValue)).count == ordered.count
        let usesDistinctTargetFastPath = hasDistinctTargetUsers
            && batchSequenceReservationStrategy == .automatic
        // Do this as the first statement of the same transaction. A second
        // projection statement can then read its own newly inserted payload
        // plus any concurrently committed one without taking a no-op row
        // update lock on the common source event.
        try await ensureSharedPayloads(sql: sql, inputJSON: inputJSON, now: now)
        let insertedInboxCount = try await insertClaimedInboxes(
            sql: sql, inputJSON: inputJSON, now: now
        )
        guard insertedInboxCount == ordered.count else {
            throw V2FanoutDeliveryError.inboxAlreadyCommitted
        }
        let sequenceReservationCTEs = usesDistinctTargetFastPath
            ? """
            reserved_sequence AS (
                INSERT INTO im_v2.user_sync_sequences AS sequence (user_id, next_sequence)
                SELECT target_user_id, 1
                FROM pending_inbox
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = sequence.next_sequence + 1
                RETURNING user_id, next_sequence
            ), numbered AS (
                SELECT claimed.ordinal, claimed.source_event_id, claimed.target_user_id,
                       claimed.projection_kind, claimed.claim_token, claimed.completion_unit_id,
                       reserved_sequence.next_sequence AS user_sync_sequence
                FROM claimed
                JOIN pending_inbox
                  USING (source_event_id, target_user_id, projection_kind)
                JOIN reserved_sequence ON reserved_sequence.user_id = claimed.target_user_id
            )
            """
            : """
            per_user AS (
                SELECT target_user_id AS user_id, COUNT(*)::bigint AS sequence_count
                FROM pending_inbox
                GROUP BY target_user_id
            ), reserved_sequence AS (
                INSERT INTO im_v2.user_sync_sequences AS sequence (user_id, next_sequence)
                SELECT user_id, sequence_count
                FROM per_user
                ORDER BY user_id
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = sequence.next_sequence + EXCLUDED.next_sequence
                RETURNING user_id, next_sequence
            ), numbered AS (
                SELECT claimed.ordinal, claimed.source_event_id, claimed.target_user_id,
                       claimed.projection_kind, claimed.claim_token, claimed.completion_unit_id,
                       reserved_sequence.next_sequence - per_user.sequence_count
                         + ROW_NUMBER() OVER (
                             PARTITION BY claimed.target_user_id
                             ORDER BY claimed.source_event_id, claimed.target_user_id, claimed.projection_kind
                           ) AS user_sync_sequence
                FROM claimed
                JOIN pending_inbox
                  USING (source_event_id, target_user_id, projection_kind)
                JOIN per_user ON per_user.user_id = claimed.target_user_id
                JOIN reserved_sequence ON reserved_sequence.user_id = claimed.target_user_id
            )
            """
        let rows = try await sql.raw("""
            WITH input AS (
                SELECT ordinal, source_event_id, target_user_id, projection_kind, claim_token
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    ordinal integer, source_event_id uuid, target_user_id uuid,
                    projection_kind text, claim_token uuid
                )
            ), claimed AS MATERIALIZED (
                SELECT input.ordinal, input.source_event_id, input.target_user_id,
                       input.projection_kind, input.claim_token, delivery.completion_unit_id
                FROM input
                JOIN im_v2.fanout_deliveries AS delivery
                  ON delivery.source_event_id = input.source_event_id
                 AND delivery.target_user_id = input.target_user_id
                 AND delivery.projection_kind = input.projection_kind
                WHERE delivery.state = 'pending' AND delivery.claim_token = input.claim_token
                FOR UPDATE OF delivery
            ), pending_inbox AS MATERIALIZED (
                SELECT inbox.source_event_id, inbox.target_user_id,
                       inbox.projection_kind
                FROM im_v2.consumer_inbox AS inbox
                JOIN claimed
                  USING (source_event_id, target_user_id, projection_kind)
                WHERE inbox.consumer_name = \(bind: consumerName)
                  AND inbox.user_sync_sequence IS NULL
            ), \(unsafeRaw: sequenceReservationCTEs), payload_keys AS MATERIALIZED (
                -- A batch commonly contains many target users for the same
                -- source event. Deduplicate the keys *before* evaluating the
                -- JSONB merge, rather than relying on `SELECT DISTINCT` over
                -- the computed payload. PostgreSQL may otherwise evaluate the
                -- merge once per target before discarding equal rows.
                SELECT DISTINCT source_event_id, projection_kind
                FROM numbered
            ), payloads AS MATERIALIZED (
                -- Build one immutable sync payload for each deduplicated
                -- `(source event, projection kind)` key, then join it back to
                -- the per-target sequence rows below.
                SELECT payload_keys.source_event_id, payload_keys.projection_kind,
                       event.payload
                FROM payload_keys
                JOIN im_v2.room_events AS event ON event.event_id = payload_keys.source_event_id
            ), verified_payloads AS MATERIALIZED (
                -- The preceding statement made the body durable. This is
                -- deliberately read-only validation so independent batches
                -- do not serialize on an otherwise immutable payload row.
                SELECT payloads.source_event_id, payloads.projection_kind
                FROM payloads
                JOIN im_v2.fanout_sync_payloads AS shared
                  ON shared.source_event_id = payloads.source_event_id
                 AND shared.projection_kind = payloads.projection_kind
                 AND shared.payload = payloads.payload
            ), inserted_log AS (
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at)
                SELECT numbered.target_user_id, numbered.user_sync_sequence, numbered.source_event_id,
                       numbered.projection_kind, NULL, 'fanout_shared',
                       \(bind: now)
                FROM numbered
                JOIN verified_payloads
                  ON verified_payloads.source_event_id = numbered.source_event_id
                 AND verified_payloads.projection_kind = numbered.projection_kind
                RETURNING user_id, user_sync_sequence, source_event_id, projection_kind
            ), recorded_inbox AS (
                UPDATE im_v2.consumer_inbox AS inbox
                SET user_sync_sequence = inserted_log.user_sync_sequence
                FROM inserted_log
                WHERE inbox.consumer_name = \(bind: consumerName)
                  AND inbox.source_event_id = inserted_log.source_event_id
                  AND inbox.target_user_id = inserted_log.user_id
                  AND inbox.projection_kind = inserted_log.projection_kind
                RETURNING inbox.source_event_id, inbox.target_user_id,
                          inbox.projection_kind, inbox.user_sync_sequence
            ), terminalized AS (
                UPDATE im_v2.fanout_deliveries AS delivery
                SET state = 'terminal', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL
                FROM numbered
                JOIN recorded_inbox
                  ON recorded_inbox.target_user_id = numbered.target_user_id
                 AND recorded_inbox.user_sync_sequence = numbered.user_sync_sequence
                 AND recorded_inbox.source_event_id = numbered.source_event_id
                 AND recorded_inbox.projection_kind = numbered.projection_kind
                WHERE delivery.source_event_id = numbered.source_event_id
                  AND delivery.target_user_id = numbered.target_user_id
                  AND delivery.projection_kind = numbered.projection_kind
                  AND delivery.state = 'pending' AND delivery.claim_token = numbered.claim_token
                RETURNING numbered.ordinal, numbered.source_event_id, numbered.target_user_id,
                          numbered.projection_kind, numbered.completion_unit_id,
                          numbered.user_sync_sequence
            ), outcomes AS (
                SELECT ordinal, source_event_id, target_user_id, projection_kind,
                       completion_unit_id, user_sync_sequence, 'committed'::text AS outcome
                FROM terminalized
                UNION ALL
                SELECT claimed.ordinal, claimed.source_event_id, claimed.target_user_id,
                       claimed.projection_kind, claimed.completion_unit_id, NULL::bigint,
                       'inbox_conflict'::text AS outcome
                FROM claimed
                LEFT JOIN pending_inbox
                  USING (source_event_id, target_user_id, projection_kind)
                WHERE pending_inbox.source_event_id IS NULL
            )
            SELECT ordinal, source_event_id, target_user_id, projection_kind,
                   completion_unit_id, user_sync_sequence, outcome
            FROM outcomes
            ORDER BY ordinal
            """).all(decoding: BatchProjectionOutcomeRow.self)

        var prepared: [PreparedFanoutDeliveryCommit] = []
        prepared.reserveCapacity(rows.count)
        for row in rows {
            guard ordered.indices.contains(row.ordinal) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard row.outcome == "committed" else { throw V2FanoutDeliveryError.inboxAlreadyCommitted }
            guard let sequence = row.userSyncSequence else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let item = ordered[row.ordinal]
            let expectedSourceEventID = try uuid(item.lease.sourceEventID)
            let expectedTargetUserID = try uuid(item.lease.targetUserID)
            guard row.sourceEventID == expectedSourceEventID,
                  row.targetUserID == expectedTargetUserID,
                  row.projectionKind == item.lease.projectionKind
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            prepared.append(.init(
                index: item.index,
                lease: item.lease,
                delivery: .init(
                    sourceEventID: row.sourceEventID, targetUserID: row.targetUserID,
                    projectionKind: row.projectionKind, completionUnitID: row.completionUnitID,
                    targetShardBucket: item.lease.observedRoute.bucket,
                    observedRouterEpoch: item.lease.observedRoute.observedRouterEpoch,
                    retryCount: Int64(item.lease.attempt),
                    eventPayloadJSON: nil
                ),
                userSyncSequence: try unsigned(sequence)
            ))
        }
        return prepared
    }

    /// PostgreSQL data-modifying CTE siblings share one snapshot and cannot
    /// update a row inserted by another sibling except through RETURNING.
    /// Persist inbox fences in their own statement first, while remaining in
    /// the same transaction, so the set-based log/update/terminalize statement
    /// can see and record every allocated sequence.
    private func insertClaimedInboxes(
        sql: any SQLDatabase, inputJSON: String, now: Date
    ) async throws -> Int {
        try await sql.raw("""
            WITH input AS (
                SELECT source_event_id, target_user_id, projection_kind, claim_token
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    ordinal integer, source_event_id uuid, target_user_id uuid,
                    projection_kind text, claim_token uuid
                )
            ), claimed AS MATERIALIZED (
                SELECT input.source_event_id, input.target_user_id,
                       input.projection_kind
                FROM input
                JOIN im_v2.fanout_deliveries AS delivery
                  ON delivery.source_event_id = input.source_event_id
                 AND delivery.target_user_id = input.target_user_id
                 AND delivery.projection_kind = input.projection_kind
                WHERE delivery.state = 'pending'
                  AND delivery.claim_token = input.claim_token
                FOR UPDATE OF delivery
            )
            INSERT INTO im_v2.consumer_inbox
                (consumer_name, source_event_id, target_user_id,
                 projection_kind, committed_at)
            SELECT \(bind: consumerName), source_event_id, target_user_id,
                   projection_kind, \(bind: now)
            FROM claimed
            ON CONFLICT DO NOTHING
            RETURNING source_event_id
            """).all(decoding: InboxInsertRow.self).count
    }

    private func ensureSharedPayloads(sql: any SQLDatabase, inputJSON: String, now: Date) async throws {
        try await sql.raw("""
            WITH input AS (
                SELECT source_event_id, projection_kind
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    ordinal integer, source_event_id uuid, target_user_id uuid,
                    projection_kind text, claim_token uuid
                )
            ), payload_keys AS MATERIALIZED (
                SELECT DISTINCT source_event_id, projection_kind FROM input
            )
            INSERT INTO im_v2.fanout_sync_payloads
                (source_event_id, projection_kind, payload, created_at)
            SELECT payload_keys.source_event_id, payload_keys.projection_kind, event.payload, \(bind: now)
            FROM payload_keys
            JOIN im_v2.room_events AS event ON event.event_id = payload_keys.source_event_id
            ON CONFLICT DO NOTHING
            """).run()
    }

    /// Completes the accounting/release side without repeatedly locking the
    /// same completion-unit row. Delivery terminalization has already occurred
    /// in the fenced set-based projection statement; this phase aggregates by
    /// `(source event, completion unit)` and acquires one counter lock per
    /// represented unit rather than one per target. All counter updates finish
    /// before a terminal unit acquires the plan/admission locks: otherwise a
    /// batch spanning two units can hold the plan while waiting for a later
    /// completion unit that another batch holds while waiting for that plan.
    private func completeBatch(
        sql: any SQLDatabase,
        prepared: [PreparedFanoutDeliveryCommit],
        now: Date
    ) async throws -> [(Int, V2FanoutDeliveryCommit)] {
        guard !prepared.isEmpty else { return [] }
        let grouped = Dictionary(grouping: prepared) { item in
            CompletionUnitBatchKey(
                sourceEventID: item.delivery.sourceEventID,
                completionUnitID: item.delivery.completionUnitID
            )
        }
        var completedUnits: [CompletedBatchUnit] = []
        completedUnits.reserveCapacity(grouped.count)
        for key in grouped.keys.sorted() {
            guard let items = grouped[key] else { throw V2RoomWriteStoreError.corruptPersistenceState }
            guard let unit = try await sql.raw("""
                UPDATE im_v2.fanout_completion_units
                SET committed_target_count = committed_target_count + \(bind: items.count),
                    state = CASE
                        WHEN committed_target_count + policy_skipped_target_count + \(bind: items.count) = target_count THEN 'terminal'
                        ELSE 'pending'
                    END,
                    lease_expires_at = NULL
                WHERE source_event_id = \(bind: key.sourceEventID)
                  AND completion_unit_id = \(bind: key.completionUnitID)
                  AND state = 'pending'
                RETURNING target_count, state
                """).first(decoding: CompletionUnitRow.self)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let isTerminal = unit.state == "terminal"
            completedUnits.append(.init(key: key, items: items, targetCount: unit.targetCount, isTerminal: isTerminal))
        }

        var closedPlans: Set<CompletionUnitBatchKey> = []
        for unit in completedUnits where unit.isTerminal {
            if try await releaseTerminalUnit(
                sql: sql, sourceEventID: unit.key.sourceEventID,
                completionUnitID: unit.key.completionUnitID, targetCount: unit.targetCount, now: now
            ) {
                closedPlans.insert(unit.key)
            }
        }

        var outcomes: [(Int, V2FanoutDeliveryCommit)] = []
        outcomes.reserveCapacity(prepared.count)
        for unit in completedUnits {
            let closesPlan = closedPlans.contains(unit.key)
            for (offset, item) in unit.items.enumerated() {
                let releasesUnit = unit.isTerminal && offset == unit.items.count - 1
                outcomes.append((item.index, .committed(
                    userSyncSequence: item.userSyncSequence,
                    releasedCompletionUnit: releasesUnit,
                    closedPlan: releasesUnit && closesPlan
                )))
            }
        }
        return outcomes
    }

    private func deliveryKey(for lease: V2FanoutDeliveryLease) throws -> String {
        let sourceEventID = try uuid(lease.sourceEventID)
        let targetUserID = try uuid(lease.targetUserID)
        return "\(sourceEventID.uuidString)|\(targetUserID.uuidString)|\(lease.projectionKind)"
    }

    private func externalBatchAcknowledgementInputs(
        _ acknowledgements: [V2ExternalFanoutDeliveryAcknowledgement]
    ) throws -> [ExternalBatchAcknowledgementInput] {
        let ordered = try acknowledgements.enumerated().map { index, acknowledgement in
            guard acknowledgement.userSyncSequence > 0,
                  acknowledgement.userSyncSequence <= UInt64(Int64.max)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return ExternalBatchAcknowledgementInput(
                ordinal: index,
                sourceEventID: try uuid(acknowledgement.lease.sourceEventID),
                targetUserID: try uuid(acknowledgement.lease.targetUserID),
                projectionKind: acknowledgement.lease.projectionKind,
                claimToken: acknowledgement.lease.claimToken,
                userSyncSequence: Int64(acknowledgement.userSyncSequence)
            )
        }
        let identities = ordered.map {
            "\($0.sourceEventID.uuidString)|\($0.targetUserID.uuidString)|\($0.projectionKind)"
        }
        guard Set(identities).count == ordered.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return ordered
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
        // Completion-unit release is serialized by its room admission row.
        // Do not take the plan lock for every terminal unit: a large plan has
        // many independent units, but only the last release can transition
        // the plan/outbox to terminal. Holding the admission lock before the
        // unreleased-unit check also makes that check a durable finalization
        // decision rather than a racy snapshot of concurrent unit releases.
        guard let plan = try await sql.raw("""
            SELECT room_id, state FROM im_v2.fanout_plans
            WHERE source_event_id = \(bind: sourceEventID)
            """).first(decoding: ReleasePlanRow.self), plan.state == "planned"
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
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

        let hasOtherUnreleasedUnits = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM im_v2.fanout_completion_units
                WHERE source_event_id = \(bind: sourceEventID)
                  AND completion_unit_id <> \(bind: completionUnitID)
                  AND state <> 'released'
            ) AS value
            """).first(decoding: BooleanRow.self)?.value ?? true
        if !hasOtherUnreleasedUnits {
            // The admission row serializes every completion release for this
            // room, so this is the sole candidate to close the plan. Lock it
            // only now to preserve the plan/outbox terminal transition while
            // avoiding a shared plan lock for all earlier unit releases.
            guard let lockedPlan = try await sql.raw("""
                SELECT room_id, state FROM im_v2.fanout_plans
                WHERE source_event_id = \(bind: sourceEventID) FOR UPDATE
                """).first(decoding: ReleasePlanRow.self), lockedPlan.state == "planned"
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
        }

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

/// The production store selects the distinct-user path automatically. The
/// generic path remains selectable by in-module regression tests so its
/// repeated-user sequence guarantee is continuously comparable.
enum V2FanoutBatchSequenceReservationStrategy: Sendable {
    case automatic
    case forceGeneric
}

private extension V2FanoutDeliveryClaimLane {
    func sqlEligibilityPredicate(now: Date) -> SQLQueryString {
        switch self {
        case .fresh:
            "delivery.next_attempt_at IS NULL AND delivery.lease_expires_at IS NULL"
        case .retryDue:
            "delivery.next_attempt_at IS NOT NULL AND delivery.next_attempt_at <= \(bind: now) AND delivery.lease_expires_at IS NULL"
        case .expiredLease:
            "delivery.lease_expires_at IS NOT NULL AND delivery.lease_expires_at <= \(bind: now) AND (delivery.next_attempt_at IS NULL OR delivery.next_attempt_at <= \(bind: now))"
        }
    }

    var sqlOrdering: SQLQueryString {
        switch self {
        case .fresh:
            "delivery.source_event_id, delivery.target_user_id, delivery.projection_kind"
        case .retryDue:
            "delivery.next_attempt_at, delivery.source_event_id, delivery.target_user_id, delivery.projection_kind"
        case .expiredLease:
            "delivery.lease_expires_at, delivery.source_event_id, delivery.target_user_id, delivery.projection_kind"
        }
    }
}

private struct ClaimedDeliveryRow: Decodable {
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let completionUnitID: UUID
    let targetShardBucket: String
    let observedRouterEpoch: Int64
    let retryCount: Int64
    let eventPayloadJSON: String?
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id", targetUserID = "target_user_id", projectionKind = "projection_kind", completionUnitID = "completion_unit_id", targetShardBucket = "target_shard_bucket", observedRouterEpoch = "observed_router_epoch", retryCount = "retry_count", eventPayloadJSON = "event_payload_json" }
}
private struct PreparedFanoutDeliveryProjection {
    let delivery: ClaimedDeliveryRow
    let userSyncSequence: UInt64
}
private struct PreparedFanoutDeliveryCommit {
    let index: Int
    let lease: V2FanoutDeliveryLease
    let delivery: ClaimedDeliveryRow
    let userSyncSequence: UInt64
}
private struct BatchFanoutDeliveryLease {
    let index: Int
    let lease: V2FanoutDeliveryLease
    let key: String
}
private struct BatchProjectionInput: Encodable {
    let ordinal: Int
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let claimToken: UUID

    init(ordinal: Int, item: BatchFanoutDeliveryLease) throws {
        self.ordinal = ordinal
        sourceEventID = try uuid(item.lease.sourceEventID)
        targetUserID = try uuid(item.lease.targetUserID)
        projectionKind = item.lease.projectionKind
        claimToken = item.lease.claimToken
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case claimToken = "claim_token"
    }
}
private struct ExternalBatchAcknowledgementInput: Encodable {
    let ordinal: Int
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let claimToken: UUID
    let userSyncSequence: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case claimToken = "claim_token"
        case userSyncSequence = "user_sync_sequence"
    }
}
private struct RouterFenceConfigurationRow: Decodable {
    let routerEpoch: Int64
    enum CodingKeys: String, CodingKey { case routerEpoch = "router_epoch" }
}
private struct RouterFenceInput: Encodable {
    let ordinal: Int
    let userID: UUID
    enum CodingKeys: String, CodingKey { case ordinal; case userID = "user_id" }
}
private struct RouterFenceRouteRow: Decodable {
    let ordinal: Int
    let writeBucket: String
    let routerEpoch: Int64
    let readFallbackBucket: String?
    enum CodingKeys: String, CodingKey {
        case ordinal
        case writeBucket = "write_bucket"
        case routerEpoch = "router_epoch"
        case readFallbackBucket = "read_fallback_bucket"
    }
}
private struct HandoffClaimedRow: Decodable {
    let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" }
}
private struct ExternalBatchTerminalizedRow: Decodable {
    let ordinal: Int
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let completionUnitID: UUID
    let targetShardBucket: String
    let observedRouterEpoch: Int64
    let retryCount: Int64
    let userSyncSequence: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case completionUnitID = "completion_unit_id"
        case targetShardBucket = "target_shard_bucket"
        case observedRouterEpoch = "observed_router_epoch"
        case retryCount = "retry_count"
        case userSyncSequence = "user_sync_sequence"
    }
}
private struct BatchProjectionOutcomeRow: Decodable {
    let ordinal: Int
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let completionUnitID: UUID
    let userSyncSequence: Int64?
    let outcome: String

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case completionUnitID = "completion_unit_id"
        case userSyncSequence = "user_sync_sequence"
        case outcome
    }
}
private struct CompletionUnitBatchKey: Hashable, Comparable {
    let sourceEventID: UUID
    let completionUnitID: UUID

    static func < (lhs: Self, rhs: Self) -> Bool {
        let left = lhs.sourceEventID.uuidString
        let right = rhs.sourceEventID.uuidString
        return left == right
            ? lhs.completionUnitID.uuidString < rhs.completionUnitID.uuidString
            : left < right
    }
}
private struct CompletedBatchUnit {
    let key: CompletionUnitBatchKey
    let items: [PreparedFanoutDeliveryCommit]
    let targetCount: Int
    let isTerminal: Bool
}
private struct ProjectionInputRow: Decodable {
    let eventPayloadJSON: String
    enum CodingKeys: String, CodingKey { case eventPayloadJSON = "event_payload_json" }
}
private struct LeasedProjectionInput: Encodable {
    let ordinal: Int
    let sourceEventID: UUID
    let targetUserID: UUID
    let projectionKind: String
    let claimToken: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case targetUserID = "target_user_id"
        case projectionKind = "projection_kind"
        case claimToken = "claim_token"
    }
}
private struct LeasedProjectionInputRow: Decodable {
    let ordinal: Int
    let sourceEventID: UUID
    let eventPayloadJSON: String?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case eventPayloadJSON = "event_payload_json"
    }
}
private struct InboxInsertRow: Decodable { let sourceEventID: UUID; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" } }
private struct SyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private struct UserSyncSequenceRow: Decodable { let userSyncSequence: Int64; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence" } }
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
private func batchJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}
