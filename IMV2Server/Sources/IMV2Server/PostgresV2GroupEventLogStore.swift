import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2GroupEventLogStore: V2GroupEventLogStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue),
              afterRoomSequence <= UInt64(Int64.max)
        else { throw V2GroupEventLogError.corruptPersistenceState }

        let rows = try await sql.raw("""
            WITH room AS MATERIALIZED (
                SELECT rooms.room_sequence, rooms.room_kind,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_memberships AS membership
                           WHERE membership.room_id = rooms.room_id
                             AND membership.user_id = \(bind: actorUUID)
                             AND membership.joined_revision <= rooms.membership_revision
                             AND (membership.left_revision IS NULL OR membership.left_revision > rooms.membership_revision)
                       ) AS actor_is_active_member
                FROM im_v2.rooms AS rooms
                WHERE rooms.room_id = \(bind: roomUUID)
            ), visible_event_candidates AS MATERIALIZED (
                -- Legacy/group events retain their immutable event row.
                SELECT event.event_id, event.room_id, event.room_sequence, event.event_type,
                       event.payload, event.committed_membership_revision,
                       NULL::uuid AS message_id, FALSE AS is_message_row
                FROM im_v2.room_events AS event
                WHERE event.room_id = \(bind: roomUUID)

                UNION ALL

                -- Plain direct room-log messages materialize their accepted
                -- event in the messages row itself. They retain an explicit
                -- event ID and membership revision, so cursor and visibility
                -- semantics are identical to the legacy room-event form.
                SELECT message.accepted_event_id, message.room_id, message.room_sequence,
                       'message.accepted', NULL::jsonb,
                       message.accepted_membership_revision,
                       message.message_id, TRUE
                FROM im_v2.messages AS message
                WHERE message.room_id = \(bind: roomUUID)
                  AND message.accepted_event_storage = 'message_row'
            ), visible_events AS MATERIALIZED (
                SELECT event.event_id, event.room_sequence, event.event_type,
                       event.payload, event.message_id, event.is_message_row
                FROM room
                JOIN visible_event_candidates AS event ON TRUE
                WHERE room.room_kind IN ('group', 'direct')
                  AND room.actor_is_active_member
                  AND event.room_sequence > \(bind: Int64(afterRoomSequence))
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS membership
                      WHERE membership.room_id = event.room_id
                        AND membership.user_id = \(bind: actorUUID)
                        AND membership.joined_revision <= event.committed_membership_revision
                        AND (membership.left_revision IS NULL OR membership.left_revision > event.committed_membership_revision)
                  )
                ORDER BY event.room_sequence
                LIMIT \(bind: pageSize + 1)
            )
            SELECT room.room_kind, room.actor_is_active_member,
                   event.event_id, event.room_sequence, event.event_type,
                   CASE
                       WHEN event.is_message_row
                       THEN jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', message.message_id::text,
                           'room_id', message.room_id::text,
                           'room_sequence', event.room_sequence,
                           'timeline_sequence', message.timeline_sequence,
                           'sender_user_id', message.sender_user_id::text,
                           'text', COALESCE(snapshot.text_body, message.text_body),
                           'media_ids', '[]'::jsonb,
                           'media_presentations', '[]'::jsonb,
                           'mention_user_ids', '[]'::jsonb,
                           'mentions_everyone', FALSE,
                           'entities', COALESCE(snapshot.rich_entities, message.rich_entities),
                           'reply_to_message_id', message.reply_to_message_id::text,
                           'forwarded_from_message_id', message.forwarded_from_message_id::text,
                           'forwarded_from_user_id', message.forwarded_from_user_id::text,
                           'message_revision', 1,
                           'server_created_at_ms',
                               floor(extract(epoch FROM message.created_at) * 1000)::bigint
                       )
                       WHEN event.event_type = 'message.accepted'
                        AND event.payload->>'payload_storage' = 'message_reference_v1'
                       THEN jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', message.message_id::text,
                           'room_id', message.room_id::text,
                           'room_sequence', event.room_sequence,
                           'timeline_sequence', message.timeline_sequence,
                           'sender_user_id', message.sender_user_id::text,
                           'text', COALESCE(snapshot.text_body, message.text_body),
                           'media_ids', '[]'::jsonb,
                           'media_presentations', '[]'::jsonb,
                           'mention_user_ids', '[]'::jsonb,
                           'mentions_everyone', FALSE,
                           'entities', COALESCE(snapshot.rich_entities, message.rich_entities),
                           'reply_to_message_id', message.reply_to_message_id::text,
                           'forwarded_from_message_id', message.forwarded_from_message_id::text,
                           'forwarded_from_user_id', message.forwarded_from_user_id::text,
                           'message_revision', (event.payload->>'message_revision')::bigint,
                           'server_created_at_ms',
                               (event.payload->>'server_created_at_ms')::bigint
                       )
                       ELSE event.payload
                   END::text AS payload_json,
                   CASE
                       WHEN event.is_message_row
                       THEN message.message_id IS NOT NULL
                            AND (snapshot.message_id IS NOT NULL
                                 OR message.content_revision = 1)
                       WHEN event.event_type = 'message.accepted'
                        AND event.payload->>'payload_storage' = 'message_reference_v1'
                       THEN message.message_id IS NOT NULL
                            AND (
                                snapshot.message_id IS NOT NULL
                                OR message.content_revision = (event.payload->>'message_revision')::bigint
                            )
                       ELSE TRUE
                   END AS payload_is_complete
            FROM room
            LEFT JOIN visible_events AS event ON TRUE
            LEFT JOIN im_v2.messages AS message
              ON message.message_id = COALESCE(
                    event.message_id,
                    (event.payload->>'message_id')::uuid
                 )
             AND message.room_id = \(bind: roomUUID)
             AND message.room_sequence = event.room_sequence
            LEFT JOIN im_v2.message_content_versions AS snapshot
              ON snapshot.message_id = message.message_id
             AND snapshot.message_revision = CASE
                 WHEN event.is_message_row THEN 1
                 ELSE (event.payload->>'message_revision')::bigint
             END
            ORDER BY event.room_sequence NULLS LAST
            """).all(decoding: GroupEventLogRow.self)
        guard let room = rows.first else { throw V2GroupEventLogError.roomNotFound }
        guard room.roomKind == "group" || room.roomKind == "direct" else {
            throw V2GroupEventLogError.roomNotFound
        }
        guard room.actorIsActiveMember else { throw V2GroupEventLogError.actorNotMember }

        let eventRows = rows.compactMap { $0.eventID == nil ? nil : $0 }
        let hasMore = eventRows.count > pageSize
        let pageRows = hasMore ? Array(eventRows.prefix(pageSize)) : eventRows
        let entries: [V2GroupEventLogEntry] = try pageRows.map { row in
            guard let eventID = row.eventID,
                  let roomSequence = row.roomSequence,
                  let eventType = row.eventType,
                  let payloadJSON = row.payloadJSON,
                  row.payloadIsComplete,
                  let payload = payloadJSON.data(using: .utf8)
            else { throw V2GroupEventLogError.corruptPersistenceState }
            return V2GroupEventLogEntry(
                sourceEventID: try EventID(eventID.uuidString),
                roomSequence: try groupEventUnsigned(roomSequence),
                projectionKind: groupEventProjectionKind(for: eventType),
                payload: payload
            )
        }
        let next = entries.last?.roomSequence ?? afterRoomSequence
        return V2GroupEventLogPage(roomID: roomID, events: entries, nextRoomSequence: next, hasMore: hasMore)
    }

    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        guard let sql = database as? any SQLDatabase else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
        let room = try await authorizedRoom(roomID: roomID, actorUserID: actorUserID, sql: sql)
        return .init(roomID: roomID, highWatermark: try groupEventUnsigned(room.roomSequence))
    }

    /// Group rooms and direct rooms use the same cursor protocol. A direct
    /// room is admitted here only after its pair/membership policy has
    /// accepted the write; every pull still checks the revision fence below,
    /// so a stale wake can never reveal pre-join or post-leave payloads.
    /// Standard groups remain preview-only: their delivery stream is still
    /// authoritative unless the room is explicitly configured for its hybrid
    /// event-log mode.
    private func authorizedRoom(
        roomID: RoomID,
        actorUserID: UserID,
        sql: any SQLDatabase
    ) async throws -> GroupEventLogRoomRow {
        guard let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue)
        else { throw V2GroupEventLogError.corruptPersistenceState }
        guard let room = try await sql.raw("""
            SELECT room_sequence, room_kind,
                   EXISTS (
                       SELECT 1 FROM im_v2.room_memberships AS membership
                       WHERE membership.room_id = rooms.room_id
                         AND membership.user_id = \(bind: actorUUID)
                         AND membership.joined_revision <= rooms.membership_revision
                         AND (membership.left_revision IS NULL OR membership.left_revision > rooms.membership_revision)
                   ) AS actor_is_active_member
            FROM im_v2.rooms AS rooms
            WHERE rooms.room_id = \(bind: roomUUID)
            """).first(decoding: GroupEventLogRoomRow.self)
        else { throw V2GroupEventLogError.roomNotFound }
        guard room.roomKind == "group" || room.roomKind == "direct" else {
            throw V2GroupEventLogError.roomNotFound
        }
        guard room.actorIsActiveMember else { throw V2GroupEventLogError.actorNotMember }
        return room
    }
}

private struct GroupEventLogRoomRow: Decodable {
    let roomSequence: Int64
    let roomKind: String
    let actorIsActiveMember: Bool
    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case roomKind = "room_kind"
        case actorIsActiveMember = "actor_is_active_member"
    }
}

private struct GroupEventLogRow: Decodable {
    let roomKind: String
    let actorIsActiveMember: Bool
    let eventID: UUID?
    let roomSequence: Int64?
    let eventType: String?
    let payloadJSON: String?
    let payloadIsComplete: Bool
    enum CodingKeys: String, CodingKey {
        case roomKind = "room_kind"
        case actorIsActiveMember = "actor_is_active_member"
        case eventID = "event_id"
        case roomSequence = "room_sequence"
        case eventType = "event_type"
        case payloadJSON = "payload_json"
        case payloadIsComplete = "payload_is_complete"
    }
}

private func groupEventUnsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2GroupEventLogError.corruptPersistenceState }
    return UInt64(value)
}

private func groupEventProjectionKind(for eventType: String) -> String {
    switch eventType {
    case "room.created": "room"
    case "membership_changed": "membership"
    case "member.muted", "room.frozen", "room.unfrozen": "moderation"
    case "message.reaction_changed": "message_reaction"
    case "message.pinned_changed", "group.announcement_changed", "group.role_permissions_changed", "group.member_role_changed": "group_capability"
    default: "message"
    }
}
