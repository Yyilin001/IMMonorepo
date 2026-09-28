import IMV2Core
public struct V2MessageModerationBaselineQuery: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let messageID: MessageID
    public init(roomID:RoomID,actorUserID:UserID,messageID:MessageID) {
        self.roomID=roomID;self.actorUserID=actorUserID;self.messageID=messageID
    }
}
