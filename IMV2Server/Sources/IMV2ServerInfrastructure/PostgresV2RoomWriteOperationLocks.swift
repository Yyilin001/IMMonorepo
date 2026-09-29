import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import PostgresNIO

/// 有序幂等围栏批次中的一行。
///
/// 它刻意保留原始序号，尽管 `OrderedRoomWriteRequest` 恰好也携带该序号：
/// SQL 中的递归边才是「在获取咨询锁期间没有命令被跳过或重排」的持久断言。
struct MessageOperationLockInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
    }
}

struct MessageOperationLockBatchRow: Decodable {
    let acquiredCount: Int64

    enum CodingKeys: String, CodingKey {
        case acquiredCount = "acquired_count"
    }
}

/// 有序幂等围栏批次的具名、类型化数组形式。
///
/// 递归边刻意与 SQLKit 回退实现完全一致：
/// 在 PostgreSQL 取得前一个序号之前，不会尝试获取后一个锁。
/// 每当 SQL 或绑定契约变化时都要提升 `name`。
struct MessageOperationLockBatchStatement: PostgresPreparedStatement {
    static let name = "im_v2_message_operation_lock_batch_v2"
    static let sql = """
        WITH RECURSIVE key_input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   hashtextextended(
                       'v2-message-operation:' || input.room_id::text || ':' || input.sender_id::text || ':' || input.client_message_id::text,
                       0
                   ) AS lock_key
            FROM unnest($1::uuid[], $2::uuid[], $3::uuid[]) WITH ORDINALITY AS input(
                room_id, sender_id, client_message_id, ordinality
            )
        ), input AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY lock_key, ordinal) - 1)::integer AS ordinal, lock_key
            FROM key_input
        ), locked(ordinal, lock_acquired) AS (
            SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
            FROM input
            WHERE input.ordinal = 0

            UNION ALL

            SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
            FROM locked AS previous
            JOIN input
              ON input.ordinal = previous.ordinal + 1
        )
        SELECT count(*)::bigint AS acquired_count
        FROM locked
        """

    typealias Row = Int64

    let inputs: [MessageOperationLockInput]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        try row.decode(Int64.self)
    }
}
