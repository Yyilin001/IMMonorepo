import Foundation
import IMV2Core

/// 不可变消息接受事件的本地可查询表示。
///
/// 它在同步游标推进之前完成解码，因此界面读取者不会看到「序号已持久化、
/// 但所需消息投影缺失」的中间状态。
public struct V2ClientMessageProjection: Equatable, Sendable {
    public let sourceEventID: EventID
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    /// 房间展示时间线中的排序键。
    ///
    /// 仅作用于消息本身的操作（已读回执、编辑与撤回）仍使用房间序号。
    public let timelineSequence: UInt64
    public let messageRevision: UInt64
    public let senderUserID: UserID
    public let text: String
    public let media: [V2MediaReference]
    public let mediaPresentations: [V2MediaPresentation]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?
    public let forwardedFrom: V2ForwardedMessageAttribution?
    public let createdAt: Date
    public let isWithdrawn: Bool

    public init(sourceEventID: EventID, messageID: MessageID, roomID: RoomID, roomSequence: UInt64, timelineSequence: UInt64? = nil, messageRevision: UInt64 = 1, senderUserID: UserID, text: String, media: [V2MediaReference] = [], mediaPresentations: [V2MediaPresentation] = [], mentions: [V2MentionTarget] = [], entities: [V2MessageEntity] = [], replyTo: V2MessageReplyReference? = nil, forwardedFrom: V2ForwardedMessageAttribution? = nil, createdAt: Date, isWithdrawn: Bool = false) {
        self.sourceEventID = sourceEventID
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence ?? roomSequence
        self.messageRevision = messageRevision
        self.senderUserID = senderUserID
        self.text = text
        self.media = media
        precondition(mediaPresentations.map(\.mediaID) == media.map(\.mediaID))
        self.mediaPresentations = mediaPresentations
        self.mentions = mentions
        precondition((try? V2RichMessageContent.validate(text: text, entities: entities)) != nil)
        self.entities = entities
        self.replyTo = replyTo
        self.forwardedFrom = forwardedFrom
        self.createdAt = createdAt
        self.isWithdrawn = isWithdrawn
    }

    init(record: V2ClientSyncRecord) throws {
        guard record.projectionKind == "message" else { throw V2ClientProjectionError.invalidMessagePayload }
        let payload: Wire
        do { payload = try JSONDecoder().decode(Wire.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        try self.init(sourceEventID: record.sourceEventID, payload: payload)
    }

    private init(sourceEventID: EventID, payload: Wire) throws {
        guard payload.eventType == "message.accepted", payload.roomSequence > 0, (payload.timelineSequence ?? payload.roomSequence) > 0, payload.messageRevision > 0,
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
            let forwardedFrom: V2ForwardedMessageAttribution?
            switch (payload.forwardedFromMessageID, payload.forwardedFromUserID) {
            case (nil, nil):
                forwardedFrom = nil
            case let (.some(messageID), .some(userID)) where !messageID.isEmpty && !userID.isEmpty:
                forwardedFrom = try .init(messageID: .init(messageID), senderUserID: .init(userID))
            default:
                throw V2ClientProjectionError.invalidMessagePayload
            }
            guard Set(media).count == media.count, media.count <= V2MessageCommandLimits.maxMediaAttachments,
                  mediaPresentations.map(\.mediaID) == media.map(\.mediaID),
                  Set(mentions).count == mentions.count, mentions.count <= V2MessageCommandLimits.maxMentions
            else { throw V2ClientProjectionError.invalidMessagePayload }
            try V2RichMessageContent.validate(text: payload.text, entities: entities)
            self.init(sourceEventID: sourceEventID, messageID: try .init(payload.messageID), roomID: try .init(payload.roomID), roomSequence: payload.roomSequence, timelineSequence: payload.timelineSequence, messageRevision: payload.messageRevision, senderUserID: try .init(payload.senderUserID), text: payload.text, media: media, mediaPresentations: mediaPresentations, mentions: mentions, entities: entities, replyTo: replyTo, forwardedFrom: forwardedFrom, createdAt: Date(timeIntervalSince1970: TimeInterval(payload.serverCreatedAtMilliseconds) / 1_000))
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }

    // A replacement must explicitly supply every content field, including
    // null references. Legacy acceptance defaults cannot prove completeness.
    fileprivate init(replacementState decoder: any Decoder, sourceEventID: EventID) throws {
        let fields = try decoder.container(keyedBy: Wire.CodingKeys.self)
        for key in Wire.CodingKeys.allCases {
            guard fields.contains(key) else { throw V2ClientProjectionError.invalidMessagePayload }
            if ![Wire.CodingKeys.replyToMessageID, .forwardedFromMessageID, .forwardedFromUserID].contains(key) {
                guard try !fields.decodeNil(forKey: key) else { throw V2ClientProjectionError.invalidMessagePayload }
            }
        }
        struct Removal: Decodable { let is_withdrawn: Bool? }
        guard try Removal(from: decoder).is_withdrawn != true else { throw V2ClientProjectionError.invalidMessagePayload }
        try self.init(sourceEventID: sourceEventID, payload: Wire(from: decoder))
    }

    func hasSameAcceptance(as other: Self) -> Bool {
        sourceEventID == other.sourceEventID && messageID == other.messageID && roomID == other.roomID
            && roomSequence == other.roomSequence && timelineSequence == other.timelineSequence
            && senderUserID == other.senderUserID && createdAt == other.createdAt
    }

    private struct Wire: Decodable {
        let eventType: String
        let messageID: String
        let roomID: String
        let roomSequence: UInt64
        let timelineSequence: UInt64?
        let messageRevision: UInt64
        let senderUserID: String
        let text: String
        let mediaIDs: [String]?
        let mediaPresentations: [MediaPresentation]?
        let mentionedUserIDs: [String]?
        let mentionsEveryone: Bool?
        let entities: [V2MessageEntity]?
        let replyToMessageID: String?
        let forwardedFromMessageID: String?
        let forwardedFromUserID: String?
        let serverCreatedAtMilliseconds: Int64
        enum CodingKeys: String, CodingKey, CaseIterable {
            case eventType = "event_type"
            case messageID = "message_id"
            case roomID = "room_id"
            case roomSequence = "room_sequence"
            case timelineSequence = "timeline_sequence"
            case messageRevision = "message_revision"
            case senderUserID = "sender_user_id"
            case text
            case mediaIDs = "media_ids"
            case mediaPresentations = "media_presentations"
            case mentionedUserIDs = "mention_user_ids"
            case mentionsEveryone = "mentions_everyone"
            case entities
            case replyToMessageID = "reply_to_message_id"
            case forwardedFromMessageID = "forwarded_from_message_id"
            case forwardedFromUserID = "forwarded_from_user_id"
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

/// 由房间内最新本地投影消息派生的持久化会话列表行。
///
/// 它刻意不含服务端掌管的展示名或可变成员事实：这些内容必须各自拥有已同步的投影，
/// 才能作为权威界面数据展示。
public struct V2ClientConversationSummary: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 该房间最新一条消息投影。
    public let lastMessage: V2ClientMessageProjection

    /// 保存会话摘要。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - lastMessage: 最新消息投影，其房间必须与 `roomID` 一致。
    ///
    /// 房间不一致时直接失败，避免出现归属错位的摘要行。
    public init(roomID: RoomID, lastMessage: V2ClientMessageProjection) {
        precondition(roomID == lastMessage.roomID)
        self.roomID = roomID
        self.lastMessage = lastMessage
    }
}

/// 统一房间时间线中的条目种类。
public enum V2ClientTimelineItemKind: Int, Equatable, Sendable { case message, activity }

/// 统一房间时间线的稳定键集游标。
///
/// 序号是权威顺序，不透明的条目标识则是消息与私有活动投影共用的确定性并列裁决键。
public struct V2ClientTimelineCursor: Equatable, Sendable {
    /// 时间线序号。
    public let timelineSequence: UInt64
    /// 条目标识。
    public let itemID: String

    /// 条目种类。
    public let kind: V2ClientTimelineItemKind

    /// 保存时间线游标。
    ///
    /// - Parameters:
    ///   - timelineSequence: 时间线序号，需大于零。
    ///   - itemID: 条目标识，需非空。
    ///   - kind: 条目种类，默认消息。
    ///
    /// 序号非正或标识为空时直接失败，避免产生无效游标。
    public init(timelineSequence: UInt64, itemID: String, kind: V2ClientTimelineItemKind = .message) {
        precondition(timelineSequence > 0 && !itemID.isEmpty)
        self.kind = kind
        self.timelineSequence = timelineSequence
        self.itemID = itemID
    }
}

/// 有界房间时间线窗口的单次不可变 SQLite 快照。
///
/// 把装饰数据放在同一读事务中，可避免消息分页与来自另一代次的表情、收藏、置顶或回执配对。
public struct V2ClientConversationTimelinePage: Equatable, Sendable {
    /// 本页消息投影。
    public let messages: [V2ClientMessageProjection]
    /// 本页时间线活动条目。
    public let activities: [V2ClientTimelineActivityProjection]
    /// 本页涉及的表情记录。
    public let reactions: [V2ClientMessageReaction]
    /// 展示查询的聚合结果；nil 表示调用者选择了原始表情记录。
    public let reactionSummaries: [V2ClientMessageReactionSummary]?
    /// 本页涉及的置顶消息标识。
    public let pinnedMessageIDs: Set<MessageID>
    /// 本页涉及的收藏消息标识。
    public let favoritedMessageIDs: Set<MessageID>
    /// 私聊已读回执投影。
    public let directReadReceipt: V2DirectReadReceiptProjection?
    /// 更早页面的游标。
    public let olderCursor: V2ClientTimelineCursor?

    /// 保存时间线分页。
    ///
    /// - Parameters:
    ///   - messages: 消息投影。
    ///   - activities: 时间线活动条目。
    ///   - reactions: 表情记录。
    ///   - pinnedMessageIDs: 置顶消息标识。
    ///   - favoritedMessageIDs: 收藏消息标识。
    ///   - directReadReceipt: 私聊已读回执投影。
    ///   - olderCursor: 更早页面游标。
    public init(
        messages: [V2ClientMessageProjection],
        activities: [V2ClientTimelineActivityProjection],
        reactions: [V2ClientMessageReaction],
        pinnedMessageIDs: Set<MessageID>,
        favoritedMessageIDs: Set<MessageID>,
        directReadReceipt: V2DirectReadReceiptProjection?,
        olderCursor: V2ClientTimelineCursor?,
        reactionSummaries: [V2ClientMessageReactionSummary]? = nil
    ) {
        self.messages = messages
        self.activities = activities
        self.reactions = reactions
        self.reactionSummaries = reactionSummaries
        self.pinnedMessageIDs = pinnedMessageIDs
        self.favoritedMessageIDs = favoritedMessageIDs
        self.directReadReceipt = directReadReceipt
        self.olderCursor = olderCursor
    }
}

/// 房间时间线窗口。
///
/// 两个边界与目标条目及装饰数据都属于同一快照。`newerBoundary` 是首个被排除的更新条目，
/// 即使该条目之后被删除，也仍适合作为本窗口的严格 `before` 游标刷新点。
public struct V2ClientConversationTimelineWindow: Equatable, Sendable {
    /// 窗口内的时间线分页。
    public let page: V2ClientConversationTimelinePage
    /// 首个被排除的更新条目游标。
    public let newerBoundary: V2ClientTimelineCursor?
}

/// 时间线定位结果。
public enum V2ClientTimelineLocation: Equatable, Sendable {
    /// 已定位到目标窗口。
    case found(V2ClientConversationTimelineWindow)
    /// 目标消息已被撤回。
    case withdrawn
    /// 不可用。
    ///
    /// 表示目标不存在、不属于该房间，或不属于绑定的本地账号；
    /// 它刻意不披露其他账号的消息是否存在。
    case unavailable
}

public enum V2ClientProjectionError: Error, Equatable, Sendable { case invalidMessagePayload }

/// 消息编辑投影。
///
/// 文本增量必须依赖前一个修订。显式的完整值只在其被接受的标识校验通过后，
/// 才可以跨越被授权的缺口。
struct V2ClientMessageEditProjection: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case textDelta(String)
        case complete(V2ClientMessageReplacement)
    }
    let roomID: RoomID
    let messageID: MessageID
    let messageRevision: UInt64
    let content: Content
    var text: String {
        switch content { case .textDelta(let text): text; case .complete(let value): value.projection.text }
    }

    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let eventType: String; let roomID: String; let messageID: String
            let text: String; let messageRevision: UInt64
            let roomSequence: UInt64?; let entities: [V2MessageEntity]?
            let replacement: V2ClientMessageReplacement?
            enum CodingKeys: String, CodingKey { case eventType = "event_type", roomID = "room_id", messageID = "message_id", text, messageRevision = "message_revision", roomSequence = "room_sequence", entities, replacement }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                eventType = try c.decode(String.self, forKey: .eventType)
                roomID = try c.decode(String.self, forKey: .roomID)
                messageID = try c.decode(String.self, forKey: .messageID)
                text = try c.decode(String.self, forKey: .text)
                messageRevision = try c.decode(UInt64.self, forKey: .messageRevision)
                roomSequence = try c.decodeIfPresent(UInt64.self, forKey: .roomSequence)
                entities = try c.decodeIfPresent([V2MessageEntity].self, forKey: .entities)
                // A present but null/invalid replacement never falls back to delta.
                replacement = c.contains(.replacement) ? try c.decode(V2ClientMessageReplacement.self, forKey: .replacement) : nil
            }
        }
        do {
            let payload = try JSONDecoder().decode(Wire.self, from: record.payload)
            guard record.projectionKind == "message", payload.eventType == "message.edited",
                  payload.messageRevision > 1, !payload.text.isEmpty else { throw V2ClientProjectionError.invalidMessagePayload }
            roomID = try .init(payload.roomID); messageID = try .init(payload.messageID)
            messageRevision = payload.messageRevision
            if let replacement = payload.replacement {
                let state = replacement.projection
                guard state.roomID == roomID, state.messageID == messageID,
                      state.messageRevision == messageRevision, state.text == payload.text,
                      state.entities == payload.entities,
                      let sequence = payload.roomSequence, sequence > state.roomSequence
                else { throw V2ClientProjectionError.invalidMessagePayload }
                content = .complete(replacement.withMutationSequence(sequence))
            } else { content = .textDelta(payload.text) }
        } catch { throw V2ClientProjectionError.invalidMessagePayload }
    }
}

struct V2ClientMessageReplacement: Decodable, Equatable, Sendable {
    let projection: V2ClientMessageProjection
    let acceptedMembershipRevision: UInt64
    private(set) var mutationRoomSequence: UInt64 = 0
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", acceptedEventID = "accepted_event_id", acceptedMembershipRevision = "accepted_membership_revision", state }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw V2ClientProjectionError.invalidMessagePayload }
        let origin = try EventID(c.decode(String.self, forKey: .acceptedEventID))
        guard origin.uuidValue != nil else { throw V2ClientProjectionError.invalidMessagePayload }
        acceptedMembershipRevision = try c.decode(UInt64.self, forKey: .acceptedMembershipRevision)
        projection = try .init(replacementState: c.superDecoder(forKey: .state), sourceEventID: origin)
    }
    func withMutationSequence(_ value: UInt64) -> Self {
        var result = self; result.mutationRoomSequence = value; return result
    }
}

/// 属于某条消息表态集合的、可持久查询的成员。
///
/// 增量事件会添加/移除这个精确的键；不会改变消息文本或内容修订。
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
        guard record.projectionKind == "message_reaction", payload.eventType == "message.reaction_changed",
              (payload.action == "add" || payload.action == "remove"), !payload.reaction.isEmpty,
              payload.reaction.utf8.count <= V2MessageReactionLimits.maximumReactionBytes
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

/// A presentation needs counts and own participation, rather than all actor identities.
public struct V2ClientMessageReactionSummary: Equatable, Sendable {
    public let messageID: MessageID
    public let reaction: String
    public let count: Int
    public let includesCurrentUser: Bool

    public init(messageID: MessageID, reaction: String, count: Int, includesCurrentUser: Bool) {
        self.messageID = messageID
        self.reaction = reaction
        self.count = count
        self.includesCurrentUser = includesCurrentUser
    }
}
