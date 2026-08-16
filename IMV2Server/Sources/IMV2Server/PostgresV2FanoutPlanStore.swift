import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Plans fan-out from the membership revision committed with the source event.
/// It never reads today's membership set for an older event. When the logical
/// route control plane is co-located in PostgreSQL, every page is planned with
/// one set-based statement: candidate snapshot, route snapshot, completion
/// unit, delivery rows and durable checkpoint advance either commit together
/// or roll back together.
public struct PostgresV2FanoutPlanStore: V2FanoutPlanStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    public func plan(_ trigger: V2FanoutPlanTrigger, pageSize: Int, now: Date) async throws -> V2FanoutPlanningResult {
        guard pageSize > 0 else { throw V2FanoutPlanningError.invalidPageSize }
        let planID = try planUUID(trigger.planID)
        let sourceEventID = try sourceEventUUID(trigger.sourceEventID)
        var createdUnits = 0
        var createdDeliveries = 0
        while true {
            let step = try await planNextPage(
                planID: planID,
                sourceEventID: sourceEventID,
                pageSize: pageSize
            )
            switch step {
            case .alreadyPlanned:
                return .init(
                    createdCompletionUnits: createdUnits,
                    createdDeliveries: createdDeliveries,
                    wasAlreadyPlanned: createdUnits == 0 && createdDeliveries == 0
                )
            case .page(let units, let deliveries):
                createdUnits += units
                createdDeliveries += deliveries
            case .completed(let units, let deliveries):
                createdUnits += units
                createdDeliveries += deliveries
                return .init(
                    createdCompletionUnits: createdUnits,
                    createdDeliveries: createdDeliveries,
                    wasAlreadyPlanned: false
                )
            }
        }
    }

    /// Advances the same bounded page for many independent plans in one
    /// transaction. This is the steady-state path for small-room traffic: a
    /// 256-message relay claim creates all completion units and deliveries
    /// with one PostgreSQL round trip instead of 256 serial transactions.
    /// Large audiences retain durable page checkpoints and simply remain in
    /// `pending` for the next set-based page pass in this method.
    public func planBatch(
        _ triggers: [V2FanoutPlanTrigger],
        pageSize: Int,
        now _: Date
    ) async throws -> [V2FanoutPlanningResult] {
        guard pageSize > 0 else { throw V2FanoutPlanningError.invalidPageSize }
        guard !triggers.isEmpty else { return [] }
        let inputs = try triggers.enumerated().map { ordinal, trigger in
            BatchPlanInput(
                ordinal: ordinal,
                planID: try planUUID(trigger.planID),
                sourceEventID: try sourceEventUUID(trigger.sourceEventID)
            )
        }
        guard Set(inputs.map(\.planID)).count == inputs.count,
              Set(inputs.map(\.sourceEventID)).count == inputs.count
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        var progress = Dictionary(
            uniqueKeysWithValues: inputs.map {
                ($0.planID, BatchPlanningProgress())
            }
        )
        var pending = inputs
        while !pending.isEmpty {
            let steps = try await planNextBatchPage(pending, pageSize: pageSize)
            guard steps.count == pending.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            var nextPending: [BatchPlanInput] = []
            nextPending.reserveCapacity(pending.count)
            for (input, step) in zip(pending, steps) {
                guard input.ordinal == step.ordinal,
                      input.planID == step.planID,
                      input.sourceEventID == step.sourceEventID,
                      let originalState = step.originalState
                else {
                    throw V2FanoutPlanningError.planNotFound
                }
                guard var item = progress[input.planID] else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                if originalState == "planned" || originalState == "terminal" {
                    progress[input.planID] = item
                    continue
                }
                guard originalState == "planning",
                      let expectedTargetCount = step.targetCount,
                      let enumeratedTargetCount = step.enumeratedTargetCount,
                      expectedTargetCount >= 0,
                      enumeratedTargetCount >= 0
                else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }

                if step.candidateCount == 0 {
                    guard enumeratedTargetCount == expectedTargetCount else {
                        throw V2FanoutPlanningError.membershipCountMismatch(
                            expected: try batchCount(expectedTargetCount),
                            actual: try batchCount(enumeratedTargetCount)
                        )
                    }
                    guard step.resultingState == "planned" else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    item.didAdvance = true
                    progress[input.planID] = item
                    continue
                }
                guard step.routedCount == step.candidateCount else {
                    throw V2UserShardRouterError.resultCountMismatch
                }
                guard step.insertedCount == step.candidateCount else {
                    throw V2FanoutPlanningError.deliveryCoverageMismatch(
                        expected: step.candidateCount,
                        actual: step.insertedCount
                    )
                }
                guard step.candidateCount <= Int64(Int.max),
                      let resultingState = step.resultingState
                else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                item.createdCompletionUnits += 1
                item.createdDeliveries += Int(step.candidateCount)
                item.didAdvance = true
                progress[input.planID] = item
                switch resultingState {
                case "planned": break
                case "planning": nextPending.append(input)
                default: throw V2RoomWriteStoreError.corruptPersistenceState
                }
            }
            pending = nextPending
        }

        return try inputs.map { input in
            guard let item = progress[input.planID] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return .init(
                createdCompletionUnits: item.createdCompletionUnits,
                createdDeliveries: item.createdDeliveries,
                wasAlreadyPlanned: !item.didAdvance
            )
        }
    }

    private func planNextBatchPage(
        _ inputs: [BatchPlanInput],
        pageSize: Int
    ) async throws -> [SetBasedBatchPlanningPageRow] {
        let pageInputs = inputs.map {
            BatchPlanningPageInput(
                ordinal: $0.ordinal,
                planID: $0.planID,
                sourceEventID: $0.sourceEventID,
                completionUnitID: makeUUID()
            )
        }
        let inputJSON = try fanoutPlanJSON(pageInputs)
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT ordinal, plan_id, source_event_id, completion_unit_id
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb)
                        AS value(ordinal integer, plan_id uuid, source_event_id uuid, completion_unit_id uuid)
                ), locked_plans AS MATERIALIZED (
                    SELECT input.ordinal, input.completion_unit_id,
                           plan.plan_id, plan.source_event_id, plan.room_id,
                           plan.committed_membership_revision, plan.target_count,
                           plan.state AS original_state,
                           plan.target_rule->>'kind' AS target_rule_kind,
                           plan.enumeration_checkpoint->>'after_user_id' AS after_user_id,
                           plan.enumerated_target_count, event.event_type
                    FROM input
                    JOIN im_v2.fanout_plans AS plan
                      ON plan.plan_id = input.plan_id
                     AND plan.source_event_id = input.source_event_id
                    JOIN im_v2.room_events AS event
                      ON event.event_id = plan.source_event_id
                    ORDER BY plan.plan_id
                    FOR UPDATE OF plan
                ), candidate_members AS MATERIALIZED (
                    SELECT plan.plan_id, plan.source_event_id, candidate.user_id
                    FROM locked_plans AS plan
                    CROSS JOIN LATERAL (
                        SELECT page.user_id
                        FROM (
                            SELECT membership.user_id
                            FROM im_v2.room_memberships AS membership
                            WHERE plan.target_rule_kind <> 'frozen_targets'
                              AND membership.room_id = plan.room_id
                              AND membership.joined_revision <= plan.committed_membership_revision
                              AND (membership.left_revision IS NULL OR membership.left_revision > plan.committed_membership_revision)
                              AND (plan.after_user_id IS NULL OR membership.user_id > plan.after_user_id::uuid)
                            UNION ALL
                            SELECT target.target_user_id AS user_id
                            FROM im_v2.fanout_plan_targets AS target
                            WHERE plan.target_rule_kind = 'frozen_targets'
                              AND target.source_event_id = plan.source_event_id
                              AND (plan.after_user_id IS NULL OR target.target_user_id > plan.after_user_id::uuid)
                        ) AS page
                        ORDER BY page.user_id
                        LIMIT \(bind: pageSize)
                    ) AS candidate
                    WHERE plan.original_state = 'planning'
                ), routed_members AS MATERIALIZED (
                    SELECT candidate.plan_id, candidate.source_event_id, candidate.user_id,
                           COALESCE(route_override.write_bucket, config.default_write_bucket) AS target_shard_bucket,
                           COALESCE(route_override.router_epoch, config.router_epoch) AS observed_router_epoch
                    FROM candidate_members AS candidate
                    CROSS JOIN im_v2.user_shard_router_configuration AS config
                    LEFT JOIN im_v2.user_shard_route_overrides AS route_override
                      ON route_override.user_id = candidate.user_id
                    WHERE config.configuration_key = TRUE
                ), page_counts AS MATERIALIZED (
                    SELECT plan.ordinal, plan.completion_unit_id,
                           plan.plan_id, plan.source_event_id,
                           plan.committed_membership_revision, plan.target_count,
                           plan.original_state, plan.target_rule_kind,
                           plan.enumerated_target_count, plan.event_type,
                           COUNT(candidate.user_id)::bigint AS candidate_count,
                           COUNT(route.user_id)::bigint AS routed_count,
                           MIN(candidate.user_id::text)::uuid AS first_user_id,
                           MAX(candidate.user_id::text)::uuid AS last_user_id
                    FROM locked_plans AS plan
                    LEFT JOIN candidate_members AS candidate
                      ON candidate.plan_id = plan.plan_id
                    LEFT JOIN routed_members AS route
                      ON route.plan_id = candidate.plan_id
                     AND route.user_id = candidate.user_id
                    GROUP BY plan.ordinal, plan.completion_unit_id,
                             plan.plan_id, plan.source_event_id,
                             plan.committed_membership_revision, plan.target_count,
                             plan.original_state, plan.target_rule_kind,
                             plan.enumerated_target_count, plan.event_type
                ), completion_units AS (
                    INSERT INTO im_v2.fanout_completion_units
                        (source_event_id, completion_unit_id, target_boundary, target_count, state)
                    SELECT page.source_event_id, page.completion_unit_id,
                           jsonb_build_object(
                               'first_user_id', page.first_user_id::text,
                               'last_user_id', page.last_user_id::text,
                               'membership_revision', page.committed_membership_revision,
                               'audience_kind', page.target_rule_kind
                           ),
                           page.candidate_count, 'pending'
                    FROM page_counts AS page
                    WHERE page.original_state = 'planning'
                      AND page.candidate_count > 0
                      AND page.candidate_count = page.routed_count
                    RETURNING source_event_id, completion_unit_id
                ), inserted_deliveries AS (
                    INSERT INTO im_v2.fanout_deliveries
                        (source_event_id, target_user_id, projection_kind,
                         completion_unit_id, target_shard_bucket, observed_router_epoch)
                    SELECT route.source_event_id, route.user_id,
                           CASE page.event_type
                               WHEN 'membership_changed' THEN 'membership'
                               WHEN 'member.muted' THEN 'moderation'
                               WHEN 'room.frozen' THEN 'moderation'
                               WHEN 'room.unfrozen' THEN 'moderation'
                               WHEN 'room.created' THEN 'room'
                               WHEN 'message.reaction_changed' THEN 'message_reaction'
                               WHEN 'message.pinned_changed' THEN 'group_capability'
                               WHEN 'group.announcement_changed' THEN 'group_capability'
                               WHEN 'group.role_permissions_changed' THEN 'group_capability'
                               WHEN 'group.member_role_changed' THEN 'group_capability'
                               ELSE 'message'
                           END,
                           completion.completion_unit_id,
                           route.target_shard_bucket, route.observed_router_epoch
                    FROM routed_members AS route
                    JOIN page_counts AS page ON page.plan_id = route.plan_id
                    JOIN completion_units AS completion
                      ON completion.source_event_id = route.source_event_id
                     AND completion.completion_unit_id = page.completion_unit_id
                    ON CONFLICT (source_event_id, target_user_id, projection_kind) DO NOTHING
                    RETURNING source_event_id, target_user_id
                ), inserted_counts AS MATERIALIZED (
                    SELECT source_event_id, COUNT(*)::bigint AS inserted_count
                    FROM inserted_deliveries
                    GROUP BY source_event_id
                ), page_status AS MATERIALIZED (
                    SELECT page.*,
                           COALESCE(inserted.inserted_count, 0)::bigint AS inserted_count
                    FROM page_counts AS page
                    LEFT JOIN inserted_counts AS inserted
                      ON inserted.source_event_id = page.source_event_id
                ), page_write AS (
                    UPDATE im_v2.fanout_plans AS plan
                    SET enumeration_checkpoint = CASE
                            WHEN page.candidate_count > 0
                            THEN jsonb_build_object('after_user_id', page.last_user_id::text)
                            ELSE plan.enumeration_checkpoint
                        END,
                        enumerated_target_count = plan.enumerated_target_count + page.candidate_count,
                        state = CASE
                            WHEN plan.enumerated_target_count + page.candidate_count = plan.target_count
                            THEN 'planned'
                            ELSE plan.state
                        END
                    FROM page_status AS page
                    WHERE plan.plan_id = page.plan_id
                      AND page.original_state = 'planning'
                      AND (
                          (page.candidate_count > 0
                           AND page.candidate_count = page.routed_count
                           AND page.candidate_count = page.inserted_count)
                          OR
                          (page.candidate_count = 0
                           AND page.enumerated_target_count = page.target_count)
                      )
                    RETURNING plan.plan_id, plan.state
                )
                SELECT input.ordinal, input.plan_id, input.source_event_id,
                       page.original_state, page.target_count,
                       page.enumerated_target_count,
                       COALESCE(page.candidate_count, 0)::bigint AS candidate_count,
                       COALESCE(page.routed_count, 0)::bigint AS routed_count,
                       COALESCE(page.inserted_count, 0)::bigint AS inserted_count,
                       page_write.state AS resulting_state
                FROM input
                LEFT JOIN page_status AS page
                  ON page.plan_id = input.plan_id
                 AND page.source_event_id = input.source_event_id
                LEFT JOIN page_write ON page_write.plan_id = input.plan_id
                ORDER BY input.ordinal
                """).all(decoding: SetBasedBatchPlanningPageRow.self)
        }
    }

    /// Each enumerated target page commits its delivery rows and checkpoint in
    /// a separate transaction. If the planner process dies, the outbox lease
    /// can be reclaimed and this method resumes strictly after that durable
    /// checkpoint instead of re-enumerating the entire audience.
    private func planNextPage(
        planID: UUID,
        sourceEventID: UUID,
        pageSize: Int
    ) async throws -> PlanningStep {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            guard let plan = try await sql.raw("""
                SELECT plan.plan_id, plan.source_event_id, plan.room_id, plan.committed_membership_revision,
                       plan.target_count, plan.state, plan.target_rule->>'kind' AS target_rule_kind,
                       event.event_type,
                       plan.enumeration_checkpoint->>'after_user_id' AS after_user_id,
                       plan.enumerated_target_count
                FROM im_v2.fanout_plans AS plan
                JOIN im_v2.room_events AS event ON event.event_id = plan.source_event_id
                WHERE plan.plan_id = \(bind: planID) AND plan.source_event_id = \(bind: sourceEventID)
                FOR UPDATE
                """).first(decoding: FanoutPlanRow.self)
            else {
                throw V2FanoutPlanningError.planNotFound
            }
            if plan.state == "planned" || plan.state == "terminal" {
                return .alreadyPlanned
            }
            guard plan.state == "planning", let expectedTargetCount = plan.targetCount else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }

            return try await planPostgresRoutedPage(
                sql: sql,
                plan: plan,
                planID: planID,
                pageSize: pageSize,
                expectedTargetCount: expectedTargetCount
            )
        }
    }

    /// `candidateMembers` is intentionally
    /// MATERIALIZED because its exact bounded membership snapshot feeds the
    /// completion boundary, route join, delivery write and checkpoint in one
    /// statement. No application-side UUID JSON round trip is involved.
    private func planPostgresRoutedPage(
        sql: any SQLDatabase,
        plan: FanoutPlanRow,
        planID: UUID,
        pageSize: Int,
        expectedTargetCount: Int
    ) async throws -> PlanningStep {
        let candidates = candidatePageQuery(plan: plan, pageSize: pageSize)
        let completionUnitID = makeUUID()
        let projectionKind = projectionKind(for: plan.eventType)
        guard let result = try await sql.raw("""
            WITH candidate_members AS MATERIALIZED (
                \(candidates)
            ),
            routed_members AS MATERIALIZED (
                SELECT candidate.user_id,
                       COALESCE(route_override.write_bucket, config.default_write_bucket) AS target_shard_bucket,
                       COALESCE(route_override.router_epoch, config.router_epoch) AS observed_router_epoch
                FROM candidate_members AS candidate
                CROSS JOIN im_v2.user_shard_router_configuration AS config
                LEFT JOIN im_v2.user_shard_route_overrides AS route_override
                  ON route_override.user_id = candidate.user_id
                WHERE config.configuration_key = TRUE
            ),
            page_counts AS (
                SELECT
                    (SELECT COUNT(*)::bigint FROM candidate_members) AS candidate_count,
                    (SELECT COUNT(*)::bigint FROM routed_members) AS routed_count,
                    (SELECT user_id FROM candidate_members ORDER BY user_id ASC LIMIT 1) AS first_user_id,
                    (SELECT user_id FROM candidate_members ORDER BY user_id DESC LIMIT 1) AS last_user_id
            ),
            completion_unit AS (
                INSERT INTO im_v2.fanout_completion_units
                    (source_event_id, completion_unit_id, target_boundary, target_count, state)
                SELECT \(bind: plan.sourceEventID), \(bind: completionUnitID),
                       jsonb_build_object('first_user_id', page.first_user_id::text,
                                          'last_user_id', page.last_user_id::text,
                                          'membership_revision', \(bind: plan.committedMembershipRevision),
                                          'audience_kind', \(bind: plan.targetRuleKind)),
                       page.candidate_count, 'pending'
                FROM page_counts AS page
                WHERE page.candidate_count > 0
                  AND page.candidate_count = page.routed_count
                RETURNING completion_unit_id
            ),
            inserted_deliveries AS (
                INSERT INTO im_v2.fanout_deliveries
                    (source_event_id, target_user_id, projection_kind, completion_unit_id,
                     target_shard_bucket, observed_router_epoch)
                SELECT \(bind: plan.sourceEventID), route.user_id, \(bind: projectionKind), completion.completion_unit_id,
                       route.target_shard_bucket, route.observed_router_epoch
                FROM routed_members AS route
                CROSS JOIN completion_unit AS completion
                ON CONFLICT (source_event_id, target_user_id, projection_kind) DO NOTHING
                RETURNING target_user_id
            ),
            page_guard AS (
                SELECT page.*,
                       (SELECT COUNT(*)::bigint FROM inserted_deliveries) AS inserted_count
                FROM page_counts AS page
            ),
            page_write AS (
                UPDATE im_v2.fanout_plans AS plan
                SET enumeration_checkpoint = jsonb_build_object('after_user_id', page.last_user_id::text),
                    enumerated_target_count = plan.enumerated_target_count + page.candidate_count,
                    state = CASE
                        WHEN plan.enumerated_target_count + page.candidate_count = plan.target_count THEN 'planned'
                        ELSE plan.state
                    END
                FROM page_guard AS page
                WHERE plan.plan_id = \(bind: planID)
                  AND plan.state = 'planning'
                  AND page.candidate_count > 0
                  AND page.candidate_count = page.routed_count
                  AND page.candidate_count = page.inserted_count
                RETURNING plan.state
            )
            SELECT page.candidate_count, page.routed_count, page.inserted_count,
                   page.first_user_id, page.last_user_id,
                   (SELECT state FROM page_write) AS resulting_state
            FROM page_guard AS page
            """).first(decoding: SetBasedPlanningPageRow.self)
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        if result.candidateCount == 0 {
            return try await completeEmptyPage(
                sql: sql,
                planID: planID,
                expectedTargetCount: expectedTargetCount,
                enumeratedTargetCount: plan.enumeratedTargetCount
            )
        }
        guard result.routedCount == result.candidateCount else {
            throw V2UserShardRouterError.resultCountMismatch
        }
        guard result.insertedCount == result.candidateCount else {
            throw V2FanoutPlanningError.deliveryCoverageMismatch(
                expected: result.candidateCount,
                actual: result.insertedCount
            )
        }
        guard let state = result.resultingState else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard result.candidateCount <= Int64(Int.max) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        if state == "planned" {
            return .completed(units: 1, deliveries: Int(result.candidateCount))
        }
        guard state == "planning" else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .page(units: 1, deliveries: Int(result.candidateCount))
    }

    private func candidatePageQuery(plan: FanoutPlanRow, pageSize: Int) -> SQLQueryString {
        if plan.targetRuleKind == "frozen_targets" {
            if let afterUserID = plan.afterUserID {
                return """
                    SELECT target_user_id AS user_id FROM im_v2.fanout_plan_targets
                    WHERE source_event_id = \(bind: plan.sourceEventID)
                      AND target_user_id > \(bind: afterUserID)
                    ORDER BY target_user_id LIMIT \(bind: pageSize)
                    """
            }
            return """
                SELECT target_user_id AS user_id FROM im_v2.fanout_plan_targets
                WHERE source_event_id = \(bind: plan.sourceEventID)
                ORDER BY target_user_id LIMIT \(bind: pageSize)
                """
        }
        if let afterUserID = plan.afterUserID {
            return """
                SELECT user_id FROM im_v2.room_memberships
                WHERE room_id = \(bind: plan.roomID)
                  AND joined_revision <= \(bind: plan.committedMembershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: plan.committedMembershipRevision))
                  AND user_id > \(bind: afterUserID)
                ORDER BY user_id LIMIT \(bind: pageSize)
                """
        }
        return """
            SELECT user_id FROM im_v2.room_memberships
            WHERE room_id = \(bind: plan.roomID)
              AND joined_revision <= \(bind: plan.committedMembershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: plan.committedMembershipRevision))
            ORDER BY user_id LIMIT \(bind: pageSize)
            """
    }

    private func completeEmptyPage(
        sql: any SQLDatabase,
        planID: UUID,
        expectedTargetCount: Int,
        enumeratedTargetCount: Int64
    ) async throws -> PlanningStep {
        guard enumeratedTargetCount == Int64(expectedTargetCount) else {
            throw V2FanoutPlanningError.membershipCountMismatch(
                expected: expectedTargetCount,
                actual: Int(enumeratedTargetCount)
            )
        }
        guard try await sql.raw("""
            UPDATE im_v2.fanout_plans
            SET state = 'planned'
            WHERE plan_id = \(bind: planID)
              AND state = 'planning'
              AND enumerated_target_count = target_count
            RETURNING plan_id
            """).first() != nil else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return .completed(units: 0, deliveries: 0)
    }

}

private extension PostgresV2FanoutPlanStore {
    func projectionKind(for eventType: String) -> String {
        switch eventType {
        case "membership_changed": return "membership"
        case "member.muted", "room.frozen", "room.unfrozen": return "moderation"
        case "room.created": return "room"
        case "message.reaction_changed": return "message_reaction"
        case "message.pinned_changed", "group.announcement_changed", "group.role_permissions_changed", "group.member_role_changed": return "group_capability"
        default: return "message"
        }
    }
}

public enum V2FanoutPlanningError: Error, Equatable, Sendable {
    case invalidPageSize
    case planNotFound
    case membershipCountMismatch(expected: Int, actual: Int)
    case deliveryCoverageMismatch(expected: Int64, actual: Int64)
}

private struct FanoutPlanRow: Decodable {
    let planID: UUID
    let sourceEventID: UUID
    let roomID: UUID
    let committedMembershipRevision: Int64
    let targetCount: Int?
    let state: String
    let targetRuleKind: String
    let eventType: String
    let afterUserID: UUID?
    let enumeratedTargetCount: Int64
    enum CodingKeys: String, CodingKey {
        case planID = "plan_id", sourceEventID = "source_event_id", roomID = "room_id", committedMembershipRevision = "committed_membership_revision", targetCount = "target_count", state, targetRuleKind = "target_rule_kind", eventType = "event_type", afterUserID = "after_user_id", enumeratedTargetCount = "enumerated_target_count"
    }
}

private struct SetBasedPlanningPageRow: Decodable {
    let candidateCount: Int64
    let routedCount: Int64
    let insertedCount: Int64
    let firstUserID: UUID?
    let lastUserID: UUID?
    let resultingState: String?
    enum CodingKeys: String, CodingKey {
        case candidateCount = "candidate_count", routedCount = "routed_count", insertedCount = "inserted_count"
        case firstUserID = "first_user_id", lastUserID = "last_user_id", resultingState = "resulting_state"
    }
}

private struct BatchPlanInput: Sendable {
    let ordinal: Int
    let planID: UUID
    let sourceEventID: UUID
}

private struct BatchPlanningPageInput: Encodable {
    let ordinal: Int
    let planID: UUID
    let sourceEventID: UUID
    let completionUnitID: UUID
    enum CodingKeys: String, CodingKey {
        case ordinal
        case planID = "plan_id"
        case sourceEventID = "source_event_id"
        case completionUnitID = "completion_unit_id"
    }
}

private struct BatchPlanningProgress: Sendable {
    var createdCompletionUnits = 0
    var createdDeliveries = 0
    var didAdvance = false
}

private struct SetBasedBatchPlanningPageRow: Decodable {
    let ordinal: Int
    let planID: UUID
    let sourceEventID: UUID
    let originalState: String?
    let targetCount: Int64?
    let enumeratedTargetCount: Int64?
    let candidateCount: Int64
    let routedCount: Int64
    let insertedCount: Int64
    let resultingState: String?
    enum CodingKeys: String, CodingKey {
        case ordinal
        case planID = "plan_id"
        case sourceEventID = "source_event_id"
        case originalState = "original_state"
        case targetCount = "target_count"
        case enumeratedTargetCount = "enumerated_target_count"
        case candidateCount = "candidate_count"
        case routedCount = "routed_count"
        case insertedCount = "inserted_count"
        case resultingState = "resulting_state"
    }
}

private enum PlanningStep: Sendable {
    case alreadyPlanned
    case page(units: Int, deliveries: Int)
    case completed(units: Int, deliveries: Int)
}

private func planUUID(_ identifier: FanoutPlanID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return value
}

private func sourceEventUUID(_ identifier: EventID) throws -> UUID {
    guard let value = UUID(uuidString: identifier.rawValue) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return value
}

private func batchCount(_ value: Int64) throws -> Int {
    guard let value = Int(exactly: value) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return value
}

private func fanoutPlanJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}
