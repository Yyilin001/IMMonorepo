import Foundation
import IMV2Core
import SQLKit

// Both forms write on the transaction already selected and fenced by the Store.
extension PostgresV2RoomWriteStore {
    /// 追加单聊接受后的投影。
    ///
    /// 只有在其首条消息于同一个事务中通过拉黑、陌生人偏好与配额检查之后，
    /// 才会把一个尚未开启的单聊配对展示给接收者。
    /// 资料投影排在该接收者同步流中异步消息扇出之前，
    /// 因此被投递的首条消息总有一个稳定的会话身份。
    ///
    /// 配对本地的生产者标记由 `directMessageContext` 加锁，
    /// 因此它们对「投影是否发生变化」始终给出精确且与压缩无关的答案。
    /// 已建立的会话无需再走一次 PostgreSQL 往返即可返回；
    /// 发生状态迁移时会分配其序号，并与消息事务原子地推进这些标记。
    ///
    /// 有序单聊微批已经锁定了每个配对与策略行。
    /// 因此在单条 SQL 语句中分配全部首消息投影，
    /// 而不是为每个独立房间重复执行单消息 CTE。
    /// 一个发送者可能在同一批次中出现在多个房间里，
    /// 因此这里刻意把该用户的同步序号区间只预留一次，并按既有的有序批次顺序分配其条目。
    ///
    /// - Parameter appends: 已准备的单聊房间日志追加。
    /// - Throws: 持久化状态损坏或写入失败时抛出。
    func appendDirectPostAcceptanceProjections(
        for appends: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws -> [DirectPostAcceptanceProjectionChanges] {
        guard !appends.isEmpty else { return [] }
        // The authoritative preflight has already locked every direct-pair
        // row and read the current visibility/capability facts. Once both
        // pair-local producer markers are established, another plain message
        // cannot produce a profile or capability outbox event. Avoid sending
        // the otherwise-empty set CTE to PostgreSQL for that steady state:
        // under load it was one complete SQL statement per append batch even
        // though `needed`, `projection_events`, and `pair_update` were empty.
        //
        // This is deliberately a batch-wide short circuit. If even one room
        // still needs a first-message projection, the existing CTE runs for
        // the complete batch so outbox insertion and pair marker updates
        // remain one atomic transaction. The user owner allocates sequences.
        guard appends.contains(where: {
            !$0.directContext.senderProfileVisibleToRecipient
                || $0.directContext.senderCanSend != true
        }) else {
            return Array(
                repeating: .init(
                    senderCapabilityInserted: false,
                    recipientProfileInserted: false
                ),
                count: appends.count
            )
        }
        let inputs = try appends.enumerated().map { ordinal, append in
            DirectPostAcceptanceProjectionInput(
                ordinal: ordinal,
                roomID: append.roomID,
                senderID: append.senderID,
                recipientID: append.directContext.recipientID,
                senderProfileVisibleToRecipient: append.directContext.senderProfileVisibleToRecipient,
                senderCanSend: append.directContext.senderCanSend,
                sourceEventID: append.input.eventID,
                createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(append.now),
                createdAtMilliseconds: try v2GatewayMilliseconds(roomWritePersistedDate(append.now)),
                stateVersion: append.input.timelineSequence
            )
        }
        let inputJSON = try roomWriteJSON(inputs)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.recipient_id,
                       input.sender_profile_visible_to_recipient,
                       input.sender_can_send, input.source_event_id,
                       input.created_at_postgres_microseconds, input.created_at_ms, input.state_version,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    recipient_id uuid,
                    sender_profile_visible_to_recipient boolean,
                    sender_can_send boolean,
                    source_event_id uuid,
                    created_at_postgres_microseconds bigint,
                    created_at_ms bigint,
                    state_version bigint
                )
            ), needed AS MATERIALIZED (
                SELECT *
                FROM input
                WHERE NOT sender_profile_visible_to_recipient
                   OR sender_can_send IS DISTINCT FROM TRUE
            ), profile AS MATERIALIZED (
                SELECT needed.ordinal, profile.public_handle,
                       profile.display_name, profile.account_kind,
                       profile.revision, profile.updated_at
                FROM needed
                JOIN im_v2.public_user_profiles AS profile
                  ON profile.user_id = needed.sender_id
                 AND profile.state = 'active'
                 AND profile.revision > 0
            ), projection_events AS MATERIALIZED (
                SELECT needed.ordinal, needed.room_id, needed.sender_id,
                       needed.recipient_id, needed.source_event_id,
                       needed.created_at, needed.sender_id AS user_id,
                       'direct_sending_capability'::text AS projection_kind,
                       0 AS event_order,
                       jsonb_build_object(
                           'room_id', upper(needed.room_id::text),
                           'can_send', TRUE,
                           'state_version', needed.state_version,
                           'updated_at_ms',
                               needed.created_at_ms
                       ) AS payload
                FROM needed
                WHERE needed.sender_can_send IS DISTINCT FROM TRUE

                UNION ALL

                SELECT needed.ordinal, needed.room_id, needed.sender_id,
                       needed.recipient_id, needed.source_event_id,
                       needed.created_at, needed.recipient_id,
                       'direct_room_profile', 1,
                       jsonb_build_object(
                           'room_id', upper(needed.room_id::text),
                           'target_user_id', upper(needed.sender_id::text),
                           'room_created_at_ms', (SELECT floor(extract(epoch FROM created_at) * 1000)::bigint FROM im_v2.rooms WHERE room_id = needed.room_id),
                           'public_handle', profile.public_handle,
                           'display_name', profile.display_name,
                           'account_kind', profile.account_kind,
                           'revision', profile.revision,
                           'updated_at_ms',
                               \(directProfileUpdatedAtMillisecondsSQL)
                       )
                FROM needed
                JOIN profile USING (ordinal)
                WHERE NOT needed.sender_profile_visible_to_recipient
            ), log_insert AS (
                INSERT INTO im_v2.user_state_event_outbox
                    (user_id, source_event_id, projection_kind, payload,
                     created_at, next_attempt_at, source_room_id)
                SELECT event.user_id, event.source_event_id, event.projection_kind,
                       event.payload, event.created_at, event.created_at, (event.payload->>'room_id')::uuid
                FROM projection_events AS event
                ORDER BY event.user_id, event.ordinal, event.event_order
                RETURNING user_id, source_event_id, projection_kind
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_profile_visible_to_higher = CASE
                        WHEN pair.lower_user_id = needed.sender_id THEN TRUE
                        ELSE pair.lower_profile_visible_to_higher
                    END,
                    higher_profile_visible_to_lower = CASE
                        WHEN pair.higher_user_id = needed.sender_id THEN TRUE
                        ELSE pair.higher_profile_visible_to_lower
                    END,
                    lower_can_send = CASE
                        WHEN pair.lower_user_id = needed.sender_id THEN TRUE
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = needed.sender_id THEN TRUE
                        ELSE pair.higher_can_send
                    END
                FROM needed
                WHERE pair.room_id = needed.room_id
                  AND (SELECT count(*) FROM profile) = (SELECT count(*) FROM needed)
                  AND (SELECT count(*) FROM log_insert) = (SELECT count(*) FROM projection_events)
                RETURNING needed.ordinal
            )
            SELECT input.ordinal,
                   EXISTS (
                       SELECT 1 FROM projection_events AS event
                       WHERE event.ordinal = input.ordinal
                         AND event.projection_kind = 'direct_sending_capability'
                   ) AS sender_capability_inserted,
                   EXISTS (
                       SELECT 1 FROM projection_events AS event
                       WHERE event.ordinal = input.ordinal
                         AND event.projection_kind = 'direct_room_profile'
                   ) AS recipient_profile_inserted,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM needed
                       WHERE needed.ordinal = input.ordinal
                   ) THEN EXISTS (
                       SELECT 1 FROM profile
                       WHERE profile.ordinal = input.ordinal
                   ) ELSE TRUE END AS profile_exists,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM needed
                       WHERE needed.ordinal = input.ordinal
                   ) THEN EXISTS (
                       SELECT 1 FROM pair_update
                       WHERE pair_update.ordinal = input.ordinal
                   ) ELSE TRUE END AS pair_updated,
                   (SELECT count(*)::bigint FROM projection_events) AS expected_event_count,
                   (SELECT count(*)::bigint FROM log_insert) AS inserted_event_count
            FROM input
            ORDER BY input.ordinal
            """).all(decoding: DirectPostAcceptanceProjectionBatchRow.self)
        guard rows.count == appends.count,
              rows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }),
              rows.allSatisfy(\.profileExists),
              rows.allSatisfy(\.pairUpdated),
              let first = rows.first,
              rows.allSatisfy({
                  $0.expectedEventCount == first.expectedEventCount
                      && $0.insertedEventCount == first.insertedEventCount
              }),
              first.expectedEventCount == first.insertedEventCount
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return rows.map {
            .init(
                senderCapabilityInserted: $0.senderCapabilityInserted,
                recipientProfileInserted: $0.recipientProfileInserted
            )
        }
    }

    func appendDirectPostAcceptanceProjections(
        roomID: UUID,
        senderID: UUID,
        recipientID: UUID,
        senderProfileVisibleToRecipient: Bool,
        senderCanSend: Bool?,
        sourceEventID: UUID,
        createdAt: Date,
        stateVersion: UInt64,
        sql: any SQLDatabase
    ) async throws -> DirectPostAcceptanceProjectionChanges {
        guard !senderProfileVisibleToRecipient || senderCanSend != true else {
            return .init(senderCapabilityInserted: false, recipientProfileInserted: false)
        }
        guard let mutation = try await sql.raw("""
            WITH profile AS MATERIALIZED (
                SELECT public_handle, display_name, account_kind, revision, updated_at
                FROM im_v2.public_user_profiles
                WHERE user_id = \(bind: senderID)
                  AND state = 'active'
                  AND revision > 0
            ), needed AS MATERIALIZED (
                SELECT \(bind: senderID)::uuid AS user_id,
                       'direct_sending_capability'::text AS projection_kind,
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'can_send', TRUE,
                           'state_version', \(bind: try directProjectionSigned(stateVersion)),
                           'updated_at_ms', \(bind: try v2GatewayMilliseconds(roomWritePersistedDate(createdAt)))
                       ) AS payload
                WHERE \(bind: senderCanSend != true)
                UNION ALL
                SELECT \(bind: recipientID), 'direct_room_profile',
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'target_user_id', \(bind: senderID.uuidString),
                           'room_created_at_ms', (SELECT floor(extract(epoch FROM created_at) * 1000)::bigint FROM im_v2.rooms WHERE room_id = \(bind: roomID)),
                           'public_handle', profile.public_handle,
                           'display_name', profile.display_name,
                           'account_kind', profile.account_kind,
                           'revision', profile.revision,
                           'updated_at_ms', \(directProfileUpdatedAtMillisecondsSQL)
                       )
                FROM profile
                WHERE \(bind: !senderProfileVisibleToRecipient)
            ), log_insert AS (
                INSERT INTO im_v2.user_state_event_outbox
                    (user_id, source_event_id, projection_kind, payload,
                     created_at, next_attempt_at, source_room_id)
                SELECT needed.user_id, \(bind: sourceEventID),
                       needed.projection_kind, needed.payload,
                       \(bind: createdAt), \(bind: createdAt), \(bind: roomID)
                FROM needed
                ORDER BY needed.user_id
                RETURNING user_id, projection_kind
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_profile_visible_to_higher = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_profile_visible_to_higher
                    END,
                    higher_profile_visible_to_lower = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_profile_visible_to_lower
                    END,
                    lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND (SELECT count(*) FROM log_insert) = (SELECT count(*) FROM needed)
                RETURNING pair.room_id
            )
            SELECT EXISTS (SELECT 1 FROM profile) AS profile_exists,
                   (SELECT count(*) FROM needed) AS needed_count,
                   (SELECT count(*) FROM log_insert WHERE projection_kind = 'direct_room_profile') AS profile_inserted_count,
                   (SELECT count(*) FROM log_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectRoomProfileMutationRow.self),
              mutation.profileExists,
              mutation.insertedCount == mutation.neededCount,
              mutation.pairCount == 1,
              (0...2).contains(mutation.neededCount),
              (0...1).contains(mutation.profileInsertedCount),
              mutation.profileInsertedCount <= mutation.insertedCount,
              (0...1).contains(mutation.insertedCount - mutation.profileInsertedCount)
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return .init(
            senderCapabilityInserted: mutation.insertedCount - mutation.profileInsertedCount == 1,
            recipientProfileInserted: mutation.profileInsertedCount == 1
        )
    }
}

// Match postgres-nio Date decoding and Foundation's reference-date arithmetic before
// truncating to wire milliseconds. Numeric-to-bigint rounds; truncating the native
// epoch alone can also disagree with decoded Date near PostgreSQL's upper bound.
private let directProfileUpdatedAtMillisecondsSQL: SQLQueryString = """
    trunc((
        ((extract(epoch FROM profile.updated_at) - 946684800) * 1000000)::double precision
        / 1000000 - 31622400 + 978307200
    ) * 1000)::bigint
    """

private struct DirectPostAcceptanceProjectionInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let recipientID: UUID
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let sourceEventID: UUID
    let createdAtPostgresMicroseconds: Int64
    let createdAtMilliseconds: Int64
    let stateVersion: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case sourceEventID = "source_event_id"
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
        case createdAtMilliseconds = "created_at_ms"
        case stateVersion = "state_version"
    }
}
private struct DirectPostAcceptanceProjectionBatchRow: Decodable {
    let ordinal: Int
    let senderCapabilityInserted: Bool
    let recipientProfileInserted: Bool
    let profileExists: Bool
    let pairUpdated: Bool
    let expectedEventCount: Int64
    let insertedEventCount: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case senderCapabilityInserted = "sender_capability_inserted"
        case recipientProfileInserted = "recipient_profile_inserted"
        case profileExists = "profile_exists"
        case pairUpdated = "pair_updated"
        case expectedEventCount = "expected_event_count"
        case insertedEventCount = "inserted_event_count"
    }
}

private struct DirectRoomProfileMutationRow: Decodable {
    let profileExists: Bool
    let neededCount: Int64
    let profileInsertedCount: Int64
    let insertedCount: Int64
    let pairCount: Int64

    enum CodingKeys: String, CodingKey {
        case profileExists = "profile_exists"
        case neededCount = "needed_count"
        case profileInsertedCount = "profile_inserted_count"
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}

private func directProjectionSigned(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}
