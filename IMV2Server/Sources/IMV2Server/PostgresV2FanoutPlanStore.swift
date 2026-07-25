import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Plans fan-out from the membership revision committed with the source event.
/// It never reads today's membership set for an older event.
public struct PostgresV2FanoutPlanStore: V2FanoutPlanStore {
    private let database: any Database
    private let router: any V2UserShardRouter
    private let makeUUID: @Sendable () -> UUID

    public init(database: any Database, router: any V2UserShardRouter, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.router = router
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
            case .completed:
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
                       plan.enumeration_checkpoint->>'after_user_id' AS after_user_id
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

            let members = try await fetchPage(
                sql: sql,
                plan: plan,
                afterUserID: plan.afterUserID,
                pageSize: pageSize
            )
            guard !members.isEmpty else {
                guard let createdDeliveries = try await sql.raw("""
                    SELECT COUNT(*) AS value FROM im_v2.fanout_deliveries
                    WHERE source_event_id = \(bind: plan.sourceEventID)
                    """).first(decoding: PlanningCountRow.self)?.value
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
                guard createdDeliveries == expectedTargetCount else {
                    throw V2FanoutPlanningError.membershipCountMismatch(expected: expectedTargetCount, actual: createdDeliveries)
                }
                try await sql.raw("""
                    UPDATE im_v2.fanout_plans
                    SET state = 'planned'
                    WHERE plan_id = \(bind: planID)
                """).run()
                return .completed
            }

            let users = try members.map { try UserID($0.userID.uuidString) }
            let routes = try await router.routes(for: users)
            guard routes.count == members.count else { throw V2UserShardRouterError.resultCountMismatch }
            let first = members[0].userID
            let last = members[members.count - 1].userID
            let completionUnitID = makeUUID()
            try await sql.raw("""
                INSERT INTO im_v2.fanout_completion_units
                    (source_event_id, completion_unit_id, target_boundary, target_count, state)
                VALUES
                    (\(bind: plan.sourceEventID), \(bind: completionUnitID),
                     jsonb_build_object('first_user_id', \(bind: first.uuidString),
                                        'last_user_id', \(bind: last.uuidString),
                                        'membership_revision', \(bind: plan.committedMembershipRevision),
                                        'audience_kind', \(bind: plan.targetRuleKind)),
                     \(bind: members.count), 'pending')
            """).run()
            try await insertDeliveries(sql: sql, plan: plan, members: members, routes: routes, completionUnitID: completionUnitID)
            try await sql.raw("""
                UPDATE im_v2.fanout_plans
                SET enumeration_checkpoint = jsonb_build_object('after_user_id', \(bind: last.uuidString))
                WHERE plan_id = \(bind: planID) AND state = 'planning'
                """).run()
            return .page(units: 1, deliveries: members.count)
        }
    }

    private func fetchPage(
        sql: any SQLDatabase,
        plan: FanoutPlanRow,
        afterUserID: UUID?,
        pageSize: Int
    ) async throws -> [FanoutMemberRow] {
        if plan.targetRuleKind == "frozen_targets" {
            if let afterUserID {
                return try await sql.raw("""
                    SELECT target_user_id AS user_id FROM im_v2.fanout_plan_targets
                    WHERE source_event_id = \(bind: plan.sourceEventID) AND target_user_id > \(bind: afterUserID)
                    ORDER BY target_user_id LIMIT \(bind: pageSize)
                    """).all(decoding: FanoutMemberRow.self)
            }
            return try await sql.raw("""
                SELECT target_user_id AS user_id FROM im_v2.fanout_plan_targets
                WHERE source_event_id = \(bind: plan.sourceEventID)
                ORDER BY target_user_id LIMIT \(bind: pageSize)
                """).all(decoding: FanoutMemberRow.self)
        }
        if let afterUserID {
            return try await sql.raw("""
                SELECT user_id FROM im_v2.room_memberships
                WHERE room_id = \(bind: plan.roomID)
                  AND joined_revision <= \(bind: plan.committedMembershipRevision)
                  AND (left_revision IS NULL OR left_revision > \(bind: plan.committedMembershipRevision))
                  AND user_id > \(bind: afterUserID)
                ORDER BY user_id LIMIT \(bind: pageSize)
                """).all(decoding: FanoutMemberRow.self)
        }
        return try await sql.raw("""
            SELECT user_id FROM im_v2.room_memberships
            WHERE room_id = \(bind: plan.roomID)
              AND joined_revision <= \(bind: plan.committedMembershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: plan.committedMembershipRevision))
            ORDER BY user_id LIMIT \(bind: pageSize)
            """).all(decoding: FanoutMemberRow.self)
    }

    private func insertDeliveries(
        sql: any SQLDatabase,
        plan: FanoutPlanRow,
        members: [FanoutMemberRow],
        routes: [V2UserShardRoute],
        completionUnitID: UUID
    ) async throws {
        let projectionKind: String
        switch plan.eventType {
        case "membership_changed": projectionKind = "membership"
        case "member.muted", "room.frozen", "room.unfrozen": projectionKind = "moderation"
        case "room.created": projectionKind = "room"
        default: projectionKind = "message"
        }
        guard members.count == routes.count else { throw V2UserShardRouterError.resultCountMismatch }
        let routeJSON = try String(data: JSONEncoder().encode(zip(members, routes).map {
            DeliveryRouteInsertRow(userID: $0.0.userID, bucket: $0.1.bucket, observedRouterEpoch: $0.1.observedRouterEpoch)
        }), encoding: .utf8)
        guard let routeJSON else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("""
            INSERT INTO im_v2.fanout_deliveries
                (source_event_id, target_user_id, projection_kind, completion_unit_id,
                 target_shard_bucket, observed_router_epoch)
            SELECT \(bind: plan.sourceEventID), route.target_user_id, \(bind: projectionKind), \(bind: completionUnitID),
                   route.target_shard_bucket, route.observed_router_epoch
            FROM jsonb_to_recordset(\(bind: routeJSON)::jsonb) AS route(
                target_user_id UUID, target_shard_bucket TEXT, observed_router_epoch BIGINT
            )
            ON CONFLICT (source_event_id, target_user_id, projection_kind) DO NOTHING
            """).run()
    }
}

public enum V2FanoutPlanningError: Error, Equatable, Sendable {
    case invalidPageSize
    case planNotFound
    case membershipCountMismatch(expected: Int, actual: Int)
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
    enum CodingKeys: String, CodingKey {
        case planID = "plan_id", sourceEventID = "source_event_id", roomID = "room_id", committedMembershipRevision = "committed_membership_revision", targetCount = "target_count", state, targetRuleKind = "target_rule_kind", eventType = "event_type", afterUserID = "after_user_id"
    }
}

private struct FanoutMemberRow: Decodable {
    let userID: UUID
    enum CodingKeys: String, CodingKey { case userID = "user_id" }
}

private struct DeliveryRouteInsertRow: Encodable {
    let userID: UUID
    let bucket: String
    let observedRouterEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "target_user_id"
        case bucket = "target_shard_bucket"
        case observedRouterEpoch = "observed_router_epoch"
    }
}

private enum PlanningStep: Sendable {
    case alreadyPlanned
    case page(units: Int, deliveries: Int)
    case completed
}

private struct PlanningCountRow: Decodable { let value: Int }

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
