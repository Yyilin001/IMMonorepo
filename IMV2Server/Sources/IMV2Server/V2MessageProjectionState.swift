import Crypto
import Foundation
import IMV2Core

/// 适用于快照 V3 的不可变、自包含消息值。
///
/// 显式的完整编辑事件同样携带该值。它是同一消息修订下所有接收者投影共享的持久化折叠状态；
/// 把折叠过程保持为强类型且无副作用，可以避免每个用户投影器各自改写未经校验的 JSON 字典。
struct V2MessageProjectionState: Codable, Equatable, Sendable {
    static let payloadSchemaVersion: Int16 = 1

    let messageID: MessageID
    let roomID: RoomID
    let acceptedRoomSequence: UInt64
    let timelineSequence: UInt64
    let senderUserID: UserID
    let acceptedAtUnixMilliseconds: Int64
    let messageRevision: UInt64
    let text: String
    let mediaIDs: [MediaID]
    let mediaPresentations: [V2MediaPresentation]
    let mentionUserIDs: [UserID]
    let mentionsEveryone: Bool
    let entities: [V2MessageEntity]
    let replyToMessageID: MessageID?
    let forwardedFromMessageID: MessageID?
    let forwardedFromUserID: UserID?
    let isWithdrawn: Bool

    init(
        accepted message: V2AcceptedMessage,
        forwardedFromMessageID: MessageID?,
        forwardedFromUserID: UserID?
    ) throws {
        let signedMilliseconds = try v2MessageProjectionMilliseconds(message)
        guard (forwardedFromMessageID == nil) == (forwardedFromUserID == nil)
        else { throw V2MessageProjectionStateError.invalidPayload }
        try self.init(
            messageID: message.messageID,
            roomID: message.roomID,
            acceptedRoomSequence: message.roomSequence,
            timelineSequence: message.timelineSequence,
            senderUserID: message.senderUserID,
            acceptedAtUnixMilliseconds: signedMilliseconds,
            messageRevision: 1,
            text: message.text,
            mediaIDs: message.media.map(\.mediaID),
            mediaPresentations: message.mediaPresentations,
            mentionUserIDs: message.mentions.compactMap { target in
                guard case .user(let userID) = target else { return nil }
                return userID
            },
            mentionsEveryone: message.mentions.contains(.everyone),
            entities: message.entities,
            replyToMessageID: message.replyTo?.messageID,
            forwardedFromMessageID: forwardedFromMessageID,
            forwardedFromUserID: forwardedFromUserID,
            isWithdrawn: false
        )
    }

    func applyingEdit(
        revision: UInt64,
        text: String,
        entities: [V2MessageEntity]
    ) throws -> Self {
        guard !isWithdrawn,
              messageRevision < UInt64(Int64.max),
              revision == messageRevision + 1
        else { throw V2MessageProjectionStateError.invalidTransition }
        return try .init(
            messageID: messageID,
            roomID: roomID,
            acceptedRoomSequence: acceptedRoomSequence,
            timelineSequence: timelineSequence,
            senderUserID: senderUserID,
            acceptedAtUnixMilliseconds: acceptedAtUnixMilliseconds,
            messageRevision: revision,
            text: text,
            mediaIDs: mediaIDs,
            mediaPresentations: mediaPresentations,
            mentionUserIDs: mentionUserIDs,
            mentionsEveryone: mentionsEveryone,
            entities: entities,
            replyToMessageID: replyToMessageID,
            forwardedFromMessageID: forwardedFromMessageID,
            forwardedFromUserID: forwardedFromUserID,
            isWithdrawn: false
        )
    }

    func applyingRemoval(revision: UInt64) throws -> Self {
        guard !isWithdrawn,
              messageRevision < UInt64(Int64.max),
              revision == messageRevision + 1
        else { throw V2MessageProjectionStateError.invalidTransition }
        return try .init(
            messageID: messageID,
            roomID: roomID,
            acceptedRoomSequence: acceptedRoomSequence,
            timelineSequence: timelineSequence,
            senderUserID: senderUserID,
            acceptedAtUnixMilliseconds: acceptedAtUnixMilliseconds,
            messageRevision: revision,
            text: "[removed]",
            mediaIDs: [],
            mediaPresentations: [],
            mentionUserIDs: [],
            mentionsEveryone: false,
            entities: [],
            replyToMessageID: nil,
            forwardedFromMessageID: nil,
            forwardedFromUserID: nil,
            isWithdrawn: true
        )
    }

    /// 在当前修订尚未物化为共享状态时重建有效状态。
    ///
    /// 权威 `messages` 行提供当前修订与可变正文，已接受事件提供不可变信封数据。
    ///
    /// - Parameters:
    ///   - revision: 目标修订，需不小于当前修订。
    ///   - text: 权威正文。
    ///   - entities: 权威富文本实体。
    /// - Returns: 指定修订下的重建状态。
    /// - Throws: 消息已撤回或修订倒退时抛出
    ///   ``V2MessageProjectionStateError/invalidTransition``。
    func restoringActiveRevision(
        _ revision: UInt64,
        text: String,
        entities: [V2MessageEntity]
    ) throws -> Self {
        guard !isWithdrawn, revision >= messageRevision else {
            throw V2MessageProjectionStateError.invalidTransition
        }
        return try .init(
            messageID: messageID,
            roomID: roomID,
            acceptedRoomSequence: acceptedRoomSequence,
            timelineSequence: timelineSequence,
            senderUserID: senderUserID,
            acceptedAtUnixMilliseconds: acceptedAtUnixMilliseconds,
            messageRevision: revision,
            text: text,
            mediaIDs: mediaIDs,
            mediaPresentations: mediaPresentations,
            mentionUserIDs: mentionUserIDs,
            mentionsEveryone: mentionsEveryone,
            entities: entities,
            replyToMessageID: replyToMessageID,
            forwardedFromMessageID: forwardedFromMessageID,
            forwardedFromUserID: forwardedFromUserID,
            isWithdrawn: false
        )
    }

    func encodedPayloadJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let value = String(data: try encoder.encode(self), encoding: .utf8) else {
            throw V2MessageProjectionStateError.invalidPayload
        }
        return value
    }

    init(payloadJSON: String) throws {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw V2MessageProjectionStateError.invalidPayload
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw V2MessageProjectionStateError.invalidPayload
        }
    }

    private init(
        messageID: MessageID,
        roomID: RoomID,
        acceptedRoomSequence: UInt64,
        timelineSequence: UInt64,
        senderUserID: UserID,
        acceptedAtUnixMilliseconds: Int64,
        messageRevision: UInt64,
        text: String,
        mediaIDs: [MediaID],
        mediaPresentations: [V2MediaPresentation],
        mentionUserIDs: [UserID],
        mentionsEveryone: Bool,
        entities: [V2MessageEntity],
        replyToMessageID: MessageID?,
        forwardedFromMessageID: MessageID?,
        forwardedFromUserID: UserID?,
        isWithdrawn: Bool
    ) throws {
        guard acceptedRoomSequence > 0, acceptedRoomSequence <= UInt64(Int64.max),
              timelineSequence > 0, timelineSequence <= UInt64(Int64.max),
              messageRevision > 0, messageRevision <= UInt64(Int64.max),
              Set(mediaIDs).count == mediaIDs.count,
              Set(mentionUserIDs).count == mentionUserIDs.count,
              mediaPresentations.map(\.mediaID) == mediaIDs,
              (forwardedFromMessageID == nil) == (forwardedFromUserID == nil)
        else { throw V2MessageProjectionStateError.invalidPayload }
        if isWithdrawn {
            guard text == "[removed]",
                  mediaIDs.isEmpty,
                  mediaPresentations.isEmpty,
                  mentionUserIDs.isEmpty,
                  !mentionsEveryone,
                  entities.isEmpty,
                  replyToMessageID == nil,
                  forwardedFromMessageID == nil,
                  forwardedFromUserID == nil
            else { throw V2MessageProjectionStateError.invalidPayload }
        } else {
            do {
                try V2RichMessageContent.validate(text: text, entities: entities)
            } catch {
                throw V2MessageProjectionStateError.invalidPayload
            }
        }
        self.messageID = messageID
        self.roomID = roomID
        self.acceptedRoomSequence = acceptedRoomSequence
        self.timelineSequence = timelineSequence
        self.senderUserID = senderUserID
        self.acceptedAtUnixMilliseconds = acceptedAtUnixMilliseconds
        self.messageRevision = messageRevision
        self.text = text
        self.mediaIDs = mediaIDs
        self.mediaPresentations = mediaPresentations
        self.mentionUserIDs = mentionUserIDs
        self.mentionsEveryone = mentionsEveryone
        self.entities = entities
        self.replyToMessageID = replyToMessageID
        self.forwardedFromMessageID = forwardedFromMessageID
        self.forwardedFromUserID = forwardedFromUserID
        self.isWithdrawn = isWithdrawn
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .eventType) == "message.accepted" else {
            throw V2MessageProjectionStateError.invalidPayload
        }
        let mediaIDs = try values.decode([String].self, forKey: .mediaIDs).map { try MediaID($0) }
        let presentations = try values.decode([MediaPresentationWire].self, forKey: .mediaPresentations).map { try $0.value }
        let mentionUserIDs = try values.decode([String].self, forKey: .mentionUserIDs).map { try UserID($0) }
        let reply = try values.decodeIfPresent(String.self, forKey: .replyToMessageID).map { try MessageID($0) }
        let forwardedMessage = try values.decodeIfPresent(String.self, forKey: .forwardedFromMessageID).map { try MessageID($0) }
        let forwardedUser = try values.decodeIfPresent(String.self, forKey: .forwardedFromUserID).map { try UserID($0) }
        try self.init(
            messageID: MessageID(try values.decode(String.self, forKey: .messageID)),
            roomID: RoomID(try values.decode(String.self, forKey: .roomID)),
            acceptedRoomSequence: try values.decode(UInt64.self, forKey: .acceptedRoomSequence),
            timelineSequence: try values.decode(UInt64.self, forKey: .timelineSequence),
            senderUserID: UserID(try values.decode(String.self, forKey: .senderUserID)),
            acceptedAtUnixMilliseconds: try values.decode(Int64.self, forKey: .acceptedAtUnixMilliseconds),
            messageRevision: try values.decode(UInt64.self, forKey: .messageRevision),
            text: try values.decode(String.self, forKey: .text),
            mediaIDs: mediaIDs,
            mediaPresentations: presentations,
            mentionUserIDs: mentionUserIDs,
            mentionsEveryone: try values.decode(Bool.self, forKey: .mentionsEveryone),
            entities: try values.decode([V2MessageEntity].self, forKey: .entities),
            replyToMessageID: reply,
            forwardedFromMessageID: forwardedMessage,
            forwardedFromUserID: forwardedUser,
            isWithdrawn: try values.decodeIfPresent(Bool.self, forKey: .isWithdrawn) ?? false
        )
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("message.accepted", forKey: .eventType)
        try values.encode(messageID.rawValue, forKey: .messageID)
        try values.encode(roomID.rawValue, forKey: .roomID)
        try values.encode(acceptedRoomSequence, forKey: .acceptedRoomSequence)
        try values.encode(timelineSequence, forKey: .timelineSequence)
        try values.encode(senderUserID.rawValue, forKey: .senderUserID)
        try values.encode(text, forKey: .text)
        try values.encode(mediaIDs.map(\.rawValue), forKey: .mediaIDs)
        try values.encode(mediaPresentations.map(MediaPresentationWire.init), forKey: .mediaPresentations)
        try values.encode(mentionUserIDs.map(\.rawValue), forKey: .mentionUserIDs)
        try values.encode(mentionsEveryone, forKey: .mentionsEveryone)
        try values.encode(entities, forKey: .entities)
        try values.encode(messageRevision, forKey: .messageRevision)
        try values.encode(acceptedAtUnixMilliseconds, forKey: .acceptedAtUnixMilliseconds)
        if isWithdrawn {
            try values.encode(true, forKey: .isWithdrawn)
        } else {
            try values.encodeIfPresent(replyToMessageID?.rawValue, forKey: .replyToMessageID)
            if replyToMessageID == nil { try values.encodeNil(forKey: .replyToMessageID) }
            try values.encodeIfPresent(forwardedFromMessageID?.rawValue, forKey: .forwardedFromMessageID)
            if forwardedFromMessageID == nil { try values.encodeNil(forKey: .forwardedFromMessageID) }
            try values.encodeIfPresent(forwardedFromUserID?.rawValue, forKey: .forwardedFromUserID)
            if forwardedFromUserID == nil { try values.encodeNil(forKey: .forwardedFromUserID) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case messageID = "message_id"
        case roomID = "room_id"
        case acceptedRoomSequence = "room_sequence"
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
        case acceptedAtUnixMilliseconds = "server_created_at_ms"
        case isWithdrawn = "is_withdrawn"
    }
}

enum V2MessageProjectionStateError: Error, Equatable, Sendable {
    case invalidPayload
    case invalidTransition
}

/// 由语义状态身份而非 JSON 字节派生的稳定跨分片标识。
///
/// 该版本形态的 UUID 不作为安全原语使用；SHA-256 只用于让彼此独立的重试写入收敛到同一标识。
///
/// - Parameters:
///   - messageID: 目标消息。
///   - messageRevision: 消息修订，需大于零。
///   - variantKey: 变体键，需非负。
/// - Returns: 派生出的稳定标识。
/// - Throws: 修订非正或变体键为负时抛出
///   ``V2MessageProjectionStateError/invalidPayload``。
func v2MessageProjectionStateID(
    messageID: UUID,
    messageRevision: Int64,
    variantKey: Int16 = 0
) throws -> UUID {
    guard messageRevision > 0, variantKey >= 0 else {
        throw V2MessageProjectionStateError.invalidPayload
    }
    let input = "im-v2:message-projection-state:\(messageID.uuidString.lowercased()):\(messageRevision):\(variantKey)"
    var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

private struct MediaPresentationWire: Codable {
    let mediaID: String
    let kind: V2MediaPresentation.Kind
    let contentType: String
    let byteCount: Int64

    init(_ value: V2MediaPresentation) {
        mediaID = value.mediaID.rawValue
        kind = value.kind
        contentType = value.contentType
        byteCount = value.byteCount
    }

    var value: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: MediaID(mediaID),
                kind: kind,
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case kind
        case contentType = "content_type"
        case byteCount = "byte_count"
    }
}

// 不可变投影格式使用向下取整，1970 年之前的时间也一样。
// SQL 事件写入器共用此转换，避免载荷与类型化投影不一致，
// 从而错误触发不可变内容栅栏。
/// 计算已接受消息的投影毫秒时间戳。
///
/// 优先使用消息自带的投影时间戳，缺失时回落到创建时刻。
///
/// - Parameter message: 已接受消息。
/// - Returns: 投影使用的 Unix 毫秒时间戳。
/// - Throws: 时刻无法表示为毫秒整数时抛出
///   ``V2MessageProjectionStateError/invalidPayload``。
func v2MessageProjectionMilliseconds(_ message: V2AcceptedMessage) throws -> Int64 {
    let dateMilliseconds = try v2MessageProjectionMilliseconds(message.createdAt)
    return message.projectionCreatedAtUnixMilliseconds ?? dateMilliseconds
}

/// 以向下取整方式把时刻转换为 Unix 毫秒。
///
/// 不可变投影格式统一使用向下取整，包括 1970 年之前的时间；SQL 事件写入方共用同一转换，
/// 使其载荷不会与强类型投影产生分歧并误判为内容栅栏不通过。
///
/// - Parameter date: 待转换时刻。
/// - Returns: Unix 毫秒时间戳。
/// - Throws: 取值超出 `Int64` 范围时抛出
///   ``V2MessageProjectionStateError/invalidPayload``。
func v2MessageProjectionMilliseconds(_ date: Date) throws -> Int64 {
    guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded(.down)) else {
        throw V2MessageProjectionStateError.invalidPayload
    }
    return value
}
