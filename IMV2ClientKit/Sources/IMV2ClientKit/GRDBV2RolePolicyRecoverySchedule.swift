import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// 读取角色策略恢复的下一次尝试调度。
    ///
    /// 只有在同步游标就绪、安装已绑定用户，且存在待恢复或与当前成员修订、
    /// 来源事件、安装绑定或用户不一致的群组时，才会给出下一次尝试时间；
    /// 否则返回 `nil` 表示无需调度。
    ///
    /// - Returns: 下一次尝试时间与变更通知组成的调度。
    public nonisolated func rolePolicyRecoverySchedule() -> V2CommandRetrySchedule {
        let pool = databasePool
        let query = Self.rolePolicyRecoveryScheduleQuery
        return .init(nextAttemptAt: {
            try await pool.read { try Double.fetchOne($0, sql: query).map(Date.init(timeIntervalSince1970:)) }
        }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        let observation = ValueObservation.tracking { try Double.fetchOne($0, sql: query) }.removeDuplicates()
                        for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }

    /// 角色策略恢复调度的查询语句。
    ///
    /// 它汇总三类到期项：显式待处理的恢复请求、基线与房间成员修订/来源事件不一致的房间，
    /// 以及已失去群组事件授权对应行的恢复请求。
    static let rolePolicyRecoveryScheduleQuery = """
        SELECT CASE WHEN COALESCE((SELECT state FROM v2_sync_cursor WHERE singleton = 1), 'ready') = 'ready'
            AND EXISTS (SELECT 1 FROM v2_local_installation WHERE singleton = 1 AND user_id IS NOT NULL)
        THEN (SELECT MIN(due) FROM (
            SELECT request.next_attempt_at AS due FROM v2_role_policy_recovery_requests AS request
            JOIN v2_room_profile_projections AS room ON room.room_id = request.room_id
            WHERE request.state = 'pending' AND room.is_group_event_authorized = 1
            UNION ALL
            SELECT 0.0 AS due FROM v2_room_profile_projections AS room
            JOIN v2_local_installation AS account ON account.singleton = 1
            LEFT JOIN v2_group_role_policy_baselines AS baseline ON baseline.room_id = room.room_id
            LEFT JOIN v2_role_policy_recovery_requests AS request ON request.room_id = room.room_id
            WHERE room.is_group_event_authorized = 1 AND (
                (baseline.room_id IS NULL AND request.room_id IS NULL)
                OR request.membership_revision <> room.membership_revision
                OR request.membership_source_event_id <> room.source_event_id
                OR request.generation <> COALESCE((SELECT generation FROM v2_sync_cursor WHERE singleton = 1), 1)
                OR request.installation_binding <> account.binding OR request.user_id <> account.user_id
            )
            UNION ALL
            SELECT 0.0 AS due FROM v2_role_policy_recovery_requests AS request
            LEFT JOIN v2_room_profile_projections AS room ON room.room_id = request.room_id AND room.is_group_event_authorized = 1
            WHERE room.room_id IS NULL
        )) ELSE NULL END
        """
}
