import Foundation

/// A read receipt is an explicit user-viewing assertion, intentionally
/// separate from a device's transport or sync acknowledgement. Its room
/// watermark can only advance.
public struct V2RecordReadReceiptCommand: Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: ReadReceiptOperationID
    public let readThroughRoomSequence: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) throws {
        guard readThroughRoomSequence > 0 else { throw V2ReadReceiptValidationError.invalidRoomSequence }
        self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID
        self.readThroughRoomSequence = readThroughRoomSequence
    }
}

public struct V2ReadReceipt: Equatable, Sendable {
    public let roomID: RoomID
    public let userID: UserID
    public let readThroughRoomSequence: UInt64
    public let recordedAt: Date

    public init(roomID: RoomID, userID: UserID, readThroughRoomSequence: UInt64, recordedAt: Date) {
        self.roomID = roomID; self.userID = userID
        self.readThroughRoomSequence = readThroughRoomSequence; self.recordedAt = recordedAt
    }
}

public enum V2ReadReceiptValidationError: Error, Equatable, Sendable { case invalidRoomSequence }
