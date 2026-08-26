import Foundation
import IMV2Core

/// Canonical JSON representation shared by the process-local direct room-log
/// cache and the optional foreground live-event hint. PostgreSQL remains the
/// durable source; this codec only prevents two accelerators from constructing
/// subtly different payloads or paying an encode -> `Any` -> encode round trip.
enum V2DirectRoomLogPayloadCodec {
    static func encode(_ message: V2AcceptedMessage) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Payload(message))
    }

    private struct Payload: Encodable {
        let message: V2AcceptedMessage

        init(_ message: V2AcceptedMessage) { self.message = message }

        enum CodingKeys: String, CodingKey {
            case eventType = "event_type"
            case messageID = "message_id"
            case roomID = "room_id"
            case roomSequence = "room_sequence"
            case timelineSequence = "timeline_sequence"
            case senderUserID = "sender_user_id"
            case text
            case mediaIDs = "media_ids"
            case mediaPresentations = "media_presentations"
            case mentionUserIDs = "mention_user_ids"
            case mentionsEveryone = "mentions_everyone"
            case entities
            case replyToMessageID = "reply_to_message_id"
            case forwardedFromMessageID = "forwarded_from_message_id"
            case forwardedFromUserID = "forwarded_from_user_id"
            case messageRevision = "message_revision"
            case serverCreatedAtMilliseconds = "server_created_at_ms"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("message.accepted", forKey: .eventType)
            try container.encode(message.messageID.rawValue, forKey: .messageID)
            try container.encode(message.roomID.rawValue, forKey: .roomID)
            try container.encode(message.roomSequence, forKey: .roomSequence)
            try container.encode(message.timelineSequence, forKey: .timelineSequence)
            try container.encode(message.senderUserID.rawValue, forKey: .senderUserID)
            try container.encode(message.text, forKey: .text)
            try container.encode([String](), forKey: .mediaIDs)
            try container.encode([String](), forKey: .mediaPresentations)
            try container.encode([String](), forKey: .mentionUserIDs)
            try container.encode(false, forKey: .mentionsEveryone)
            try container.encode(message.entities, forKey: .entities)
            try container.encodeNil(forKey: .replyToMessageID)
            try container.encodeNil(forKey: .forwardedFromMessageID)
            try container.encodeNil(forKey: .forwardedFromUserID)
            try container.encode(1, forKey: .messageRevision)
            try container.encode(
                Int64(message.createdAt.timeIntervalSince1970 * 1_000),
                forKey: .serverCreatedAtMilliseconds
            )
        }
    }
}
