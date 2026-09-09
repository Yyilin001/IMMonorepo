/// The authoritative message that gives a conversation attachment its room
/// owner and visibility context. This is a locator, never authorization.
public struct V2MediaMessageLocation: Equatable, Hashable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public init(roomID: RoomID, messageID: MessageID) {
        self.roomID = roomID
        self.messageID = messageID
    }
}
