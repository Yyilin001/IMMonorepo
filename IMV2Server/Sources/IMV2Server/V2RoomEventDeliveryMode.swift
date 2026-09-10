import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 所有房间变更共用的投递边界。
///
/// 该边界把写入侧的投递选择显式化：标准房间创建异步扇出计划；
/// 混合房间则创建一个零目标的终态审计计划，实际投递依赖有序的房间事件日志。
enum V2RoomEventDeliveryMode {
    /// 按房间投递模式预留准入容量。
    ///
    /// 标准扇出按目标规则计费；混合大群只按命令计费，不预留扇出目标容量。
    ///
    /// - Parameters:
    ///   - deliveryMode: 房间的投递模式。
    ///   - targetRule: 标准扇出使用的目标计费规则。
    ///   - profile: 房间容量配置。
    ///   - roomState: 房间当前准入状态。
    ///   - shardState: 分片当前准入状态。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 准入预留结果。
    /// - Throws: 容量不足或状态不满足准入条件时抛出。
    static func reserve(
        deliveryMode: V2GroupDeliveryMode,
        targetRule: FanoutTargetRule,
        profile: RoomCapacityProfile,
        roomState: RoomAdmissionState,
        shardState: ShardAdmissionState,
        now: Date
    ) throws -> FanoutAdmissionResult {
        switch deliveryMode {
        case .standardFanout:
            try FanoutAdmissionEvaluator.reserve(
                request: .init(targetRule: targetRule),
                profile: profile,
                roomState: roomState,
                shardState: shardState,
                now: now
            )
        case .largeGroupHybrid:
            try V2CommandOnlyAdmissionEvaluator.reserve(
                profile: profile,
                roomState: roomState,
                shardState: shardState,
                now: now
            )
        }
    }

    /// 按房间投递模式在同一事务内持久化扇出计划。
    ///
    /// 标准扇出写入计划行并创建待处理发件箱条目；混合大群写入零目标、
    /// 预留成本为零且立即终态的计划行，不创建发件箱条目。
    ///
    /// - Parameters:
    ///   - deliveryMode: 房间的投递模式。
    ///   - planID: 本次扇出计划标识。
    ///   - eventID: 触发本次计划的来源事件标识。
    ///   - roomID: 目标房间。
    ///   - roomSequence: 来源事件在房间日志中的序号。
    ///   - committedMembershipRevision: 提交时冻结的成员修订。
    ///   - standardTargetRuleJSON: 标准扇出使用的目标规则 JSON。
    ///   - standardTargetCount: 标准扇出的目标数量。
    ///   - now: 服务端统一授时时刻。
    ///   - sql: 当前变更事务使用的数据库连接。
    /// - Throws: 持久化失败时抛出。
    static func persistPlan(
        deliveryMode: V2GroupDeliveryMode,
        planID: UUID,
        eventID: UUID,
        roomID: UUID,
        roomSequence: Int64,
        committedMembershipRevision: Int64,
        standardTargetRuleJSON: String,
        standardTargetCount: Int,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        switch deliveryMode {
        case .standardFanout:
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                VALUES
                    (\(bind: planID), \(bind: eventID), \(bind: roomID), \(bind: roomSequence), \(bind: committedMembershipRevision),
                     \(bind: standardTargetRuleJSON)::jsonb, jsonb_build_object('after_user_id', NULL),
                     \(bind: standardTargetCount), \(bind: standardTargetCount), 'planning', \(bind: now))
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at)
                VALUES (\(bind: eventID), \(bind: planID), 'pending', \(bind: now))
                """).run()
        case .largeGroupHybrid:
            try await sql.raw("""
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                     target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at, terminal_at)
                VALUES
                    (\(bind: planID), \(bind: eventID), \(bind: roomID), \(bind: roomSequence), \(bind: committedMembershipRevision),
                     '{"kind":"hybrid_room_log"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                     0, 0, 'terminal', \(bind: now), \(bind: now))
                """).run()
        }
    }
}
