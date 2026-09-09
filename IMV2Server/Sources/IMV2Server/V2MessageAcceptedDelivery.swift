import Foundation
import IMV2Core
import SQLKit

/// Accepted delivery is independent of room defaults and payload placement.
/// Callers hold the room/message mutation locks before reading this fact.
enum V2StoredMessageDeliveryAuthority: String, Decodable, Sendable {
    case personal
    case roomLog = "room_log"

    // Reuse the existing admission/audit-plan implementation. This conversion
    // is execution policy only; it never changes a room's group delivery mode.
    var eventDeliveryMode: V2GroupDeliveryMode {
        switch self {
        case .personal: .standardFanout
        case .roomLog: .largeGroupHybrid
        }
    }
}

struct V2MessageAcceptedDelivery: Sendable {
    let authority: V2StoredMessageDeliveryAuthority
    let eventID: UUID
    let membershipRevision: Int64
    let roomSequence: Int64

    func targetRuleJSON(reservationUpperBound: Int, leaseID: UUID, leaseGeneration: Int64) -> String {
        // Only fixed UUID/integer persistence facts enter this JSON.
        #"{"kind":"message_visible_members","accepted_membership_revision":\#(membershipRevision),"accepted_event_id":"\#(eventID.uuidString)","accepted_room_sequence":\#(roomSequence),"reservation_upper_bound":\#(reservationUpperBound),"reservation_lease_id":"\#(leaseID.uuidString)","reservation_lease_generation":\#(leaseGeneration)}"#
    }
}

enum V2MessageAcceptedDeliveryError: Error, Sendable {
    case unavailable
}

func v2MessageAcceptedDelivery(messageID: UUID, roomID: UUID, sql: any SQLDatabase) async throws -> V2MessageAcceptedDelivery {
    // Follow the existing completion primary key via the already indexed
    // message row. No message-id scan or new hot-write index is required.
    // Completion owns the accepted membership revision: legacy room-event
    // storage leaves the physical message-row copy at its default value.
    guard let row = try await sql.raw(v2MessageAcceptedDeliveryQuery(
        messageID: "\(bind: messageID)", roomID: "\(bind: roomID)"
    )).first(decoding: AcceptedDeliveryRow.self),
          row.messageID == messageID,
          row.roomSequence > 0, row.roomSequence == row.messageRoomSequence,
          row.membershipRevision >= 0
    else { throw V2MessageAcceptedDeliveryError.unavailable }
    return .init(authority: row.authority, eventID: row.eventID,
        membershipRevision: row.membershipRevision, roomSequence: row.roomSequence)
}

/// A composable indexed lookup for both commands and event-log reads.
/// SQL fragments are server-owned expressions, never client-provided SQL.
func v2MessageAcceptedDeliveryQuery(messageID: SQLQueryString, roomID: SQLQueryString) -> SQLQueryString {
    """
    SELECT completion.message_id, completion.event_id, completion.room_sequence,
           completion.accepted_membership_revision, completion.delivery_authority,
           message.room_sequence AS message_room_sequence
    FROM im_v2.messages AS message
    JOIN im_v2.message_send_completions AS completion
      ON completion.room_id = message.room_id
     AND completion.sender_user_id = message.sender_user_id
     AND completion.client_message_id = message.client_message_id
    WHERE message.message_id = \(messageID) AND message.room_id = \(roomID)
      AND completion.message_id = message.message_id
      AND completion.room_sequence = message.room_sequence
    """
}

private struct AcceptedDeliveryRow: Decodable {
    let messageID: UUID
    let eventID: UUID
    let roomSequence: Int64
    let membershipRevision: Int64
    let authority: V2StoredMessageDeliveryAuthority
    let messageRoomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", eventID = "event_id", roomSequence = "room_sequence"
        case membershipRevision = "accepted_membership_revision", authority = "delivery_authority"
        case messageRoomSequence = "message_room_sequence"
    }
}
