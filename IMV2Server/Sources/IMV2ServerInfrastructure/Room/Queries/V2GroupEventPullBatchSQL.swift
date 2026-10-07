import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
import SQLKit

// The scalar and collection paths share this complete authoritative page query.
// Arguments are typed SQL fragments (bound values or fixed input columns).
func v2GroupEventPullQuery(room: SQLQueryString, viewer: SQLQueryString,
    cursor: SQLQueryString, pageLimit: SQLQueryString, candidateLimit: SQLQueryString
) -> SQLQueryString {
        let acceptance = v2MessageAcceptanceFactQuery(
            messageID: "CASE WHEN event.event_type IN ('message.edited', 'message.withdrawn', 'message.reaction_changed') THEN (event.payload->>'message_id')::uuid ELSE NULL END",
            roomID: "event.room_id"
        )
    return """
            WITH room AS MATERIALIZED (
                SELECT rooms.room_sequence, rooms.room_kind,
                       rooms.log_trimmed_through_room_sequence,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_memberships AS membership
                           WHERE membership.room_id = rooms.room_id
                             AND membership.user_id = \(viewer)
                             AND membership.joined_revision <= rooms.membership_revision
                             AND (membership.left_revision IS NULL OR membership.left_revision > rooms.membership_revision)
                       ) AS actor_is_active_member
                FROM im_v2.rooms AS rooms
                WHERE rooms.room_id = \(room)
            ), event_candidates AS MATERIALIZED (
                SELECT event.event_id, event.room_id, event.room_sequence, event.event_type,
                       event.payload, event.committed_membership_revision,
                       NULL::uuid AS message_id, FALSE AS is_message_row
                FROM im_v2.room_events AS event
                WHERE event.room_id = \(room)
                  AND event.room_sequence > \(cursor)
                ORDER BY event.room_sequence
                LIMIT \(candidateLimit)
            ), message_candidates AS MATERIALIZED (
                SELECT message.accepted_event_id AS event_id, message.room_id, message.room_sequence,
                       'message.accepted' AS event_type, NULL::jsonb AS payload,
                       message.accepted_membership_revision AS committed_membership_revision,
                       message.message_id, TRUE AS is_message_row
                FROM im_v2.messages AS message
                WHERE message.room_id = \(room)
                  AND message.accepted_event_storage = 'message_row'
                  AND message.timeline_sequence > \(cursor)
                ORDER BY message.timeline_sequence
                LIMIT \(candidateLimit)
            ), candidates AS MATERIALIZED (
                SELECT * FROM event_candidates
                UNION ALL
                SELECT * FROM message_candidates
                ORDER BY room_sequence
                LIMIT \(candidateLimit)
            ), scan_window AS MATERIALIZED (
                -- The extra candidate proves there is more work; it is not
                -- authorized, hydrated or consumed by this page.
                SELECT * FROM candidates ORDER BY room_sequence LIMIT \(pageLimit)
            ), scan_progress AS MATERIALIZED (
                SELECT (SELECT count(*) FROM candidates) > \(pageLimit) AS has_more,
                       (SELECT max(room_sequence) FROM scan_window) AS scanned_through
            ), visible_events AS MATERIALIZED (
                SELECT event.event_id, event.room_sequence, event.event_type,
                       event.payload, event.message_id, event.is_message_row,
                       (event.event_type NOT IN ('message.edited', 'message.withdrawn', 'message.reaction_changed')
                        OR accepted.message_id IS NOT NULL) AS authority_complete
                FROM room
                JOIN scan_window AS event ON TRUE
                LEFT JOIN LATERAL (\(acceptance)) AS accepted ON TRUE
                WHERE room.room_kind IN ('group', 'direct')
                  AND room.actor_is_active_member
                  AND event.room_sequence > \(cursor)
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS membership
                      WHERE membership.room_id = event.room_id
                        AND membership.user_id = \(viewer)
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
                            AND original_membership.user_id = \(viewer)
                            AND original_membership.joined_revision <= accepted.accepted_membership_revision
                            AND (original_membership.left_revision IS NULL
                                 OR original_membership.left_revision > accepted.accepted_membership_revision)
                      )
                  )
                ORDER BY event.room_sequence
            )
            SELECT room.room_kind, room.actor_is_active_member,
                   CASE WHEN scan_progress.has_more THEN scan_progress.scanned_through
                        ELSE room.room_sequence END AS scanned_through_room_sequence,
                   scan_progress.has_more AS has_more_candidates,
                   room.log_trimmed_through_room_sequence AS trimmed_through_room_sequence,
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
            CROSS JOIN scan_progress
            LEFT JOIN visible_events AS event ON TRUE
            LEFT JOIN im_v2.messages AS message
              ON message.message_id = COALESCE(
                    event.message_id,
                    (event.payload->>'message_id')::uuid
                 )
             AND message.room_id = \(room)
             AND message.room_sequence = event.room_sequence
            LEFT JOIN im_v2.message_content_versions AS snapshot
              ON snapshot.message_id = message.message_id
             AND snapshot.message_revision = CASE
                 WHEN event.is_message_row THEN 1
                 ELSE (event.payload->>'message_revision')::bigint
             END
            ORDER BY event.room_sequence NULLS LAST
        """
}

struct V2GroupEventPullBatchInput: Encodable, Sendable {
    let ordinal: Int
    let roomID: UUID, viewerID: UUID
    let cursor: Int64, pageSize: Int
    init(ordinal: Int, query: V2ActorRoomLogPullWire) throws {
        guard let room = query.roomID.uuidValue, let viewer = query.actorUserID.uuidValue,
              (1...V2GroupEventLogService.maximumPageSize).contains(query.pageSize),
              query.afterRoomSequence <= UInt64(Int64.max) else { throw V2GroupEventLogError.invalidRequest }
        self.ordinal = ordinal; roomID = room; viewerID = viewer
        cursor = Int64(query.afterRoomSequence); pageSize = query.pageSize
    }
    enum CodingKeys: String, CodingKey {
        case ordinal, roomID = "room_id", viewerID = "viewer_id", cursor, pageSize = "page_size"
    }
}

struct V2GroupEventPullMetadata: Codable, Sendable {
    let ordinal: Int
    let roomKind: String?
    let active: Bool, complete: Bool
    let eventCount: Int64, escapedPayloadBound: Int64
    let scannedThrough: Int64?, trimmedThrough: Int64?, hasMore: Bool?
    enum CodingKeys: String, CodingKey {
        case ordinal, roomKind = "room_kind", active, complete
        case eventCount = "event_count", escapedPayloadBound = "escaped_payload_bound"
        case scannedThrough = "scanned_through", trimmedThrough = "trimmed_through", hasMore = "has_more"
    }
    func validate() throws {
        guard roomKind == "group" || roomKind == "direct" else { throw V2GroupEventLogError.roomNotFound }
        guard active else { throw V2GroupEventLogError.actorNotMember }
        guard complete, eventCount >= 0, eventCount <= Int64(V2ActorRoomLogPullWire.maximumPageSize),
              escapedPayloadBound >= 0, let scannedThrough, scannedThrough >= 0,
              let trimmedThrough, trimmedThrough >= 0, hasMore != nil else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
    }
}

// Bounded scalar metadata per request; no candidate IDs/payload strings cross
// the connection before whole-page packing. Both phases use the same query.
func v2GroupEventPullMetadata(_ inputs: [V2GroupEventPullBatchInput], sql: any SQLDatabase)
    async throws -> [Int: V2GroupEventPullMetadata] {
    guard !inputs.isEmpty, inputs.count <= 100 else { throw V2GroupEventLogError.invalidRequest }
    // Every result contains only these fixed scalar fields. Prove the bounded
    // metadata decode independently of any event/payload count.
    let maximumRow = V2GroupEventPullMetadata(ordinal: Int.max, roomKind: "direct", active: false,
        complete: false, eventCount: Int64.max, escapedPayloadBound: Int64.max,
        scannedThrough: Int64.max, trimmedThrough: Int64.max, hasMore: false)
    guard try JSONEncoder().encode(Array(repeating: maximumRow, count: inputs.count)).count <= 64 * 1024 else {
        throw V2GroupEventLogError.corruptPersistenceState
    }
    let payload = String(decoding: try JSONEncoder().encode(inputs), as: UTF8.self)
    let page = v2GroupEventPullQuery(room: "input.room_id", viewer: "input.viewer_id", cursor: "input.cursor",
        pageLimit: "input.page_size", candidateLimit: "input.page_size + 1")
    let rows = try await sql.raw("""
        WITH input AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(\(bind: payload)::jsonb)
                AS input(ordinal integer,room_id uuid,viewer_id uuid,cursor bigint,page_size integer)
        )
        SELECT input.ordinal, facts.* FROM input
        CROSS JOIN LATERAL (
            SELECT CASE WHEN max(page.room_kind) IN ('group','direct') THEN max(page.room_kind) END AS room_kind,
                   COALESCE(bool_or(page.actor_is_active_member),false) AS active,
                   COALESCE(bool_and(page.payload_is_complete),true) AS complete,
                   count(page.event_id)::bigint AS event_count,
                   COALESCE(sum(CASE WHEN page.event_id IS NULL THEN 0 ELSE
                       8 * ((octet_length(page.payload_json)::bigint + 2) / 3) END),0)::bigint AS escaped_payload_bound,
                   max(page.scanned_through_room_sequence) AS scanned_through,
                   max(page.trimmed_through_room_sequence) AS trimmed_through,
                   bool_or(page.has_more_candidates) AS has_more
            FROM (\(page)) AS page
        ) AS facts ORDER BY input.ordinal
        """).all(decoding: V2GroupEventPullMetadata.self)
    guard rows.count == inputs.count, Set(rows.map(\.ordinal)) == Set(inputs.map(\.ordinal)) else {
        throw V2GroupEventLogError.corruptPersistenceState
    }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.ordinal, $0) })
}

func v2HydrateGroupEventPulls(_ inputs: [V2GroupEventPullBatchInput], sql: any SQLDatabase)
    async throws -> [Int: [GroupEventLogRow]] {
    guard !inputs.isEmpty, inputs.count <= 100 else { throw V2GroupEventLogError.invalidRequest }
    let payload = String(decoding: try JSONEncoder().encode(inputs), as: UTF8.self)
    let page = v2GroupEventPullQuery(room: "input.room_id", viewer: "input.viewer_id", cursor: "input.cursor",
        pageLimit: "input.page_size", candidateLimit: "input.page_size + 1")
    let rows = try await sql.raw("""
        WITH input AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(\(bind: payload)::jsonb)
                AS input(ordinal integer,room_id uuid,viewer_id uuid,cursor bigint,page_size integer)
        )
        SELECT input.ordinal, page.* FROM input
        CROSS JOIN LATERAL (\(page)) AS page
        ORDER BY input.ordinal,page.room_sequence NULLS LAST
        """).all()
    var results: [Int: [GroupEventLogRow]] = [:]
    let expected = Set(inputs.map(\.ordinal))
    for row in rows {
        let ordinal = try row.decode(column: "ordinal", as: Int.self)
        guard expected.contains(ordinal) else { throw V2GroupEventLogError.corruptPersistenceState }
        results[ordinal, default: []].append(try row.decode(model: GroupEventLogRow.self))
    }
    return results
}

struct V2PullBudgetReply: Encodable {
    let id: UUID
    let outcome: Outcome
    enum Outcome: Encodable { case response(V2RoomResponse), failure(V2RoomCallFailure) }
}

// Data is base64-encoded, whose only possibly escaped character is '/'.
// SQL reports 2 * 4 * ceil(payloadUTF8Bytes/3), not raw UTF8 as wire size.
func v2PullReplyUpperBound(id: UUID, query: V2ActorRoomLogPullWire,
    metadata: V2GroupEventPullMetadata
) throws -> Int {
    try metadata.validate()
    let emptyPage = try V2ActorRoomLogPageWire(roomID: query.roomID, events: [],
        nextRoomSequence: max(query.afterRoomSequence, UInt64(metadata.scannedThrough!)),
        hasMore: metadata.hasMore!, logTrimmedThroughRoomSequence: UInt64(metadata.trimmedThrough!))
    let header = try JSONEncoder().encode(V2PullBudgetReply(id: id,
        outcome: .response(.roomLog(.page(emptyPage))))).count
    let recordSize = try V2PullSizeModel.recordSize.get()
    guard metadata.escapedPayloadBound <= Int64(Int.max) else { throw V2GroupEventLogError.corruptPersistenceState }
    let entries = Int(metadata.eventCount).multipliedReportingOverflow(by: recordSize)
    let body = entries.partialValue.addingReportingOverflow(Int(metadata.escapedPayloadBound))
    let commas = body.partialValue.addingReportingOverflow(max(0, Int(metadata.eventCount) - 1))
    let total = commas.partialValue.addingReportingOverflow(header)
    guard !entries.overflow, !body.overflow, !commas.overflow, !total.overflow else {
        throw V2GroupEventLogError.corruptPersistenceState
    }
    return total.partialValue
}

private enum V2PullSizeModel {
    static let recordSize: Result<Int, any Error> = Result {
        let kinds = ["room", "membership", "moderation", "message_reaction", "group_capability", "message"]
        let id = EventID(uuid: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        return try kinds.map {
            try JSONEncoder().encode(V2ActorRoomLogEntryWire(sourceEventID: id,
                roomSequence: UInt64(Int64.max), projectionKind: $0, payload: Data())).count
        }.max()!
    }
}

func v2PullWireFailure(_ error: any Error) -> V2RoomCallFailure {
    let completion: V2RoomTransactionCompletion<Void> = v2RoomDomainCompletion(error)
    if case .rolledBack(let reason) = completion { return .rolledBack(reason) }
    return .outcomeUnknown
}
