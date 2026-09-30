@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// Reads immutable producer facts for projector disorder tests. Leasing itself
/// deliberately serializes a user's stream, so it cannot supply both A and B.
func frozenUserStateEvents(
    on sql: any SQLDatabase, userID: UUID, kind: V2UserStateEventKind
) async throws -> [V2UserStateEvent] {
    let rows = try await sql.raw("""
        SELECT source_event_id, user_id, payload::text AS payload_json, created_at
        FROM im_v2.user_state_event_outbox
        WHERE user_id = \(bind: userID) AND projection_kind = \(bind: kind.rawValue)
        ORDER BY (payload->>'revision')::bigint DESC, source_event_id
        """).all(decoding: FrozenUserStateEventRow.self)
    return try rows.map {
        try .init(sourceEventID: .init(uuid: $0.sourceEventID), userID: .init(uuid: $0.userID),
                  kind: kind, payload: Data($0.payloadJSON.utf8), createdAt: $0.createdAt)
    }
}

private struct FrozenUserStateEventRow: Decodable {
    let sourceEventID: UUID
    let userID: UUID
    let payloadJSON: String
    let createdAt: V2PersistenceTimestamp
    enum CodingKeys: String, CodingKey {
        case sourceEventID = "source_event_id", userID = "user_id"
        case payloadJSON = "payload_json", createdAt = "created_at"
    }
}
