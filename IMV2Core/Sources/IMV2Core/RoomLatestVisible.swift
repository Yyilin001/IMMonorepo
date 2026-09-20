import Foundation

/// A display candidate observed with the room's authority and head in one snapshot.
/// It never proves that the client's content cursor has reached that head.
public struct V2RoomLatestVisible: Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public let id: MessageID
        public let senderID: UserID
        public let sequence: UInt64
        public let revision: UInt64
        public let preview: String
        public let mediaCount: Int
        public let createdAt: Date

        public init(id: MessageID, senderID: UserID, sequence: UInt64, revision: UInt64,
                    preview: String, mediaCount: Int, createdAt: Date) throws {
            guard sequence > 0, sequence <= UInt64(Int64.max), revision > 0, revision <= UInt64(Int64.max),
                  preview.utf8.count <= 512, mediaCount >= 0, createdAt.timeIntervalSince1970.isFinite
            else { throw V2RoomSynchronizationError.invalidState }
            self.id = id; self.senderID = senderID; self.sequence = sequence; self.revision = revision
            self.preview = preview; self.mediaCount = mediaCount; self.createdAt = createdAt
        }
    }

    public let roomID: RoomID
    public let ownerEpoch: UInt64
    public let membershipRevision: UInt64
    public let head: UInt64
    public let latest: Message?

    public init(roomID: RoomID, ownerEpoch: UInt64, membershipRevision: UInt64, head: UInt64, latest: Message?) throws {
        guard ownerEpoch <= UInt64(Int64.max), membershipRevision > 0, membershipRevision <= UInt64(Int64.max),
              head <= UInt64(Int64.max), (latest?.sequence ?? 0) <= head
        else { throw V2RoomSynchronizationError.invalidState }
        self.roomID = roomID; self.ownerEpoch = ownerEpoch; self.membershipRevision = membershipRevision
        self.head = head; self.latest = latest
    }
}
