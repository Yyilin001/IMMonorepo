import Foundation
import IMV2Core

public struct V2ClientGroupEvent: Equatable, Sendable {
    public let sourceEventID: EventID
    private let roomSequenceValue: V2RoomCursor
    public var roomSequence: UInt64 { roomSequenceValue.rawValue }
    public let projectionKind: String
    public let payload: Data

    public init(sourceEventID: EventID, roomSequence: UInt64, projectionKind: String, payload: Data) throws {
        guard let cursor = try? V2RoomCursor(roomSequence) else { throw V2ClientSyncError.storageRangeExceeded }
        guard roomSequence > 0 else { throw V2ClientSyncError.invalidRecordOrdering }
        self.sourceEventID = sourceEventID
        self.roomSequenceValue = cursor
        self.projectionKind = projectionKind
        self.payload = payload
    }
}

public struct V2ClientGroupEventPage: Equatable, Sendable {
    public let roomID: RoomID
    public let events: [V2ClientGroupEvent]
    private let nextRoomSequenceValue: V2RoomCursor
    public var nextRoomSequence: UInt64 { nextRoomSequenceValue.rawValue }
    public let hasMore: Bool

    public init(roomID: RoomID, events: [V2ClientGroupEvent], nextRoomSequence: UInt64, hasMore: Bool) throws {
        guard let cursor = try? V2RoomCursor(nextRoomSequence) else { throw V2ClientSyncError.storageRangeExceeded }
        self.roomID = roomID
        self.events = events
        self.nextRoomSequenceValue = cursor
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
public struct V2GroupEventPageCommit: Equatable, Sendable {
    private let appliedThroughValue: V2RoomCursor
    public var appliedThrough: UInt64 { appliedThroughValue.rawValue }
    public let insertedEventCount: Int
    public init(appliedThrough: UInt64, insertedEventCount: Int) throws {
        guard let cursor = try? V2RoomCursor(appliedThrough) else { throw V2ClientSyncError.storageRangeExceeded }
        guard insertedEventCount >= 0 else { throw V2ClientSyncError.invalidRecordOrdering }
        self.appliedThroughValue = cursor
        self.insertedEventCount = insertedEventCount
    }
}

public struct V2GroupEventBackgroundSyncProgress: Equatable, Sendable {
    public let processedPageCount: Int
    public let appliedEventCount: Int
    /// Continue this finite directory scan or known page backlog after yielding.
    /// Once false, a new availability cycle may request a fresh directory scan.
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
    private let highWatermarkValue: V2RoomCursor
    public var highWatermark: UInt64 { highWatermarkValue.rawValue }

    public init(roomID: RoomID, highWatermark: UInt64) throws {
        guard let cursor = try? V2RoomCursor(highWatermark) else { throw V2ClientSyncError.storageRangeExceeded }
        self.roomID = roomID
        self.highWatermarkValue = cursor
    }
}

/// Selects whether a room-event read is its durable recovery stream or only
/// an online preview layered over ordinary user sync.
public enum V2ClientRoomEventDelivery: Equatable, Sendable {
    case durableRoomLog
    case foregroundPreview
}

/// Durable local access state for a projected room. A private room never
/// borrows a synthetic group delivery mode: it is explicitly a durable room
/// log, while a standard group remains a foreground-only preview.
public struct V2ClientGroupEventAccess: Equatable, Sendable {
    public let delivery: V2ClientRoomEventDelivery
    public let isAuthorized: Bool

    public init(delivery: V2ClientRoomEventDelivery, isAuthorized: Bool) {
        self.delivery = delivery
        self.isAuthorized = isAuthorized
    }
}

/// Foreground subscription control is intentionally distinct from durable
/// event reads so callers cannot mistake a wake for a delivered message.
public protocol V2ClientGroupEventSubscriptionTransport: Sendable {
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription
    func unsubscribeFromGroupEvents(roomID: RoomID) async throws
}

public protocol V2LocalGroupEventStore: Sendable {
    /// Rooms whose event log is the durable recovery stream. This includes
    /// large-group hybrid rooms and private rooms; standard fan-out groups
    /// deliberately stay out of this background scheduler.
    func knownRoomLogRoomIDs(after roomID: RoomID?, limit: Int) async throws -> [RoomID]
    /// Captures the inclusive end marker of one finite directory scan.
    func lastKnownRoomLogRoomID() async throws -> RoomID?
    /// Durable keyset cursor for fair background scheduling. This cursor is
    /// only a scheduling hint; per-room event cursors remain the delivery
    /// authority.
    func hybridGroupBackgroundCursor() async throws -> RoomID?
    func setHybridGroupBackgroundCursor(_ roomID: RoomID?) async throws
    func isKnownRoomLogRoom(roomID: RoomID) async throws -> Bool
    /// Stops room-log pulls after the authoritative server says this device's
    /// user is no longer a member. Historical local projections and the
    /// immutable delivery mode remain readable.
    func markRoomEventUnauthorized(roomID: RoomID) async throws
    func groupEventCursor(roomID: RoomID) async throws -> UInt64
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) async throws -> UInt64
    /// Count only rows inserted by this transaction, excluding exact replay.
    func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) async throws -> V2GroupEventPageCommit
}

/// Foreground preview for a standard fan-out group deliberately has a
/// separate local-store contract.  Its cursor is process-local, never a
/// durable acknowledgement: `user_sync_log` remains the recovery and ACK
/// authority for standard groups.
public protocol V2LocalForegroundGroupEventPreviewStore: Sendable {
    /// Returns the immutable delivery mode and current local authorization.
    /// `nil` means this device does not know the group room.
    func groupEventAccess(roomID: RoomID) async throws -> V2ClientGroupEventAccess?
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

    private struct PageFlight {
        let id: UUID
        let task: Task<V2GroupEventSyncProgress, any Error>
    }
    private var pageFlights: [RoomID: PageFlight] = [:]
    private var backgroundFlight: (id: UUID, task: Task<V2GroupEventBackgroundSyncProgress, any Error>)?

    private struct DirectoryRange {
        var after: RoomID?
        let through: RoomID
    }
    private struct Scan {
        var ranges: [DirectoryRange]
        var pendingRooms: [RoomID] = []
        var backlog: [RoomID] = []
        var backlogHead = 0
        var hasWork: Bool { !ranges.isEmpty || !pendingRooms.isEmpty || backlogHead < backlog.count }
    }
    private var scan: Scan?

    public func synchronizeOnePage(roomID: RoomID) async throws -> V2GroupEventSyncProgress {
        // Actor methods can interleave at network awaits. Serialize the entire
        // read/pull/apply sequence for this room, including foreground callers.
        while let previous = pageFlights[roomID] {
            _ = await previous.task.result
            try Task.checkCancellation()
            if pageFlights[roomID]?.id == previous.id { pageFlights[roomID] = nil }
        }
        try Task.checkCancellation()
        let current = PageFlight(id: UUID(), task: Task { [store, transport, pageSize] in
            let cursor = try await store.groupEventCursor(roomID: roomID)
            try Task.checkCancellation()
            let page = try await transport.pullGroupEvents(roomID: roomID, afterRoomSequence: cursor, pageSize: pageSize)
            try Task.checkCancellation()
            guard page.roomID == roomID,
                  page.nextRoomSequence >= cursor,
                  !page.hasMore || page.nextRoomSequence > cursor
            else { throw V2RealtimeTransportError.unexpectedResponse }
            let commit = try await store.applyGroupEventPageReportingChanges(page)
            return .init(appliedEventCount: commit.insertedEventCount, hasMore: page.hasMore)
        })
        pageFlights[roomID] = current
        defer { if pageFlights[roomID]?.id == current.id { pageFlights[roomID] = nil } }
        return try await withTaskCancellationHandler(operation: {
            let result = await current.task.result
            try Task.checkCancellation()
            return try result.get()
        }, onCancel: { current.task.cancel() })
    }

    public func synchronizeUntilCaughtUp(roomID: RoomID) async throws {
        while (try await synchronizeOnePage(roomID: roomID)).hasMore {
            try Task.checkCancellation()
        }
    }

    /// Continues one finite scan from the durable round-robin position. Rooms
    /// discovered after the captured upper bound wait for the next wake. Only
    /// a server page with hasMore enters the FIFO backlog; empty rooms never
    /// cycle indefinitely merely because the directory exceeds this budget.
    public func synchronizeBackgroundKnownRooms(maximumPages: Int) async throws -> V2GroupEventBackgroundSyncProgress {
        precondition(maximumPages > 0 && maximumPages <= 10_000)
        while let previous = backgroundFlight {
            _ = await previous.task.result
            try Task.checkCancellation()
            if backgroundFlight?.id == previous.id { backgroundFlight = nil }
        }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await self.synchronizeBackgroundPass(maximumPages: maximumPages) }
        backgroundFlight = (id, task)
        defer { if backgroundFlight?.id == id { backgroundFlight = nil } }
        return try await withTaskCancellationHandler(operation: {
            let result = await task.result
            try Task.checkCancellation()
            return try result.get()
        }, onCancel: { task.cancel() })
    }

    private func synchronizeBackgroundPass(maximumPages: Int) async throws -> V2GroupEventBackgroundSyncProgress {
        if scan == nil {
            let pivot = try await store.hybridGroupBackgroundCursor()
            guard let upper = try await store.lastKnownRoomLogRoomID() else {
                try await store.setHybridGroupBackgroundCursor(nil)
                return .init(processedPageCount: 0, appliedEventCount: 0, mayHaveRemainingWork: false)
            }
            var ranges: [DirectoryRange] = []
            if let pivot {
                if pivot.rawValue < upper.rawValue { ranges.append(.init(after: pivot, through: upper)) }
            } else {
                ranges.append(.init(after: nil, through: upper))
            }
            if let pivot {
                ranges.append(.init(after: nil, through: pivot.rawValue < upper.rawValue ? pivot : upper))
            }
            scan = .init(ranges: ranges)
        }
        guard var scan else { throw V2RealtimeTransportError.unexpectedResponse }
        defer { self.scan = scan.hasWork ? scan : nil }
        var processedPages = 0
        var appliedEvents = 0
        var visited = Set<RoomID>()
        while processedPages < maximumPages {
            try Task.checkCancellation()
            // Keep only a bounded keyset page in memory. Each range advances
            // once; the head range ends at the original persisted pivot.
            while scan.pendingRooms.isEmpty, let range = scan.ranges.first {
                let rows = try await store.knownRoomLogRoomIDs(after: range.after, limit: maximumPages)
                try Task.checkCancellation()
                let bounded = rows.prefix { $0.rawValue <= range.through.rawValue }
                scan.pendingRooms = Array(bounded)
                if rows.count < maximumPages || bounded.count < rows.count || bounded.last == range.through {
                    scan.ranges.removeFirst()
                } else if let last = bounded.last {
                    scan.ranges[0].after = last
                }
            }
            let isDirectory = !scan.pendingRooms.isEmpty
            let roomID: RoomID
            if let first = scan.pendingRooms.first {
                roomID = first
            } else if scan.backlogHead < scan.backlog.count {
                roomID = scan.backlog[scan.backlogHead]
            } else { break }
            // One page per room per quantum, even at the directory/backlog boundary.
            guard visited.insert(roomID).inserted else { break }
            var hasMore = false
            do {
                if try await store.isKnownRoomLogRoom(roomID: roomID) {
                    let progress = try await synchronizeOnePage(roomID: roomID)
                    appliedEvents += progress.appliedEventCount
                    hasMore = progress.hasMore
                }
            } catch let error as V2RealtimeTransportError {
                guard case .server(let code, _, _, _) = error, code == "FORBIDDEN" else { throw error }
                try await store.markRoomEventUnauthorized(roomID: roomID)
            }
            try Task.checkCancellation()
            try await store.setHybridGroupBackgroundCursor(roomID)
            processedPages += 1
            if isDirectory { scan.pendingRooms.removeFirst() }
            else { scan.backlogHead += 1 }
            if hasMore { scan.backlog.append(roomID) }
        }
        let remaining = scan.hasWork
        if scan.backlogHead > 64 {
            scan.backlog.removeFirst(scan.backlogHead)
            scan.backlogHead = 0
        }
        return .init(processedPageCount: processedPages, appliedEventCount: appliedEvents, mayHaveRemainingWork: remaining)
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
              (page.events.last?.roomSequence ?? cursor) <= page.nextRoomSequence,
              !page.hasMore || page.nextRoomSequence > cursor,
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
