import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 依据与来源事件一同提交的成员修订来规划扇出。
///
/// 它绝不会为较老的事件读取今天的成员集合。当逻辑路由控制面与数据同库时，
/// 每页都由一条集合式语句完成规划：候选快照、路由快照、完成单元、投递行与持久化检查点推进，
/// 要么一同提交，要么一同回滚。
public struct PostgresV2FanoutPlanStore: V2FanoutPlanStore {
    private let database: any Database
    private let makeUUID: @Sendable () -> UUID

    /// 组合数据库与标识生成方式。
    ///
    /// - Parameters:
    ///   - database: 存放扇出计划、完成单元与投递行的数据库。
    ///   - makeUUID: 完成单元标识生成方式。
    public init(database: any Database, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.database = database
        self.makeUUID = makeUUID
    }

    /// 规划单个扇出触发。
    ///
    /// 标量路径与批量路径共享同一份冻结受众、持久化分页边界与结算契约，
    /// 因此这里直接复用批量实现并取其唯一结果。
    ///
    /// - Parameters:
    ///   - trigger: 待规划的触发。
    ///   - pageSize: 成员枚举分页大小。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 本次规划结果。
    /// - Throws: 分页大小非正、时刻不可编码或持久化失败时抛出。
    public func plan(_ trigger: V2FanoutPlanTrigger, pageSize: Int, now: Date) async throws -> V2FanoutPlanningResult {
        // Scalar and batched work share the same frozen audience, durable
        // page boundary and settlement contract.
        let results = try await planBatch([trigger], pageSize: pageSize, now: now)
        guard let result = results.first else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return result
    }

    /// 在单个事务内为多个独立计划推进同一有界分页。
    ///
    /// 这是小房间流量的稳态路径：一次认领 256 条消息的中继只需一次 PostgreSQL 往返
    /// 即可创建全部完成单元与投递行，而不是 256 次串行事务。
    /// 大型受众仍保留持久化分页检查点，并在本方法的下一次集合式分页推进前保持 `pending`。
    ///
    /// - Parameters:
    ///   - triggers: 待规划的触发列表。
    ///   - pageSize: 成员枚举分页大小，需大于零。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 与输入顺序对应的规划结果；输入为空时返回空数组。
    /// - Throws: 分页大小非正时抛出
    ///   ``V2FanoutPlanningError/invalidPageSize``；时刻不可编码或持久化状态异常时抛出
    ///   ``V2RoomWriteStoreError/corruptPersistenceState``。
    public func planBatch(
        _ triggers: [V2FanoutPlanTrigger],
        pageSize: Int,
        now: Date
    ) async throws -> [V2FanoutPlanningResult] {
        guard pageSize > 0 else { throw V2FanoutPlanningError.invalidPageSize }
        guard !triggers.isEmpty else { return [] }
        guard v2PostgresTimestampCanEncode(now) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
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
            let settling = steps.filter { $0.originalState == "planning" && $0.audienceComplete }
            try await v2SettleMessageAudiencePlans(database: database, planIDs: settling.map(\.planID), now: now)
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
                    guard step.audienceComplete || enumeratedTargetCount == expectedTargetCount else {
                        throw V2FanoutPlanningError.membershipCountMismatch(
                            expected: try batchCount(expectedTargetCount),
                            actual: try batchCount(enumeratedTargetCount)
                        )
                    }
                    guard step.audienceComplete || step.resultingState == "planned" else {
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
                case "planning": if !step.audienceComplete { nextPending.append(input) }
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
                           plan.enumerated_target_count, event.event_type,
                           (plan.target_rule->>'accepted_membership_revision')::bigint AS accepted_membership_revision,
                           COALESCE((plan.enumeration_checkpoint->>'audience_complete')::boolean, FALSE) AS audience_complete
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
                              AND (plan.target_rule_kind <> 'message_visible_members' OR EXISTS (
                                  SELECT 1 FROM im_v2.room_memberships AS accepted
                                  WHERE accepted.room_id = membership.room_id
                                    AND accepted.user_id = membership.user_id
                                    AND accepted.joined_revision <= plan.accepted_membership_revision
                                    AND (accepted.left_revision IS NULL OR accepted.left_revision > plan.accepted_membership_revision)
                              ))
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
                    WHERE plan.original_state = 'planning' AND NOT plan.audience_complete
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
                           plan.enumerated_target_count, plan.event_type, plan.audience_complete,
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
                             plan.enumerated_target_count, plan.event_type, plan.audience_complete
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
                    SET enumeration_checkpoint = (CASE
                            WHEN page.candidate_count > 0
                            THEN jsonb_build_object('after_user_id', page.last_user_id::text)
                            ELSE plan.enumeration_checkpoint
                        END) || CASE WHEN page.target_rule_kind = 'message_visible_members'
                            THEN jsonb_build_object('audience_complete',
                                page.audience_complete OR page.candidate_count < \(bind: pageSize)
                                OR plan.enumerated_target_count + page.candidate_count = plan.target_count)
                            ELSE '{}'::jsonb END,
                        enumerated_target_count = plan.enumerated_target_count + page.candidate_count,
                        state = CASE
                            WHEN page.target_rule_kind <> 'message_visible_members'
                             AND plan.enumerated_target_count + page.candidate_count = plan.target_count
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
                           AND (page.target_rule_kind = 'message_visible_members'
                                OR page.enumerated_target_count = page.target_count))
                      )
                    RETURNING plan.plan_id, plan.state,
                              COALESCE((plan.enumeration_checkpoint->>'audience_complete')::boolean, FALSE) AS audience_complete
                )
                SELECT input.ordinal, input.plan_id, input.source_event_id,
                       page.original_state, page.target_count,
                       page.enumerated_target_count,
                       COALESCE(page.candidate_count, 0)::bigint AS candidate_count,
                       COALESCE(page.routed_count, 0)::bigint AS routed_count,
                       COALESCE(page.inserted_count, 0)::bigint AS inserted_count,
                       page_write.state AS resulting_state,
                       COALESCE(page_write.audience_complete, page.audience_complete, FALSE) AS audience_complete
                FROM input
                LEFT JOIN page_status AS page
                  ON page.plan_id = input.plan_id
                 AND page.source_event_id = input.source_event_id
                LEFT JOIN page_write ON page_write.plan_id = input.plan_id
                ORDER BY input.ordinal
                """).all(decoding: SetBasedBatchPlanningPageRow.self)
        }
    }

    /// 分页结算说明。
    ///
    /// 每一个已枚举的目标分页都会在独立事务中提交其投递行与检查点。
    /// 规划进程若中途退出，发件箱租约可被重新认领，本方法会严格从该持久化检查点之后继续，
    /// 而不是重新枚举整个受众。
}

/// 扇出规划错误。
public enum V2FanoutPlanningError: Error, Equatable, Sendable {
    /// 分页大小为非正值。
    case invalidPageSize
    /// 目标计划不存在。
    case planNotFound
    /// 计划统计的成员数量与枚举结果不一致，参数为期望值与实际值。
    case membershipCountMismatch(expected: Int, actual: Int)
    /// 投递覆盖数量与目标数量不一致，参数为期望值与实际值。
    case deliveryCoverageMismatch(expected: Int64, actual: Int64)
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
    let audienceComplete: Bool
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
        case resultingState = "resulting_state", audienceComplete = "audience_complete"
    }
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
