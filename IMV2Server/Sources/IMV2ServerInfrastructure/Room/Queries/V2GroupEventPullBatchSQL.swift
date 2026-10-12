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

struct V2GroupEventPullMetadata: Decodable, Sendable {
    let ordinal: Int
    let roomKind: String?
    let active: Bool, complete: Bool
    let eventCount: Int64, payloadBytes: Int64
    let scannedThrough: Int64?, trimmedThrough: Int64?, hasMore: Bool?
    enum CodingKeys: String, CodingKey {
        case ordinal, roomKind = "room_kind", active, complete
        case eventCount = "event_count", payloadBytes = "payload_bytes"
        case scannedThrough = "scanned_through", trimmedThrough = "trimmed_through", hasMore = "has_more"
    }
    func validate() throws {
        guard roomKind == "group" || roomKind == "direct" else { throw V2GroupEventLogError.roomNotFound }
        guard active else { throw V2GroupEventLogError.actorNotMember }
        guard complete, eventCount >= 0, eventCount <= Int64(V2ActorRoomLogPullWire.maximumPageSize),
              payloadBytes >= 0, let scannedThrough, scannedThrough >= 0,
              let trimmedThrough, trimmedThrough >= 0, hasMore != nil else {
            throw V2GroupEventLogError.corruptPersistenceState
        }
    }
}


struct V2PackedRoomPull {
    let metadata: [Int: V2GroupEventPullMetadata]
    let failures: [Int: any Error]
    let selected: Set<Int>
    let rows: [Int: [GroupEventLogRow]]
    let byteHints: [Int: Int]
}

// Room/lease authority, historical visibility, bounds and hydration share ONE
// MVCC statement snapshot. Reads do not lock rows or serialize with a writer.
// Pages are materialized once in PostgreSQL; only whole selected pages cross
// the connection. No event IDs/payloads are carried into a later transaction.
func v2PackedGroupEventPulls(_ inputs: [V2GroupEventPullBatchInput],
    tokens: [RoomID: V2RoomActivationToken], maximumBytes: Int, sql: any SQLDatabase
) async throws -> V2PackedRoomPull {
    struct Input: Encodable {
        let ordinal: Int, room_id: UUID, viewer_id: UUID, cursor: Int64, page_size: Int
        let owner_shard: String, owner_epoch: Int64, activation_epoch: Int64
        let host_id: String, incarnation: UUID, header_bytes: Int
    }
    guard !inputs.isEmpty, inputs.count <= 100, maximumBytes > 0 else {
        throw V2GroupEventLogError.invalidRequest
    }
    let values = try inputs.map { input -> Input in
        guard let token = tokens[RoomID(uuid: input.roomID)] else { throw V2RoomActorStateError.activationChanged }
        let header = try V2ActorRoomLogPageWire(roomID: token.roomID, events: [],
            nextRoomSequence: UInt64(Int64.max), hasMore: true,
            logTrimmedThroughRoomSequence: UInt64(Int64.max)).protobufResponseByteCount()
        return Input(ordinal: input.ordinal, room_id: input.roomID, viewer_id: input.viewerID,
            cursor: input.cursor, page_size: input.pageSize, owner_shard: token.owner.shardID,
            owner_epoch: token.owner.epoch, activation_epoch: token.activationEpoch.rawValue,
            host_id: token.host.hostID.rawValue, incarnation: token.host.incarnationID,
            header_bytes: header + 64)
    }
    let payload = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    let page = v2GroupEventPullQuery(room: "valid.room_id", viewer: "valid.viewer_id", cursor: "valid.cursor",
        pageLimit: "valid.page_size", candidateLimit: "valid.page_size + 1")
    let rows = try await sql.raw("""
        /* imv2_room_pull_snapshot */
        WITH input AS MATERIALIZED (
            SELECT * FROM jsonb_to_recordset(\(bind: payload)::jsonb) AS input(
                ordinal integer,room_id uuid,viewer_id uuid,cursor bigint,page_size integer,
                owner_shard text,owner_epoch bigint,activation_epoch bigint,host_id text,
                incarnation uuid,header_bytes bigint)
        ), observed AS MATERIALIZED (SELECT clock_timestamp() AS observed_at),
        authority AS MATERIALIZED (
            SELECT input.*, CASE
                WHEN room.room_id IS NULL THEN 'room_not_found'
                WHEN room.room_shard_id IS DISTINCT FROM input.owner_shard
                  OR room.owner_epoch IS DISTINCT FROM input.owner_epoch THEN 'owner_changed'
            END AS failure
            FROM input CROSS JOIN observed LEFT JOIN im_v2.rooms room USING(room_id)
        ), valid AS MATERIALIZED (SELECT * FROM authority WHERE failure IS NULL),
        pages AS MATERIALIZED (
            SELECT valid.ordinal, page.* FROM valid CROSS JOIN LATERAL (\(page)) page
        ), facts AS MATERIALIZED (
            SELECT authority.ordinal,authority.failure,authority.header_bytes,
                max(pages.room_kind) AS room_kind,
                COALESCE(bool_or(pages.actor_is_active_member),false) AS active,
                COALESCE(bool_and(pages.payload_is_complete),true) AS complete,
                count(pages.event_id)::bigint AS event_count,
                COALESCE(sum(CASE WHEN pages.event_id IS NULL THEN 0 ELSE
                    octet_length(pages.payload_json)::bigint END),0)::bigint AS payload_bytes,
                max(pages.scanned_through_room_sequence) AS scanned_through,
                max(pages.trimmed_through_room_sequence) AS trimmed_through,
                bool_or(pages.has_more_candidates) AS has_more
            FROM authority LEFT JOIN pages USING(ordinal)
            GROUP BY authority.ordinal,authority.failure,authority.header_bytes
        ), bounded AS MATERIALIZED (
            SELECT facts.*, header_bytes + event_count * \(bind: V2PullSizeModel.recordOverhead)::bigint
                + payload_bytes AS byte_bound FROM facts
        ), packed AS MATERIALIZED (
            SELECT bounded.*, sum(byte_bound) OVER(ORDER BY ordinal) <= \(bind: maximumBytes)::bigint AS selected
            FROM bounded
        )
        SELECT packed.*, page.actor_is_active_member,page.scanned_through_room_sequence,
            page.has_more_candidates,page.trimmed_through_room_sequence,page.event_id,
            page.room_sequence,page.event_type,page.payload_json,page.payload_is_complete
        FROM packed LEFT JOIN pages page ON page.ordinal=packed.ordinal AND packed.selected
        ORDER BY packed.ordinal,page.room_sequence NULLS LAST
        """).all()
    let expectedOrdinals = Set(inputs.map(\.ordinal))
    var metadata: [Int: V2GroupEventPullMetadata] = [:], failures: [Int: any Error] = [:]
    var selected = Set<Int>(), hydrated: [Int: [GroupEventLogRow]] = [:], hints: [Int: Int] = [:]
    for row in rows {
        let ordinal = try row.decode(column: "ordinal", as: Int.self)
        guard expectedOrdinals.contains(ordinal) else { throw V2GroupEventLogError.corruptPersistenceState }
        if hints[ordinal] == nil {
            let included = try row.decode(column: "selected", as: Bool.self)
            if included { selected.insert(ordinal) }
            hints[ordinal] = try row.decode(column: "byte_bound", as: Int.self)
            if let failure = try row.decode(column: "failure", as: String?.self) {
                failures[ordinal] = switch failure {
                case "room_not_found": V2RoomActorStateError.roomNotFound
                case "owner_changed": V2RoomActorStateError.ownerChanged
                default: V2GroupEventLogError.corruptPersistenceState
                }
            } else { metadata[ordinal] = try row.decode(model: V2GroupEventPullMetadata.self) }
        }
        if selected.contains(ordinal), metadata[ordinal]?.roomKind != nil {
            hydrated[ordinal, default: []].append(try row.decode(model: GroupEventLogRow.self))
        }
    }
    guard hints.count == inputs.count else { throw V2GroupEventLogError.corruptPersistenceState }
    return .init(metadata: metadata, failures: failures, selected: selected, rows: hydrated, byteHints: hints)
}

private enum V2PullSizeModel {
    // Field tags, UUID, maximum sequence and longest SQL projection kind;
    // 22 accounts for payload length and repeated-entry length varints (10 each).
    // Payload bytes are bounded separately before returning any page rows.
    static let recordOverhead: Int = 38 + 11 + 18 + 22
}
