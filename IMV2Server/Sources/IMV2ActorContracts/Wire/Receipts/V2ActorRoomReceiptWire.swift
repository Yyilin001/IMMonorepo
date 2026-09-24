import Foundation
import IMV2Core

public enum V2ActorRoomReceiptWireError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResult
}

public struct V2ActorRecordReadReceiptWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public let operationID: ReadReceiptOperationID
    public let readThroughRoomSequence: UInt64

    public init(roomID: RoomID, actorUserID: UserID, operationID: ReadReceiptOperationID,
                readThroughRoomSequence: UInt64) throws {
        _ = try V2RecordReadReceiptCommand(roomID: roomID, actorUserID: actorUserID,
                                            operationID: operationID,
                                            readThroughRoomSequence: readThroughRoomSequence)
        self.roomID = roomID; self.actorUserID = actorUserID
        self.operationID = operationID; self.readThroughRoomSequence = readThroughRoomSequence
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: values.decode(RoomID.self, forKey: .roomID),
                      actorUserID: values.decode(UserID.self, forKey: .actorUserID),
                      operationID: values.decode(ReadReceiptOperationID.self, forKey: .operationID),
                      readThroughRoomSequence: values.decode(UInt64.self, forKey: .readThroughRoomSequence))
    }

    private enum CodingKeys: String, CodingKey {
        case roomID, actorUserID, operationID, readThroughRoomSequence
    }
}

public struct V2ActorReadReceiptWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let userID: UserID
    public let readThroughRoomSequence: UInt64
    public let recordedAt: Date
    public init(roomID: RoomID, userID: UserID, readThroughRoomSequence: UInt64,
                recordedAt: Date) {
        self.roomID = roomID; self.userID = userID
        self.readThroughRoomSequence = readThroughRoomSequence; self.recordedAt = recordedAt
    }
}

public enum V2ActorRecordReadReceiptResultWire: Codable, Equatable, Sendable {
    case recorded(V2ActorReadReceiptWire)
    case idempotent(V2ActorReadReceiptWire)
    case idempotencyConflict
}

public struct V2ActorReadReceiptReadersQueryWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let actorUserID: UserID
    public let cursor: String?
    public let pageSize: Int

    public init(roomID: RoomID, messageID: MessageID, actorUserID: UserID,
                cursor: String?, pageSize: Int) throws {
        guard (1...100).contains(pageSize) else { throw V2ActorRoomReceiptWireError.invalidRequest }
        self.roomID = roomID; self.messageID = messageID
        self.actorUserID = actorUserID; self.cursor = cursor; self.pageSize = pageSize
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(roomID: values.decode(RoomID.self, forKey: .roomID),
                      messageID: values.decode(MessageID.self, forKey: .messageID),
                      actorUserID: values.decode(UserID.self, forKey: .actorUserID),
                      cursor: values.decodeIfPresent(String.self, forKey: .cursor),
                      pageSize: values.decode(Int.self, forKey: .pageSize))
    }
    private enum CodingKeys: String, CodingKey { case roomID, messageID, actorUserID, cursor, pageSize }
}

public struct V2ActorReadReceiptReaderWire: Codable, Equatable, Sendable {
    public let userID: UserID
    public let publicIdentity: V2ActorPublicIdentityWire
    public init(userID: UserID, publicIdentity: V2ActorPublicIdentityWire) {
        self.userID = userID; self.publicIdentity = publicIdentity
    }
}

public struct V2ActorReadReceiptReadersPageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let readers: [V2ActorReadReceiptReaderWire]
    public let nextCursor: String?
    public init(roomID: RoomID, messageID: MessageID,
                readers: [V2ActorReadReceiptReaderWire], nextCursor: String?) {
        self.roomID = roomID; self.messageID = messageID
        self.readers = readers; self.nextCursor = nextCursor
    }
}

public enum V2RoomReceiptCommand: Codable, Equatable, Sendable {
    case record(V2ActorRecordReadReceiptWire)
    public var roomID: RoomID {
        switch self { case .record(let value): value.roomID }
    }
    public var actorUserID: UserID {
        switch self { case .record(let value): value.actorUserID }
    }
    public var operationID: ReadReceiptOperationID {
        switch self { case .record(let value): value.operationID }
    }
    public var replayPolicy: V2RoomReplayPolicy { .durableIdempotent }
}

public enum V2RoomReceiptQuery: Codable, Equatable, Sendable {
    /// Legacy combined room/user read. Production transport rejects this;
    /// candidates must pass through authoritative control privacy filtering.
    case readers(V2ActorReadReceiptReadersQueryWire)
    case readerCandidates(V2ActorReadReceiptReadersQueryWire)
    public var roomID: RoomID {
        switch self { case .readers(let value), .readerCandidates(let value): value.roomID }
    }
    public var actorUserID: UserID {
        switch self { case .readers(let value), .readerCandidates(let value): value.actorUserID }
    }
    public var replayPolicy: V2RoomReplayPolicy { .readOnly }
}

public enum V2ActorRoomReceiptFailureWire: Codable, Equatable, Sendable {
    case store(V2ActorReadReceiptStoreErrorWire)
    case serverBusy
}

public enum V2RoomReceiptResult: Codable, Equatable, Sendable {
    case recordFailure(V2ActorRoomReceiptFailureWire)
    case readersFailure(V2ActorReadReceiptStoreErrorWire)
    case record(V2ActorRecordReadReceiptResultWire)
    case readers(V2ActorReadReceiptReadersPageWire)
    case readerCandidates(V2ActorReadReceiptCandidatePageWire)
}

/// Optional physical microbatch transport preserves one outcome or domain rejection per item.
/// It does not imply that a room actor loops over these requests sequentially.
public struct V2ActorReadReceiptRecordBatchWire: Codable, Equatable, Sendable {
    public let requests: [V2ActorRecordReadReceiptWire]
    public init(requests: [V2ActorRecordReadReceiptWire]) throws {
        guard (1...128).contains(requests.count) else { throw V2ActorRoomReceiptWireError.invalidRequest }
        self.requests = requests
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(requests: values.decode([V2ActorRecordReadReceiptWire].self, forKey: .requests))
    }
    private enum CodingKeys: String, CodingKey { case requests }
}

public enum V2ActorReadReceiptStoreErrorWire: String, Codable, Equatable, Sendable {
    case ownerChanged, roomNotFound, messageNotFound, actorNotMember
    case roomSequenceNotFound, invalidRequest, corruptPersistenceState
}

public enum V2ActorReadReceiptBatchItemResultWire: Codable, Equatable, Sendable {
    case success(V2ActorRecordReadReceiptResultWire)
    case failure(V2ActorReadReceiptStoreErrorWire)
}

public struct V2ActorReadReceiptRecordBatchResultWire: Codable, Equatable, Sendable {
    public let results: [V2ActorReadReceiptBatchItemResultWire]
    public init(results: [V2ActorReadReceiptBatchItemResultWire]) { self.results = results }
}

/// Room-owned facts only. Candidate identity disclosure must be checked in the
/// control database before any caller-facing reader page is assembled.
public struct V2ActorReadReceiptCandidateWire: Codable, Equatable, Sendable {
    public let userID: UserID
    public let readThroughRoomSequence: UInt64
    public init(userID: UserID, readThroughRoomSequence: UInt64) {
        self.userID = userID
        self.readThroughRoomSequence = readThroughRoomSequence
    }
}

public struct V2ActorReadReceiptCandidatePageWire: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let candidates: [V2ActorReadReceiptCandidateWire]
    public let nextCursor: String?
    public init(roomID: RoomID, messageID: MessageID,
                candidates: [V2ActorReadReceiptCandidateWire], nextCursor: String?) {
        self.roomID = roomID
        self.messageID = messageID
        self.candidates = candidates
        self.nextCursor = nextCursor
    }
}
