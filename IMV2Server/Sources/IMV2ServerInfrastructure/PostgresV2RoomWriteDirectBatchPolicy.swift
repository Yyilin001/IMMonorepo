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
        guard appends.count <= 256 else { throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch) }
        var quotaByPair: [String: DirectRoomLogQuotaMutationInput] = [:]
        for append in appends where append.requiresStrangerQuota {
            let key = "\(append.senderID.uuidString)|\(append.recipientID.uuidString)"
            let timestamp = try roomWritePostgresMicroseconds(append.now)
            let cutoff = try roomWritePostgresMicroseconds(
                roomWriteStrangerWindowStart(now: append.now, interval: strangerMessagePolicy.window))
            if var input = quotaByPair[key] {
                // A frozen owner cohort uses one supplied now. Older callers
                // with different snapshots retain their strict scalar fallback.
                guard input.nowPostgresMicroseconds == timestamp,
                      input.windowStartPostgresMicroseconds == cutoff else {
                    throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
                }
                let sum = input.delta.addingReportingOverflow(1)
                guard !sum.overflow else { throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch) }
                input.delta = sum.partialValue
                quotaByPair[key] = input
            } else {
                quotaByPair[key] = .init(senderID: append.senderID, recipientID: append.recipientID,
                    nowPostgresMicroseconds: timestamp, windowStartPostgresMicroseconds: cutoff, delta: 1)
            }
        }
        let quotaInputs = quotaByPair.keys.sorted().map { quotaByPair[$0]! }
        if !quotaInputs.isEmpty {
            let inputJSON = try roomWriteJSON(quotaInputs)
            let expectedCount = Int64(quotaInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.sender_id, input.recipient_id,
                           input.now_postgres_microseconds, input.delta,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.window_start_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.window_start_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC') AS window_start
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        sender_id uuid,
                        recipient_id uuid,
                        now_postgres_microseconds bigint,
                        window_start_postgres_microseconds bigint,
                        delta bigint
                    )
                ), consumed AS (
                    INSERT INTO im_v2.stranger_message_windows AS existing_window
                        (sender_user_id, recipient_user_id, window_started_at, message_count)
                    SELECT input.sender_id, input.recipient_id,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC'), input.delta
                    FROM input
                    WHERE input.delta > 0 AND input.delta <= \(bind: strangerMessagePolicy.maximumMessagesPerWindow)
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
                            THEN EXCLUDED.message_count
                            ELSE existing_window.message_count + EXCLUDED.message_count
                        END
                    WHERE existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                       OR existing_window.message_count <= \(bind: strangerMessagePolicy.maximumMessagesPerWindow) - EXCLUDED.message_count
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

        var sendersByRoom: [UUID: Set<UUID>] = [:]
        for append in appends where append.advancesReplyMarker {
            sendersByRoom[append.roomID, default: []].insert(append.senderID)
        }
        let markerInputs = sendersByRoom.keys.sorted { $0.uuidString < $1.uuidString }.map {
            DirectRoomLogReplyMarkerMutationInput(roomID: $0,
                senderIDs: sendersByRoom[$0]!.sorted { $0.uuidString < $1.uuidString })
        }
        if !markerInputs.isEmpty {
            let inputJSON = try roomWriteJSON(markerInputs)
            let expectedCount = Int64(markerInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.room_id, input.sender_ids
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        room_id uuid,
                        sender_ids uuid[]
                    )
                ), advanced AS (
                    UPDATE im_v2.direct_room_pairs AS pair
                    SET lower_has_replied = CASE
                            WHEN pair.lower_user_id = ANY(input.sender_ids) THEN TRUE
                            ELSE pair.lower_has_replied
                        END,
                        higher_has_replied = CASE
                            WHEN pair.higher_user_id = ANY(input.sender_ids) THEN TRUE
                            ELSE pair.higher_has_replied
                        END,
                        direct_policy_revision = pair.direct_policy_revision + cardinality(input.sender_ids)
                    FROM input
                    WHERE pair.room_id = input.room_id
                      AND pair.direct_policy_revision <= \(bind: Int64.max) - cardinality(input.sender_ids)
                      AND cardinality(input.sender_ids) BETWEEN 1 AND 2
                      AND input.sender_ids <@ ARRAY[pair.lower_user_id,pair.higher_user_id]
                      AND NOT (pair.lower_user_id = ANY(input.sender_ids) AND pair.lower_has_replied)
                      AND NOT (pair.higher_user_id = ANY(input.sender_ids) AND pair.higher_has_replied)
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
    var delta: Int64

    enum CodingKeys: String, CodingKey {
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
        case windowStartPostgresMicroseconds = "window_start_postgres_microseconds"
        case delta
    }
}

private struct DirectRoomLogReplyMarkerMutationInput: Encodable {
    let roomID: UUID
    let senderIDs: [UUID]
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case senderIDs = "sender_ids"
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
