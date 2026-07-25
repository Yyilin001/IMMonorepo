import Foundation

/// An edit replaces only a message's mutable text and is fenced by the
/// caller's observed content revision. A later withdrawal always wins over an
/// edit because the authoritative transaction rejects withdrawn messages.
public struct V2EditMessageCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageEditOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64
    public let text: String

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String, maximumUTF8Bytes: Int) throws {
        guard maximumUTF8Bytes > 0,
              !text.isEmpty,
              text.utf8.count <= maximumUTF8Bytes
        else { throw V2MessageEditValidationError.invalidText }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
        self.text = text
    }
}

public struct V2MessageEdit: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let text: String
    public let messageRevision: UInt64
    public let roomSequence: UInt64
    public let eventID: EventID
    public let fanoutPlanID: FanoutPlanID
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, text: String, messageRevision: UInt64, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.text = text
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}

public enum V2MessageEditValidationError: Error, Equatable, Sendable {
    case invalidText
}
