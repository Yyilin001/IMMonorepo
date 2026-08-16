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
