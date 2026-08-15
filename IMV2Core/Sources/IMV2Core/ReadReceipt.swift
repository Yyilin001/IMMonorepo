import Foundation

/// Device-independent disclosure controls.  Receipt collection remains a
/// local viewing fact; these settings determine whether it is observable by
/// another participant.  Direct receipts are reciprocal at the server: both
/// participants must opt in before either can observe the other.
public struct V2ReadReceiptPreferences: Equatable, Sendable {
    public let allowsDirectReadReceipts: Bool
    public let allowsGroupReadReceipts: Bool
    public let updatedAt: Date

    public init(allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool, updatedAt: Date) {
        self.allowsDirectReadReceipts = allowsDirectReadReceipts
        self.allowsGroupReadReceipts = allowsGroupReadReceipts
        self.updatedAt = updatedAt
    }
}

public struct V2SetReadReceiptPreferencesCommand: Equatable, Sendable {
    public let actorUserID: UserID
    public let operationID: ReadReceiptPreferenceOperationID
    public let allowsDirectReadReceipts: Bool
    public let allowsGroupReadReceipts: Bool

    public init(actorUserID: UserID, operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) {
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.allowsDirectReadReceipts = allowsDirectReadReceipts
        self.allowsGroupReadReceipts = allowsGroupReadReceipts
    }
}

/// A direct-room receipt is delivered only to the counterpart, through that
/// user's durable sync stream. `isVisible == false` is a privacy tombstone
/// and must remove any locally cached receipt immediately.
public struct V2DirectReadReceiptProjection: Equatable, Sendable {
    public let roomID: RoomID
    public let readerUserID: UserID
    public let readThroughRoomSequence: UInt64
    public let recordedAt: Date
    public let isVisible: Bool

    public init(roomID: RoomID, readerUserID: UserID, readThroughRoomSequence: UInt64, recordedAt: Date, isVisible: Bool) {
        self.roomID = roomID
        self.readerUserID = readerUserID
        self.readThroughRoomSequence = readThroughRoomSequence
        self.recordedAt = recordedAt
        self.isVisible = isVisible
    }
}

public struct V2ReadReceiptReader: Equatable, Sendable {
    public let userID: UserID
    /// Bounded profile presentation for an active account that belonged to the
    /// message audience and remains in the group at the page's bound revision.
    /// The opaque user ID is retained for pagination correctness, never display.
    public let publicIdentity: V2PublicIdentity

    public init(userID: UserID, publicIdentity: V2PublicIdentity) {
        precondition(publicIdentity.userID == userID)
        self.userID = userID
        self.publicIdentity = publicIdentity
    }
}

public struct V2ReadReceiptReadersPage: Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let readers: [V2ReadReceiptReader]
    public let nextCursor: String?

    public init(roomID: RoomID, messageID: MessageID, readers: [V2ReadReceiptReader], nextCursor: String?) throws {
        guard Set(readers.map(\.userID)).count == readers.count else {
            throw V2ReadReceiptValidationError.invalidReaderPage
        }
        self.roomID = roomID
        self.messageID = messageID
        self.readers = readers; self.nextCursor = nextCursor
    }
}

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

public enum V2ReadReceiptValidationError: Error, Equatable, Sendable { case invalidRoomSequence, invalidReaderPage }
