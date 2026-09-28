import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// Bounded visible rows drive page observation. This creates no work and its
    /// termination only cancels the observer, leaving account activities intact.
    public nonisolated func resourceSendChanges(in roomID:RoomID, page:Int=0) -> AsyncThrowingStream<Void,any Error> {
        let pool=databasePool
        let boundedPage=max(0,min(page,Int.max / 200 - 1))
        let offset=boundedPage * 200
        return AsyncThrowingStream(bufferingPolicy:.bufferingNewest(1)) { continuation in
            let observer=Task {
                do {
                    let observation=ValueObservation.tracking { db in
                        try String.fetchAll(db,sql:"""
                            WITH visible AS (
                              SELECT i.intent_id FROM v2_send_intents i
                              WHERE i.room_id=? AND i.stage='preparing' AND ?=0 ORDER BY i.created_at LIMIT 200),
                            submitted AS (
                              SELECT i.intent_id FROM v2_send_intents i JOIN v2_operation_work w ON w.work_id=i.work_id
                              JOIN v2_message_send_operations m ON m.work_id=w.work_id
                              WHERE i.room_id=? AND i.stage='handedOff' AND \(Self.submittedSendVisibilityPredicate)
                              ORDER BY CASE WHEN w.scheduling_state='finished' AND NOT (w.execution_state='committed' AND m.accepted_projection_observed=0) THEN 1 ELSE 0 END,
                              CASE WHEN w.scheduling_state='finished' AND NOT (w.execution_state='committed' AND m.accepted_projection_observed=0) THEN -i.created_at ELSE i.created_at END,
                              i.intent_id LIMIT 201 OFFSET ?),
                            ids AS (SELECT intent_id FROM visible UNION SELECT intent_id FROM submitted),
                            dependencies AS (
                              SELECT intent_id,ordinal,job_id,'upload' kind FROM v2_send_intent_dependencies
                              UNION ALL SELECT intent_id,ordinal,job_id,'import' kind FROM v2_send_intent_import_dependencies)
                            SELECT printf('%s|%s|%d|%f|%s|%s|%s|%s|%s|%d|%s|%d',
                              i.intent_id,i.stage,i.attempts,i.retry_at,w.execution_state,w.scheduling_state,w.last_error_code,
                              d.job_id,j.stage,j.needs_attention,r.stage,r.attempts) || printf('|%s|%d|%d',m.accepted_message_id,m.accepted_projection_observed,
                              EXISTS(SELECT 1 FROM v2_message_projections p WHERE p.message_id=m.accepted_message_id AND p.room_id=m.room_id AND p.room_sequence=m.accepted_room_sequence)
                              OR EXISTS(SELECT 1 FROM v2_message_tombstones t WHERE t.message_id=m.accepted_message_id AND t.room_id=m.room_id)
                              OR EXISTS(SELECT 1 FROM v2_room_membership_states a WHERE a.room_id=m.room_id AND a.is_member=0)
                              OR EXISTS(SELECT 1 FROM v2_room_event_authorizations a WHERE a.room_id=m.room_id AND a.is_authorized=0))
                            FROM ids JOIN v2_send_intents i USING(intent_id)
                            LEFT JOIN v2_operation_work w ON w.work_id=i.work_id
                            LEFT JOIN v2_message_send_operations m ON m.work_id=w.work_id
                            LEFT JOIN dependencies d USING(intent_id)
                            LEFT JOIN v2_resource_transfer_jobs j ON j.job_id=d.job_id AND d.kind='upload'
                            LEFT JOIN v2_resource_import_jobs r ON r.job_id=d.job_id AND d.kind='import'
                            ORDER BY i.created_at,i.intent_id,d.ordinal,d.kind
                            """,arguments:[roomID.rawValue,boundedPage,roomID.rawValue,offset])
                    }.removeDuplicates()
                    for try await _ in observation.values(in:pool,bufferingPolicy:.bufferingNewest(1)) {
                        continuation.yield(())
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
    }
}
