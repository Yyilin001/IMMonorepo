import Foundation
import IMV2Core

/// Canonical JSON representation shared by the process-local direct room-log
/// cache and the optional foreground live-event hint. PostgreSQL remains the
/// durable source; this codec only prevents two accelerators from constructing
/// subtly different payloads or paying an encode -> `Any` -> encode round trip.
enum V2DirectRoomLogPayloadCodec {
    private static let hexadecimal = Array("0123456789abcdef".utf8)

    static func encode(_ message: V2AcceptedMessage) -> Data? {
        // This is a message projection, so pre-1970 timestamps must match the durable floor rounding.
        guard let milliseconds = try? v2MessageProjectionMilliseconds(message) else { return nil }
        if message.entities.isEmpty {
            return encodePlainText(message, milliseconds: milliseconds)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Payload(message: message, milliseconds: milliseconds))
    }

    /// Plain direct text is the dominant room-log shape. Avoid constructing a
    /// keyed Codable graph and a fresh JSONEncoder for every committed message,
    /// while retaining the exact JSON contract. Dynamic strings are escaped
    /// from their UTF-8 bytes according to RFC 8259; richer entity payloads keep
    /// using the general encoder above.
    private static func encodePlainText(_ message: V2AcceptedMessage, milliseconds: Int64) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(message.text.utf8.count + 512)
        append("{\"entities\":[],\"event_type\":\"message.accepted\",\"forwarded_from_message_id\":null,\"forwarded_from_user_id\":null,\"media_ids\":[],\"media_presentations\":[],\"mention_user_ids\":[],\"mentions_everyone\":false,\"message_id\":", to: &bytes)
        appendJSONString(message.messageID.rawValue, to: &bytes)
        append(",\"message_revision\":1,\"reply_to_message_id\":null,\"room_id\":", to: &bytes)
        appendJSONString(message.roomID.rawValue, to: &bytes)
        append(",\"room_sequence\":\(message.roomSequence),\"sender_user_id\":", to: &bytes)
        appendJSONString(message.senderUserID.rawValue, to: &bytes)
        append(",\"server_created_at_ms\":\(milliseconds),\"text\":", to: &bytes)
        appendJSONString(message.text, to: &bytes)
        append(",\"timeline_sequence\":\(message.timelineSequence)}", to: &bytes)
        return Data(bytes)
    }

    private static func append(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: value.utf8)
    }

    private static func appendJSONString(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(0x22)
        for byte in value.utf8 {
            switch byte {
            case 0x22: bytes.append(contentsOf: [0x5c, 0x22])
            case 0x5c: bytes.append(contentsOf: [0x5c, 0x5c])
            case 0x08: bytes.append(contentsOf: [0x5c, 0x62])
            case 0x0c: bytes.append(contentsOf: [0x5c, 0x66])
            case 0x0a: bytes.append(contentsOf: [0x5c, 0x6e])
            case 0x0d: bytes.append(contentsOf: [0x5c, 0x72])
            case 0x09: bytes.append(contentsOf: [0x5c, 0x74])
            case 0x00...0x1f:
                bytes.append(contentsOf: [
                    0x5c, 0x75, 0x30, 0x30,
                    hexadecimal[Int(byte >> 4)],
                    hexadecimal[Int(byte & 0x0f)],
                ])
            default:
                bytes.append(byte)
            }
        }
        bytes.append(0x22)
    }

    private struct Payload: Encodable {
        let message: V2AcceptedMessage
        let milliseconds: Int64

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
                milliseconds,
                forKey: .serverCreatedAtMilliseconds
            )
        }
    }
}
