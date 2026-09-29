import IMV2ServerContracts
import Foundation
import IMV2Core

/// 进程内私聊房间日志缓存与可选前台实时事件提示共用的规范 JSON 表示。
///
/// 持久化来源仍然是 PostgreSQL；该编解码器只负责避免两个加速器构造出细微不同的载荷，
/// 也避免付出「编码 → `Any` → 再编码」的往返代价。
package enum V2DirectRoomLogPayloadCodec {
    private static let hexadecimal = Array("0123456789abcdef".utf8)

    /// 把已接受消息编码为房间日志载荷。
    ///
    /// - Parameter message: 已接受的消息投影。
    /// - Returns: 规范 JSON 载荷；时间戳无法投影为毫秒时返回 `nil`。
    package static func encode(_ message: V2AcceptedMessage) -> Data? {
    // 这是消息投影，因此 1970 年之前的时间戳须与持久化时的向下取整保持一致。
        guard let milliseconds = try? v2MessageProjectionMilliseconds(message) else { return nil }
        if message.entities.isEmpty {
            return encodePlainText(message, milliseconds: milliseconds)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Payload(message: message, milliseconds: milliseconds))
    }

    /// 编码不含实体的纯文本消息，这是私聊房间日志最常见的形态。
    ///
    /// 直接拼接字节可以避免为每条已提交消息构造键值式 Codable 图与新的 `JSONEncoder`，
    /// 同时保持完全一致的 JSON 契约：动态字符串按 RFC 8259 从 UTF-8 字节转义，
    /// 含实体的富载荷仍走通用编码路径。
    ///
    /// - Parameters:
    ///   - message: 已接受的消息投影，其实体列表为空。
    ///   - milliseconds: 已投影的服务端毫秒时间戳。
    /// - Returns: 规范 JSON 载荷。
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

    /// 把字符串的 UTF-8 字节追加到输出缓冲。
    ///
    /// - Parameters:
    ///   - value: 待追加字符串。
    ///   - bytes: 输出缓冲。
    private static func append(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(contentsOf: value.utf8)
    }

    /// 以 JSON 字符串形式追加内容并完成必要的转义。
    ///
    /// - Parameters:
    ///   - value: 待追加字符串。
    ///   - bytes: 输出缓冲。
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

    /// 通用编码路径使用的载荷包装，统一键名与固定字段取值。
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

        /// 按固定字段集合写出载荷。
        ///
        /// - Parameter encoder: 数据编码器。
        /// - Throws: 编码失败时抛出。
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
