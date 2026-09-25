import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

// Executes on the Store's borrowed transaction connection. It does not own
// owner fencing, admission credit finalization, or transaction commit.
enum PlainHybridGroupWritePath {
    /// 用单条语句持久化紧凑的混合群组已接受事件。
    ///
    /// 消息行同时是规范正文与不可变的已接受事件身份。
    /// 房间日志读取方将这种表示与 `room_events` 合并，
    /// 且语句触发器会发出同样的合并式持久唤醒。
    /// 修订为一的投影状态可以无损推导，只有后续编辑/撤回需要时才会物化。
    /// 重复房间会保留每一条消息，而只有其最终输入会推进可变游标与房间准入。
    ///
    /// - Parameters:
    ///   - inputs: 已准备的混合群组追加输入。
    ///   - sql: 参与当前事务的数据库连接。
    /// - Throws: 影响行数不符或写入失败时抛出。
    static func persist(
        inputs: [PlainHybridGroupAppendInput],
        sql: any SQLDatabase
    ) async throws {
        guard !inputs.isEmpty else { return }
        guard Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let expected = Int64(inputs.count)
        let expectedRooms = Int64(Set(inputs.map(\.roomID)).count)
        // The production PostgreSQL path binds typed arrays to a named
        // statement. The former JSON recordset encoded the complete batch in
        // Swift, parsed it again in PostgreSQL and replanned this invariant
        // write graph for every transaction. Typed arrays retain the same
        // one-statement atomicity and cardinality fences while avoiding that
        // duplicate serialization work. Keep the JSON branch for SQL test
        // doubles that do not expose PostgresNIO connections.
        if let postgres = sql as? any PostgresDatabase {
            let statement = try PlainHybridGroupAppendStatement(inputs: inputs)
            let mutation = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var result: PlainHybridGroupMutationRow?
                    for try await row in rows {
                        guard result == nil else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        result = row
                    }
                    return result
                }
            }.get()
            guard let mutation,
                  mutation.roomCount == expectedRooms,
                  mutation.admissionCount == expectedRooms,
                  mutation.messageCount == expected
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return
        }
        let inputJSON = try roomWriteJSON(inputs)
        guard let mutation = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.message_id,
                       (input.fingerprint->>'version')::smallint AS fingerprint_version,
                       decode(input.fingerprint->>'digest', 'base64') AS request_fingerprint,
                       input.event_id, input.sender_id,
                       input.client_message_id, input.room_sequence,
                       input.timeline_sequence, input.membership_revision,
                       input.command_window_used,
                       input.shard_lease_id, input.shard_lease_generation,
                       input.text_body, input.rich_entities,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    message_id uuid,
                    event_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    room_sequence bigint,
                    timeline_sequence bigint,
                    membership_revision bigint,
                    command_window_used bigint,
                    shard_lease_id uuid,
                    shard_lease_generation bigint,
                    text_body text,
                    rich_entities jsonb,
                    fingerprint jsonb,
                    created_at_postgres_microseconds bigint
                )
            ), final_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) *
                FROM input
                ORDER BY room_id, ordinal DESC
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = input.room_sequence,
                    timeline_sequence = input.timeline_sequence
                FROM final_room_input AS input
                WHERE room.room_id = input.room_id
                RETURNING room.room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = input.command_window_used,
                    shard_lease_id = input.shard_lease_id,
                    shard_lease_generation = input.shard_lease_generation
                FROM final_room_input AS input
                JOIN room_update ON room_update.room_id = input.room_id
                WHERE admission.room_id = input.room_id
                RETURNING admission.room_id
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence,
                     sender_user_id, client_message_id, text_body,
                     rich_entities, created_at, accepted_event_id,
                     accepted_event_storage, accepted_membership_revision)
                SELECT input.message_id, input.room_id, input.room_sequence,
                       input.timeline_sequence, input.sender_id,
                       input.client_message_id, input.text_body,
                       input.rich_entities, input.created_at, CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
                FROM input
                JOIN admission_update ON admission_update.room_id = input.room_id
                RETURNING *
            )
            \(unsafeRaw: v2HybridGroupSendCompletionCTE)
            SELECT (SELECT count(*) FROM room_update)::bigint AS room_count,
                   (SELECT count(*) FROM admission_update)::bigint AS admission_count,
                   (SELECT count(*) FROM message_insert)::bigint AS message_count
            """).first(decoding: PlainHybridGroupMutationRow.self),
              mutation.roomCount == expectedRooms,
              mutation.admissionCount == expectedRooms,
              mutation.messageCount == expected
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
    }
}

private struct PlainHybridGroupMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
    }
}

struct PlainHybridGroupAppendInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let messageID: UUID
    let eventID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let commandWindowUsed: Int
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    let text: String
    let entities: [V2MessageEntity]
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case messageID = "message_id"
        case eventID = "event_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case commandWindowUsed = "command_window_used"

        case shardLeaseID = "shard_lease_id"
        case shardLeaseGeneration = "shard_lease_generation"
        case text = "text_body"
        case entities = "rich_entities"
        case fingerprint
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
    }
}

/// 混合群组规范追加的具名、连接级缓存形式。
///
/// 数组刻意采用列式：PostgresNIO 可以在扩展协议中直接编码它们，
/// 而 PostgreSQL 可以用一次 `unnest` 展开。
/// JSON 值的实体列在服务端转换之前一直保持 JSON 文本，
/// 因此任意实体都能保持与回退路径完全相同的表示。
private struct PlainHybridGroupAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_append_v5"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT input.ordinal, input.room_id, input.message_id,
                   input.event_id, input.sender_id,
                   input.client_message_id, input.fingerprint_version, input.request_fingerprint, input.room_sequence,
                   input.timeline_sequence, input.membership_revision,
                   input.command_window_used,
                   input.shard_lease_id, input.shard_lease_generation,
                   input.text_body,
                   input.rich_entities_json::jsonb AS rich_entities,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
            FROM unnest(
                $1::integer[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::uuid[], $7::bigint[], $8::bigint[],
                $9::bigint[], $10::bigint[], $11::uuid[], $12::bigint[], $13::text[],
                $14::text[], $15::bigint[], $16::smallint[], $17::bytea[]
            ) AS input(
                ordinal, room_id, message_id, event_id, sender_id,
                client_message_id, room_sequence, timeline_sequence,
                membership_revision, command_window_used, shard_lease_id,
                shard_lease_generation, text_body, rich_entities_json,
                created_at_postgres_microseconds, fingerprint_version, request_fingerprint
            )
        ), final_room_input AS MATERIALIZED (
            SELECT DISTINCT ON (room_id) *
            FROM input
            ORDER BY room_id, ordinal DESC
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = input.room_sequence,
                timeline_sequence = input.timeline_sequence
            FROM final_room_input AS input
            WHERE room.room_id = input.room_id
            RETURNING room.room_id
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used = input.command_window_used,
                shard_lease_id = input.shard_lease_id,
                shard_lease_generation = input.shard_lease_generation
            FROM final_room_input AS input
            JOIN room_update ON room_update.room_id = input.room_id
            WHERE admission.room_id = input.room_id
            RETURNING admission.room_id
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, created_at, accepted_event_id,
                 accepted_event_storage, accepted_membership_revision)
            SELECT input.message_id, input.room_id, input.room_sequence,
                   input.timeline_sequence, input.sender_id,
                   input.client_message_id, input.text_body,
                   input.rich_entities, input.created_at, CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
            FROM input
            JOIN admission_update ON admission_update.room_id = input.room_id
            RETURNING *
        )
        \(v2HybridGroupSendCompletionCTE)
        SELECT (SELECT count(*) FROM room_update)::bigint AS room_count,
               (SELECT count(*) FROM admission_update)::bigint
                   AS admission_count,
               (SELECT count(*) FROM message_insert)::bigint AS message_count
        """

    typealias Row = PlainHybridGroupMutationRow

    let inputs: [PlainHybridGroupAppendInput]
    let richEntitiesJSON: [String]

    init(inputs: [PlainHybridGroupAppendInput]) throws {
        self.inputs = inputs
        richEntitiesJSON = try inputs.map { input in
            input.entities.isEmpty ? "[]" : try roomWriteJSON(input.entities)
        }
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 17)
        bindings.append(try inputs.map { input in
            guard let ordinal = Int32(exactly: input.ordinal) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return ordinal
        })
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.roomSequence))
        bindings.append(inputs.map(\.timelineSequence))
        bindings.append(inputs.map(\.membershipRevision))
        bindings.append(try inputs.map { input in
            guard let value = Int64(exactly: input.commandWindowUsed) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return value
        })
        bindings.append(inputs.map(\.shardLeaseID))
        bindings.append(inputs.map(\.shardLeaseGeneration))
        bindings.append(inputs.map(\.text))
        bindings.append(richEntitiesJSON)
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let counts = try row.decode((Int64, Int64, Int64).self)
        return .init(
            roomCount: counts.0,
            admissionCount: counts.1,
            messageCount: counts.2
        )
    }
}
