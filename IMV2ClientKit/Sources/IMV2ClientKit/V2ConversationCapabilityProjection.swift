import Foundation
import IMV2Core

public struct V2ClientConversationState: Equatable, Sendable {
    public let roomID: RoomID; public let isPinned: Bool; public let isArchived: Bool; public let muteUntil: Date?; public let updatedAt: Date
    init(roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?, updatedAt: Date) { self.roomID = roomID; self.isPinned = isPinned; self.isArchived = isArchived; self.muteUntil = muteUntil; self.updatedAt = updatedAt }
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable { let roomID: String; let isPinned: Bool; let isArchived: Bool; let muteUntilMs: Int64; let updatedAtMs: Int64; enum CodingKeys: String, CodingKey { case roomID = "room_id", isPinned = "is_pinned", isArchived = "is_archived", muteUntilMs = "mute_until_ms", updatedAtMs = "updated_at_ms" } }
        guard record.projectionKind == "conversation_state", let wire = try? JSONDecoder().decode(Wire.self, from: record.payload), wire.muteUntilMs >= 0, wire.updatedAtMs >= 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        roomID = try .init(wire.roomID); isPinned = wire.isPinned; isArchived = wire.isArchived; muteUntil = wire.muteUntilMs == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(wire.muteUntilMs) / 1_000); updatedAt = Date(timeIntervalSince1970: TimeInterval(wire.updatedAtMs) / 1_000)
    }
}

public struct V2ClientMessageFavorite: Equatable, Sendable {
    public let roomID: RoomID; public let messageID: MessageID; public let isFavorited: Bool; public let updatedAt: Date
    init(roomID: RoomID, messageID: MessageID, isFavorited: Bool, updatedAt: Date) { self.roomID = roomID; self.messageID = messageID; self.isFavorited = isFavorited; self.updatedAt = updatedAt }
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable { let roomID: String; let messageID: String; let isFavorited: Bool; let updatedAtMs: Int64; enum CodingKeys: String, CodingKey { case roomID = "room_id", messageID = "message_id", isFavorited = "is_favorited", updatedAtMs = "updated_at_ms" } }
        guard record.projectionKind == "message_favorite", let wire = try? JSONDecoder().decode(Wire.self, from: record.payload), wire.updatedAtMs >= 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        roomID = try .init(wire.roomID); messageID = try .init(wire.messageID); isFavorited = wire.isFavorited; updatedAt = Date(timeIntervalSince1970: TimeInterval(wire.updatedAtMs) / 1_000)
    }
}
