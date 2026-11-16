import Foundation
import IMV2Core
import IMV2ClientRuntime

public enum V2ConversationServiceError: Error, Sendable { case closed, busy, invalidQuery, windowLimit }

/// Account-scoped business queries. Projection values remain source compatible in this stage;
/// neither UI nor language bindings issue database queries or own recovery policy.
public actor V2ConversationService {
    public nonisolated let accountID: UserID
    public nonisolated let changes: V2ConversationChangeNotifier
    private let store: GRDBV2LocalSyncStore
    private let requiresAuthorization: Bool
    private let requestLatestVisible: @Sendable ([RoomID]) async throws -> Void
    private var closed = false
    private var closing: Task<Void, Never>?
    private var windows: [UUID: V2ConversationWindow] = [:]
    private struct Read: Sendable { let cancel: @Sendable () -> Void; let drain: @Sendable () async -> Void }
    private var reads: [UUID: Read] = [:]

    /// Composition boundary for legacy hosts and fixtures. Production ownership is registered
    /// with V2SharedSession before publishing the service to a page.
    public init(accountID: UserID, store: GRDBV2LocalSyncStore, requiresAuthorization: Bool = true,
                requestLatestVisible: @escaping @Sendable ([RoomID]) async throws -> Void = { _ in }) {
        self.accountID = accountID; self.store = store; self.requiresAuthorization = requiresAuthorization
        self.requestLatestVisible = requestLatestVisible
        changes = V2ConversationChangeNotifier(localStore: store)
    }

    public func openList(isArchived: Bool = false, limit: Int = 50) throws -> V2ConversationWindow {
        try open(.conversations(isArchived: isArchived, before: nil, limit: limit))
    }

    public func openTimeline(in roomID: RoomID, limit: Int = 50) throws -> V2ConversationWindow {
        try open(.timeline(roomID: roomID, before: nil, limit: limit, pendingPage: 0))
    }

    private func open(_ query: V2ConversationQuery) throws -> V2ConversationWindow {
        guard !closed else { throw V2ConversationServiceError.closed }
        try query.validate()
        guard windows.count < 128 else { throw V2ConversationServiceError.windowLimit }
        let window = V2ConversationWindow(service: self, query: query)
        windows[window.id] = window
        return window
    }

    fileprivate func removeWindow(_ id: UUID) { windows.removeValue(forKey: id) }

    public func list(isArchived: Bool, before: V2ClientConversationListCursor? = nil, limit: Int = 50) async throws -> V2ConversationListSnapshot {
        try await perform { [self] in
            let page = try await store.conversationListPage(isArchived: isArchived, before: before, limit: limit)
            return try await decorate(page)
        }
    }

    /// Native iOS keeps its existing complete-list snapshot/diff behavior.
    public func allConversations(isArchived: Bool) async throws -> [V2ConversationListSnapshot] {
        try await perform { [self] in
            let entries = try await store.allConversationListEntries(isArchived: isArchived)
            var result: [V2ConversationListSnapshot] = []
            for offset in stride(from: 0, to: entries.count, by: 100) {
                try Task.checkCancellation()
                result.append(try await decorate(.init(entries: Array(entries[offset..<min(offset + 100, entries.count)]), nextCursor: nil)))
            }
            return result
        }
    }

    private func decorate(_ page: V2ClientConversationListPage) async throws -> V2ConversationListSnapshot {
        var allowed: [V2ClientConversationListEntry] = []
        for entry in page.entries {
            if requiresAuthorization, try await !store.roomAllowsLocalRead(roomID: entry.roomID) { continue }
            allowed.append(entry)
        }
        let ids = allowed.map(\.roomID)
        let unread = (try? await store.roomUnreadSnapshot(roomIDs: ids).mapValues(\.displayedUnread)) ?? [:]
        let titles = try await store.conversationTitles(for: ids)
        let missing = allowed.filter { $0.latestVisible == nil }.map(\.roomID)
        for offset in stride(from: 0, to: missing.count, by: 100) {
            try Task.checkCancellation()
            do { try await requestLatestVisible(Array(missing[offset..<min(offset + 100, missing.count)])) }
            catch V2RoomRecoveryEngineError.notStarted { break }
            catch V2RoomRecoveryEngineError.coverageLost { break }
        }
        return .init(page: .init(entries: allowed, nextCursor: page.nextCursor), unread: unread, titles: titles)
    }

    public func timeline(in roomID: RoomID, before: V2ClientTimelineCursor? = nil, limit: Int = 50,
                         pendingPage: Int = 0) async throws -> V2MessageTimelineSnapshot {
        try await perform { [self] in
            let value = try await store.conversationSendTimeline(in: roomID, for: accountID, before: before,
                limit: limit, pendingPage: pendingPage, requiresAuthorization: requiresAuthorization)
            return .init(page: value.timeline, pending: value.pending)
        }
    }

    public func locate(in roomID: RoomID, messageID: MessageID, before: Int = 40, after: Int = 39) async throws -> V2ClientTimelineLocation {
        try await perform { [self] in
            if requiresAuthorization, try await !store.roomAllowsLocalRead(roomID: roomID) { return .unavailable }
            return try await store.conversationTimelineWindow(in: roomID, for: accountID, around: messageID,
                before: before, after: after)
        }
    }

    /// Locally verified facts used by the native viewport's existing read policy.
    public func readCheckpoint(in room: RoomID) async throws -> V2ConversationReadCheckpoint {
        try await perform { [store] in
            let applied = try await store.roomAppliedRoomSequence(roomID: room)
            let states = try await store.roomUnreadSnapshot(roomIDs: [room])
            return .init(knownHead: states[room]?.head, appliedRoomSequence: applied > 0 ? applied : nil)
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw V2ConversationServiceError.closed }
        try Task.checkCancellation()
        let id = UUID(), task = Task { try await operation() }
        reads[id] = .init(cancel: { task.cancel() }, drain: { _ = await task.result })
        defer { reads.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !closed else { throw V2ConversationServiceError.closed }
        try Task.checkCancellation()
        return result
    }

    public func close() async {
        if let closing { await closing.value; return }
        closed = true
        let captured = Array(windows.values), work = Array(reads.values), changes = changes
        let task = Task {
            for read in work { read.cancel() }
            for window in captured { await window.close() }
            await changes.closeAndDrain()
            for read in work { await read.drain() }
        }
        closing = task
        await task.value
        windows.removeAll()
    }
}

public struct V2ConversationListSnapshot: Sendable {
    public let page: V2ClientConversationListPage
    public let unread: [RoomID: UInt64]
    public let titles: [RoomID: String]
}

public struct V2MessageTimelineSnapshot: Sendable {
    public let page: V2ClientConversationTimelinePage
    public let pending: V2PendingResourceSendSnapshot
}

public enum V2ConversationQuery: Sendable {
    case conversations(isArchived: Bool, before: V2ClientConversationListCursor?, limit: Int)
    case timeline(roomID: RoomID, before: V2ClientTimelineCursor?, limit: Int, pendingPage: Int)

    fileprivate func validate() throws {
        switch self {
        case .conversations(_, _, let limit):
            guard (1...100).contains(limit) else { throw V2ConversationServiceError.invalidQuery }
        case .timeline(_, _, let limit, let page):
            guard (1...10_000).contains(limit), (0...(Int.max / 200 - 1)).contains(page) else { throw V2ConversationServiceError.invalidQuery }
        }
    }
}

public enum V2ConversationWindowContent: Sendable {
    case conversations(V2ConversationListSnapshot)
    case timeline(V2MessageTimelineSnapshot)
}

/// A window owns only its query and observers, never the account's physical connection.
public actor V2ConversationWindow {
    public nonisolated let id = UUID()
    private let service: V2ConversationService
    private var query: V2ConversationQuery
    private var closed = false
    private var revision: UInt64 = 0
    private var reading = false
    private var last: V2ConversationWindowContent?
    private var observers: [UUID: (task: Task<Void, Never>, continuation: AsyncThrowingStream<V2ConversationWindowUpdate, any Error>.Continuation)] = [:]

    fileprivate init(service: V2ConversationService, query: V2ConversationQuery) { self.service = service; self.query = query }

    public func isFirstPage() -> Bool {
        switch query {
        case .conversations(_, let cursor, _): cursor == nil
        case .timeline(_, let cursor, _, _): cursor == nil
        }
    }

    public func read() async throws -> V2ConversationWindowContent {
        guard !closed else { throw V2ConversationServiceError.closed }
        // Each read captures its own query; a concurrent page change cannot publish a stale result.
        let version = revision, selected = query
        let value: V2ConversationWindowContent
        switch selected {
        case .conversations(let archived, let before, let limit): value = .conversations(try await service.list(isArchived: archived, before: before, limit: limit))
        case .timeline(let room, let before, let limit, let page): value = .timeline(try await service.timeline(in: room, before: before, limit: limit, pendingPage: page))
        }
        guard !closed else { throw V2ConversationServiceError.closed }
        guard version == revision else { throw V2ConversationServiceError.busy }
        last = value
        return value
    }

    public func nextPage() async throws -> V2ConversationWindowContent {
        guard !reading else { throw V2ConversationServiceError.busy }
        reading = true; defer { reading = false }
        let current = try await read()
        switch (query, current) {
        case (.conversations(let archived, _, let limit), .conversations(let page)):
            if let next = page.page.nextCursor { query = .conversations(isArchived: archived, before: next, limit: limit) }
        case (.timeline(let room, _, let limit, let pending), .timeline(let page)):
            if let next = page.page.olderCursor { query = .timeline(roomID: room, before: next, limit: limit, pendingPage: pending) }
        default: throw V2ConversationServiceError.invalidQuery
        }
        revision &+= 1
        let value = try await read(); publish(value); return value
    }

    public func reset() async throws -> V2ConversationWindowContent {
        guard !reading else { throw V2ConversationServiceError.busy }
        reading = true; defer { reading = false }
        switch query {
        case .conversations(let archived, _, let limit): query = .conversations(isArchived: archived, before: nil, limit: limit)
        case .timeline(let room, _, let limit, _): query = .timeline(roomID: room, before: nil, limit: limit, pendingPage: 0)
        }
        revision &+= 1
        let value = try await read(); publish(value); return value
    }

    public func updates() async -> V2ConversationWindowUpdates {
        let (stream, continuation) = AsyncThrowingStream<V2ConversationWindowUpdate, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !closed else { continuation.finish(throwing: V2ConversationServiceError.closed); return .init(window: self, stream: stream) }
        let id = UUID(), scopes: V2ProjectionScopes, room: String?
        switch query {
        case .conversations: scopes = .conversations; room = nil
        case .timeline(let value, _, _, _): scopes = [.conversationDetails, .conversationTimeline, .conversationMetadata, .resources]; room = value.rawValue
        }
        let subscription = await service.changes.updates(scopes: scopes, roomID: room)
        guard !closed else { continuation.finish(throwing: V2ConversationServiceError.closed); return .init(window: self, stream: stream) }
        let task = Task { [weak self] in
            for await _ in subscription {
                guard !Task.isCancelled, let self else { break }
                let version = await self.currentRevision()
                do {
                    let value = try await self.read()
                    await self.yield(value, version: version, to: continuation)
                }
                catch V2ConversationServiceError.busy { continue }
                catch { continuation.finish(throwing: error); await self.removeObserver(id); return }
            }
            continuation.finish()
            await self?.removeObserver(id)
        }
        observers[id] = (task, continuation)
        continuation.onTermination = { [weak self] _ in task.cancel(); Task { await self?.removeObserver(id) } }
        return .init(window: self, stream: stream)
    }

    fileprivate func requireOpen() throws { if closed { throw V2ConversationServiceError.closed } }
    func accepts(_ update: V2ConversationWindowUpdate) throws -> Bool {
        try requireOpen()
        return update.revision == revision
    }
    private func currentRevision() -> UInt64 { revision }
    private func yield(_ value: V2ConversationWindowContent, version: UInt64,
        to continuation: AsyncThrowingStream<V2ConversationWindowUpdate, any Error>.Continuation) {
        guard !closed, revision == version else { return }
        continuation.yield(.init(value: value, revision: revision))
    }

    private func publish(_ value: V2ConversationWindowContent) { for observer in observers.values { observer.continuation.yield(.init(value: value, revision: revision)) } }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.task.cancel() }

    public func close() async {
        guard !closed else { return }; closed = true; revision &+= 1; last = nil
        let captured = Array(observers.values); observers.removeAll()
        for observer in captured { observer.task.cancel(); observer.continuation.finish() }
        for observer in captured { await observer.task.value }
        await service.removeWindow(id)
    }
}

struct V2ConversationWindowUpdate: Sendable {
    let value: V2ConversationWindowContent
    let revision: UInt64
}

/// Validates ownership and query revision when a buffered value is consumed.
public struct V2ConversationWindowUpdates: AsyncSequence, Sendable {
    public typealias Element = V2ConversationWindowContent
    let window: V2ConversationWindow
    let stream: AsyncThrowingStream<V2ConversationWindowUpdate, any Error>
    public struct AsyncIterator: AsyncIteratorProtocol {
        let window: V2ConversationWindow
        var iterator: AsyncThrowingStream<V2ConversationWindowUpdate, any Error>.Iterator
        @concurrent public mutating func next() async throws -> Element? {
            try await window.requireOpen()
            while let update = try await iterator.next() {
                if try await window.accepts(update) { return update.value }
            }
            try await window.requireOpen()
            return nil
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { .init(window: window, iterator: stream.makeAsyncIterator()) }
}

public struct V2ConversationReadCheckpoint: Sendable {
    public let knownHead: UInt64?
    public let appliedRoomSequence: UInt64?
}
