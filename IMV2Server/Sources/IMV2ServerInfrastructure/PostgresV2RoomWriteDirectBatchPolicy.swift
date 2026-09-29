import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// Executes policy mutations on the caller's locked transaction connection.
/// It has no connection pool, cache or commit capability.
struct V2RoomWriteDirectBatchPolicy: Sendable {
    let strangerMessagePolicy: V2StrangerMessagePolicy

    struct Input: Sendable {
        let roomID: UUID
        let senderID: UUID
        let recipientID: UUID
        let now: Date
        let requiresStrangerQuota: Bool
        let advancesReplyMarker: Bool
    }

    func persist(
        _ appends: [Input],
        sql: any SQLDatabase
    ) async throws {
        let quotaInputs = try appends.compactMap { append -> DirectRoomLogQuotaMutationInput? in
            guard append.requiresStrangerQuota else { return nil }
            return .init(
                senderID: append.senderID,
                recipientID: append.recipientID,
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(append.now),
                windowStartPostgresMicroseconds: try roomWritePostgresMicroseconds(
                    roomWriteStrangerWindowStart(now: append.now, interval: strangerMessagePolicy.window))
            )
        }
        guard Set(quotaInputs.map { "\($0.senderID.uuidString)|\($0.recipientID.uuidString)" }).count == quotaInputs.count else {
            // 私聊关系按设计唯一，且此批次每个房间仅有一条命令。
            // 保留显式断言：即使将来该不变量改变，下方 upsert 也不能
            // 为同一逻辑关系消耗两份配额。
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        if !quotaInputs.isEmpty {
            let inputJSON = try roomWriteJSON(quotaInputs)
            let expectedCount = Int64(quotaInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.sender_id, input.recipient_id,
                           input.now_postgres_microseconds,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.window_start_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.window_start_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC') AS window_start
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        sender_id uuid,
                        recipient_id uuid,
                        now_postgres_microseconds bigint,
                        window_start_postgres_microseconds bigint
                    )
                ), consumed AS (
                    INSERT INTO im_v2.stranger_message_windows AS existing_window
                        (sender_user_id, recipient_user_id, window_started_at, message_count)
                    SELECT input.sender_id, input.recipient_id,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC'), 1
                    FROM input
                    ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
                    SET window_started_at = CASE
                            WHEN existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                            THEN EXCLUDED.window_started_at
                            ELSE existing_window.window_started_at
                        END,
                        message_count = CASE
                            WHEN existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                            THEN 1
                            ELSE existing_window.message_count + 1
                        END
                    WHERE existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                       OR existing_window.message_count < \(bind: strangerMessagePolicy.maximumMessagesPerWindow)
                    RETURNING sender_user_id, recipient_user_id
                )
                SELECT \(bind: expectedCount)::bigint AS expected_count,
                       (SELECT count(*) FROM consumed)::bigint AS applied_count
                """).first(decoding: DirectRoomLogBatchMutationCounts.self),
                  result.expectedCount == expectedCount,
                  result.appliedCount == expectedCount
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
        }

        let markerInputs = appends.compactMap { append -> DirectRoomLogReplyMarkerMutationInput? in
            guard append.advancesReplyMarker else { return nil }
            return .init(roomID: append.roomID, senderID: append.senderID)
        }
        guard Set(markerInputs.map(\.roomID)).count == markerInputs.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        if !markerInputs.isEmpty {
            let inputJSON = try roomWriteJSON(markerInputs)
            let expectedCount = Int64(markerInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.room_id, input.sender_id
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        room_id uuid,
                        sender_id uuid
                    )
                ), advanced AS (
                    UPDATE im_v2.direct_room_pairs AS pair
                    SET lower_has_replied = CASE
                            WHEN pair.lower_user_id = input.sender_id THEN TRUE
                            ELSE pair.lower_has_replied
                        END,
                        higher_has_replied = CASE
                            WHEN pair.higher_user_id = input.sender_id THEN TRUE
                            ELSE pair.higher_has_replied
                        END,
                        direct_policy_revision = pair.direct_policy_revision + 1
                    FROM input
                    WHERE pair.room_id = input.room_id
                      AND pair.direct_policy_revision < \(bind: Int64.max)
                      AND (pair.lower_user_id = input.sender_id
                           OR pair.higher_user_id = input.sender_id)
                      AND ((pair.lower_user_id = input.sender_id AND NOT pair.lower_has_replied)
                           OR (pair.higher_user_id = input.sender_id AND NOT pair.higher_has_replied))
                    RETURNING pair.room_id
                )
                SELECT \(bind: expectedCount)::bigint AS expected_count,
                       (SELECT count(*) FROM advanced)::bigint AS applied_count
                """).first(decoding: DirectRoomLogBatchMutationCounts.self),
                  result.expectedCount == expectedCount,
                  result.appliedCount == expectedCount
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
        }
    }


}

private struct DirectRoomLogQuotaMutationInput: Encodable {
    let senderID: UUID
    let recipientID: UUID
    let nowPostgresMicroseconds: Int64
    let windowStartPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
        case windowStartPostgresMicroseconds = "window_start_postgres_microseconds"
    }
}

private struct DirectRoomLogReplyMarkerMutationInput: Encodable {
    let roomID: UUID
    let senderID: UUID

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case senderID = "sender_id"
    }
}

private struct DirectRoomLogBatchMutationCounts: Decodable {
    let expectedCount: Int64
    let appliedCount: Int64

    enum CodingKeys: String, CodingKey {
        case expectedCount = "expected_count"
        case appliedCount = "applied_count"
    }
}
