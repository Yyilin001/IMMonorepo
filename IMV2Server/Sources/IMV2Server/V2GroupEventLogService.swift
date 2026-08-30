import Foundation
import IMV2Core

public struct V2GroupEventLogEntry: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomSequence: UInt64
    public let projectionKind: String
    public let payload: Data

    public init(sourceEventID: EventID, roomSequence: UInt64, projectionKind: String, payload: Data) {
        self.sourceEventID = sourceEventID
        self.roomSequence = roomSequence
        self.projectionKind = projectionKind
        self.payload = payload
    }
}

public struct V2GroupEventLogPage: Equatable, Sendable {
    public let roomID: RoomID
    public let events: [V2GroupEventLogEntry]
    public let nextRoomSequence: UInt64
    public let hasMore: Bool

    public init(roomID: RoomID, events: [V2GroupEventLogEntry], nextRoomSequence: UInt64, hasMore: Bool) {
        self.roomID = roomID
        self.events = events
        self.nextRoomSequence = nextRoomSequence
        self.hasMore = hasMore
    }
}

/// A successful foreground subscription proves only current room eligibility
/// and exposes the durable room-log waterline. It is not a delivery receipt.
public struct V2GroupEventSubscription: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64

    public init(roomID: RoomID, highWatermark: UInt64) {
        self.roomID = roomID
        self.highWatermark = highWatermark
    }
}

public enum V2GroupEventLogError: Error, Equatable, Sendable {
    case invalidRequest
    case roomNotFound
    case actorNotMember
    case corruptPersistenceState
}

public protocol V2GroupEventLogStore: Sendable {
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription
}

// Pull is deliberately independent from user-sync ACKs. Hybrid rooms retain a
// durable local room cursor; standard rooms use it only as a foreground
// preview and keep user-sync as the acknowledgement authority. Retries are
// idempotent because projections key on source event ID.
public struct V2GroupEventLogService: Sendable {
    public static let maximumPageSize = 500

    private let store: any V2GroupEventLogStore
    private let directRoomLogEventCache: V2DirectRoomLogEventCache?

    public init(
        store: any V2GroupEventLogStore,
        directRoomLogEventCache: V2DirectRoomLogEventCache? = nil
    ) {
        self.store = store
        self.directRoomLogEventCache = directRoomLogEventCache
    }

    public func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        guard afterRoomSequence <= UInt64(Int64.max),
              pageSize > 0,
              pageSize <= Self.maximumPageSize
        else { throw V2GroupEventLogError.invalidRequest }
        return try await store.pull(roomID: roomID, actorUserID: actorUserID, afterRoomSequence: afterRoomSequence, pageSize: pageSize)
    }

    /// Verifies that a foreground connection may subscribe before the gateway
    /// retains any process-local watcher state. The caller must still pull by
    /// cursor after this result, because the room can advance immediately.
    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        try await store.subscribe(roomID: roomID, actorUserID: actorUserID)
    }

    /// Best-effort local read acceleration after the message transaction has
    /// committed. The durable cursor log remains the recovery path if this
    /// process is restarted, another gateway accepted the message, or the
    /// event does not fit the plain direct-message cache contract.
    public func recordCommittedDirectRoomLogMessage(_ message: V2AcceptedMessage) {
        directRoomLogEventCache?.enqueueCommittedPlainDirectMessage(message)
    }

    /// Reuses the payload already materialized for foreground delivery. The
    /// cache remains best effort and never becomes an authorization source.
    func recordCommittedDirectRoomLogEvent(_ event: V2DirectRoomLiveEvent) {
        directRoomLogEventCache?.enqueueCommittedPlainDirectEvent(event)
    }
}
