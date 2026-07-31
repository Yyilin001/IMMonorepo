import Foundation
import IMV2Core

/// The locally queryable representation of an immutable message acceptance
/// event. It is decoded before the sync cursor advances, so UI readers never
/// observe a persisted sequence whose required message projection is absent.
public struct V2ClientMessageProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let messageRevision: UInt64
    public let senderUserID: UserID
    public let text: String
    public let media: [V2MediaReference]
    public let mediaPresentations: [V2MediaPresentation]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    public let createdAt: Date
    public let isWithdrawn: Bool

    public init(sourceEventID: EventID, messageID: MessageID, roomID: RoomID, roomSequence: UInt64, messageRevision: UInt64 = 1, senderUserID: UserID, text: String, media: [V2MediaReference] = [], mediaPresentations: [V2MediaPresentation] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil, createdAt: Date, isWithdrawn: Bool = false) {
        self.sourceEventID = sourceEventID
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.messageRevision = messageRevision
        self.senderUserID = senderUserID
        self.text = text
        self.media = media
        let presentations = mediaPresentations.isEmpty && !media.isEmpty
            ? media.map(V2MediaPresentation.legacy)
            : mediaPresentations
        precondition(presentations.map(\.mediaID) == media.map(\.mediaID))
        self.mediaPresentations = presentations
        self.mentions = mentions
        precondition((try? V2RichMessageContent.validate(text: text, entities: entities)) != nil)
        self.entities = entities
        self.replyTo = replyTo
        self.createdAt = createdAt
        self.isWithdrawn = isWithdrawn
    }

    init(snapshotProjection: V2SnapshotMessageProjection) {
        self.init(
            sourceEventID: snapshotProjection.sourceEventID,
            messageID: snapshotProjection.messageID,
            roomID: snapshotProjection.roomID,
            roomSequence: snapshotProjection.roomSequence,
            messageRevision: snapshotProjection.messageRevision,
            senderUserID: snapshotProjection.senderUserID,
            text: snapshotProjection.text,
            media: snapshotProjection.media,
            mediaPresentations: snapshotProjection.mediaPresentations,
            mentions: snapshotProjection.mentions,
            entities: snapshotProjection.entities,
            replyTo: snapshotProjection.replyTo,
            createdAt: snapshotProjection.createdAt,
            isWithdrawn: snapshotProjection.isWithdrawn
        )
    }

    init(record: V2ClientSyncRecord) throws {
        guard record.projectionKind == "message" else { throw V2ClientProjectionError.invalidMessagePayload }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard payload.eventType == "message.accepted", payload.roomSequence > 0, payload.messageRevision > 0,
              payload.serverCreatedAtMilliseconds >= 0,
              (!payload.text.isEmpty || !(payload.mediaIDs ?? []).isEmpty)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            let media = try (payload.mediaIDs ?? []).map { try V2MediaReference(mediaID: .init($0)) }
            let mediaPresentations = try (payload.mediaPresentations ?? []).map { try $0.presentation() }
            let mentions = try (payload.mentionedUserIDs ?? []).map { try V2MentionTarget.user(.init($0)) }
                + ((payload.mentionsEveryone ?? false) ? [.everyone] : [])
            let entities = payload.entities ?? []
            let replyTo = try payload.replyToMessageID.map { V2MessageReplyReference(messageID: try .init($0)) }
            guard Set(media).count == media.count, media.count <= V2MessageCommandLimits.maxMediaAttachments,
                  (mediaPresentations.isEmpty || mediaPresentations.map(\.mediaID) == media.map(\.mediaID)),
                  Set(mentions).count == mentions.count, mentions.count <= V2MessageCommandLimits.maxMentions
            else { throw V2ClientProjectionError.invalidMessagePayload }
            try V2RichMessageContent.validate(text: payload.text, entities: entities)
            self.init(sourceEventID: record.sourceEventID, messageID: try .init(payload.messageID), roomID: try .init(payload.roomID), roomSequence: payload.roomSequence, messageRevision: payload.messageRevision, senderUserID: try .init(payload.senderUserID), text: payload.text, media: media, mediaPresentations: mediaPresentations, mentions: mentions, entities: entities, replyTo: replyTo, createdAt: Date(timeIntervalSince1970: TimeInterval(payload.serverCreatedAtMilliseconds) / 1_000))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }

    private struct Wire: Decodable {
        let eventType: String
        let messageID: String
        let roomID: String
        let roomSequence: UInt64
        let messageRevision: UInt64
        let senderUserID: String
        let text: String
        let mediaIDs: [String]?
        let mediaPresentations: [MediaPresentation]?
        let mentionedUserIDs: [String]?
        let mentionsEveryone: Bool?
        let entities: [V2MessageEntity]?
        let replyToMessageID: String?
        let serverCreatedAtMilliseconds: Int64
        enum CodingKeys: String, CodingKey {
            case eventType = "event_type"
            case messageID = "message_id"
            case roomID = "room_id"
            case roomSequence = "room_sequence"
            case messageRevision = "message_revision"
            case senderUserID = "sender_user_id"
            case text
            case mediaIDs = "media_ids"
            case mediaPresentations = "media_presentations"
            case mentionedUserIDs = "mention_user_ids"
            case mentionsEveryone = "mentions_everyone"
            case entities
            case replyToMessageID = "reply_to_message_id"
            case serverCreatedAtMilliseconds = "server_created_at_ms"
        }

        struct MediaPresentation: Decodable {
            let mediaID: String
            let kind: V2MediaPresentation.Kind
            let contentType: String
            let byteCount: Int64

            func presentation() throws -> V2MediaPresentation {
                try .init(mediaID: .init(mediaID), kind: kind, contentType: contentType, byteCount: byteCount)
            }

            enum CodingKeys: String, CodingKey {
                case mediaID = "media_id"
                case kind
                case contentType = "content_type"
                case byteCount = "byte_count"
            }
        }
    }
}

/// One durable conversation-list row derived from the latest locally
/// projected message in a room. It deliberately contains no server-owned
/// display name or mutable membership facts: those require their own synced
/// projection before they can be shown as authoritative UI.
public struct V2ClientConversationSummary: Equatable, Sendable {
    public let roomID: RoomID
    public let lastMessage: V2ClientMessageProjection

    public init(roomID: RoomID, lastMessage: V2ClientMessageProjection) {
        precondition(roomID == lastMessage.roomID)
        self.roomID = roomID
        self.lastMessage = lastMessage
    }
}

public enum V2ClientProjectionError: Error, Equatable, Sendable { case invalidMessagePayload }

/// A later room event that replaces only the visible text of an existing
/// message. The local store applies it only to the immediately preceding
/// content revision, so an out-of-order or incomplete stream cannot silently
/// overwrite state.
struct V2ClientMessageEditProjection: Equatable, Sendable {
    let roomID: RoomID
    let messageID: MessageID
    let text: String
    let messageRevision: UInt64

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String; let roomID: String; let messageID: String
            let text: String; let messageRevision: UInt64
            enum CodingKeys: String, CodingKey { case eventType = "event_type"; case roomID = "room_id"; case messageID = "message_id"; case text; case messageRevision = "message_revision" }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard record.projectionKind == "message", payload.eventType == "message.edited",
              payload.messageRevision > 1, !payload.text.isEmpty
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do { roomID = try .init(payload.roomID); messageID = try .init(payload.messageID); text = payload.text; messageRevision = payload.messageRevision }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}

/// Durable, queryable member of a message's reaction set. Incremental events
/// add/remove this exact key; no message text or content revision is changed.
public struct V2ClientMessageReaction: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let actorUserID: UserID
    public let reaction: String

    public init(roomID: RoomID, messageID: MessageID, actorUserID: UserID, reaction: String) {
        self.roomID = roomID; self.messageID = messageID; self.actorUserID = actorUserID; self.reaction = reaction
    }

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String; let roomID: String; let messageID: String; let actorUserID: String
            let reaction: String; let action: String
            enum CodingKeys: String, CodingKey { case eventType = "event_type"; case roomID = "room_id"; case messageID = "message_id"; case actorUserID = "actor_user_id"; case reaction; case action }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard record.projectionKind == "message", payload.eventType == "message.reaction_changed",
              (payload.action == "add" || payload.action == "remove"), !payload.reaction.isEmpty,
              payload.reaction.utf8.count <= 64
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do { roomID = try .init(payload.roomID); messageID = try .init(payload.messageID); actorUserID = try .init(payload.actorUserID); reaction = payload.reaction }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
    }

    func action(record: V2ClientSyncRecord) throws -> V2MessageReactionAction {
        struct Header: Decodable { let action: String }
        guard let action = try? JSONDecoder().decode(Header.self, from: record.payload).action,
              let value = V2MessageReactionAction(rawValue: action)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        return value
    }
}

struct V2ClientMessageTombstone: Equatable, Sendable {
    let sourceEventID: EventID
    let roomID: RoomID
    let messageID: MessageID
    let messageRevision: UInt64

    init(sourceEventID: EventID, roomID: RoomID, messageID: MessageID, messageRevision: UInt64) {
        self.sourceEventID = sourceEventID
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
    }

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String
            let roomID: String
            let messageID: String
            let messageRevision: UInt64
            enum CodingKeys: String, CodingKey { case eventType = "event_type"; case roomID = "room_id"; case messageID = "message_id"; case messageRevision = "message_revision" }
        }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        guard record.projectionKind == "message", (payload.eventType == "message.withdrawn" || payload.eventType == "message.redacted"), payload.messageRevision > 1 else { throw V2ClientProjectionError.invalidMessagePayload }
        do { self.init(sourceEventID: record.sourceEventID, roomID: try .init(payload.roomID), messageID: try .init(payload.messageID), messageRevision: payload.messageRevision) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}
