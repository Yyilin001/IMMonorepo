import Foundation
import SQLKit

/// A committed message creates durable dispatch work even when no device is
/// connected. Recipient enumeration and external push run outside the room
/// transaction; this record freezes the audience revision and mention policy.
func v2EnqueueMessageDispatch(
    eventID: UUID, messageID: UUID, roomID: UUID, roomSequence: Int64,
    membershipRevision: Int64, senderID: UUID, mentionedUserIDs: [UUID],
    mentionsEveryone: Bool, createdAt: Date, sql: any SQLDatabase
) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.room_dispatch_outbox
            (source_event_id, message_id, room_id, room_sequence, membership_revision,
             sender_user_id, mentioned_user_ids, mentions_everyone, created_at, next_attempt_at)
        VALUES (\(bind: eventID), \(bind: messageID), \(bind: roomID), \(bind: roomSequence),
                \(bind: membershipRevision), \(bind: senderID), \(bind: mentionedUserIDs)::uuid[],
                \(bind: mentionsEveryone), \(bind: createdAt), \(bind: createdAt))
        """).run()
}
