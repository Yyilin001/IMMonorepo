import Fluent
import Foundation
import IMV2Core
import SQLKit

public struct PostgresV2GroupEventLogStore: V2PreparedGroupEventLogStore {
    private let database: any Database
    private let directRoomLogEventCache: V2DirectRoomLogEventCache?

    public init(
        database: any Database,
        directRoomLogEventCache: V2DirectRoomLogEventCache? = nil
    ) {
        self.database = database
        self.directRoomLogEventCache = directRoomLogEventCache
    }

    public func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        guard let cursor = try? V2RoomCursor(afterRoomSequence),
              (1 ... V2GroupEventLogService.maximumPageSize).contains(pageSize)
        else { throw V2GroupEventLogError.invalidRequest }
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue)
        else { throw V2GroupEventLogError.corruptPersistenceState }

        // Inspect only local coverage before spending a database round trip on
        // the cache path. A candidate contains no identity and is never
        // returned without the same fresh durable membership fence as before.
        // A definite local miss therefore goes straight to the complete,
        // authorization-bearing query below instead of paying two SQL calls.
        if let directRoomLogEventCache,
           let candidate = await directRoomLogEventCache.candidate(
               roomID: roomID,
               afterRoomSequence: afterRoomSequence,
               pageSize: pageSize
           ) {
            if let access = try await authorizedRoomCacheAccess(
                roomID: roomUUID,
                actorUserID: actorUUID,
                sql: sql
            ) {
                if let cached = await directRoomLogEventCache.page(
                    candidate: candidate,
                    actorJoinedRevision: try groupEventUnsigned(access.actorJoinedRevision),
                    actorLeftRevision: try access.actorLeftRevision.map(groupEventUnsigned),
                    currentHighWatermark: try groupEventUnsigned(access.roomSequence)
                ) {
                    return cached
                }
            } else {
                await directRoomLogEventCache.recordMiss(roomID: roomID)
            }
        }

        let acceptedDelivery = v2MessageAcceptedDeliveryQuery(
            messageID: "CASE WHEN event.event_type IN ('message.edited', 'message.withdrawn', 'message.reaction_changed') THEN (event.payload->>'message_id')::uuid ELSE NULL END",
            roomID: "event.room_id"
        )
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
                  -- Keep the cursor predicate inside the indexed source.  It
                  -- is logically identical to the visibility fence below,
                  -- but prevents a recovery miss from materializing the
                  -- room's complete legacy-event history before filtering.
                  AND event.room_sequence > \(bind: cursor.signedValue)

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
                  -- `message_row` is constrained to use the same room and
                  -- timeline sequence.  Keep the cursor predicate on the
                  -- existing unique `(room_id, timeline_sequence)` index so
                  -- direct event pulls do not need a second write index.
                  AND message.timeline_sequence > \(bind: cursor.signedValue)
            ), visible_events AS MATERIALIZED (
                SELECT event.event_id, event.room_sequence, event.event_type,
                       event.payload, event.message_id, event.is_message_row,
                       (event.event_type NOT IN ('message.edited', 'message.withdrawn', 'message.reaction_changed')
                        OR accepted.message_id IS NOT NULL) AS authority_complete
                FROM room
                JOIN visible_event_candidates AS event ON TRUE
                LEFT JOIN LATERAL (\(acceptedDelivery)) AS accepted ON TRUE
                WHERE room.room_kind IN ('group', 'direct')
                  AND room.actor_is_active_member
                  AND event.room_sequence > \(bind: cursor.signedValue)
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS membership
                      WHERE membership.room_id = event.room_id
                        AND membership.user_id = \(bind: actorUUID)
                        AND membership.joined_revision <= event.committed_membership_revision
                        AND (membership.left_revision IS NULL OR membership.left_revision > event.committed_membership_revision)
                  )
                  AND (
                      event.event_type NOT IN ('message.edited', 'message.withdrawn', 'message.reaction_changed')
                      -- Keep unknown authority as an incomplete row: fail the
                      -- page instead of silently skipping its cursor range.
                      OR accepted.message_id IS NULL
                      OR EXISTS (
                          SELECT 1 FROM im_v2.room_memberships AS original_membership
                          WHERE original_membership.room_id = event.room_id
                            AND original_membership.user_id = \(bind: actorUUID)
                            AND original_membership.joined_revision <= accepted.accepted_membership_revision
                            AND (original_membership.left_revision IS NULL
                                 OR original_membership.left_revision > accepted.accepted_membership_revision)
                      )
                  )
                ORDER BY event.room_sequence
                LIMIT \(bind: pageSize + 1)
            )
            SELECT room.room_kind, room.actor_is_active_member,
                   room.room_sequence AS scanned_through_room_sequence,
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
                   (CASE
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
                   END) AND COALESCE(event.authority_complete, TRUE) AS payload_is_complete
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
            return try V2GroupEventLogEntry(
                sourceEventID: try EventID(eventID.uuidString),
                roomSequence: try groupEventUnsigned(roomSequence),
                projectionKind: groupEventProjectionKind(for: eventType),
                payload: payload
            )
        }
        // An exhausted snapshot has checked the complete tail, including
        // authorized sequence gaps. Never advertise that tail as consumed
        // while another visible (or incomplete-authority) row remains.
        let next = hasMore
            ? (entries.last?.roomSequence ?? afterRoomSequence)
            : max(afterRoomSequence, try groupEventUnsigned(room.scannedThroughRoomSequence))
        return try V2GroupEventLogPage(roomID: roomID, events: entries, nextRoomSequence: next, hasMore: hasMore)
    }

    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult {
        guard (try? V2RoomCursor(afterRoomSequence)) != nil,
              (1 ... V2GroupEventLogService.maximumPageSize).contains(pageSize)
        else { throw V2GroupEventLogError.invalidRequest }
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let actorUUID = UUID(uuidString: actorUserID.rawValue),
              let directRoomLogEventCache,
              await directRoomLogEventCache.hasPreparedPageCoverage(
                  roomID: roomID,
                  afterRoomSequence: afterRoomSequence,
                  pageSize: pageSize
              )
        else {
            return .page(try await pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ))
        }

        guard let access = try await authorizedRoomCacheAccess(
            roomID: roomUUID,
            actorUserID: actorUUID,
            sql: sql
        ) else {
            // Preserve the complete durable query's public missing-room and
            // membership error mapping. No prepared payload is reachable
            // without the fresh row above.
            return .page(try await pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ))
        }

        switch try await directRoomLogEventCache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: try groupEventUnsigned(access.actorJoinedRevision),
            actorLeftRevision: try access.actorLeftRevision.map(groupEventUnsigned),
            currentHighWatermark: try groupEventUnsigned(access.roomSequence),
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        ) {
        case .prepared(let response):
            return .prepared(response)
        case .eventTooLarge:
            return .eventTooLarge
        case .miss:
            // A cache eviction, gap, or membership-epoch mismatch after the
            // probe is a normal race. The durable query remains authoritative.
            return .page(try await pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ))
        }
    }

    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        guard let sql = database as? any SQLDatabase else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
        let room = try await authorizedRoom(roomID: roomID, actorUserID: actorUserID, sql: sql)
        return try .init(
            roomID: roomID,
            highWatermark: try groupEventUnsigned(room.roomSequence),
            membershipRevision: try groupEventUnsigned(room.membershipRevision)
        )
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
            SELECT room_sequence, membership_revision, room_kind,
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

    /// Supplies the minimal, current membership fence needed by the local
    /// room-event cache. Returning `nil` is intentionally indistinguishable
    /// from a cache miss; the durable pull retains the public error mapping
    /// for missing rooms and unauthorized actors.
    private func authorizedRoomCacheAccess(
        roomID: UUID,
        actorUserID: UUID,
        sql: any SQLDatabase
    ) async throws -> DirectRoomCacheAccessRow? {
        try await sql.raw("""
            SELECT room.room_sequence, membership.joined_revision,
                   membership.left_revision
            FROM im_v2.rooms AS room
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = \(bind: actorUserID)
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            WHERE room.room_id = \(bind: roomID)
              AND room.room_kind IN ('direct', 'group')
            """).first(decoding: DirectRoomCacheAccessRow.self)
    }
}

private struct GroupEventLogRoomRow: Decodable {
    let roomSequence: Int64
    let membershipRevision: Int64
    let roomKind: String
    let actorIsActiveMember: Bool
    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case membershipRevision = "membership_revision"
        case roomKind = "room_kind"
        case actorIsActiveMember = "actor_is_active_member"
    }
}

private struct DirectRoomCacheAccessRow: Decodable {
    let roomSequence: Int64
    let actorJoinedRevision: Int64
    let actorLeftRevision: Int64?

    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case actorJoinedRevision = "joined_revision"
        case actorLeftRevision = "left_revision"
    }
}

private struct GroupEventLogRow: Decodable {
    let scannedThroughRoomSequence: Int64
    let roomKind: String
    let actorIsActiveMember: Bool
    let eventID: UUID?
    let roomSequence: Int64?
    let eventType: String?
    let payloadJSON: String?
    let payloadIsComplete: Bool
    enum CodingKeys: String, CodingKey {
        case scannedThroughRoomSequence = "scanned_through_room_sequence"
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
