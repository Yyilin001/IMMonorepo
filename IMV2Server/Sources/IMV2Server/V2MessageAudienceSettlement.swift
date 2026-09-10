import Fluent
import Foundation
import SQLKit

/// 把已枚举完成的受众计划结算为实际成本。
///
/// 枚举会先提交结束标记再做结算。重放路径获取同样的房间、准入与计划锁，
/// 因此要么把差额恰好应用一次，要么看到已经结算完成的计划。
/// 任何事务都不会在持有计划锁的同时等待完成释放所用的房间锁。
///
/// 结算内容为：把预留成本与已枚举数量的差额退回房间与分片准入池，
/// 把计划的目标数与预留成本改写为实际枚举值，并在枚举结果为零时直接把计划与发件箱置为终态。
///
/// - Parameters:
///   - database: 执行结算的数据库。
///   - planIDs: 待结算的计划标识列表；为空时直接返回。
///   - now: 服务端统一授时时刻。
/// - Throws: 计划、房间与准入记录不匹配或字段越界，准入池余额不足，
///   求和溢出，或持久化失败时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``；
///   死锁与序列化失败由事务重试边界处理。
func v2SettleMessageAudiencePlans(database: any Database, planIDs: [UUID], now: Date) async throws {
    guard !planIDs.isEmpty else { return }
    let input = String(decoding: try JSONEncoder().encode(planIDs), as: UTF8.self)
    try await v2WithPostgresTransactionRetry(database: database) { transaction in
        guard let sql = transaction as? any SQLDatabase else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let rooms = try await sql.raw("""
            SELECT room.room_id, room.room_shard_id, room.capacity_profile_id
            FROM im_v2.rooms AS room
            WHERE room.room_id IN (
                SELECT room_id FROM im_v2.fanout_plans
                WHERE plan_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: input)::jsonb))
            )
            ORDER BY room.room_id FOR UPDATE OF room
            """).all(decoding: AudienceSettlementRoom.self)
        let admissions = try await sql.raw("""
            SELECT admission.room_id, admission.shard_lease_id, admission.shard_lease_generation
            FROM im_v2.room_admission AS admission
            WHERE admission.room_id IN (
                SELECT room_id FROM im_v2.fanout_plans
                WHERE plan_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: input)::jsonb))
            )
            ORDER BY admission.room_id FOR UPDATE OF admission
            """).all(decoding: AudienceSettlementAdmission.self)
        let plans = try await sql.raw("""
            SELECT plan_id, source_event_id, room_id, state, target_count,
                   reserved_fanout_cost, enumerated_target_count,
                   target_rule->>'kind' AS kind,
                   (target_rule->>'reservation_lease_id')::uuid AS reservation_lease_id,
                   (target_rule->>'reservation_lease_generation')::bigint AS reservation_lease_generation,
                   COALESCE((enumeration_checkpoint->>'audience_complete')::boolean, FALSE) AS audience_complete
            FROM im_v2.fanout_plans
            WHERE plan_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: input)::jsonb))
            ORDER BY plan_id FOR UPDATE
            """).all(decoding: AudienceSettlementPlan.self)
        guard Set(plans.map(\.planID)) == Set(planIDs),
              Set(rooms.map(\.roomID)) == Set(plans.map(\.roomID)),
              Set(admissions.map(\.roomID)) == Set(rooms.map(\.roomID))
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let active = plans.filter { $0.state == "planning" }
        guard plans.allSatisfy({ $0.kind == "message_visible_members" && ["planning", "planned", "terminal"].contains($0.state) }),
              active.allSatisfy({ $0.audienceComplete && $0.targetCount == $0.reservedCost && $0.enumerated >= 0 && $0.enumerated <= $0.reservedCost })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard !active.isEmpty else { return }
        let roomByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomID, $0) })
        let admissionByID = Dictionary(uniqueKeysWithValues: admissions.map { ($0.roomID, $0) })
        var roomDeltas: [UUID: AudienceRoomDelta] = [:]
        for plan in active {
            let previous = roomDeltas[plan.roomID] ?? .init(roomID: plan.roomID, units: 0, windowUnits: 0, slots: 0)
            guard let admission = admissionByID[plan.roomID] else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let excess = plan.reservedCost - plan.enumerated
            let sameWindow = plan.reservationLeaseID == admission.leaseID && plan.reservationLeaseGeneration == admission.generation
            roomDeltas[plan.roomID] = .init(roomID: plan.roomID,
                units: try audienceSum(previous.units, excess),
                windowUnits: try audienceSum(previous.windowUnits, sameWindow ? excess : 0),
                slots: try audienceSum(previous.slots, plan.enumerated == 0 ? 1 : 0))
        }
        let deltas = roomDeltas.values.sorted { $0.roomID.uuidString < $1.roomID.uuidString }
        let roomJSON = String(decoding: try JSONEncoder().encode(deltas), as: UTF8.self)
        let changed = try await sql.raw("""
            WITH delta AS MATERIALIZED (
                SELECT * FROM jsonb_to_recordset(\(bind: roomJSON)::jsonb)
                    AS value(room_id uuid, units bigint, window_units bigint, slots bigint)
            )
            UPDATE im_v2.room_admission AS admission
            SET outstanding_fanout_units = admission.outstanding_fanout_units - delta.units,
                fanout_window_used = admission.fanout_window_used - delta.window_units,
                outstanding_plans = admission.outstanding_plans - delta.slots
            FROM delta WHERE admission.room_id = delta.room_id
              AND admission.outstanding_fanout_units >= delta.units
              AND admission.fanout_window_used >= delta.window_units
              AND admission.outstanding_plans >= delta.slots
            RETURNING admission.room_id
            """).all(decoding: AudienceRoomKey.self)
        guard Set(changed.map(\.roomID)) == Set(roomDeltas.keys) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let activeJSON = String(decoding: try JSONEncoder().encode(active.map(\.planID)), as: UTF8.self)
        let updated = try await sql.raw("""
            UPDATE im_v2.fanout_plans
            SET target_count = enumerated_target_count,
                reserved_fanout_cost = enumerated_target_count,
                state = CASE WHEN enumerated_target_count = 0 THEN 'terminal' ELSE 'planned' END,
                terminal_at = CASE WHEN enumerated_target_count = 0 THEN \(bind: now) ELSE NULL END
            WHERE plan_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: activeJSON)::jsonb))
              AND state = 'planning'
            RETURNING room_id
            """).all(decoding: AudienceRoomKey.self)
        guard updated.count == active.count else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let zeroEvents = active.filter { $0.enumerated == 0 }.map(\.sourceEventID)
        if !zeroEvents.isEmpty {
            let zeroJSON = String(decoding: try JSONEncoder().encode(zeroEvents), as: UTF8.self)
            try await sql.raw("""
                UPDATE im_v2.room_outbox SET state = 'terminal', terminal_at = \(bind: now),
                    claim_token = NULL, lease_expires_at = NULL, next_attempt_at = NULL,
                    paused_at = NULL, last_failure_code = NULL
                WHERE source_event_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: zeroJSON)::jsonb))
                  AND state <> 'terminal'
                """).run()
        }
        var shardDeltas: [AudienceShardKey: AudienceShardDelta] = [:]
        for delta in deltas {
            guard let room = roomByID[delta.roomID], let admission = admissionByID[delta.roomID] else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let key = AudienceShardKey(shard: room.shard, profile: room.profile)
            let previous = shardDeltas[key] ?? .init(shard: room.shard, profile: room.profile,
                leaseID: admission.leaseID, generation: admission.generation, units: 0, windowUnits: 0, slots: 0)
            guard previous.leaseID == admission.leaseID, previous.generation == admission.generation else { throw V2RoomWriteStoreError.corruptPersistenceState }
            shardDeltas[key] = .init(shard: room.shard, profile: room.profile,
                leaseID: admission.leaseID, generation: admission.generation,
                units: try audienceSum(previous.units, delta.units), windowUnits: try audienceSum(previous.windowUnits, delta.windowUnits), slots: try audienceSum(previous.slots, delta.slots))
        }
        let shardJSON = String(decoding: try JSONEncoder().encode(Array(shardDeltas.values)), as: UTF8.self)
        let changedShards = try await sql.raw("""
            WITH delta AS MATERIALIZED (
                SELECT * FROM jsonb_to_recordset(\(bind: shardJSON)::jsonb)
                    AS value(shard text, profile text, lease_id uuid, generation bigint, units bigint, window_units bigint, slots bigint)
            ), locked AS MATERIALIZED (
                SELECT pool.room_shard_id, pool.capacity_profile_id
                FROM im_v2.shard_admission_pools AS pool JOIN delta
                  ON pool.room_shard_id = delta.shard AND pool.capacity_profile_id = delta.profile
                 AND pool.lease_id = delta.lease_id AND pool.generation = delta.generation
                ORDER BY pool.room_shard_id, pool.capacity_profile_id FOR UPDATE OF pool
            )
            UPDATE im_v2.shard_admission_pools AS pool
            SET outstanding_fanout_units = pool.outstanding_fanout_units - delta.units,
                fanout_window_used = pool.fanout_window_used - delta.window_units,
                outstanding_plans = pool.outstanding_plans - delta.slots
            FROM delta JOIN locked ON locked.room_shard_id = delta.shard AND locked.capacity_profile_id = delta.profile
            WHERE pool.room_shard_id = delta.shard AND pool.capacity_profile_id = delta.profile
              AND pool.lease_id = delta.lease_id AND pool.generation = delta.generation
              AND pool.outstanding_fanout_units >= delta.units AND pool.outstanding_plans >= delta.slots
              AND pool.fanout_window_used >= delta.window_units
            RETURNING pool.room_shard_id AS shard, pool.capacity_profile_id AS profile
            """).all(decoding: AudienceShardKey.self)
        guard Set(changedShards) == Set(shardDeltas.keys) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    }
}

/// 以溢出检测方式求两个 64 位整数之和。
///
/// - Parameters:
///   - left: 被加数。
///   - right: 加数。
/// - Returns: 求和结果。
/// - Throws: 相加溢出时抛出 ``V2RoomWriteStoreError/corruptPersistenceState``。
private func audienceSum(_ left: Int64, _ right: Int64) throws -> Int64 {
    let (sum, overflow) = left.addingReportingOverflow(right)
    guard !overflow else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return sum
}
private struct AudienceRoomKey: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}
private struct AudienceSettlementRoom: Decodable {
    let roomID: UUID; let shard: String; let profile: String
    enum CodingKeys: String, CodingKey { case roomID = "room_id", shard = "room_shard_id", profile = "capacity_profile_id" }
}
private struct AudienceSettlementAdmission: Decodable {
    let roomID: UUID; let leaseID: UUID; let generation: Int64
    enum CodingKeys: String, CodingKey { case roomID = "room_id", leaseID = "shard_lease_id", generation = "shard_lease_generation" }
}
private struct AudienceSettlementPlan: Decodable {
    let planID: UUID; let sourceEventID: UUID; let roomID: UUID; let state: String
    let targetCount: Int64?; let reservedCost: Int64; let enumerated: Int64
    let kind: String; let audienceComplete: Bool
    let reservationLeaseID: UUID?; let reservationLeaseGeneration: Int64?
    enum CodingKeys: String, CodingKey {
        case planID = "plan_id", sourceEventID = "source_event_id", roomID = "room_id", state
        case targetCount = "target_count", reservedCost = "reserved_fanout_cost", enumerated = "enumerated_target_count"
        case kind, audienceComplete = "audience_complete"
        case reservationLeaseID = "reservation_lease_id", reservationLeaseGeneration = "reservation_lease_generation"
    }
}
private struct AudienceRoomDelta: Encodable {
    let roomID: UUID; let units: Int64; let windowUnits: Int64; let slots: Int64
    enum CodingKeys: String, CodingKey { case roomID = "room_id", units, windowUnits = "window_units", slots }
}
private struct AudienceShardKey: Hashable, Decodable { let shard: String; let profile: String }
private struct AudienceShardDelta: Encodable {
    let shard: String; let profile: String; let leaseID: UUID; let generation: Int64; let units: Int64; let windowUnits: Int64; let slots: Int64
    enum CodingKeys: String, CodingKey { case shard, profile, leaseID = "lease_id", generation, units, windowUnits = "window_units", slots }
}
