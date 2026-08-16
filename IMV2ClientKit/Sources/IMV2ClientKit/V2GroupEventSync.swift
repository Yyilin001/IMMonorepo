import Foundation
import IMV2Core

public struct V2ClientGroupEvent: Equatable, Sendable {
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

public struct V2ClientGroupEventPage: Equatable, Sendable {
    public let roomID: RoomID
    public let events: [V2ClientGroupEvent]
    public let nextRoomSequence: UInt64
    public let hasMore: Bool

    public init(roomID: RoomID, events: [V2ClientGroupEvent], nextRoomSequence: UInt64, hasMore: Bool) {
        self.roomID = roomID
        self.events = events
        self.nextRoomSequence = nextRoomSequence
        self.hasMore = hasMore
    }
}

/// The result of one bounded room-log pull. Keeping this separate from the
/// page makes foreground callers able to refresh their UI only after durable
/// local projection has actually advanced.
public struct V2GroupEventSyncProgress: Equatable, Sendable {
    public let appliedEventCount: Int
    public let hasMore: Bool

    public init(appliedEventCount: Int, hasMore: Bool) {
        self.appliedEventCount = appliedEventCount
        self.hasMore = hasMore
    }
}

/// Bounded maintenance work completed after a personal-sync cycle.  This is
/// intentionally page-based rather than room-based: a single large history
/// cannot consume the entire foreground reconnect budget.
public struct V2GroupEventBackgroundSyncProgress: Equatable, Sendable {
    public let processedPageCount: Int
    public let appliedEventCount: Int
    /// `true` means the caller used its complete page budget and should allow
    /// a later availability cycle to continue from the persisted cursors.
    public let mayHaveRemainingWork: Bool

    public init(processedPageCount: Int, appliedEventCount: Int, mayHaveRemainingWork: Bool) {
        self.processedPageCount = processedPageCount
        self.appliedEventCount = appliedEventCount
        self.mayHaveRemainingWork = mayHaveRemainingWork
    }
}

public protocol V2ClientGroupEventTransport: Sendable {
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage
}

public struct V2ClientGroupEventSubscription: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64

    public init(roomID: RoomID, highWatermark: UInt64) {
        self.roomID = roomID
        self.highWatermark = highWatermark
    }
}

/// Foreground subscription control is intentionally distinct from durable
/// event reads so callers cannot mistake a wake for a delivered message.
public protocol V2ClientGroupEventSubscriptionTransport: Sendable {
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription
    func unsubscribeFromGroupEvents(roomID: RoomID) async throws
}

public protocol V2LocalGroupEventStore: Sendable {
    /// Only rooms explicitly created as hybrid are eligible for room-log
    /// synchronization. The mode is a durable room invariant, not a runtime
    /// heuristic based on the current member count.
    func knownHybridGroupRoomIDs(after roomID: RoomID?, limit: Int) async throws -> [RoomID]
    /// Durable keyset cursor for fair background scheduling. This cursor is
    /// only a scheduling hint; per-room event cursors remain the delivery
    /// authority.
    func hybridGroupBackgroundCursor() async throws -> RoomID?
    func setHybridGroupBackgroundCursor(_ roomID: RoomID?) async throws
    func isKnownHybridGroupRoom(roomID: RoomID) async throws -> Bool
    /// Stops room-log pulls after the authoritative server says this device's
    /// user is no longer a member. Historical local projections remain
    /// readable; only the eligibility marker is cleared.
    func deactivateHybridGroupRoom(roomID: RoomID) async throws
    func groupEventCursor(roomID: RoomID) async throws -> UInt64
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) async throws -> UInt64
}

/// Foreground preview for a standard fan-out group deliberately has a
/// separate local-store contract.  Its cursor is process-local, never a
/// durable acknowledgement: `user_sync_log` remains the recovery and ACK
/// authority for standard groups.
public protocol V2LocalForegroundGroupEventPreviewStore: Sendable {
    /// Returns the immutable delivery mode from the locally projected room
    /// profile. `nil` means this device does not currently know a group room.
    func groupDeliveryMode(roomID: RoomID) async throws -> V2GroupDeliveryMode?
    /// A safe lower bound for an in-memory preview cursor. It may cause a
    /// duplicate pull after restart, but may never skip a room event.
    func foregroundGroupEventPreviewStartSequence(roomID: RoomID) async throws -> UInt64
    /// Applies a transient foreground page idempotently without writing a
    /// group-event cursor or treating it as a durable user-sync ACK.
    func applyForegroundGroupEventPreviewPage(_ page: V2ClientGroupEventPage) async throws -> UInt64
}

/// Serializes a room's cursor advancement. Each room event is projected in
/// the same SQLite transaction as its cursor, so a crash retries the exact
/// page and cannot skip a visible event.
public actor V2GroupEventSyncEngine {
    private let transport: any V2ClientGroupEventTransport
    private let store: any V2LocalGroupEventStore
    private let pageSize: Int

    public init(transport: any V2ClientGroupEventTransport, store: any V2LocalGroupEventStore, pageSize: Int = 200) {
        precondition(pageSize > 0 && pageSize <= V2GroupEventLogLimits.maximumPageSize)
        self.transport = transport
        self.store = store
        self.pageSize = pageSize
    }

    public func synchronizeOnePage(roomID: RoomID) async throws -> V2GroupEventSyncProgress {
        let cursor = try await store.groupEventCursor(roomID: roomID)
        let page = try await transport.pullGroupEvents(roomID: roomID, afterRoomSequence: cursor, pageSize: pageSize)
        guard page.roomID == roomID else { throw V2RealtimeTransportError.unexpectedResponse }
        _ = try await store.applyGroupEventPage(page)
        return .init(appliedEventCount: page.events.count, hasMore: page.hasMore)
    }

    public func synchronizeUntilCaughtUp(roomID: RoomID) async throws {
        while (try await synchronizeOnePage(roomID: roomID)).hasMore {
            try Task.checkCancellation()
        }
    }

    /// Performs a fair, bounded maintenance pass over known hybrid groups.
    /// Active conversations use `synchronizeOnePage(roomID:)` directly and
    /// therefore never wait behind this background work.  One page is taken
    /// per room before moving to the next, preserving bounded network/SQLite
    /// work while preventing a large backlog from starving quieter rooms.
    public func synchronizeBackgroundKnownRooms(maximumPages: Int) async throws -> V2GroupEventBackgroundSyncProgress {
        precondition(maximumPages > 0 && maximumPages <= 10_000)
        let cursor = try await store.hybridGroupBackgroundCursor()
        let probeLimit = maximumPages + 1
        var roomIDs = try await store.knownHybridGroupRoomIDs(after: cursor, limit: probeLimit)
        if cursor != nil, roomIDs.count < probeLimit {
            let wrapped = try await store.knownHybridGroupRoomIDs(after: nil, limit: probeLimit - roomIDs.count)
            var seen = Set(roomIDs)
            roomIDs.append(contentsOf: wrapped.filter { seen.insert($0).inserted })
        }
        guard !roomIDs.isEmpty else {
            try await store.setHybridGroupBackgroundCursor(nil)
            return .init(processedPageCount: 0, appliedEventCount: 0, mayHaveRemainingWork: false)
        }
        let hasUnscheduledRoom = roomIDs.count > maximumPages
        if hasUnscheduledRoom {
            roomIDs.removeLast(roomIDs.count - maximumPages)
        }
        var processedPages = 0
        var appliedEvents = 0
        var roomHasMoreEvents = false
        for roomID in roomIDs {
            try Task.checkCancellation()
            // A forbidden response is still one bounded background attempt;
            // otherwise a batch containing only revoked rooms could loop
            // forever while repeatedly deactivating the same stale entry.
            processedPages += 1
            do {
                let progress = try await synchronizeOnePage(roomID: roomID)
                appliedEvents += progress.appliedEventCount
                roomHasMoreEvents = roomHasMoreEvents || progress.hasMore
            } catch let error as V2RealtimeTransportError {
                guard case .server(let code, _, _, _) = error, code == "FORBIDDEN" else { throw error }
                try await store.deactivateHybridGroupRoom(roomID: roomID)
            }
            // Persist after each bounded attempt. A crash can repeat the last
            // room but cannot reset every restart to the lexicographically
            // first room and starve the tail of a large room set.
            try await store.setHybridGroupBackgroundCursor(roomID)
        }
        return .init(
            processedPageCount: processedPages,
            appliedEventCount: appliedEvents,
            mayHaveRemainingWork: hasUnscheduledRoom || roomHasMoreEvents
        )
    }
}

/// Best-effort, view-owned acceleration for a standard fan-out group. The
/// engine keeps its cursor only in memory; a reconnect or process restart
/// safely falls back to reliable per-user sync and may repeat projections.
public actor V2ForegroundGroupEventPreviewEngine {
    private let transport: any V2ClientGroupEventTransport
    private let store: any V2LocalForegroundGroupEventPreviewStore
    private let pageSize: Int
    private var cursors: [RoomID: UInt64] = [:]

    public init(
        transport: any V2ClientGroupEventTransport,
        store: any V2LocalForegroundGroupEventPreviewStore,
        pageSize: Int = 200
    ) {
        precondition(pageSize > 0 && pageSize <= V2GroupEventLogLimits.maximumPageSize)
        self.transport = transport
        self.store = store
        self.pageSize = pageSize
    }

    public func cursor(roomID: RoomID) async throws -> UInt64 {
        if let cursor = cursors[roomID] { return cursor }
        let cursor = try await store.foregroundGroupEventPreviewStartSequence(roomID: roomID)
        cursors[roomID] = cursor
        return cursor
    }

    public func synchronizeOnePage(roomID: RoomID) async throws -> V2GroupEventSyncProgress {
        let cursor = try await cursor(roomID: roomID)
        let page = try await transport.pullGroupEvents(roomID: roomID, afterRoomSequence: cursor, pageSize: pageSize)
        guard page.roomID == roomID,
              page.nextRoomSequence >= cursor,
              (page.events.last?.roomSequence ?? cursor) == page.nextRoomSequence,
              zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence })
        else { throw V2RealtimeTransportError.unexpectedResponse }
        _ = try await store.applyForegroundGroupEventPreviewPage(page)
        cursors[roomID] = page.nextRoomSequence
        return .init(appliedEventCount: page.events.count, hasMore: page.hasMore)
    }

    public func forget(roomID: RoomID) {
        cursors.removeValue(forKey: roomID)
    }
}

public enum V2GroupEventLogLimits {
    public static let maximumPageSize = 500
}
