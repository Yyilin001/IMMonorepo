import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
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
