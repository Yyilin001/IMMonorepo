import Foundation
import IMV2Compression
import IMV2Core

public struct V2GroupEventLogEntry: Equatable, Sendable {
    public let sourceEventID: EventID
    public let roomSequence: UInt64
    public let projectionKind: String
    public let payload: Data

    public init(sourceEventID: EventID, roomSequence: UInt64, projectionKind: String, payload: Data) throws {
        guard (try? V2RoomCursor(roomSequence)) != nil, roomSequence > 0 else { throw V2GroupEventLogError.corruptPersistenceState }
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

    public init(roomID: RoomID, events: [V2GroupEventLogEntry], nextRoomSequence: UInt64, hasMore: Bool) throws {
        guard (try? V2RoomCursor(nextRoomSequence)) != nil else { throw V2GroupEventLogError.corruptPersistenceState }
        self.roomID = roomID
        self.events = events
        self.nextRoomSequence = nextRoomSequence
        self.hasMore = hasMore
    }
}

struct V2PreparedGroupEventPageEncodingContext: Sendable {
    let requestID: UInt64
    let frameVersion: UInt8
    let compression: V2NegotiatedFrameCompression?
    let maximumUncompressedPayloadBytes: Int
    let compressionThresholdBytes: Int
    let maximumExpansionRatio: Int
    let maximumGroupEventPagePayloadBytes: Int
    let cache: V2PreparedGroupEventPageCache
}

struct V2PreparedGroupEventPageResponse: Sendable {
    let frame: V2Frame
    let roomID: RoomID
    let nextRoomSequence: UInt64
    let hasMore: Bool
}

enum V2PreparedGroupEventPullResult: Sendable {
    case prepared(V2PreparedGroupEventPageResponse)
    case page(V2GroupEventLogPage)
    case eventTooLarge
}

/// A successful foreground subscription proves only current room eligibility
/// and exposes the durable room-log waterline. It is not a delivery receipt.
public struct V2GroupEventSubscription: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64
    /// Durable room membership epoch that authorized this subscription.
    /// Foreground group payloads are routed only when their commit epoch is
    /// exactly equal, so a membership change fails closed without enumerating
    /// the room audience on every message.
    public let membershipRevision: UInt64

    public init(roomID: RoomID, highWatermark: UInt64, membershipRevision: UInt64 = 0) throws {
        guard (try? V2RoomCursor(highWatermark)) != nil, (try? V2MembershipRevision(membershipRevision)) != nil else { throw V2GroupEventLogError.corruptPersistenceState }
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.membershipRevision = membershipRevision
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

protocol V2PreparedGroupEventLogStore: V2GroupEventLogStore {
    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult
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
        guard (try? V2RoomCursor(afterRoomSequence)) != nil,
              pageSize > 0,
              pageSize <= Self.maximumPageSize
        else { throw V2GroupEventLogError.invalidRequest }
        return try validatePage(await store.pull(roomID: roomID, actorUserID: actorUserID, afterRoomSequence: afterRoomSequence, pageSize: pageSize), after: afterRoomSequence)
    }

    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult {
        guard (try? V2RoomCursor(afterRoomSequence)) != nil,
              pageSize > 0,
              pageSize <= Self.maximumPageSize,
              context.frameVersion >= 21
        else { throw V2GroupEventLogError.invalidRequest }
        guard let preparedStore = store as? any V2PreparedGroupEventLogStore else {
            return .page(try validatePage(await store.pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ), after: afterRoomSequence))
        }
        let result = try await preparedStore.pullPrepared(
            roomID: roomID,
            actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        )
        if case .page(let page) = result { return .page(try validatePage(page, after: afterRoomSequence)) }
        if case .prepared(let response) = result {
            guard response.nextRoomSequence <= UInt64(Int64.max),
                  response.nextRoomSequence >= afterRoomSequence,
                  !response.hasMore || response.nextRoomSequence > afterRoomSequence
            else { throw V2GroupEventLogError.corruptPersistenceState }
        }
        return result
    }

    private func validatePage(_ page: V2GroupEventLogPage, after: UInt64) throws -> V2GroupEventLogPage {
        guard page.nextRoomSequence <= UInt64(Int64.max), page.nextRoomSequence >= after,
              !page.hasMore || page.nextRoomSequence > after
        else { throw V2GroupEventLogError.corruptPersistenceState }
        var previous = after
        for event in page.events {
            guard event.roomSequence > previous, event.roomSequence <= page.nextRoomSequence else {
                throw V2GroupEventLogError.corruptPersistenceState
            }
            previous = event.roomSequence
        }
        return page
    }

    /// Verifies that a foreground connection may subscribe before the gateway
    /// retains any process-local watcher state. The caller must still pull by
    /// cursor after this result, because the room can advance immediately.
    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        let subscription = try await store.subscribe(roomID: roomID, actorUserID: actorUserID)
        guard subscription.highWatermark <= UInt64(Int64.max),
              subscription.membershipRevision <= UInt64(Int64.max)
        else { throw V2GroupEventLogError.corruptPersistenceState }
        return subscription
    }

    /// Best-effort local read acceleration after the message transaction has
    /// committed. The durable cursor log remains the recovery path if this
    /// process is restarted, another gateway accepted the message, or the
    /// event does not fit the plain direct-message cache contract.
    public func recordCommittedDirectRoomLogMessage(_ message: V2AcceptedMessage) async {
        await directRoomLogEventCache?.recordCommittedPlainDirectMessage(message)
    }

    /// Reuses the payload already materialized for foreground delivery. The
    /// cache remains best effort and never becomes an authorization source.
    func recordCommittedDirectRoomLogEvent(_ event: V2DirectRoomLiveEvent) async {
        // Do not make the acceptance/foreground path wait for the cache
        // actor's LRU mutation. The cache already owns a bounded, room-sharded
        // mailbox whose writer preserves per-lane order; a mailbox miss or
        // overflow merely sends the later authorized pull to PostgreSQL.
        directRoomLogEventCache?.enqueueCommittedPlainDirectEvent(event)
    }

    /// Seeds this Gateway's recovery cache from an already-validated
    /// cross-Gateway foreground relay. Core NATS is deliberately lossy, so
    /// these entries never replace the durable room log: an absent sequence,
    /// mailbox overflow or process restart still falls back to PostgreSQL.
    ///
    /// Enqueueing before the socket notification closes the common race where
    /// a client observes a later watermark and immediately asks this Gateway
    /// to repair a gap. The cache candidate carries no identity and every page
    /// remains behind the store's fresh membership-revision fence.
    public func recordRelayedForegroundEvents(_ events: [V2DirectRoomLiveEvent]) {
        guard let directRoomLogEventCache else { return }
        directRoomLogEventCache.enqueueCommittedPlainDirectEvents(events)
    }
}
