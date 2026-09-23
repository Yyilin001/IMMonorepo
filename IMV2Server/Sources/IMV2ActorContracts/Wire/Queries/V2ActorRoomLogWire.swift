import Foundation
import IMV2Core

public enum V2ActorRoomLogWireError: Error, Equatable, Sendable {
    case invalidPageSize
    case invalidSequence
}

public struct V2ActorRoomLogPullWire: Equatable, Codable, Sendable {
    public static let maximumPageSize = 500
    public let roomID: RoomID
    public let actorUserID: UserID
    public let afterRoomSequence: UInt64
    public let pageSize: Int

    public init(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) throws {
        guard (1...Self.maximumPageSize).contains(pageSize) else {
            throw V2ActorRoomLogWireError.invalidPageSize
        }
        _ = try V2RoomCursor(afterRoomSequence)
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.afterRoomSequence = afterRoomSequence
        self.pageSize = pageSize
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            roomID: values.decode(RoomID.self, forKey: .roomID),
            actorUserID: values.decode(UserID.self, forKey: .actorUserID),
            afterRoomSequence: values.decode(UInt64.self, forKey: .afterRoomSequence),
            pageSize: values.decode(Int.self, forKey: .pageSize)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case roomID, actorUserID, afterRoomSequence, pageSize
    }
}

public struct V2ActorRoomLogSubscribeWire: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID

    public init(roomID: RoomID, actorUserID: UserID) {
        self.roomID = roomID
        self.actorUserID = actorUserID
    }
}

/// Payload is the existing canonical encoded room event, not an arbitrary RPC
/// operation. Event identity, ordering and projection kind remain explicit.
public struct V2ActorRoomLogEntryWire: Equatable, Codable, Sendable {
    public let sourceEventID: EventID
    public let roomSequence: UInt64
    public let projectionKind: String
    public let payload: Data

    public init(sourceEventID: EventID, roomSequence: UInt64, projectionKind: String, payload: Data) throws {
        guard roomSequence > 0 else { throw V2ActorRoomLogWireError.invalidSequence }
        _ = try V2RoomCursor(roomSequence)
        self.sourceEventID = sourceEventID
        self.roomSequence = roomSequence
        self.projectionKind = projectionKind
        self.payload = payload
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sourceEventID: values.decode(EventID.self, forKey: .sourceEventID),
            roomSequence: values.decode(UInt64.self, forKey: .roomSequence),
            projectionKind: values.decode(String.self, forKey: .projectionKind),
            payload: values.decode(Data.self, forKey: .payload)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourceEventID, roomSequence, projectionKind, payload
    }
}

public struct V2ActorRoomLogPageWire: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let events: [V2ActorRoomLogEntryWire]
    public let nextRoomSequence: UInt64
    public let hasMore: Bool
    public let logTrimmedThroughRoomSequence: UInt64

    public init(
        roomID: RoomID, events: [V2ActorRoomLogEntryWire], nextRoomSequence: UInt64,
        hasMore: Bool, logTrimmedThroughRoomSequence: UInt64
    ) throws {
        _ = try V2RoomCursor(nextRoomSequence)
        _ = try V2RoomCursor(logTrimmedThroughRoomSequence)
        guard events.count <= V2ActorRoomLogPullWire.maximumPageSize else {
            throw V2ActorRoomLogWireError.invalidPageSize
        }
        self.roomID = roomID
        self.events = events
        self.nextRoomSequence = nextRoomSequence
        self.hasMore = hasMore
        self.logTrimmedThroughRoomSequence = logTrimmedThroughRoomSequence
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            roomID: values.decode(RoomID.self, forKey: .roomID),
            events: values.decode([V2ActorRoomLogEntryWire].self, forKey: .events),
            nextRoomSequence: values.decode(UInt64.self, forKey: .nextRoomSequence),
            hasMore: values.decode(Bool.self, forKey: .hasMore),
            logTrimmedThroughRoomSequence: values.decode(UInt64.self, forKey: .logTrimmedThroughRoomSequence)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case roomID, events, nextRoomSequence, hasMore, logTrimmedThroughRoomSequence
    }
}

public struct V2ActorRoomLogSubscriptionWire: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64
    public let membershipRevision: UInt64

    public init(roomID: RoomID, highWatermark: UInt64, membershipRevision: UInt64) throws {
        _ = try V2RoomCursor(highWatermark)
        _ = try V2MembershipRevision(membershipRevision)
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.membershipRevision = membershipRevision
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            roomID: values.decode(RoomID.self, forKey: .roomID),
            highWatermark: values.decode(UInt64.self, forKey: .highWatermark),
            membershipRevision: values.decode(UInt64.self, forKey: .membershipRevision)
        )
    }

    private enum CodingKeys: String, CodingKey { case roomID, highWatermark, membershipRevision }
}

public enum V2RoomLogQuery: Equatable, Codable, Sendable {
    case pull(V2ActorRoomLogPullWire)
    case subscribe(V2ActorRoomLogSubscribeWire)

    public var roomID: RoomID {
        switch self {
        case .pull(let request): request.roomID
        case .subscribe(let request): request.roomID
        }
    }

    public var actorUserID: UserID {
        switch self {
        case .pull(let request): request.actorUserID
        case .subscribe(let request): request.actorUserID
        }
    }

    /// Subscribe here only observes eligibility/watermarks. Host interest
    /// registration is a separately versioned lifecycle operation.
    public var replayPolicy: V2RoomReplayPolicy { .readOnly }
}

public enum V2RoomLogQueryResult: Equatable, Codable, Sendable {
    case page(V2ActorRoomLogPageWire)
    case subscription(V2ActorRoomLogSubscriptionWire)
}
