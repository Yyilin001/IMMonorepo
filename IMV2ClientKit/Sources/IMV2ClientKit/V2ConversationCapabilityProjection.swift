import Foundation
import IMV2Core

/// 客户端侧的会话状态投影：置顶、归档与免打扰。
public struct V2ClientConversationState: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 是否置顶。
    public let isPinned: Bool
    /// 是否归档。
    public let isArchived: Bool
    /// 免打扰截止时间；为空表示当前不处于免打扰。
    public let muteUntil: Date?
    /// 该状态的更新时间。
    public let updatedAt: Date
    public let revision: V2PersonalPreferenceRevision
    /// 创建会话状态投影。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - isPinned: 是否置顶。
    ///   - isArchived: 是否归档。
    ///   - muteUntil: 免打扰截止时间。
    ///   - updatedAt: 该状态的更新时间。
    public init(roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?, updatedAt: Date, revision: V2PersonalPreferenceRevision) { self.roomID = roomID; self.isPinned = isPinned; self.isArchived = isArchived; self.muteUntil = muteUntil; self.updatedAt = updatedAt; self.revision = revision }
    /// 从本地同步记录解码会话状态。
    ///
    /// - Parameter record: 投影类型为 `conversation_state` 的同步记录。
    /// - Throws: 投影类型不符、载荷非法或时间字段为负时抛出 `invalidMessagePayload`。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable { let roomID: String; let isPinned: Bool; let isArchived: Bool; let muteUntilMs: Int64; let updatedAtMs: Int64; let revision: V2PersonalPreferenceRevision; enum CodingKeys: String, CodingKey { case roomID = "room_id", isPinned = "is_pinned", isArchived = "is_archived", muteUntilMs = "mute_until_ms", updatedAtMs = "updated_at_ms", revision } }
        guard record.projectionKind == "conversation_state", let wire = try? JSONDecoder().decode(Wire.self, from: record.payload), wire.muteUntilMs >= 0, wire.updatedAtMs >= 0, wire.revision.rawValue > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        roomID = try .init(wire.roomID); isPinned = wire.isPinned; isArchived = wire.isArchived; muteUntil = wire.muteUntilMs == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(wire.muteUntilMs) / 1_000); updatedAt = Date(timeIntervalSince1970: TimeInterval(wire.updatedAtMs) / 1_000); revision = wire.revision
    }
}

/// 客户端侧的消息收藏投影。
public struct V2ClientMessageFavorite: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 被收藏的消息。
    public let messageID: MessageID
    /// 当前是否处于已收藏状态。
    public let isFavorited: Bool
    /// 该状态的更新时间。
    public let updatedAt: Date
    public let revision: V2PersonalPreferenceRevision
    /// 创建收藏投影。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 被收藏的消息。
    ///   - isFavorited: 当前是否已收藏。
    ///   - updatedAt: 该状态的更新时间。
    init(roomID: RoomID, messageID: MessageID, isFavorited: Bool, updatedAt: Date, revision: V2PersonalPreferenceRevision) { self.roomID = roomID; self.messageID = messageID; self.isFavorited = isFavorited; self.updatedAt = updatedAt; self.revision = revision }
    /// 从本地同步记录解码收藏状态。
    ///
    /// - Parameter record: 投影类型为 `message_favorite` 的同步记录。
    /// - Throws: 投影类型不符、载荷非法或时间字段为负时抛出 `invalidMessagePayload`。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable { let roomID: String; let messageID: String; let isFavorited: Bool; let updatedAtMs: Int64; let revision: V2PersonalPreferenceRevision; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", isFavorited = "is_favorited", updatedAtMs = "updated_at_ms", revision } }
        guard record.projectionKind == "message_favorite", let wire = try? JSONDecoder().decode(Wire.self, from: record.payload), wire.updatedAtMs >= 0, wire.revision.rawValue > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        roomID = try .init(wire.roomID); messageID = try .init(wire.messageID); isFavorited = wire.isFavorited; updatedAt = Date(timeIntervalSince1970: TimeInterval(wire.updatedAtMs) / 1_000); revision = wire.revision
    }
}
