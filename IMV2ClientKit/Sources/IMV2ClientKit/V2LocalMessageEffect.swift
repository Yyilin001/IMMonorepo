import Crypto
import Foundation
import IMV2Core

/// Parsed facts shared by personal sync and both room-event entry points.
/// The digest covers semantic content, excluding the delivery stream cursor
/// and JSON spelling. Construction always passes the existing wire decoders.
enum V2LocalMessageEffect: Encodable {
    case accepted(V2ClientMessageProjection)
    case edited(V2ClientMessageEditProjection)
    case withdrawn(V2ClientMessageTombstone)
    case redacted(V2ClientMessageTombstone)

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

    var messageID: MessageID {
        switch self {
        case .accepted(let value): value.messageID
        case .edited(let value): value.messageID
        case .withdrawn(let value), .redacted(let value): value.messageID
        }
    }
    var roomID: RoomID {
        switch self {
        case .accepted(let value): value.roomID
        case .edited(let value): value.roomID
        case .withdrawn(let value), .redacted(let value): value.roomID
        }
    }
    var revision: UInt64 {
        switch self {
        case .accepted(let value): value.messageRevision
        case .edited(let value): value.messageRevision
        case .withdrawn(let value), .redacted(let value): value.messageRevision
        }
    }
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
