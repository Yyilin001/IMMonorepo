import Foundation

public enum V2ResourceCategory: String, Codable, CaseIterable, Sendable {
    case all, image, video, audio, file
    public func includes(contentType: String) -> Bool {
        switch self {
        case .all: true
        case .image: contentType.hasPrefix("image/")
        case .video: contentType.hasPrefix("video/")
        case .audio: contentType.hasPrefix("audio/")
        case .file: !contentType.hasPrefix("image/") && !contentType.hasPrefix("video/") && !contentType.hasPrefix("audio/")
        }
    }
}

/// Exclusive time boundaries are Unix milliseconds; cursor is opaque to clients.
public struct V2RoomResourceQuery: Equatable, Codable, Sendable {
    public let category: V2ResourceCategory
    public let limit: Int
    public let cursor: String?
    public let before: Int64?
    public let after: Int64?
    public init(category: V2ResourceCategory = .all, limit: Int = 50, cursor: String? = nil,
                before: Int64? = nil, after: Int64? = nil) throws {
        guard (1...100).contains(limit), cursor.map({ !$0.isEmpty && $0.utf8.count <= 4096 }) ?? true,
              before.map({ $0 >= 0 && $0 <= 253_402_300_799_000 }) ?? true,
              after.map({ $0 >= 0 && $0 <= 253_402_300_799_000 }) ?? true else { throw V2ResourceValidationError.invalidDescriptor }
        if let before, let after, after >= before { throw V2ResourceValidationError.invalidDescriptor }
        self.category = category; self.limit = limit; self.cursor = cursor; self.before = before; self.after = after
    }
    private enum CodingKeys: String, CodingKey { case category, limit, cursor, before, after }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(category: c.decode(V2ResourceCategory.self, forKey: .category), limit: c.decode(Int.self, forKey: .limit),
            cursor: c.decodeIfPresent(String.self, forKey: .cursor), before: c.decodeIfPresent(Int64.self, forKey: .before),
            after: c.decodeIfPresent(Int64.self, forKey: .after))
    }
}

public struct V2RoomResourcePosition: Hashable, Comparable, Codable, Sendable {
    public let roomSequence: UInt64
    public let ordinal: Int
    public let mediaID: MediaID
    public init(roomSequence: UInt64, ordinal: Int, mediaID: MediaID) throws {
        guard roomSequence > 0, roomSequence <= UInt64(Int64.max),
              (0..<V2MessageCommandLimits.maxMediaAttachments).contains(ordinal) else { throw V2ResourceValidationError.invalidDescriptor }
        self.roomSequence = roomSequence; self.ordinal = ordinal; self.mediaID = mediaID
    }
    private enum CodingKeys: String, CodingKey { case roomSequence, ordinal, mediaID }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.roomSequence,lhs.ordinal,lhs.mediaID) < (rhs.roomSequence,rhs.ordinal,rhs.mediaID)
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomSequence: c.decode(UInt64.self, forKey: .roomSequence), ordinal: c.decode(Int.self, forKey: .ordinal), mediaID: c.decode(MediaID.self, forKey: .mediaID))
    }
}

public struct V2RoomResourceItem: Equatable, Codable, Sendable {
    public let messageID: MessageID
    public let messageRevision: UInt64
    public let position: V2RoomResourcePosition
    public let createdAt: Int64
    public let descriptor: V2ResourceDescriptor
    public init(messageID: MessageID, messageRevision: UInt64, position: V2RoomResourcePosition,
                createdAt: Int64, descriptor: V2ResourceDescriptor) throws {
        guard messageRevision > 0, messageRevision <= UInt64(Int64.max), createdAt >= 0, createdAt <= 253_402_300_799_000,
              position.mediaID == descriptor.key.mediaID else { throw V2ResourceValidationError.invalidDescriptor }
        self.messageID = messageID; self.messageRevision = messageRevision; self.position = position
        self.createdAt = createdAt; self.descriptor = descriptor
    }
    private enum CodingKeys: String, CodingKey { case messageID, messageRevision, position, createdAt, descriptor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageID: c.decode(MessageID.self, forKey: .messageID), messageRevision: c.decode(UInt64.self, forKey: .messageRevision),
            position: c.decode(V2RoomResourcePosition.self, forKey: .position), createdAt: c.decode(Int64.self, forKey: .createdAt),
            descriptor: c.decode(V2ResourceDescriptor.self, forKey: .descriptor))
    }
}

public struct V2RoomResourcePage: Equatable, Codable, Sendable {
    public let items: [V2RoomResourceItem]
    public let snapshotUpperRoomSequence: UInt64
    public let nextCursor: String?
    public init(items: [V2RoomResourceItem], snapshotUpperRoomSequence: UInt64, nextCursor: String?) throws {
        guard items.count <= 100, snapshotUpperRoomSequence <= UInt64(Int64.max),
              items.allSatisfy({ $0.position.roomSequence <= snapshotUpperRoomSequence }),
              Set(items.map(\.position)).count == items.count,
              zip(items,items.dropFirst()).allSatisfy({ $0.position > $1.position }),
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 4096 && !items.isEmpty }) ?? true else {
            throw V2ResourceValidationError.invalidDescriptor
        }
        self.items = items; self.snapshotUpperRoomSequence = snapshotUpperRoomSequence; self.nextCursor = nextCursor
    }
    private enum CodingKeys: String, CodingKey { case items, snapshotUpperRoomSequence, nextCursor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(items: c.decode([V2RoomResourceItem].self, forKey: .items),
            snapshotUpperRoomSequence: c.decode(UInt64.self, forKey: .snapshotUpperRoomSequence), nextCursor: c.decodeIfPresent(String.self, forKey: .nextCursor))
    }
}
