import Foundation

/// A withdrawal is a revision-fenced tombstone command. The message record is
/// retained for ordering and audit; consumers render the later tombstone event
/// instead of physically deleting history in the request path.
public struct V2WithdrawMessageCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: MessageWithdrawalOperationID
    public let messageID: MessageID
    public let expectedRevision: V2MessageRevision
    public var expectedMessageRevision: UInt64 { expectedRevision.rawValue }

    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) throws {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedRevision = try .init(expectedMessageRevision)
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

    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) throws {
        guard messageRevision > 0, messageRevision <= UInt64(Int64.max),
              roomSequence > 0, roomSequence <= UInt64(Int64.max)
        else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}
