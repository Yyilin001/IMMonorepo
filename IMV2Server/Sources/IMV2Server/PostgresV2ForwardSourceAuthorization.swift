import Foundation
import SQLKit

/// Forward, reference and media callers bind `message` and `room` aliases. Historical
/// membership and current membership are separate intervals: a rejoined user
/// may read a message from an earlier interval, but never one from the gap.
/// Missing accepted evidence fails closed; current membership is no fallback.
/// The immutable completion primary key owns acceptance; payload storage and
/// the physical compatibility copy of its revision are not authority.
func v2ForwardSourceVisibility(actorID: UUID) -> SQLQueryString {
    """
    EXISTS (
        SELECT 1 FROM im_v2.room_memberships AS current_membership
        WHERE current_membership.room_id = message.room_id
          AND current_membership.user_id = \(bind: actorID)
          AND current_membership.joined_revision <= room.membership_revision
          AND (current_membership.left_revision IS NULL
               OR current_membership.left_revision > room.membership_revision)
    )
    AND EXISTS (
        SELECT 1 FROM im_v2.room_memberships AS historical_membership
        WHERE historical_membership.room_id = message.room_id
          AND historical_membership.user_id = \(bind: actorID)
          AND historical_membership.joined_revision <= (
              \(unsafeRaw: v2ForwardAcceptedMembershipRevision)
          )
          AND (historical_membership.left_revision IS NULL
               OR historical_membership.left_revision > (
                   \(unsafeRaw: v2ForwardAcceptedMembershipRevision)
               ))
    )
    AND (
        message.content_revision = 1
        OR EXISTS (
            SELECT 1
            FROM im_v2.room_events AS content_event
            JOIN im_v2.room_memberships AS content_membership
              ON content_membership.room_id = content_event.room_id
             AND content_membership.user_id = \(bind: actorID)
             AND content_membership.joined_revision <= content_event.committed_membership_revision
             AND (content_membership.left_revision IS NULL
                  OR content_membership.left_revision > content_event.committed_membership_revision)
            WHERE content_event.room_id = message.room_id
              AND content_event.event_type = 'message.edited'
              AND lower(content_event.payload->>'message_id') = message.message_id::text
              AND content_event.payload->>'message_revision' = message.content_revision::text
              AND lower(content_event.payload->>'room_id') = message.room_id::text
        )
    )
    """
}

private let v2ForwardAcceptedMembershipRevision = """
SELECT completion.accepted_membership_revision
FROM im_v2.message_send_completions AS completion
WHERE completion.room_id = message.room_id
  AND completion.sender_user_id = message.sender_user_id
  AND completion.client_message_id = message.client_message_id
  AND completion.message_id = message.message_id
  AND completion.room_sequence = message.room_sequence
  AND completion.room_sequence > 0
  AND completion.accepted_membership_revision >= 0
"""

/// Acquire the entire room set before destination admission or message locks.
/// Membership changes, edits, and withdrawals also start with their room lock.
/// Opposite forwards therefore serialize in UUID order, without holding a
/// destination room while waiting for the source room in reverse order.
/// A missing source is preserved as nil so an immutable completed send can
/// still replay; a fresh command will fail the final source check.
func v2LockForwardRooms(
    sourceMessageID: UUID,
    targetRoomID: UUID,
    sql: any SQLDatabase
) async throws -> UUID? {
    let source = try await sql.raw("""
        SELECT room_id FROM im_v2.messages WHERE message_id = \(bind: sourceMessageID)
        """).first(decoding: ForwardRoomIDRow.self)
    let sourceRoomID = source?.roomID
    _ = try await sql.raw("""
        SELECT room_id FROM im_v2.rooms
        WHERE room_id = \(bind: targetRoomID) OR room_id = \(bind: sourceRoomID)
        ORDER BY room_id FOR UPDATE
        """).all(decoding: ForwardRoomIDRow.self)
    return sourceRoomID
}

private struct ForwardRoomIDRow: Decodable {
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case roomID = "room_id" }
}
