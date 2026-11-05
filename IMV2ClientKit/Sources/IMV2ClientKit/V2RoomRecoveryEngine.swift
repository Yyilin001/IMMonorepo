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

/// Payload-free recovery scheduling observations for diagnostics.
public enum V2RoomRecoveryObservation: Sendable {
    case latestVisibleRequested, directoryRestart, directoryPage
    case onlineHead(UInt64), workSelected(UInt64, requiresState: Bool)
}

/// Wall-clock stages may be nested; contentCommit is included in contentBatch.
public enum V2RoomRecoveryStage: String, Sendable {
    case selectWork, fetchState, commitState, fetchSummary, commitSummary, inspectContent, contentBatch, contentCommit
}

/// One runtime-owned driver for discovery and room catch-up. Notifications may
/// enqueue while a budget is awaiting I/O, but only one budget can drive pulls.
public actor V2RoomRecoveryEngine {
    private let transport: any V2ClientRoomRecoveryTransport
    private let store: GRDBV2LocalSyncStore
    private let latestVisible: any V2ClientRoomLatestVisibleTransport
    private let contentRecoveryBatchSize: Int
    private let groupEvents: V2GroupEventSyncEngine
    private let didPersistProgress: @Sendable (RoomID, UInt64) async throws -> Void
    private let observe: (@Sendable (V2RoomRecoveryObservation) -> Void)?
    private let observeStage: (@Sendable (V2RoomRecoveryStage, Double) -> Void)?
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
                groupEvents: V2GroupEventSyncEngine, contentRecoveryBatchSize: Int = 16,
                now: @escaping @Sendable () -> Date = Date.init,
                didPersistProgress: @escaping @Sendable (RoomID, UInt64) async throws -> Void = { _, _ in },
                observe: (@Sendable (V2RoomRecoveryObservation) -> Void)? = nil,
                observeStage: (@Sendable (V2RoomRecoveryStage, Double) -> Void)? = nil) {
        precondition((1...16).contains(contentRecoveryBatchSize), "contentRecoveryBatchSize must be between 1 and 16")
        self.contentRecoveryBatchSize = contentRecoveryBatchSize
        self.transport = transport; self.latestVisible = latestVisible; self.store = store; self.groupEvents = groupEvents; self.now = now
        self.didPersistProgress = didPersistProgress
        self.observe = observe
        self.observeStage = observeStage
    }

    /// Establishes the listener without reading a directory or processing old work.
    /// The runtime can start its notification consumer immediately after this returns.
    public func prepare(userID: UserID) async throws {
        _ = try await executeBudget(userID: userID, maximumDirectoryPages: 0, maximumRooms: 0)
    }

    /// Restarts only directory discovery; queued targets and the listener survive.
    public func restartDirectory(userID: UserID) async throws {
        observe?(.directoryRestart)
        _ = try await executeBudget(userID: userID, maximumDirectoryPages: 0, maximumRooms: 0, restartDirectory: true)
    }

    public func requestLatestVisible(roomIDs: [RoomID]) async throws {
        guard roomIDs.count <= 100 else { throw V2RoomRecoveryEngineError.invalidBudget }
        guard coverageValid, !stopping else { throw V2RoomRecoveryEngineError.coverageLost }
        guard let scope else { throw V2RoomRecoveryEngineError.notStarted }
        notificationRevision = UUID()
        pendingNotificationWrites += 1
        defer { pendingNotificationWrites -= 1 }
        if !roomIDs.isEmpty { observe?(.latestVisibleRequested) }
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

    public func runBudget(userID: UserID, maximumDirectoryPages: Int = 1, maximumRooms: Int = 100) async throws -> V2RoomRecoveryBudgetResult {
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

    public func retainOnlineRoomHead(roomID: RoomID, highWatermark: UInt64, userID: UserID) async throws {
        guard coverageValid, !stopping else { throw V2RoomRecoveryEngineError.coverageLost }
        notificationRevision = UUID()
        pendingNotificationWrites += 1
        defer { pendingNotificationWrites -= 1 }
        observe?(.onlineHead(highWatermark))
        try await store.retainOnlineRoomHead(roomID: roomID, targetHead: highWatermark, userID: userID, now: now())
        phase = .catchingUp
    }

    public func accept(_ change: V2AccountRoomChange) async throws {
        guard let scope, let epoch else { throw V2RoomRecoveryEngineError.notStarted }
        guard coverageValid else { throw V2RoomRecoveryEngineError.coverageLost }
        switch change {
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

    private func report(_ stage: V2RoomRecoveryStage, since start: ContinuousClock.Instant) {
        observeStage?(stage, recoveryStageMilliseconds(since: start))
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
                observe?(.directoryPage)
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
        var stageStart = ContinuousClock.now
        let work = try await store.roomRecoveryWork(scope: scope, limit: rooms, oldestFirst: batches % 4 == 0, now: now())
        for item in work { observe?(.workSelected(item.targetHead, requiresState: item.requiresState)) }
        report(.selectWork, since: stageStart)
        let needingState = work.filter(\.requiresState)
        if !needingState.isEmpty {
            phase = .reconciling
            stageStart = .now
            let results = try await transport.roomSyncStates(roomIDs: needingState.map(\.roomID))
            try Task.checkCancellation()
            report(.fetchState, since: stageStart)
            stageStart = .now
            let states = try needingState.compactMap { item -> (state: V2RoomSynchronizationState, work: V2RoomRecoveryWork)? in
                guard let result = results[item.roomID] else { throw V2RealtimeTransportError.unexpectedResponse }
                if case .state(let state) = result { return (state, item) }; return nil
            }
            if !states.isEmpty { try await store.commitRoomRecoveryStates(states, now: now()) }
            for item in needingState {
                switch results[item.roomID] {
                case .state: break
                case .retry(let seconds):
                    phase = .retryWaiting
                    try await store.retryRoomRecoveryWork(item, at: now().addingTimeInterval(TimeInterval(max(1, seconds))))
                case .unavailable:
                    _ = try await store.commitRoomRecoveryUnavailable(item)
                case nil: throw V2RealtimeTransportError.unexpectedResponse
                }
            }
        }
        if !needingState.isEmpty { report(.commitState, since: stageStart) }
        let summaryWork = try await store.roomRecoveryWork(scope: scope, limit: rooms,
            oldestFirst: batches % 4 == 0, now: now()).filter { $0.requiresSummary && !$0.requiresState }
        if !summaryWork.isEmpty {
            let request = try await store.beginRoomLatestVisibleRequest(scope: scope)
            stageStart = .now
            let snapshots = try await latestVisible.latestVisible(roomIDs: summaryWork.map(\.roomID))
            try Task.checkCancellation()
            report(.fetchSummary, since: stageStart)
            stageStart = .now
            let valid = try summaryWork.compactMap { item -> (snapshot: V2RoomLatestVisible, work: V2RoomRecoveryWork)? in
                guard let result = snapshots[item.roomID] else { throw V2RealtimeTransportError.unexpectedResponse }
                if case .snapshot(let snapshot) = result { return (snapshot, item) }; return nil
            }
            let accepted: Set<RoomID> = valid.isEmpty ? [] : try await store.commitRoomLatestVisibleBatch(valid, request: request)
            for item in summaryWork {
                switch snapshots[item.roomID] {
                case .snapshot:
                    if !accepted.contains(item.roomID) {
                        try await store.retryRoomRecoveryWork(item, at: now().addingTimeInterval(1))
                    }
                case .unavailable: _ = try await store.commitRoomRecoveryUnavailable(item)
                case .retry(let seconds):
                    try await store.retryRoomRecoveryWork(item, at: now().addingTimeInterval(TimeInterval(max(1, seconds))))
                case nil: throw V2RealtimeTransportError.unexpectedResponse
                }
            }
        }
        if !summaryWork.isEmpty { report(.commitSummary, since: stageStart) }
        stageStart = .now
        // Re-read targets after state commits. A response may raise the head,
        // or an in-flight notification may have replaced the request revision.
        let ready = try await store.roomRecoveryWork(scope: scope, limit: rooms, oldestFirst: batches % 4 == 0, now: now())
        var processed = 0
        var appliedEvents = 0
        var contentWork: [V2RoomRecoveryWork] = []
        let eligible = ready.filter { !$0.requiresState }
        let finished = try await store.finishRoomRecoveryWorks(eligible)
        for item in eligible {
            try Task.checkCancellation()
            if finished.contains(item.roomID) {
                try await didPersistProgress(item.roomID, store.groupEventCursor(roomID: item.roomID))
                processed += 1; continue
            }
            contentWork.append(item)
        }
        report(.inspectContent, since: stageStart)
        if !contentWork.isEmpty {
            phase = .catchingUp
            // Two disjoint batches overlap network I/O. Group-event flights
            // still reserve each room, and SQLite serializes the fenced commits.
            let groups = stride(from: 0, to: contentWork.count, by: contentRecoveryBatchSize).map {
                Array(contentWork[$0..<min($0 + contentRecoveryBatchSize, contentWork.count)])
            }
            let content = try await withThrowingTaskGroup(of: (Int, Int).self) { tasks in
                var next = 0, applied = 0, processed = 0
                func submit(_ batch: [V2RoomRecoveryWork]) {
                    tasks.addTask { [store, groupEvents, didPersistProgress, observeStage] in
                        let byRoom = Dictionary(uniqueKeysWithValues: batch.map { ($0.roomID, $0) })
                        let started = ContinuousClock.now
                        let result = try await groupEvents.synchronizePages(targets: batch.map { ($0.roomID, $0.targetHead) },
                            commit: { pages in
                                let items = try pages.map { page in
                                    guard let item = byRoom[page.roomID] else { throw V2RealtimeTransportError.unexpectedResponse }
                                    return (page: page, work: item)
                                }
                                let commitStart = ContinuousClock.now
                                let committed = try await store.applyRoomRecoveryPages(items)
                                observeStage?(.contentCommit, recoveryStageMilliseconds(since: commitStart))
                                // No report can precede the durable batch commit.
                                for page in pages {
                                    guard let cursor = committed[page.roomID] else { throw V2RealtimeTransportError.unexpectedResponse }
                                    try await didPersistProgress(page.roomID, cursor.appliedThrough)
                                }
                                return committed
                            }, unavailable: { room in
                                guard let item = byRoom[room] else { throw V2RealtimeTransportError.unexpectedResponse }
                                _ = try await store.commitRoomRecoveryUnavailable(item)
                            })
                        observeStage?(.contentBatch, recoveryStageMilliseconds(since: started))
                        return (result.appliedEventCount, batch.count)
                    }
                }
                while next < min(2, groups.count) { submit(groups[next]); next += 1 }
                while let result = try await tasks.next() {
                    applied += result.0; processed += result.1
                    if next < groups.count { submit(groups[next]); next += 1 }
                }
                return (applied, processed)
            }
            appliedEvents += content.0; processed += content.1
        }
        let scan = try await store.roomRecoveryScan(scope: scope)
        // Directory completion alone cannot establish live: the personal stream
        // and all delayed/unfinished work must also be proven complete.
        return .init(directoryPages: scanned, processedRooms: processed, directoryComplete: scan.directoryComplete, appliedEventCount: appliedEvents)
    }
}

private func recoveryStageMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
}
