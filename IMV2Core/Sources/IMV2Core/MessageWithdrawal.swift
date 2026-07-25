import Foundation

/// A withdrawal is a revision-fenced tombstone command. The message record is
/// retained for ordering and audit; consumers render the later tombstone event
/// instead of physically deleting history in the request path.
public struct V2WithdrawMessageCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageWithdrawalOperationID
    public let messageID: MessageID
    public let expectedMessageRevision: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedMessageRevision = expectedMessageRevision
    }
}

public struct V2MessageWithdrawal: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let messageRevision: UInt64
    public let roomSequence: UInt64
    public let eventID: EventID
    public let fanoutPlanID: FanoutPlanID
    public let createdAt: Date

    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) {
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}
