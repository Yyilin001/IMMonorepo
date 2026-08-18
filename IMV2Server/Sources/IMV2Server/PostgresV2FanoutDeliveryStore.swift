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
/// the same transaction. Capacity release is deliberately a separate durable
/// phase: projection transactions never acquire room or shard-admission locks.
/// A consumer-inbox row makes broker redelivery safe.
public struct PostgresV2FanoutDeliveryStore:
    V2PartitionedFanoutDeliveryStore,
    V2FanoutCompletionReleaseStore
{
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID
    private let batchSequenceReservationStrategy: V2FanoutBatchSequenceReservationStrategy
    private let payloadWriteMode: V2FanoutPayloadWriteMode
    private let consumerName = "v2-fanout-delivery"

    public init(
        database: any Database,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        payloadWriteMode: V2FanoutPayloadWriteMode = .body
    ) {
        self.database = database
        self.makeUUID = makeUUID
        self.payloadWriteMode = payloadWriteMode
        batchSequenceReservationStrategy = .automatic
    }

    /// Internal only so the isolated capacity regression can compare the
    /// general repeated-user query with its standard fan-out fast path. The
    /// running server always uses `.automatic` through the public initializer.
    init(
        database: any Database,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        batchSequenceReservationStrategy: V2FanoutBatchSequenceReservationStrategy,
        payloadWriteMode: V2FanoutPayloadWriteMode = .body
    ) {
        self.database = database
        self.makeUUID = makeUUID
        self.batchSequenceReservationStrategy = batchSequenceReservationStrategy
        self.payloadWriteMode = payloadWriteMode
    }

    /// A fixed database lane makes fresh predicates indexable while allowing
    /// the process to run any smaller worker count. All fresh work is assigned
    /// by target user so sequence writers remain disjoint. Direct deliveries
    /// separately elect one source-event payload materializer below.
    private static let stableFreshLaneCount: Int64 = 8
    /// A transaction may amortize sequence/trigger work across repeated
    /// messages for several users, but must not pre-lock an entire claim-sized
    /// user set that it cannot actually project. Eight users keeps advisory
    /// ownership narrow and still fills the standard 128-row commit boundary.
    private static let maximumFreshDirectUsersPerBatch = 8

    private static func dynamicTargetPartitionEligibility(
        _ partition: V2FanoutDeliveryClaimPartition?
    ) -> SQLQueryString {
        guard let partition else { return "" }
        return """
            AND mod(
                hashtextextended(delivery.target_user_id::text, 0)
                    & 9223372036854775807,
                \(bind: Int64(partition.count))
            ) = \(bind: Int64(partition.index))
            """
    }

    private static func stableFreshPartitionEligibility(
        _ partition: V2FanoutDeliveryClaimPartition?
    ) -> SQLQueryString {
        guard let partition else { return "" }
        let lanes = stride(
            from: Int64(partition.index), to: stableFreshLaneCount,
            by: partition.count
        ).map { $0 }
        if lanes.count == 1, let lane = lanes.first {
            // PostgreSQL does not reliably reduce `= ANY(singleton)` to an
            // equality index condition. The scalar form lets the matching
            // expression index also supply source/target ordering.
            return """
                AND mod(
                    hashtextextended(delivery.target_user_id::text, 0)
                        & 9223372036854775807,
                    8
                ) = \(bind: lane)
                """
        }
        return """
            AND mod(
                hashtextextended(delivery.target_user_id::text, 0)
                    & 9223372036854775807,
                8
            ) = ANY(\(bind: lanes)::bigint[])
            """
    }

    public func claimPending(bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2FanoutDeliveryLease] {
        return try await claimPendingRows(
            bucket: bucket, lane: lane, now: now, leaseDuration: leaseDuration,
            limit: limit
        )
    }

    public func claimPending(
        bucket: String?, lane: V2FanoutDeliveryClaimLane,
        partition: V2FanoutDeliveryClaimPartition,
        now: Date, leaseDuration: TimeInterval, limit: Int
    ) async throws -> [V2FanoutDeliveryLease] {
        try await claimPendingRows(
            bucket: bucket, lane: lane, now: now,
            leaseDuration: leaseDuration, limit: limit,
            partition: partition
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
        maximumInlinePayloadBytes: Int,
        partition: V2FanoutDeliveryClaimPartition? = nil
    ) async throws -> [V2FanoutDeliveryLease] {
        precondition(maximumInlinePayloadBytes > 0)
        return try await claimPendingRows(
            bucket: bucket, lane: lane, now: now, leaseDuration: leaseDuration,
            limit: limit, maximumInlinePayloadBytes: maximumInlinePayloadBytes,
            partition: partition
        )
    }

    public func claimFreshDirectPreplannedForRecovery(
        bucket: String?, partition: V2FanoutDeliveryClaimPartition?,
        now: Date, leaseDuration: TimeInterval, limit: Int
    ) async throws -> [V2FanoutDeliveryLease] {
        try await claimPendingRows(
            bucket: bucket, lane: .fresh, now: now,
            leaseDuration: leaseDuration, limit: limit,
            partition: partition, freshSelection: .directOnly
        )
    }

    private enum FreshSelection: Equatable {
        case automatic
        case directOnly
    }

    private func claimPendingRows(
        bucket: String?, lane: V2FanoutDeliveryClaimLane, now: Date,
        leaseDuration: TimeInterval, limit: Int,
        maximumInlinePayloadBytes: Int? = nil,
        partition: V2FanoutDeliveryClaimPartition? = nil,
        freshSelection: FreshSelection = .automatic
    ) async throws -> [V2FanoutDeliveryLease] {
        guard leaseDuration > 0, limit > 0 else { return [] }
        let token = makeUUID()
        let expiry = now.addingTimeInterval(leaseDuration)
        let eligibility = lane.sqlEligibilityPredicate(now: now)
        let ordering = lane.sqlOrdering
        let selectsDirectRecovery = freshSelection == .directOnly
        let selectsGenericFresh = lane == .fresh
            && maximumInlinePayloadBytes == nil
            && !selectsDirectRecovery
        let freshClassEligibility: SQLQueryString = if selectsDirectRecovery {
            "AND delivery.fresh_direct_eligible"
        } else if selectsGenericFresh {
            "AND NOT delivery.fresh_direct_eligible"
        } else {
            ""
        }
        let partitionEligibility = if lane == .fresh {
            Self.stableFreshPartitionEligibility(partition)
        } else {
            Self.dynamicTargetPartitionEligibility(partition)
        }
        let planJoin: SQLQueryString = selectsDirectRecovery ? "" : """
            JOIN im_v2.fanout_plans AS plan
              ON plan.source_event_id = delivery.source_event_id
            """
        let plannedEligibility: SQLQueryString = selectsDirectRecovery
            ? ""
            : "AND plan.state = 'planned'"
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let rows: [ClaimedDeliveryRow]
            if let bucket {
                if let maximumInlinePayloadBytes {
                    rows = try await sql.raw("""
                        WITH candidates AS (
                            SELECT delivery.source_event_id, delivery.target_user_id, delivery.projection_kind
                            FROM im_v2.fanout_deliveries AS delivery
                            \(planJoin)
                            WHERE delivery.target_shard_bucket = \(bind: bucket) AND delivery.state = 'pending'
                              \(plannedEligibility)
                              AND \(eligibility)
                              \(freshClassEligibility)
                              \(partitionEligibility)
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
                        \(planJoin)
                        WHERE delivery.target_shard_bucket = \(bind: bucket) AND delivery.state = 'pending'
                          \(plannedEligibility)
                          AND \(eligibility)
                          \(freshClassEligibility)
                          \(partitionEligibility)
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
                            \(planJoin)
                            WHERE delivery.state = 'pending'
                              \(plannedEligibility)
                              AND \(eligibility)
                              \(freshClassEligibility)
                              \(partitionEligibility)
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
                        \(planJoin)
                        WHERE delivery.state = 'pending'
                          \(plannedEligibility)
                          AND \(eligibility)
                          \(freshClassEligibility)
                          \(partitionEligibility)
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

    /// Commits brand-new, co-located direct deliveries without first turning
    /// each row into a leased heap version. Selection, route/migration fence,
    /// inbox effect, Sync Log append, delivery terminalization and completion
    /// accounting all remain inside one retryable PostgreSQL transaction.
    /// Rows that have ever failed or been leased are excluded and continue on
    /// the ordinary claim-token recovery protocol.
    public func commitFreshDirectPreplanned(
        bucket: String?, partition: V2FanoutDeliveryClaimPartition?,
        now: Date, limit: Int
    ) async throws -> [V2FreshDirectFanoutDeliveryCommit] {
        guard limit > 0 else { return [] }
        var mayRetryConcurrentPayloadMaterialization = true
        while true {
            do {
                return try await commitFreshDirectPreplannedOnce(
                    bucket: bucket, partition: partition, now: now, limit: limit
                )
            } catch V2FanoutDeliveryError.inboxAlreadyCommitted
                where mayRetryConcurrentPayloadMaterialization {
                // Two replicas can recover different recipients of one event
                // accepted by an older binary while its shared payload row is
                // still absent. Under READ COMMITTED, the loser of INSERT ..
                // ON CONFLICT cannot see the winner in its original statement
                // snapshot. Roll back its untouched delivery rows and retry
                // once; a real immutable inbox conflict repeats and remains a
                // hard error on the second attempt.
                mayRetryConcurrentPayloadMaterialization = false
            }
        }
    }

    private func commitFreshDirectPreplannedOnce(
        bucket: String?, partition: V2FanoutDeliveryClaimPartition?,
        now: Date, limit: Int
    ) async throws -> [V2FreshDirectFanoutDeliveryCommit] {
        let bucketEligibility: SQLQueryString = if let bucket {
            "AND delivery.target_shard_bucket = \(bind: bucket)"
        } else {
            ""
        }
        let partitionEligibility = Self.stableFreshPartitionEligibility(partition)
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // Discover users without taking row locks. Replicas then arbitrate
            // the same stable user lane before any delivery row is locked, so
            // a losing transaction cannot pin work it is not allowed to
            // project. The matching partial index is user-first within a lane.
            let candidateUserLimit = min(
                limit, Self.maximumFreshDirectUsersPerBatch
            )
            let candidateUsers = try await sql.raw("""
                SELECT DISTINCT ON (delivery.target_user_id)
                       delivery.target_user_id
                FROM im_v2.fanout_deliveries AS delivery
                WHERE delivery.state = 'pending'
                  AND delivery.fresh_direct_eligible
                  AND delivery.projection_kind = 'message'
                  AND delivery.claim_token IS NULL
                  AND delivery.lease_expires_at IS NULL
                  AND delivery.next_attempt_at IS NULL
                  AND delivery.paused_at IS NULL
                  AND delivery.retry_count = 0
                  \(bucketEligibility)
                  \(partitionEligibility)
                ORDER BY delivery.target_user_id, delivery.source_event_id,
                         delivery.projection_kind
                LIMIT \(bind: candidateUserLimit)
                """).all(decoding: FreshDirectCandidateUserRow.self)
            guard !candidateUsers.isEmpty else { return [] }

            // Stable target lanes keep users disjoint inside one process. A
            // second replica may own the same database lane, so elect users
            // again with the same advisory key used by route migration. The
            // non-blocking lock avoids turning overlapping batches into a
            // convoy; unowned rows remain pending for a later pass.
            // Foundation/V2Identifier canonicalizes UUID-backed IDs to the
            // uppercase spelling. Preserve it here: advisory keys are lexical
            // and must exactly match V2PostgresUserShardRouter cutover locks.
            let lockUsers = candidateUsers.map { $0.targetUserID.uuidString }.sorted()
            let lockUsersJSON = try batchJSON(lockUsers)
            let userLocks = try await sql.raw("""
                WITH requested AS MATERIALIZED (
                    SELECT lock_user
                    FROM jsonb_array_elements_text(\(bind: lockUsersJSON)::jsonb)
                        AS value(lock_user)
                    ORDER BY lock_user
                )
                SELECT lock_user,
                       pg_try_advisory_xact_lock(
                           hashtextextended(lock_user, 0)
                       ) AS acquired
                FROM requested
                ORDER BY lock_user
                """).all(decoding: FreshDirectUserLockRow.self)
            let ownedUserIDs = Set(
                userLocks.lazy.filter(\.acquired).map(\.lockUser)
            )
            let ownedTargetUserIDs = candidateUsers.lazy
                .map(\.targetUserID)
                .filter { ownedUserIDs.contains($0.uuidString) }
                .sorted { $0.uuidString < $1.uuidString }
            guard !ownedTargetUserIDs.isEmpty else { return [] }

            // Divide the delivery boundary exactly across only the users this
            // replica owns. A heavy lexically-first user can therefore use its
            // share of the batch without consuming every row or preventing a
            // second replica from progressing disjoint users.
            let deliveriesPerUser = limit / ownedTargetUserIDs.count
            let usersWithOneExtraDelivery = limit % ownedTargetUserIDs.count

            // Only now acquire delivery row locks. One owned user may
            // contribute several source events, which amortizes route checks,
            // sequence reservation, trigger execution and transaction commit
            // while preserving that user's strict source-event order.
            let candidates = try await sql.raw("""
                WITH owned_users AS MATERIALIZED (
                    SELECT target_user_id, ordinal - 1 AS user_ordinal
                    FROM unnest(\(bind: ownedTargetUserIDs)::uuid[])
                        WITH ORDINALITY AS owned(target_user_id, ordinal)
                )
                SELECT candidate.source_event_id, candidate.target_user_id,
                       candidate.projection_kind, candidate.completion_unit_id,
                       candidate.target_shard_bucket, candidate.observed_router_epoch,
                       candidate.retry_count, NULL::text AS event_payload_json
                FROM owned_users
                CROSS JOIN LATERAL (
                    SELECT delivery.*
                    FROM im_v2.fanout_deliveries AS delivery
                    WHERE delivery.target_user_id = owned_users.target_user_id
                      AND delivery.state = 'pending'
                      AND delivery.fresh_direct_eligible
                      AND delivery.projection_kind = 'message'
                      AND delivery.claim_token IS NULL
                      AND delivery.lease_expires_at IS NULL
                      AND delivery.next_attempt_at IS NULL
                      AND delivery.paused_at IS NULL
                      AND delivery.retry_count = 0
                      \(bucketEligibility)
                      \(partitionEligibility)
                    ORDER BY delivery.source_event_id,
                             delivery.projection_kind
                    LIMIT (
                        \(bind: deliveriesPerUser)
                        + CASE
                            WHEN owned_users.user_ordinal
                                    < \(bind: usersWithOneExtraDelivery)
                            THEN 1 ELSE 0
                          END
                    )
                    FOR UPDATE OF delivery SKIP LOCKED
                ) AS candidate
                ORDER BY candidate.target_user_id, candidate.source_event_id,
                         candidate.projection_kind
                """).all(decoding: ClaimedDeliveryRow.self)
            guard !candidates.isEmpty else { return [] }

            let routeInput = candidates.enumerated().map {
                FreshDirectRouteInput(ordinal: $0.offset, userID: $0.element.targetUserID)
            }
            let routeInputJSON = try batchJSON(routeInput)
            let routes = try await sql.raw("""
                WITH input AS (
                    SELECT ordinal, user_id
                    FROM jsonb_to_recordset(\(bind: routeInputJSON)::jsonb)
                        AS value(ordinal integer, user_id uuid)
                )
                SELECT input.ordinal,
                       COALESCE(route.write_bucket, config.default_write_bucket)
                           AS write_bucket,
                       COALESCE(route.router_epoch, config.router_epoch) AS router_epoch,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.user_shard_migrations AS migration
                           WHERE migration.user_id = input.user_id
                             AND migration.phase IN ('forwarding', 'verified')
                             AND migration.source_bucket = COALESCE(
                                 route.write_bucket, config.default_write_bucket
                             )
                       ) AS requires_forwarding
                FROM input
                CROSS JOIN im_v2.user_shard_router_configuration AS config
                LEFT JOIN im_v2.user_shard_route_overrides AS route
                  ON route.user_id = input.user_id
                WHERE config.configuration_key = TRUE
                ORDER BY input.ordinal
                """).all(decoding: FreshDirectRouteRow.self)
            guard routes.count == candidates.count else {
                throw V2UserShardRouteControlError.missingRouterConfiguration
            }

            var accepted: [V2FanoutDeliveryLease] = []
            accepted.reserveCapacity(candidates.count)
            for (index, candidate) in candidates.enumerated() {
                let route = routes[index]
                guard route.ordinal == index else {
                    throw V2UserShardRouterError.resultCountMismatch
                }
                guard !route.requiresForwarding,
                      route.writeBucket == candidate.targetShardBucket,
                      route.routerEpoch == candidate.observedRouterEpoch
                else {
                    // Roll back the whole no-lease batch. The worker will
                    // immediately claim these explicitly-classified rows via
                    // the ordinary route-fenced recovery path; silently
                    // skipping one would otherwise strand it behind the
                    // generic fresh index's NOT-direct predicate.
                    throw V2UserShardRouterError.invalidRoute
                }
                accepted.append(.init(
                    sourceEventID: try .init(candidate.sourceEventID.uuidString),
                    targetUserID: try .init(candidate.targetUserID.uuidString),
                    projectionKind: candidate.projectionKind,
                    completionUnitID: try .init(candidate.completionUnitID.uuidString),
                    observedRoute: try .init(
                        bucket: candidate.targetShardBucket,
                        observedRouterEpoch: candidate.observedRouterEpoch
                    ),
                    claimToken: makeUUID(),
                    attempt: 1
                ))
            }
            guard !accepted.isEmpty else { return [] }
            let ordered = try accepted.enumerated().map { index, lease in
                BatchFanoutDeliveryLease(
                    index: index, lease: lease, key: try deliveryKey(for: lease)
                )
            }.sorted { $0.key < $1.key }
            let prepared = try await projectAndTerminalizeBatch(
                sql: sql, ordered: ordered, now: now, fence: .freshDirect
            )
            guard prepared.count == ordered.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let completed = try await completeBatch(sql: sql, prepared: prepared)
            guard completed.count == accepted.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return try completed.sorted { $0.0 < $1.0 }.map { index, commit in
                guard accepted.indices.contains(index),
                      case .committed(let sequence, _, _) = commit
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                return .init(
                    sourceEventID: accepted[index].sourceEventID,
                    targetUserID: accepted[index].targetUserID,
                    userSyncSequence: sequence
                )
            }
        }
    }

    public func commit(_ lease: V2FanoutDeliveryLease, now: Date) async throws -> V2FanoutDeliveryCommit {
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
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
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
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
            for (index, commit) in try await completeBatch(sql: sql, prepared: prepared) {
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
            SELECT event.payload::text AS event_payload_json,
                   state.state_id, state.message_id, state.room_id,
                   state.message_revision, state.variant_key,
                   state.origin_event_id, state.state_event_id,
                   state.is_withdrawn, state.payload_schema_version,
                   state.payload::text AS state_payload_json,
                   state.created_at AS state_created_at
            FROM im_v2.fanout_deliveries AS delivery
            JOIN im_v2.room_events AS event ON event.event_id = delivery.source_event_id
            LEFT JOIN im_v2.message_projection_state_values AS state
              ON state.state_event_id = event.event_id
             AND state.variant_key = 0
            WHERE delivery.source_event_id = \(bind: sourceEventID)
              AND delivery.target_user_id = \(bind: targetUserID)
              AND delivery.projection_kind = \(bind: lease.projectionKind)
              AND delivery.state = 'pending' AND delivery.claim_token = \(bind: lease.claimToken)
            """).first(decoding: ProjectionInputRow.self)
        guard let row else { return nil }
        return .init(
            sourceEventID: lease.sourceEventID, targetUserID: lease.targetUserID,
            projectionKind: lease.projectionKind,
            eventPayloadJSON: row.eventPayloadJSON,
            messageState: try row.messageState(projectionKind: lease.projectionKind)
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
                       event.payload::text AS event_payload_json,
                       state.state_id, state.message_id, state.room_id,
                       state.message_revision, state.variant_key,
                       state.origin_event_id, state.state_event_id,
                       state.is_withdrawn, state.payload_schema_version,
                       state.payload::text AS state_payload_json,
                       state.created_at AS state_created_at
                FROM valid
                JOIN im_v2.room_events AS event ON event.event_id = valid.source_event_id
                LEFT JOIN im_v2.message_projection_state_values AS state
                  ON state.state_event_id = event.event_id
                 AND state.variant_key = 0
                ORDER BY valid.source_event_id, valid.ordinal
            )
            SELECT valid.ordinal, valid.source_event_id, payload.event_payload_json,
                   payload.state_id, payload.message_id, payload.room_id,
                   payload.message_revision, payload.variant_key,
                   payload.origin_event_id, payload.state_event_id,
                   payload.is_withdrawn, payload.payload_schema_version,
                   payload.state_payload_json, payload.state_created_at
            FROM valid
            LEFT JOIN first_payload_rows AS payload ON payload.ordinal = valid.ordinal
            ORDER BY valid.ordinal
            """).all(decoding: LeasedProjectionInputRow.self)
        var payloadsBySourceEvent: [UUID: LeasedProjectionInputRow] = [:]
        for row in rows {
            guard row.eventPayloadJSON != nil else { continue }
            guard payloadsBySourceEvent[row.sourceEventID] == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            payloadsBySourceEvent[row.sourceEventID] = row
        }
        var results = Array<V2FanoutProjectionInput?>(repeating: nil, count: leases.count)
        for row in rows {
            guard results.indices.contains(row.ordinal), results[row.ordinal] == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let lease = leases[row.ordinal]
            guard try uuid(lease.sourceEventID) == row.sourceEventID,
                  let source = payloadsBySourceEvent[row.sourceEventID],
                  let payload = source.eventPayloadJSON
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            results[row.ordinal] = .init(
                sourceEventID: lease.sourceEventID, targetUserID: lease.targetUserID,
                projectionKind: lease.projectionKind,
                eventPayloadJSON: payload,
                messageState: try source.messageState(projectionKind: lease.projectionKind)
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
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
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
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
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
            for (index, commit) in try await completeBatch(sql: sql, prepared: prepared) {
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
            return RouterFenceInput(
                ordinal: index, userID: userID, lockUser: user.rawValue
            )
        }
        let inputJSON = try batchJSON(requested)
        // Acquire the stable, de-duplicated per-user cutover barrier and read
        // all routes in one statement. This preserves the exact advisory-lock
        // protocol used by migration finalization while removing two network
        // round trips from every delivery batch.
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT ordinal, user_id, lock_user
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    ordinal integer, user_id uuid, lock_user text
                )
            ), lock_users AS MATERIALIZED (
                SELECT DISTINCT lock_user
                FROM input
                ORDER BY lock_user
            ), acquired_locks AS MATERIALIZED (
                SELECT pg_advisory_xact_lock_shared(
                           hashtextextended(lock_user, 0)
                       ) AS acquired
                FROM lock_users
                ORDER BY lock_user
            ), lock_barrier AS MATERIALIZED (
                SELECT COUNT(*) AS acquired_count FROM acquired_locks
            )
            SELECT input.ordinal,
                   COALESCE(route.write_bucket, config.default_write_bucket) AS write_bucket,
                   COALESCE(route.router_epoch, config.router_epoch) AS router_epoch,
                   COALESCE(route.read_fallback_bucket, config.default_read_fallback_bucket) AS read_fallback_bucket
            FROM input
            CROSS JOIN im_v2.user_shard_router_configuration AS config
            CROSS JOIN lock_barrier
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
                (source_event_id, projection_kind, payload, message_state_id, created_at)
            SELECT event.event_id, \(bind: lease.projectionKind),
                   CASE WHEN \(bind: payloadWriteMode == .reference)
                                  AND state.payload = event.payload
                        THEN NULL ELSE event.payload END,
                   state.state_id, \(bind: now)
            FROM im_v2.room_events AS event
            LEFT JOIN im_v2.message_projection_state_values AS state
              ON state.state_event_id = event.event_id
             AND state.variant_key = 0
             AND \(bind: lease.projectionKind) = 'message'
            WHERE event.event_id = \(bind: sourceEventID)
            ON CONFLICT (source_event_id, projection_kind) DO UPDATE
            SET message_state_id = COALESCE(
                    im_v2.fanout_sync_payloads.message_state_id,
                    EXCLUDED.message_state_id
                ),
                payload = CASE
                    WHEN EXCLUDED.payload IS NULL
                     AND im_v2.fanout_sync_payloads.message_state_id = EXCLUDED.message_state_id
                    THEN NULL
                    ELSE im_v2.fanout_sync_payloads.payload
                END
            WHERE EXCLUDED.message_state_id IS NOT NULL
              AND (
                  im_v2.fanout_sync_payloads.message_state_id IS NULL
                  OR (
                      EXCLUDED.payload IS NULL
                      AND im_v2.fanout_sync_payloads.payload IS NOT NULL
                      AND im_v2.fanout_sync_payloads.message_state_id = EXCLUDED.message_state_id
                  )
              )
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
            LEFT JOIN im_v2.message_projection_state_values AS state
              ON state.state_id = shared.message_state_id
            WHERE event.event_id = \(bind: sourceEventID)
              AND COALESCE(shared.payload, state.payload) = event.payload
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
    /// reserve one sequence range per user, insert the complete inbox fence,
    /// append sync rows, then terminalize the fenced deliveries. Any error
    /// rolls back the entire statement and its encompassing transaction.
    ///
    /// `user_sync_sequence` is part of the inbox compaction index. Inserting
    /// an incomplete inbox row and updating it after sequence allocation would
    /// therefore force a non-HOT heap update plus another entry in every inbox
    /// index. Building the sequence first lets the immutable result row be
    /// inserted once without weakening the unique consumer fence.
    private func projectAndTerminalizeBatch(
        sql: any SQLDatabase,
        ordered: [BatchFanoutDeliveryLease],
        now: Date,
        fence: BatchProjectionDeliveryFence = .claimed
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
        let claimedPredicate: SQLQueryString
        let terminalPredicate: SQLQueryString
        switch fence {
        case .claimed:
            claimedPredicate = "delivery.state = 'pending' AND delivery.claim_token = input.claim_token"
            terminalPredicate = "delivery.state = 'pending' AND delivery.claim_token = numbered.claim_token"
        case .freshDirect:
            claimedPredicate = """
                delivery.state = 'pending'
                AND delivery.claim_token IS NULL
                AND delivery.lease_expires_at IS NULL
                AND delivery.next_attempt_at IS NULL
                AND delivery.paused_at IS NULL
                AND delivery.retry_count = 0
                AND EXISTS (
                    SELECT 1 FROM im_v2.fanout_plans AS direct_plan
                    WHERE direct_plan.source_event_id = delivery.source_event_id
                      AND direct_plan.state = 'planned'
                      AND direct_plan.target_rule->>'planning_strategy' = 'direct_preplanned'
                )
                """
            terminalPredicate = """
                delivery.state = 'pending'
                AND delivery.claim_token IS NULL
                AND delivery.lease_expires_at IS NULL
                AND delivery.next_attempt_at IS NULL
                AND delivery.paused_at IS NULL
                AND delivery.retry_count = 0
                """
        }
        // Fresh direct acceptance already materializes the one immutable
        // shared body in its source transaction. Skipping this statement is
        // safe because `verified_payloads` below remains an integrity fence:
        // a missing or mismatched row cannot produce an inbox/log commit.
        // The claimed compatibility lane still materializes payloads for
        // older binaries and non-message fan-out event kinds.
        if case .claimed = fence {
            try await ensureSharedPayloads(sql: sql, inputJSON: inputJSON, now: now)
        }
        let sequenceReservationCTEs = usesDistinctTargetFastPath
            ? """
            reserved_sequence AS (
                INSERT INTO im_v2.user_sync_sequences AS sequence (user_id, next_sequence)
                SELECT target_user_id, 1
                FROM claimed
                ORDER BY target_user_id
                ON CONFLICT (user_id)
                DO UPDATE SET next_sequence = sequence.next_sequence + 1
                RETURNING user_id, next_sequence
            ), numbered AS (
                SELECT claimed.ordinal, claimed.source_event_id, claimed.target_user_id,
                       claimed.projection_kind, claimed.claim_token, claimed.completion_unit_id,
                       reserved_sequence.next_sequence AS user_sync_sequence
                FROM claimed
                JOIN reserved_sequence ON reserved_sequence.user_id = claimed.target_user_id
            )
            """
            : """
            per_user AS (
                SELECT target_user_id AS user_id, COUNT(*)::bigint AS sequence_count
                FROM claimed
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
                WHERE \(claimedPredicate)
                FOR UPDATE OF delivery
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
                -- Acceptance (or the claimed compatibility preflight) made
                -- the body durable. Keep the hot statement read-only at this
                -- key: attempting an INSERT ... ON CONFLICT for every target
                -- still performs unique-index and visibility work even when
                -- the immutable row already exists.
                SELECT payloads.source_event_id, payloads.projection_kind
                FROM payloads
                JOIN im_v2.fanout_sync_payloads AS shared
                 ON shared.source_event_id = payloads.source_event_id
                 AND shared.projection_kind = payloads.projection_kind
                LEFT JOIN im_v2.message_projection_state_values AS state
                  ON state.state_id = shared.message_state_id
                WHERE COALESCE(shared.payload, state.payload) = payloads.payload
            ), recorded_inbox AS (
                INSERT INTO im_v2.consumer_inbox
                    (consumer_name, source_event_id, target_user_id,
                     projection_kind, committed_at, user_sync_sequence)
                SELECT \(bind: consumerName), numbered.source_event_id,
                       numbered.target_user_id, numbered.projection_kind,
                       \(bind: now), numbered.user_sync_sequence
                FROM numbered
                JOIN verified_payloads
                  ON verified_payloads.source_event_id = numbered.source_event_id
                 AND verified_payloads.projection_kind = numbered.projection_kind
                ORDER BY numbered.source_event_id, numbered.target_user_id,
                         numbered.projection_kind
                ON CONFLICT DO NOTHING
                RETURNING source_event_id, target_user_id, projection_kind,
                          user_sync_sequence
            ), inserted_log AS (
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, payload_storage, created_at)
                SELECT recorded_inbox.target_user_id,
                       recorded_inbox.user_sync_sequence,
                       recorded_inbox.source_event_id,
                       recorded_inbox.projection_kind,
                       NULL, 'fanout_shared',
                       \(bind: now)
                FROM recorded_inbox
                RETURNING user_id, user_sync_sequence, source_event_id, projection_kind
            ), terminalized AS (
                UPDATE im_v2.fanout_deliveries AS delivery
                SET state = 'terminal', claim_token = NULL, lease_expires_at = NULL,
                    next_attempt_at = NULL, paused_at = NULL, last_failure_code = NULL
                FROM numbered
                JOIN inserted_log
                  ON inserted_log.user_id = numbered.target_user_id
                 AND inserted_log.user_sync_sequence = numbered.user_sync_sequence
                 AND inserted_log.source_event_id = numbered.source_event_id
                 AND inserted_log.projection_kind = numbered.projection_kind
                WHERE delivery.source_event_id = numbered.source_event_id
                  AND delivery.target_user_id = numbered.target_user_id
                  AND delivery.projection_kind = numbered.projection_kind
                  AND \(terminalPredicate)
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
                LEFT JOIN recorded_inbox
                  USING (source_event_id, target_user_id, projection_kind)
                WHERE recorded_inbox.source_event_id IS NULL
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
                (source_event_id, projection_kind, payload, message_state_id, created_at)
            SELECT payload_keys.source_event_id, payload_keys.projection_kind,
                   CASE WHEN \(bind: payloadWriteMode == .reference)
                                  AND state.payload = event.payload
                        THEN NULL ELSE event.payload END,
                   state.state_id, \(bind: now)
            FROM payload_keys
            JOIN im_v2.room_events AS event ON event.event_id = payload_keys.source_event_id
            LEFT JOIN im_v2.message_projection_state_values AS state
              ON state.state_event_id = event.event_id
             AND state.variant_key = 0
             AND payload_keys.projection_kind = 'message'
            ORDER BY payload_keys.source_event_id, payload_keys.projection_kind
            ON CONFLICT (source_event_id, projection_kind) DO UPDATE
            SET message_state_id = COALESCE(
                    im_v2.fanout_sync_payloads.message_state_id,
                    EXCLUDED.message_state_id
                ),
                payload = CASE
                    WHEN EXCLUDED.payload IS NULL
                     AND im_v2.fanout_sync_payloads.message_state_id = EXCLUDED.message_state_id
                    THEN NULL
                    ELSE im_v2.fanout_sync_payloads.payload
                END
            WHERE EXCLUDED.message_state_id IS NOT NULL
              AND (
                  im_v2.fanout_sync_payloads.message_state_id IS NULL
                  OR (
                      EXCLUDED.payload IS NULL
                      AND im_v2.fanout_sync_payloads.payload IS NOT NULL
                      AND im_v2.fanout_sync_payloads.message_state_id = EXCLUDED.message_state_id
                  )
              )
            """).run()
    }

    /// Completes the accounting/release side without a completion-unit N+1.
    /// Delivery terminalization has already occurred in the fenced set-based
    /// projection statement; this phase aggregates by `(source event,
    /// completion unit)`, locks those counters in canonical order, and applies
    /// every increment in one statement. This is phase A of the durable
    /// protocol: it terminalizes projections and completion counters, but
    /// never acquires room/admission locks. A separate release worker owns
    /// phase B after this transaction commits.
    private func completeBatch(
        sql: any SQLDatabase,
        prepared: [PreparedFanoutDeliveryCommit]
    ) async throws -> [(Int, V2FanoutDeliveryCommit)] {
        guard !prepared.isEmpty else { return [] }
        let grouped = Dictionary(grouping: prepared) { item in
            CompletionUnitBatchKey(
                sourceEventID: item.delivery.sourceEventID,
                completionUnitID: item.delivery.completionUnitID
            )
        }
        let orderedKeys = grouped.keys.sorted()
        let increments = try orderedKeys.map { key in
            guard let items = grouped[key], !items.isEmpty else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return CompletionUnitIncrementInput(
                sourceEventID: key.sourceEventID,
                completionUnitID: key.completionUnitID,
                committedTargetDelta: items.count
            )
        }
        let inputJSON = try batchJSON(increments)
        let updated = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT source_event_id, completion_unit_id, committed_target_delta
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS value(
                    source_event_id uuid,
                    completion_unit_id uuid,
                    committed_target_delta integer
                )
            ), locked AS MATERIALIZED (
                -- Multiple gateway replicas may touch distinct targets in one
                -- large completion unit. Lock every represented counter in a
                -- stable order before updating so overlapping batches cannot
                -- form opposite-order lock cycles.
                SELECT unit.source_event_id, unit.completion_unit_id
                FROM input
                JOIN im_v2.fanout_completion_units AS unit
                  USING (source_event_id, completion_unit_id)
                WHERE unit.state = 'pending'
                  AND input.committed_target_delta > 0
                  AND unit.committed_target_count + unit.policy_skipped_target_count
                        + input.committed_target_delta <= unit.target_count
                ORDER BY unit.source_event_id, unit.completion_unit_id
                FOR UPDATE OF unit
            ), updated AS (
                UPDATE im_v2.fanout_completion_units AS unit
                SET committed_target_count = unit.committed_target_count
                        + input.committed_target_delta,
                    state = CASE
                        WHEN unit.committed_target_count + unit.policy_skipped_target_count
                                + input.committed_target_delta = unit.target_count
                            THEN 'terminal'
                        ELSE 'pending'
                    END,
                    lease_expires_at = NULL
                FROM input
                JOIN locked USING (source_event_id, completion_unit_id)
                WHERE unit.source_event_id = input.source_event_id
                  AND unit.completion_unit_id = input.completion_unit_id
                  AND unit.state = 'pending'
                RETURNING unit.source_event_id, unit.completion_unit_id
            )
            SELECT source_event_id, completion_unit_id
            FROM updated
            ORDER BY source_event_id, completion_unit_id
            """).all(decoding: UpdatedCompletionUnitRow.self)
        let updatedKeys = updated.map {
            CompletionUnitBatchKey(
                sourceEventID: $0.sourceEventID,
                completionUnitID: $0.completionUnitID
            )
        }
        guard updatedKeys == orderedKeys else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        var outcomes: [(Int, V2FanoutDeliveryCommit)] = []
        outcomes.reserveCapacity(prepared.count)
        for key in orderedKeys {
            guard let items = grouped[key] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            for item in items {
                outcomes.append((item.index, .committed(
                    userSyncSequence: item.userSyncSequence,
                    releasedCompletionUnit: false,
                    closedPlan: false
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
        return .committed(userSyncSequence: userSyncSequence, releasedCompletionUnit: false, closedPlan: false)
    }

    /// Releases a bounded terminal batch in one transaction. Unit claiming is
    /// skip-locked for replica safety; room, admission and shard rows are then
    /// locked in stable order. A crash before commit rolls back every counter
    /// and state transition, leaving the same units eligible for recovery.
    public func releaseTerminalCompletionUnits(
        now: Date,
        limit: Int
    ) async throws -> V2FanoutCompletionReleaseReport {
        precondition(limit > 0)
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let units = try await sql.raw("""
                SELECT source_event_id, completion_unit_id, target_count
                FROM im_v2.fanout_completion_units
                WHERE state = 'terminal'
                ORDER BY source_event_id, completion_unit_id
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
                """).all(decoding: TerminalCompletionUnitRow.self)
            guard !units.isEmpty else {
                return .init(releasedCount: 0, closedPlanCount: 0)
            }
            return try await releaseTerminalCompletionUnits(
                sql: sql,
                units: units,
                now: now
            )
        }
    }

    private func releaseTerminalCompletionUnits(
        sql: any SQLDatabase,
        units: [TerminalCompletionUnitRow],
        now: Date
    ) async throws -> V2FanoutCompletionReleaseReport {
        let keys = units.map {
            TerminalCompletionReleaseInput(
                sourceEventID: $0.sourceEventID,
                completionUnitID: $0.completionUnitID
            )
        }
        guard Set(keys).count == units.count,
              units.allSatisfy({ $0.targetCount >= 0 })
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let inputJSON = try batchJSON(keys)

        let plans = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT DISTINCT source_event_id
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                    AS value(source_event_id uuid, completion_unit_id uuid)
            )
            SELECT plan.source_event_id, plan.room_id, plan.state
            FROM input
            JOIN im_v2.fanout_plans AS plan USING (source_event_id)
            ORDER BY plan.source_event_id
            """).all(decoding: BatchReleasePlanRow.self)
        let sourceEventIDs = Set(units.map(\.sourceEventID))
        guard plans.count == sourceEventIDs.count,
              Set(plans.map(\.sourceEventID)) == sourceEventIDs,
              plans.allSatisfy({ $0.state == "planned" })
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let planByEvent = Dictionary(uniqueKeysWithValues: plans.map { ($0.sourceEventID, $0) })
        let roomIDs = Set(plans.map(\.roomID))

        // Room-local writes use `rooms -> room_admission`. Acquiring every row
        // in sorted order preserves that contract even when one recovery batch
        // spans rooms, and the admission locks serialize the final-plan test.
        let rooms = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT DISTINCT plan.room_id
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                    AS value(source_event_id uuid, completion_unit_id uuid)
                JOIN im_v2.fanout_plans AS plan USING (source_event_id)
            )
            SELECT room.room_id, room.room_shard_id, room.capacity_profile_id
            FROM input
            JOIN im_v2.rooms AS room USING (room_id)
            ORDER BY room.room_id
            FOR UPDATE OF room
            """).all(decoding: BatchReleaseRoomRow.self)
        guard rooms.count == roomIDs.count, Set(rooms.map(\.roomID)) == roomIDs else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let roomByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomID, $0) })

        let admissions = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT DISTINCT plan.room_id
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                    AS value(source_event_id uuid, completion_unit_id uuid)
                JOIN im_v2.fanout_plans AS plan USING (source_event_id)
            )
            SELECT admission.room_id, admission.shard_lease_id,
                   admission.shard_lease_generation
            FROM input
            JOIN im_v2.room_admission AS admission USING (room_id)
            ORDER BY admission.room_id
            FOR UPDATE OF admission
            """).all(decoding: BatchReleaseAdmissionRow.self)
        guard admissions.count == roomIDs.count, Set(admissions.map(\.roomID)) == roomIDs else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let admissionByRoom = Dictionary(uniqueKeysWithValues: admissions.map { ($0.roomID, $0) })

        // Exclude every unit selected by this transaction. An event closes
        // only when no other unit remains unreleased. A replica that already
        // claimed a sibling leaves that sibling visible as terminal here; once
        // it obtains the admission lock it will perform the sole close.
        let closingEvents = try await sql.raw("""
            WITH selected AS MATERIALIZED (
                SELECT source_event_id, completion_unit_id
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                    AS value(source_event_id uuid, completion_unit_id uuid)
            ), selected_events AS (
                SELECT DISTINCT source_event_id FROM selected
            )
            SELECT event.source_event_id
            FROM selected_events AS event
            WHERE NOT EXISTS (
                SELECT 1
                FROM im_v2.fanout_completion_units AS other
                WHERE other.source_event_id = event.source_event_id
                  AND other.state <> 'released'
                  AND NOT EXISTS (
                      SELECT 1 FROM selected
                      WHERE selected.source_event_id = other.source_event_id
                        AND selected.completion_unit_id = other.completion_unit_id
                  )
            )
            ORDER BY event.source_event_id
            """).all(decoding: SourceEventRow.self)
        let closingEventIDs = Set(closingEvents.map(\.sourceEventID))
        guard closingEventIDs.isSubset(of: sourceEventIDs) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let closingJSON = try batchJSON(closingEvents.map(\.sourceEventID))
        if !closingEvents.isEmpty {
            let lockedPlans = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT value::uuid AS source_event_id
                    FROM jsonb_array_elements_text(\(bind: closingJSON)::jsonb)
                )
                SELECT plan.source_event_id
                FROM input
                JOIN im_v2.fanout_plans AS plan USING (source_event_id)
                WHERE plan.state = 'planned'
                ORDER BY plan.source_event_id
                FOR UPDATE OF plan
                """).all(decoding: SourceEventRow.self)
            guard Set(lockedPlans.map(\.sourceEventID)) == closingEventIDs else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }

        var roomDeltas: [UUID: BatchRoomReleaseDelta] = [:]
        for unit in units {
            guard let roomID = planByEvent[unit.sourceEventID]?.roomID else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            var delta = roomDeltas[roomID] ?? .init(roomID: roomID, fanoutUnits: 0, plans: 0)
            let (fanoutUnits, overflowed) = delta.fanoutUnits.addingReportingOverflow(unit.targetCount)
            guard !overflowed else { throw V2RoomWriteStoreError.corruptPersistenceState }
            delta.fanoutUnits = fanoutUnits
            roomDeltas[roomID] = delta
        }
        for eventID in closingEventIDs {
            guard let roomID = planByEvent[eventID]?.roomID,
                  var delta = roomDeltas[roomID]
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let (plans, overflowed) = delta.plans.addingReportingOverflow(1)
            guard !overflowed else { throw V2RoomWriteStoreError.corruptPersistenceState }
            delta.plans = plans
            roomDeltas[roomID] = delta
        }
        let orderedRoomDeltas = roomDeltas.values.sorted { $0.roomID.uuidString < $1.roomID.uuidString }
        let roomDeltaJSON = try batchJSON(orderedRoomDeltas)

        let changedRooms = try await sql.raw("""
            WITH delta AS MATERIALIZED (
                SELECT room_id, fanout_units, plans
                FROM jsonb_to_recordset(\(bind: roomDeltaJSON)::jsonb)
                    AS value(room_id uuid, fanout_units bigint, plans bigint)
            )
            UPDATE im_v2.room_admission AS admission
            SET outstanding_fanout_units = admission.outstanding_fanout_units - delta.fanout_units,
                outstanding_plans = admission.outstanding_plans - delta.plans
            FROM delta
            WHERE admission.room_id = delta.room_id
              AND admission.outstanding_fanout_units >= delta.fanout_units
              AND admission.outstanding_plans >= delta.plans
            RETURNING admission.room_id
            """).all(decoding: RoomIDRow.self)
        guard Set(changedRooms.map(\.roomID)) == roomIDs else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        let releasedUnits = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT source_event_id, completion_unit_id
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                    AS value(source_event_id uuid, completion_unit_id uuid)
            )
            UPDATE im_v2.fanout_completion_units AS unit
            SET state = 'released', released_at = \(bind: now)
            FROM input
            WHERE unit.source_event_id = input.source_event_id
              AND unit.completion_unit_id = input.completion_unit_id
              AND unit.state = 'terminal'
            RETURNING unit.source_event_id, unit.completion_unit_id
            """).all(decoding: TerminalCompletionReleaseKeyRow.self)
        guard Set(releasedUnits.map(\.key)) == Set(keys) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        if !closingEvents.isEmpty {
            let closedPlans = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT value::uuid AS source_event_id
                    FROM jsonb_array_elements_text(\(bind: closingJSON)::jsonb)
                )
                UPDATE im_v2.fanout_plans AS plan
                SET state = 'terminal', terminal_at = \(bind: now)
                FROM input
                WHERE plan.source_event_id = input.source_event_id
                  AND plan.state = 'planned'
                RETURNING plan.source_event_id
                """).all(decoding: SourceEventRow.self)
            guard Set(closedPlans.map(\.sourceEventID)) == closingEventIDs else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            // Some repair and integration paths persist plans without an
            // outbox row, so absence is valid; every present source row is
            // terminalized in the same atomic release transaction.
            try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT value::uuid AS source_event_id
                    FROM jsonb_array_elements_text(\(bind: closingJSON)::jsonb)
                )
                UPDATE im_v2.room_outbox AS outbox
                SET state = 'terminal', claim_token = NULL,
                    lease_expires_at = NULL, next_attempt_at = NULL,
                    paused_at = NULL, last_failure_code = NULL,
                    terminal_at = \(bind: now)
                FROM input
                WHERE outbox.source_event_id = input.source_event_id
                  AND outbox.state <> 'terminal'
                """).run()
        }

        var shardDeltas: [BatchShardReleaseKey: BatchShardReleaseDelta] = [:]
        for delta in orderedRoomDeltas {
            guard let room = roomByID[delta.roomID],
                  let admission = admissionByRoom[delta.roomID]
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let key = BatchShardReleaseKey(
                roomShardID: room.roomShardID,
                capacityProfileID: room.capacityProfileID
            )
            if let existing = shardDeltas[key] {
                guard existing.leaseID == admission.shardLeaseID,
                      existing.generation == admission.shardLeaseGeneration
                else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                let (fanoutUnits, unitsOverflowed) = existing.fanoutUnits.addingReportingOverflow(delta.fanoutUnits)
                let (plans, plansOverflowed) = existing.plans.addingReportingOverflow(delta.plans)
                guard !unitsOverflowed, !plansOverflowed else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                shardDeltas[key] = .init(
                    roomShardID: key.roomShardID,
                    capacityProfileID: key.capacityProfileID,
                    leaseID: existing.leaseID,
                    generation: existing.generation,
                    fanoutUnits: fanoutUnits,
                    plans: plans
                )
            } else {
                shardDeltas[key] = .init(
                    roomShardID: key.roomShardID,
                    capacityProfileID: key.capacityProfileID,
                    leaseID: admission.shardLeaseID,
                    generation: admission.shardLeaseGeneration,
                    fanoutUnits: delta.fanoutUnits,
                    plans: delta.plans
                )
            }
        }
        let orderedShardDeltas = shardDeltas.values.sorted {
            $0.roomShardID == $1.roomShardID
                ? $0.capacityProfileID < $1.capacityProfileID
                : $0.roomShardID < $1.roomShardID
        }
        let shardDeltaJSON = try batchJSON(orderedShardDeltas)

        // Shard rows are the only shared global lock. Take all of them at the
        // transaction tail in canonical order and leave no work after their
        // set-based decrement except commit.
        let lockedShards = try await sql.raw("""
            WITH delta AS MATERIALIZED (
                SELECT room_shard_id, capacity_profile_id, lease_id, generation
                FROM jsonb_to_recordset(\(bind: shardDeltaJSON)::jsonb)
                    AS value(room_shard_id text, capacity_profile_id text, lease_id uuid, generation bigint,
                             fanout_units bigint, plans bigint)
            )
            SELECT pool.room_shard_id, pool.capacity_profile_id
            FROM delta
            JOIN im_v2.shard_admission_pools AS pool
              ON pool.room_shard_id = delta.room_shard_id
             AND pool.capacity_profile_id = delta.capacity_profile_id
             AND pool.lease_id = delta.lease_id
             AND pool.generation = delta.generation
            ORDER BY pool.room_shard_id, pool.capacity_profile_id
            FOR UPDATE OF pool
            """).all(decoding: ShardReleaseKeyRow.self)
        guard Set(lockedShards.map(\.key)) == Set(shardDeltas.keys) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let changedShards = try await sql.raw("""
            WITH delta AS MATERIALIZED (
                SELECT room_shard_id, capacity_profile_id, lease_id, generation,
                       fanout_units, plans
                FROM jsonb_to_recordset(\(bind: shardDeltaJSON)::jsonb)
                    AS value(room_shard_id text, capacity_profile_id text, lease_id uuid, generation bigint,
                             fanout_units bigint, plans bigint)
            )
            UPDATE im_v2.shard_admission_pools AS pool
            SET outstanding_fanout_units = pool.outstanding_fanout_units - delta.fanout_units,
                outstanding_plans = pool.outstanding_plans - delta.plans
            FROM delta
            WHERE pool.room_shard_id = delta.room_shard_id
              AND pool.capacity_profile_id = delta.capacity_profile_id
              AND pool.lease_id = delta.lease_id
              AND pool.generation = delta.generation
              AND pool.outstanding_fanout_units >= delta.fanout_units
              AND pool.outstanding_plans >= delta.plans
            RETURNING pool.room_shard_id, pool.capacity_profile_id
            """).all(decoding: ShardReleaseKeyRow.self)
        guard Set(changedShards.map(\.key)) == Set(shardDeltas.keys) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return .init(releasedCount: units.count, closedPlanCount: closingEvents.count)
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

private enum BatchProjectionDeliveryFence: Sendable {
    case claimed
    case freshDirect
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
private struct RouterFenceInput: Encodable {
    let ordinal: Int
    let userID: UUID
    let lockUser: String
    enum CodingKeys: String, CodingKey {
        case ordinal
        case userID = "user_id"
        case lockUser = "lock_user"
    }
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
private struct FreshDirectRouteInput: Encodable {
    let ordinal: Int
    let userID: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case userID = "user_id"
    }
}
private struct FreshDirectRouteRow: Decodable {
    let ordinal: Int
    let writeBucket: String
    let routerEpoch: Int64
    let requiresForwarding: Bool

    enum CodingKeys: String, CodingKey {
        case ordinal
        case writeBucket = "write_bucket"
        case routerEpoch = "router_epoch"
        case requiresForwarding = "requires_forwarding"
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
private struct CompletionUnitIncrementInput: Encodable {
    let sourceEventID: UUID
    let completionUnitID: UUID
    let committedTargetDelta: Int

    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case completionUnitID = "completion_unit_id"
        case committedTargetDelta = "committed_target_delta"
    }
}
private struct UpdatedCompletionUnitRow: Decodable {
    let sourceEventID: UUID
    let completionUnitID: UUID

    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case completionUnitID = "completion_unit_id"
    }
}
private struct ProjectionInputRow: Decodable {
    let eventPayloadJSON: String
    let stateID: UUID?
    let messageID: UUID?
    let roomID: UUID?
    let messageRevision: Int64?
    let variantKey: Int16?
    let originEventID: UUID?
    let stateEventID: UUID?
    let isWithdrawn: Bool?
    let payloadSchemaVersion: Int16?
    let statePayloadJSON: String?
    let stateCreatedAt: Date?

    func messageState(projectionKind: String) throws -> V2FanoutMessageProjectionState? {
        try fanoutMessageState(
            projectionKind: projectionKind,
            stateID: stateID,
            messageID: messageID,
            roomID: roomID,
            messageRevision: messageRevision,
            variantKey: variantKey,
            originEventID: originEventID,
            stateEventID: stateEventID,
            isWithdrawn: isWithdrawn,
            payloadSchemaVersion: payloadSchemaVersion,
            statePayloadJSON: statePayloadJSON,
            stateCreatedAt: stateCreatedAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case eventPayloadJSON = "event_payload_json"
        case stateID = "state_id"
        case messageID = "message_id"
        case roomID = "room_id"
        case messageRevision = "message_revision"
        case variantKey = "variant_key"
        case originEventID = "origin_event_id"
        case stateEventID = "state_event_id"
        case isWithdrawn = "is_withdrawn"
        case payloadSchemaVersion = "payload_schema_version"
        case statePayloadJSON = "state_payload_json"
        case stateCreatedAt = "state_created_at"
    }
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
    let stateID: UUID?
    let messageID: UUID?
    let roomID: UUID?
    let messageRevision: Int64?
    let variantKey: Int16?
    let originEventID: UUID?
    let stateEventID: UUID?
    let isWithdrawn: Bool?
    let payloadSchemaVersion: Int16?
    let statePayloadJSON: String?
    let stateCreatedAt: Date?

    func messageState(projectionKind: String) throws -> V2FanoutMessageProjectionState? {
        try fanoutMessageState(
            projectionKind: projectionKind,
            stateID: stateID,
            messageID: messageID,
            roomID: roomID,
            messageRevision: messageRevision,
            variantKey: variantKey,
            originEventID: originEventID,
            stateEventID: stateEventID,
            isWithdrawn: isWithdrawn,
            payloadSchemaVersion: payloadSchemaVersion,
            statePayloadJSON: statePayloadJSON,
            stateCreatedAt: stateCreatedAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case sourceEventID = "source_event_id"
        case eventPayloadJSON = "event_payload_json"
        case stateID = "state_id"
        case messageID = "message_id"
        case roomID = "room_id"
        case messageRevision = "message_revision"
        case variantKey = "variant_key"
        case originEventID = "origin_event_id"
        case stateEventID = "state_event_id"
        case isWithdrawn = "is_withdrawn"
        case payloadSchemaVersion = "payload_schema_version"
        case statePayloadJSON = "state_payload_json"
        case stateCreatedAt = "state_created_at"
    }
}

private func fanoutMessageState(
    projectionKind: String,
    stateID: UUID?,
    messageID: UUID?,
    roomID: UUID?,
    messageRevision: Int64?,
    variantKey: Int16?,
    originEventID: UUID?,
    stateEventID: UUID?,
    isWithdrawn: Bool?,
    payloadSchemaVersion: Int16?,
    statePayloadJSON: String?,
    stateCreatedAt: Date?
) throws -> V2FanoutMessageProjectionState? {
    let values: [Any?] = [
        stateID, messageID, roomID, messageRevision, variantKey,
        originEventID, isWithdrawn, payloadSchemaVersion,
        statePayloadJSON, stateCreatedAt,
    ]
    if values.allSatisfy({ $0 == nil }) {
        return nil
    }
    guard projectionKind == "message",
          let stateID, let messageID, let roomID, let messageRevision,
          let variantKey, let originEventID, let isWithdrawn,
          let payloadSchemaVersion, let statePayloadJSON, let stateCreatedAt
    else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return .init(
        stateID: stateID,
        messageID: messageID,
        roomID: roomID,
        messageRevision: messageRevision,
        variantKey: variantKey,
        originEventID: originEventID,
        stateEventID: stateEventID,
        isWithdrawn: isWithdrawn,
        payloadSchemaVersion: payloadSchemaVersion,
        payloadJSON: statePayloadJSON,
        createdAt: stateCreatedAt
    )
}
private struct InboxInsertRow: Decodable { let sourceEventID: UUID; enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" } }
private struct SyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private struct UserSyncSequenceRow: Decodable { let userSyncSequence: Int64; enum CodingKeys: String, CodingKey { case userSyncSequence = "user_sync_sequence" } }
private struct CompletionUnitRow: Decodable { let targetCount: Int; let state: String; enum CodingKeys: String, CodingKey { case targetCount = "target_count", state } }
private struct TerminalCompletionUnitRow: Decodable {
    let sourceEventID: UUID
    let completionUnitID: UUID
    let targetCount: Int
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case completionUnitID = "completion_unit_id"
        case targetCount = "target_count"
    }
}
private struct TerminalCompletionReleaseInput: Encodable, Hashable {
    let sourceEventID: UUID
    let completionUnitID: UUID
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case completionUnitID = "completion_unit_id"
    }
}
private struct TerminalCompletionReleaseKeyRow: Decodable {
    let sourceEventID: UUID
    let completionUnitID: UUID
    var key: TerminalCompletionReleaseInput {
        .init(sourceEventID: sourceEventID, completionUnitID: completionUnitID)
    }
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case completionUnitID = "completion_unit_id"
    }
}
private struct BatchReleasePlanRow: Decodable {
    let sourceEventID: UUID
    let roomID: UUID
    let state: String
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id"
        case roomID = "room_id"
        case state
    }
}
private struct BatchReleaseRoomRow: Decodable {
    let roomID: UUID
    let roomShardID: String
    let capacityProfileID: String
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomShardID = "room_shard_id"
        case capacityProfileID = "capacity_profile_id"
    }
}
private struct BatchReleaseAdmissionRow: Decodable {
    let roomID: UUID
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case shardLeaseID = "shard_lease_id"
        case shardLeaseGeneration = "shard_lease_generation"
    }
}
private struct SourceEventRow: Decodable {
    let sourceEventID: UUID
    enum CodingKeys: String, CodingKey { case sourceEventID = "source_event_id" }
}

private struct FreshDirectCandidateUserRow: Decodable {
    let targetUserID: UUID

    enum CodingKeys: String, CodingKey {
        case targetUserID = "target_user_id"
    }
}
private struct FreshDirectUserLockRow: Decodable {
    let lockUser: String
    let acquired: Bool
    enum CodingKeys: String, CodingKey {
        case lockUser = "lock_user"
        case acquired
    }
}
private struct RoomIDRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}
private struct BatchRoomReleaseDelta: Encodable {
    let roomID: UUID
    var fanoutUnits: Int
    var plans: Int
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case fanoutUnits = "fanout_units"
        case plans
    }
}
private struct BatchShardReleaseKey: Hashable {
    let roomShardID: String
    let capacityProfileID: String
}
private struct BatchShardReleaseDelta: Encodable {
    let roomShardID: String
    let capacityProfileID: String
    let leaseID: UUID
    let generation: Int64
    let fanoutUnits: Int
    let plans: Int
    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id"
        case capacityProfileID = "capacity_profile_id"
        case leaseID = "lease_id"
        case generation
        case fanoutUnits = "fanout_units"
        case plans
    }
}
private struct ShardReleaseKeyRow: Decodable {
    let roomShardID: String
    let capacityProfileID: String
    var key: BatchShardReleaseKey {
        .init(roomShardID: roomShardID, capacityProfileID: capacityProfileID)
    }
    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id"
        case capacityProfileID = "capacity_profile_id"
    }
}

private func deliveryRetryAttempt(_ value: Int64) throws -> Int {
    guard value > 0, value <= Int64(Int.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int(value)
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
