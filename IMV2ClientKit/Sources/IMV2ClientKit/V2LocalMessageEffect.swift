import Crypto
import Foundation
import IMV2Core

/// 个人同步与两个房间事件入口共用的已解析消息事实。
///
/// 摘要覆盖语义内容，但排除投递流游标与 JSON 书写形式；构造过程始终复用既有的线路解码器，
/// 以保证两条路径得到完全相同的解析结果。
enum V2LocalMessageEffect: Encodable {
    /// 消息被接受。
    case accepted(V2ClientMessageProjection)
    /// 消息被编辑。
    case edited(V2ClientMessageEditProjection)
    /// 消息被撤回。
    case withdrawn(V2ClientMessageTombstone)
    /// 消息被审核屏蔽。
    case redacted(V2ClientMessageTombstone)

    /// 按事件类型解析同步记录。
    ///
    /// - Parameter record: 消息类同步记录。
    /// - Throws: 载荷无法解码或事件类型不受支持时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Header: Decodable {
            let event_type: String
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: record.payload) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        switch header.event_type {
        case "message.accepted": self = .accepted(try .init(record: record))
        case "message.edited": self = .edited(try .init(record: record))
        case "message.withdrawn": self = .withdrawn(try .init(record: record))
        case "message.redacted": self = .redacted(try .init(record: record))
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    /// 目标消息标识。
    var messageID: MessageID {
        switch self {
        case .accepted(let value): value.messageID
        case .edited(let value): value.messageID
        case .withdrawn(let value), .redacted(let value): value.messageID
        }
    }
    /// 目标房间标识。
    var roomID: RoomID {
        switch self {
        case .accepted(let value): value.roomID
        case .edited(let value): value.roomID
        case .withdrawn(let value), .redacted(let value): value.roomID
        }
    }
    /// 消息修订。
    var revision: UInt64 {
        switch self {
        case .accepted(let value): value.messageRevision
        case .edited(let value): value.messageRevision
        case .withdrawn(let value), .redacted(let value): value.messageRevision
        }
    }
    /// 计算语义内容摘要。
    ///
    /// - Returns: 键序稳定的 JSON 内容的 SHA-256 摘要。
    /// - Throws: 编码失败时抛出。
    func digest() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(self)))
    }

    private enum CodingKeys: String, CodingKey {
        case version, eventType, messageID, roomID, revision, text
        case acceptedEventID, acceptedMembershipRevision, replacementStateDigest
        case roomSequence, timelineSequence, senderUserID, media, presentations
        case mentions, entities, replyTo, forwardedMessageID, forwardedUserID, createdAt, withdrawn
    }
    /// 写出规范化的语义内容。
    ///
    /// 编码刻意按语义而非原始载荷：时间戳转为秒、提及归一为可分发的形式、
    /// 转发信息拆为消息与发送者字段，使语义相同的两种书写形式得到相同摘要。
    ///
    /// - Parameter encoder: 数据编码器。
    /// - Throws: 编码失败时抛出。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(messageID.rawValue, forKey: .messageID)
        try container.encode(roomID.rawValue, forKey: .roomID)
        try container.encode(revision, forKey: .revision)
        switch self {
        case .accepted(let value):
            try container.encode("accepted", forKey: .eventType)
            try container.encode(value.roomSequence, forKey: .roomSequence)
            try container.encode(value.timelineSequence, forKey: .timelineSequence)
            try container.encode(value.senderUserID.rawValue, forKey: .senderUserID)
            try container.encode(value.text, forKey: .text)
            try container.encode(value.media, forKey: .media)
            try container.encode(value.mediaPresentations, forKey: .presentations)
            try container.encode(value.mentions.map { mention in
                switch mention {
                case .user(let user): "user:" + user.rawValue
                case .everyone: "everyone"
                }
            }, forKey: .mentions)
            try container.encode(value.entities, forKey: .entities)
            try container.encode(value.replyTo, forKey: .replyTo)
            try container.encode(value.forwardedFrom?.messageID.rawValue, forKey: .forwardedMessageID)
            try container.encode(value.forwardedFrom?.senderUserID.rawValue, forKey: .forwardedUserID)
            try container.encode(value.createdAt.timeIntervalSince1970, forKey: .createdAt)
            try container.encode(value.isWithdrawn, forKey: .withdrawn)
        case .edited(let value):
            try container.encode("edited", forKey: .eventType)
            try container.encode(value.text, forKey: .text)
            if case .complete(let replacement) = value.content {
                try container.encode(replacement.projection.sourceEventID.rawValue, forKey: .acceptedEventID)
                try container.encode(replacement.acceptedMembershipRevision, forKey: .acceptedMembershipRevision)
                try container.encode(replacement.mutationRoomSequence, forKey: .roomSequence)
                try container.encode(V2LocalMessageEffect.accepted(replacement.projection).digest(), forKey: .replacementStateDigest)
            }
        case .withdrawn:
            try container.encode("withdrawn", forKey: .eventType)
        case .redacted:
            try container.encode("redacted", forKey: .eventType)
        }
    }
}
