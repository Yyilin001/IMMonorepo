import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Shared delivery seam for every room mutation.  It keeps the write-side
/// choice explicit: standard rooms create an asynchronous fan-out plan;
/// hybrid rooms create a terminal audit plan with zero targets and rely on
/// the ordered room event log instead.
enum V2RoomEventDeliveryMode {
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
