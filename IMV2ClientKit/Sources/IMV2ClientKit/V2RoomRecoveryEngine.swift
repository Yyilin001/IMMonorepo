import Foundation
import IMV2Core

public enum V2RoomRecoveryPhase: Equatable, Sendable {
    case idle, establishingCoverage, reconciling, catchingUp, retryWaiting, live
}

public struct V2RoomRecoveryBudgetResult: Equatable, Sendable {
    public let directoryPages: Int
    public let processedRooms: Int
    public let directoryComplete: Bool
    public var appliedEventCount: Int = 0
}

public enum V2RoomRecoveryEngineError: Error, Equatable, Sendable {
    case concurrentRun, notStarted, wrongEpoch, coverageLost, invalidBudget
}

/// One runtime-owned driver for discovery and room catch-up. Notifications may
/// enqueue while a budget is awaiting I/O, but only one budget can drive pulls.
public actor V2RoomRecoveryEngine {
    private let transport: any V2ClientRoomRecoveryTransport
    private let store: GRDBV2LocalSyncStore
    private let latestVisible: any V2ClientRoomLatestVisibleTransport
    private let groupEvents: V2GroupEventSyncEngine
    private let contentRecoveryConcurrency: Int
    private let now: @Sendable () -> Date
    private var scope: V2RoomRecoveryScope?
    private var epoch: UUID?
    private var flight: (id: UUID, task: Task<V2RoomRecoveryBudgetResult, Error>)?
    private var completionFlight: (id: UUID, task: Task<Bool, Error>)?
    private var notificationRevision = UUID()
    private var pendingNotificationWrites = 0
    private var batches = 0
    private var stopping = false
    private var coverageValid = true
    public private(set) var phase: V2RoomRecoveryPhase = .idle

    public init(transport: any V2ClientRoomRecoveryTransport, latestVisible: any V2ClientRoomLatestVisibleTransport, store: GRDBV2LocalSyncStore,
                groupEvents: V2GroupEventSyncEngine, contentRecoveryConcurrency: Int = 4,
                now: @escaping @Sendable () -> Date = Date.init) {
        precondition((1...16).contains(contentRecoveryConcurrency), "contentRecoveryConcurrency must be between 1 and 16")
        self.transport = transport; self.latestVisible = latestVisible; self.store = store; self.groupEvents = groupEvents; self.now = now
        self.contentRecoveryConcurrency = contentRecoveryConcurrency
    }

    /// Establishes the listener without reading a directory or processing old work.
    /// The runtime can start its notification consumer immediately after this returns.
    public func prepare(userID: UserID) async throws {
        _ = try await executeBudget(userID: userID, maximumDirectoryPages: 0, maximumRooms: 0)
    }

    /// Restarts only directory discovery; queued targets and the listener survive.
    public func restartDirectory(userID: UserID) async throws {
        _ = try await executeBudget(userID: userID, maximumDirectoryPages: 0, maximumRooms: 0, restartDirectory: true)
    }

    public func requestLatestVisible(roomIDs: [RoomID]) async throws {
        guard roomIDs.count <= 100 else { throw V2RoomRecoveryEngineError.invalidBudget }
        guard coverageValid, !stopping else { throw V2RoomRecoveryEngineError.coverageLost }
        guard let scope else { throw V2RoomRecoveryEngineError.notStarted }
        notificationRevision = UUID()
        pendingNotificationWrites += 1
        defer { pendingNotificationWrites -= 1 }
        for room in Set(roomIDs) {
            try Task.checkCancellation()
            try await store.ensureRoomLatestVisible(roomID: room, scope: scope, now: now())
        }
        if !roomIDs.isEmpty { phase = .catchingUp }
    }

    public func progress() async throws -> V2RoomRecoveryProgress {
        guard coverageValid else { throw V2RoomRecoveryEngineError.coverageLost }
        guard let scope else { throw V2RoomRecoveryEngineError.notStarted }
        return try await store.roomRecoveryProgress(scope: scope)
    }

    public func runBudget(userID: UserID, maximumDirectoryPages: Int = 1, maximumRooms: Int = 20) async throws -> V2RoomRecoveryBudgetResult {
        guard (0...100).contains(maximumDirectoryPages), (0...100).contains(maximumRooms),
              maximumDirectoryPages > 0 || maximumRooms > 0 else { throw V2RoomRecoveryEngineError.invalidBudget }
        return try await executeBudget(userID: userID, maximumDirectoryPages: maximumDirectoryPages, maximumRooms: maximumRooms)
    }

    private func executeBudget(userID: UserID, maximumDirectoryPages: Int, maximumRooms: Int, restartDirectory: Bool = false) async throws -> V2RoomRecoveryBudgetResult {
        guard flight == nil, completionFlight == nil, !stopping else { throw V2RoomRecoveryEngineError.concurrentRun }
        guard coverageValid else { throw V2RoomRecoveryEngineError.coverageLost }
        let id = UUID()
        let task = Task { try await self.drive(userID: userID, directoryPages: maximumDirectoryPages, rooms: maximumRooms, restartDirectory: restartDirectory) }
        flight = (id, task)
        defer { if flight?.id == id { flight = nil } }
        return try await withTaskCancellationHandler(operation: {
            let result = await task.result
            try Task.checkCancellation()
            return try result.get()
        }, onCancel: { task.cancel() })
    }

    /// The runtime must also end the corresponding transport listener. Waiting
    /// here drains owned I/O before it releases this engine's connection scope.
    public func stop() async {
        if stopping {
            _ = await flight?.task.result
            _ = await completionFlight?.task.result
            return
        }
        stopping = true
        defer { stopping = false }
        let current = flight
        let completing = completionFlight
        current?.task.cancel()
        completing?.task.cancel()
        _ = await current?.task.result
        _ = await completing?.task.result
        if completionFlight?.id == completing?.id { completionFlight = nil }
        if flight?.id == current?.id { flight = nil }
        scope = nil; epoch = nil; coverageValid = true; phase = .idle
    }

    public func accept(_ change: V2AccountRoomChange) async throws {
        guard let scope, let epoch else { throw V2RoomRecoveryEngineError.notStarted }
        guard coverageValid else { throw V2RoomRecoveryEngineError.coverageLost }
        switch change {
        case .changed(let incoming, let room, let head):
            guard incoming == epoch else { throw V2RoomRecoveryEngineError.wrongEpoch }
            notificationRevision = UUID()
            pendingNotificationWrites += 1
            phase = .catchingUp
            defer { pendingNotificationWrites -= 1 }
            try await store.enqueueRoomRecovery(roomID: room, targetHead: head, priority: 1, scope: scope, now: now())
        case .resyncRequired(let incoming):
            guard incoming == epoch else { throw V2RoomRecoveryEngineError.wrongEpoch }
            coverageValid = false
            flight?.task.cancel()
            completionFlight?.task.cancel()
            phase = .retryWaiting
            throw V2RoomRecoveryEngineError.coverageLost
        }
    }

    /// The runtime owns this call alongside its notification consumer. Personal
    /// catch-up is deliberately after directory completion, including snapshot tails.
    public func completeIfCaughtUp(using personalSync: any V2SyncDriving) async throws -> Bool {
        guard flight == nil, completionFlight == nil, !stopping else { throw V2RoomRecoveryEngineError.concurrentRun }
        guard coverageValid else { throw V2RoomRecoveryEngineError.coverageLost }
        guard let scope else { throw V2RoomRecoveryEngineError.notStarted }
        let id = UUID()
        let task = Task { try await self.evaluateCompletion(scope: scope, personalSync: personalSync) }
        completionFlight = (id, task)
        defer { if completionFlight?.id == id { completionFlight = nil } }
        return try await withTaskCancellationHandler(operation: {
            let result = await task.result
            try Task.checkCancellation()
            return try result.get()
        }, onCancel: { task.cancel() })
    }

    private func evaluateCompletion(scope: V2RoomRecoveryScope, personalSync: any V2SyncDriving) async throws -> Bool {
        try Task.checkCancellation()
        guard pendingNotificationWrites == 0,
              let candidate = try await store.roomRecoveryCompletionCandidate(scope: scope) else { return false }
        let applied = try await personalSync.synchronizeIncludingResets()
        try Task.checkCancellation()
        guard self.scope == scope, coverageValid else { throw V2RoomRecoveryEngineError.coverageLost }
        guard pendingNotificationWrites == 0 else { return false }
        let revision = notificationRevision
        let verified = try await store.verifyRoomRecoveryCompletion(candidate, personalAppliedThrough: applied)
        try Task.checkCancellation()
        guard self.scope == scope, coverageValid else { throw V2RoomRecoveryEngineError.coverageLost }
        if verified, pendingNotificationWrites == 0, revision == notificationRevision {
            phase = .live
            return true
        }
        if try await store.cursor()?.generation != candidate.personalGeneration {
            try Task.checkCancellation()
            try await store.restartRoomRecoveryDirectory(scope: scope)
            phase = .reconciling
        }
        return false
    }

    private func drive(userID: UserID, directoryPages: Int, rooms: Int, restartDirectory: Bool) async throws -> V2RoomRecoveryBudgetResult {
        try Task.checkCancellation()
        if scope == nil {
            phase = .establishingCoverage
            let ready = try await transport.startAccountRoomChanges()
            try Task.checkCancellation()
            let started = try await store.beginRoomRecoveryScan(userID: userID)
            try Task.checkCancellation()
            scope = started; epoch = ready
        }
        guard let scope, scope.userID == userID else { throw V2RoomRecoveryPersistenceError.staleScope }
        if restartDirectory {
            try await store.restartRoomRecoveryDirectory(scope: scope)
            try Task.checkCancellation()
            phase = .reconciling
        }
        if rooms == 0 && directoryPages == 0 {
            let scan = try await store.roomRecoveryScan(scope: scope)
            return .init(directoryPages: 0, processedRooms: 0, directoryComplete: scan.directoryComplete)
        }
        var scanned = 0
        for _ in 0..<directoryPages {
            let scan = try await store.roomRecoveryScan(scope: scope)
            if scan.directoryComplete { break }
            phase = .reconciling
            do {
                let page = try await transport.userRoomDirectory(cursor: scan.cursor, pageSize: 100)
                try Task.checkCancellation()
                try await store.commitRoomRecoveryDirectoryPage(page, expectedCursor: scan.cursor, request: scan, now: now())
                scanned += 1
            } catch V2ClientRoomRecoveryError.directoryResetRequired {
                try Task.checkCancellation()
                try await store.restartRoomRecoveryDirectory(scope: scope)
                break
            } catch V2RoomRecoveryPersistenceError.topologyChanged {
                try Task.checkCancellation()
                try await store.restartRoomRecoveryDirectory(scope: scope)
                break
            }
        }
        if rooms == 0 {
            let scan = try await store.roomRecoveryScan(scope: scope)
            return .init(directoryPages: scanned, processedRooms: 0, directoryComplete: scan.directoryComplete)
        }
        batches = (batches + 1) % 4
        let work = try await store.roomRecoveryWork(scope: scope, limit: rooms, oldestFirst: batches % 4 == 0, now: now())
        let needingState = work.filter(\.requiresState)
        if !needingState.isEmpty {
            phase = .reconciling
            let results = try await transport.roomSyncStates(roomIDs: needingState.map(\.roomID))
            try Task.checkCancellation()
            for item in needingState {
                switch results[item.roomID] {
                case .state(let state):
                    _ = try await store.commitRoomRecoveryState(state, work: item, now: now())
                case .retry(let seconds):
                    phase = .retryWaiting
                    try await store.retryRoomRecoveryWork(item, at: now().addingTimeInterval(TimeInterval(max(1, seconds))))
                case .unavailable:
                    _ = try await store.commitRoomRecoveryUnavailable(item)
                case nil: throw V2RealtimeTransportError.unexpectedResponse
                }
            }
        }
        let summaryWork = try await store.roomRecoveryWork(scope: scope, limit: rooms,
            oldestFirst: batches % 4 == 0, now: now()).filter { $0.requiresSummary && !$0.requiresState }
        if !summaryWork.isEmpty {
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            let snapshots = try await latestVisible.latestVisible(roomIDs: summaryWork.map(\.roomID))
            try Task.checkCancellation()
            for item in summaryWork {
                switch snapshots[item.roomID] {
                case .snapshot(let snapshot):
                    if try await !store.commitRoomLatestVisible(snapshot, request: request, work: item) {
                        try await store.retryRoomRecoveryWork(item, at: now().addingTimeInterval(1))
                    }
                case .unavailable: _ = try await store.commitRoomRecoveryUnavailable(item)
                case .retry(let seconds):
                    try await store.retryRoomRecoveryWork(item, at: now().addingTimeInterval(TimeInterval(max(1, seconds))))
                case nil: throw V2RealtimeTransportError.unexpectedResponse
                }
            }
        }
        // Re-read targets after state commits. A response may raise the head,
        // or an in-flight notification may have replaced the request revision.
        let ready = try await store.roomRecoveryWork(scope: scope, limit: rooms, oldestFirst: batches % 4 == 0, now: now())
        var processed = 0
        var appliedEvents = 0
        var contentWork: [V2RoomRecoveryWork] = []
        for item in ready where !item.requiresState {
            try Task.checkCancellation()
            if try await store.finishRoomRecoveryWork(item) { processed += 1; continue }
            contentWork.append(item)
        }
        if !contentWork.isEmpty {
            phase = .catchingUp
            // A sliding window keeps independent rooms busy while bounding network
            // and projection work. Per-room ordering remains owned by groupEvents.
            try await withThrowingTaskGroup(of: ContentRecoveryResult.self) { group in
                var next = contentWork.makeIterator()
                func submit(_ item: V2RoomRecoveryWork) {
                    group.addTask { [groupEvents, store] in
                        do {
                            let content = try await groupEvents.synchronizeOnePage(roomID: item.roomID) { [store] page in
                                try await store.applyRoomRecoveryPage(page, work: item)
                            }
                            return .applied(content.appliedEventCount)
                        } catch V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: _, currentRevision: _) {
                            try Task.checkCancellation()
                            _ = try await store.commitRoomRecoveryUnavailable(item)
                            return .denied
                        }
                    }
                }
                for _ in 0..<min(contentRecoveryConcurrency, contentWork.count) {
                    guard let item = next.next() else { break }
                    submit(item)
                }
                while let result = try await group.next() {
                    processed += 1
                    switch result {
                    case .applied(let count): appliedEvents += count
                    case .denied: break
                    }
                    try Task.checkCancellation()
                    if let item = next.next() { submit(item) }
                }
            }
        }
        let scan = try await store.roomRecoveryScan(scope: scope)
        // Directory completion alone cannot establish live: the personal stream
        // and all delayed/unfinished work must also be proven complete.
        return .init(directoryPages: scanned, processedRooms: processed, directoryComplete: scan.directoryComplete, appliedEventCount: appliedEvents)
    }
}

private enum ContentRecoveryResult: Sendable {
    case applied(Int)
    case denied
}
