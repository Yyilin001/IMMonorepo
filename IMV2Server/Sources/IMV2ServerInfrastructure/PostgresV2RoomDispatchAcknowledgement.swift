import Foundation
import IMV2ServerContracts
import SQLKit

extension PostgresV2RoomDispatchStore {
    public func acknowledgePages(_ pages: [V2RoomDispatchAcknowledgement], now: Date) async throws -> Set<UUID> {
        guard pages.count <= 32, Set(pages.map { $0.lease.eventID }).count == pages.count,
              v2PostgresTimestampCanEncode(now), let sql = database as? any SQLDatabase else { throw V2RoomDispatchError.invalidInput }
        guard !pages.isEmpty else { return [] }
        var values: SQLQueryString = ""
        for (index, page) in pages.enumerated() {
            if index > 0 { values += "," }
            values += "(\(bind: page.lease.eventID)::uuid,\(bind: page.lease.token)::uuid,\(bind: page.lease.recipientCursor)::uuid,\(bind: page.through)::uuid)"
        }
        let rows = try await sql.raw("""
            WITH requested(event_id,token,old_cursor,through) AS (VALUES \(values)), owned AS MATERIALIZED (
                SELECT work.source_event_id,requested.through, NOT EXISTS (
                    SELECT 1 FROM im_v2.room_memberships membership
                    WHERE membership.room_id=work.room_id
                      AND membership.joined_revision<=work.membership_revision
                      AND (membership.left_revision IS NULL OR membership.left_revision>work.membership_revision)
                      AND (COALESCE(requested.through,work.recipient_cursor) IS NULL
                           OR membership.user_id>COALESCE(requested.through,work.recipient_cursor))
                ) AS exhausted
                FROM im_v2.room_dispatch_outbox work JOIN requested ON requested.event_id=work.source_event_id
                WHERE work.claim_token=requested.token AND work.lease_expires_at>\(bind: now)
                  AND work.recipient_cursor IS NOT DISTINCT FROM requested.old_cursor
                  AND (requested.through IS NULL OR work.recipient_cursor IS NULL OR requested.through>work.recipient_cursor)
                ORDER BY work.source_event_id FOR UPDATE OF work
            ), finished AS (
                DELETE FROM im_v2.room_dispatch_outbox work USING owned
                WHERE work.source_event_id=owned.source_event_id AND owned.exhausted
                RETURNING work.source_event_id
            ), advanced AS (
                UPDATE im_v2.room_dispatch_outbox work
                SET recipient_cursor=owned.through,claim_token=NULL,lease_expires_at=NULL,next_attempt_at=\(bind: now)
                FROM owned WHERE work.source_event_id=owned.source_event_id AND NOT owned.exhausted AND owned.through IS NOT NULL
                RETURNING work.source_event_id
            )
            SELECT source_event_id FROM finished UNION ALL SELECT source_event_id FROM advanced
            """).all(decoding: DispatchAcknowledgedRow.self)
        return Set(rows.map(\.source_event_id))
    }
}
private struct DispatchAcknowledgedRow: Decodable { let source_event_id: UUID }
