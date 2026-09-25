import Foundation
import IMV2Core
import SQLKit

/// 在权威控制偏好锁下解析房间读取或控制策略候选项。
/// 调用方保持此事务存活，直至目标提交。
func v2ResolveDirectReadReceiptCandidate(
    _ event: V2UserStateEvent, sql: any SQLDatabase, schema: String
) async throws -> Data {
    guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
          let candidate = try? JSONDecoder().decode(DirectReadCandidate.self, from: Data(event.payloadJSON.utf8)),
          let viewer = event.userID.uuidValue,
          candidate.readerUserID != viewer,
          candidate.readThroughRoomSequence >= 0 else {
        throw V2UserStateEventError.invalidEvent
    }
    let users = [candidate.readerUserID, viewer].sorted { $0.uuidString < $1.uuidString }
    for user in users {
        let key = "v2-read-receipt-preference:" + user.uuidString
        try await sql.raw("SELECT pg_advisory_xact_lock_shared(hashtextextended(\(bind: key), 0))").run()
    }
    let rows = try await sql.raw("""
        SELECT user_id, allows_direct_read_receipts, preference_revision
        FROM \(unsafeRaw: schema).user_read_receipt_preferences
        WHERE user_id IN (\(bind: candidate.readerUserID), \(bind: viewer))
        """).all(decoding: DirectReadPolicyRow.self)
    guard rows.allSatisfy({ $0.revision > 0 }) else {
        throw V2UserStateEventError.corruptPersistenceState
    }
    let readerPolicy = rows.first { $0.userID == candidate.readerUserID }
    let viewerPolicy = rows.first { $0.userID == viewer }
    let visible = (readerPolicy?.allowsDirect ?? true) && (viewerPolicy?.allowsDirect ?? true)
    return try JSONSerialization.data(withJSONObject: [
        "room_id": candidate.roomID.uuidString,
        "reader_user_id": candidate.readerUserID.uuidString,
        "read_through_room_sequence": visible ? candidate.readThroughRoomSequence : 0,
        "recorded_at_ms": candidate.recordedAtMilliseconds,
        "is_visible": visible,
        "reader_preference_revision": readerPolicy?.revision ?? 0,
        "viewer_preference_revision": viewerPolicy?.revision ?? 0,
    ], options: [.sortedKeys])
}

private struct DirectReadCandidate: Decodable {
    let roomID: UUID
    let readerUserID: UUID
    let readThroughRoomSequence: Int64
    let recordedAtMilliseconds: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", readerUserID = "reader_user_id"
        case readThroughRoomSequence = "read_through_room_sequence"
        case recordedAtMilliseconds = "recorded_at_ms"
    }
}

private struct DirectReadPolicyRow: Decodable {
    let userID: UUID
    let allowsDirect: Bool
    let revision: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", allowsDirect = "allows_direct_read_receipts"
        case revision = "preference_revision"
    }
}
