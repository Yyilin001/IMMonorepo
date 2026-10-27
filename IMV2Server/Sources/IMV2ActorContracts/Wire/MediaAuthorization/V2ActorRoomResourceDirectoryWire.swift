import Foundation
import IMV2Core

/// A bounded, room-authoritative metadata read. Position has already been
/// authenticated by the account service; it never grants historical visibility.
public struct V2ActorRoomResourceDirectoryWire: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let query: V2RoomResourceQuery
    public let snapshotUpperRoomSequence: UInt64?
    public let before: V2RoomResourcePosition?
    public init(roomID: RoomID, actorUserID: UserID, query: V2RoomResourceQuery,
                snapshotUpperRoomSequence: UInt64?, before: V2RoomResourcePosition?) throws {
        guard roomID.uuidValue != nil, actorUserID.uuidValue != nil,
              query.cursor == nil, (snapshotUpperRoomSequence == nil) == (before == nil),
              snapshotUpperRoomSequence.map({ $0 <= UInt64(Int64.max) }) ?? true,
              before.map({ $0.roomSequence <= (snapshotUpperRoomSequence ?? 0) && $0.mediaID.uuidValue != nil }) ?? true
        else { throw V2ResourceValidationError.invalidDescriptor }
        self.roomID = roomID; self.actorUserID = actorUserID; self.query = query
        self.snapshotUpperRoomSequence = snapshotUpperRoomSequence; self.before = before
    }
    private enum CodingKeys: String, CodingKey { case roomID, actorUserID, query, snapshotUpperRoomSequence, before }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: c.decode(RoomID.self, forKey: .roomID), actorUserID: c.decode(UserID.self, forKey: .actorUserID),
            query: c.decode(V2RoomResourceQuery.self, forKey: .query), snapshotUpperRoomSequence: c.decodeIfPresent(UInt64.self, forKey: .snapshotUpperRoomSequence),
            before: c.decodeIfPresent(V2RoomResourcePosition.self, forKey: .before))
    }
}

public struct V2ActorRoomResourceDirectoryPageWire: Equatable, Codable, Sendable {
    public let items: [V2RoomResourceItem]
    public let snapshotUpperRoomSequence: UInt64
    public let hasMore: Bool
    public init(items: [V2RoomResourceItem], snapshotUpperRoomSequence: UInt64, hasMore: Bool) throws {
        guard items.count <= 100, snapshotUpperRoomSequence <= UInt64(Int64.max),
              items.allSatisfy({ $0.position.roomSequence <= snapshotUpperRoomSequence }), !hasMore || !items.isEmpty else {
            throw V2ResourceValidationError.invalidDescriptor
        }
        self.items = items; self.snapshotUpperRoomSequence = snapshotUpperRoomSequence; self.hasMore = hasMore
    }
    private enum CodingKeys: String, CodingKey { case items, snapshotUpperRoomSequence, hasMore }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(items: c.decode([V2RoomResourceItem].self, forKey: .items),
            snapshotUpperRoomSequence: c.decode(UInt64.self, forKey: .snapshotUpperRoomSequence), hasMore: c.decode(Bool.self, forKey: .hasMore))
    }
}
