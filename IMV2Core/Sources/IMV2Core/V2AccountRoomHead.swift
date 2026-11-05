import Foundation

/// A durable account hint, never a membership grant or a copy of room content.
/// Delivery may be reordered across workers; consumers retain the highest head.
public struct V2AccountRoomHead: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let membershipRevision: UInt64

    public init(roomID: RoomID, roomSequence: UInt64, membershipRevision: UInt64) throws {
        guard roomID.uuidValue != nil, roomSequence > 0, roomSequence <= UInt64(Int64.max),
              membershipRevision <= UInt64(Int64.max) else { throw V2CoreError.invalidPositiveValue }
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.membershipRevision = membershipRevision
    }

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id", roomSequence = "room_sequence", membershipRevision = "membership_revision"
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: RoomID(values.decode(String.self, forKey: .roomID)),
            roomSequence: values.decode(UInt64.self, forKey: .roomSequence),
            membershipRevision: values.decode(UInt64.self, forKey: .membershipRevision))
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(roomID.rawValue, forKey: .roomID)
        try values.encode(roomSequence, forKey: .roomSequence)
        try values.encode(membershipRevision, forKey: .membershipRevision)
    }
}
