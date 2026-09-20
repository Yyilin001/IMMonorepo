import Foundation
import IMV2Core

/// Owns a connection's notification consumer and recovery driver. The runtime
/// must close the transport when this loop fails and before reusing the engine.
public actor V2RoomRecoveryRunner {
    private let engine: V2RoomRecoveryEngine
    private let source: any V2AccountRoomChangeSource
    private let personalSync: any V2SyncDriving
    private let now: @Sendable () -> Date
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void
    private let integrityInterval: @Sendable () -> TimeInterval
    private var running = false
    private var consumerFailure: (any Error)?
    private var wake: AsyncThrowingStream<Void, Error>.Continuation?

    public init(engine: V2RoomRecoveryEngine, source: any V2AccountRoomChangeSource,
                personalSync: any V2SyncDriving,
                now: @escaping @Sendable () -> Date = Date.init,
                integrityInterval: @escaping @Sendable () -> TimeInterval = { .random(in: 600...900) },
                retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.engine = engine
        self.source = source
        self.personalSync = personalSync
        self.now = now
        self.integrityInterval = integrityInterval
        self.retrySleep = retrySleep
    }

    /// Personal projection changes can make durable recovery work eligible again.
    public func requestCatchUp() { wake?.yield(()) }

    public func requestLatestVisible(roomIDs: [RoomID]) async throws {
        try await engine.requestLatestVisible(roomIDs: roomIDs)
        wake?.yield(())
    }

    /// A background connection consumes notifications while spending a finite
    /// directory/content budget. It never performs an unbounded final personal
    /// catch-up or claims full coverage completion; the next run resumes work.
    public func runBounded(userID: UserID, maximumPages: Int) async throws -> V2IncrementalSyncResult {
        guard (1...10_000).contains(maximumPages) else { throw V2RoomRecoveryEngineError.invalidBudget }
        guard !running else { throw V2RoomRecoveryEngineError.concurrentRun }
        running = true
        defer { running = false; consumerFailure = nil }
        let (_, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        do {
            try await engine.prepare(userID: userID)
            let result = try await withThrowingTaskGroup(of: V2IncrementalSyncResult.self) { group in
                group.addTask {
                    try await self.consume(continuation)
                    throw V2RealtimeTransportError.unexpectedResponse
                }
                group.addTask { try await self.spendBoundedBudget(userID: userID, maximumPages: maximumPages) }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await engine.stop()
            return result
        } catch {
            await engine.stop()
            throw error
        }
    }

    private func spendBoundedBudget(userID: UserID, maximumPages: Int) async throws -> V2IncrementalSyncResult {
        var remaining = maximumPages
        var processed = 0
        var inserted = false
        while remaining > 0 {
            try Task.checkCancellation()
            if let consumerFailure { throw consumerFailure }
            let progress = try await engine.progress()
            let directory = !progress.directoryComplete && (remaining > 1 || progress.pendingRoomCount == 0) ? 1 : 0
            let result = try await engine.runBudget(userID: userID, maximumDirectoryPages: directory,
                maximumRooms: min(20, remaining - directory))
            let spent = result.directoryPages + result.processedRooms
            processed += spent
            inserted = inserted || result.appliedEventCount > 0
            remaining -= spent
            if spent == 0 { break }
        }
        return .init(processedPageCount: processed, didCommitNewRecords: inserted, stopReason: .pageLimit)
    }

    public func run(userID: UserID) async throws {
        guard !running else { throw V2RoomRecoveryEngineError.concurrentRun }
        running = true
        defer { running = false; wake = nil; consumerFailure = nil }
        let (events, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        defer { continuation.finish() }
        do {
            while true {
                do { try await engine.prepare(userID: userID); break }
                catch V2RealtimeTransportError.server(code: _, retryable: true, retryAfterSeconds: let seconds, currentRevision: _) {
                    try await retrySleep(TimeInterval(max(1, seconds)))
                    try Task.checkCancellation()
                }
            }
            try Task.checkCancellation()
            try await runPrepared(userID: userID, events: events, continuation: continuation)
        } catch {
            await engine.stop()
            throw error
        }
        await engine.stop()
    }

    private func runPrepared(userID: UserID, events: AsyncThrowingStream<Void, Error>,
                             continuation: AsyncThrowingStream<Void, Error>.Continuation) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.consume(continuation) }
            group.addTask { try await self.drive(userID: userID, events: events, continuation: continuation) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func consume(_ continuation: AsyncThrowingStream<Void, Error>.Continuation) async throws {
        do {
            while true {
                try Task.checkCancellation()
                let change = try await source.nextAccountRoomChange()
                try Task.checkCancellation()
                try await engine.accept(change)
                continuation.yield(())
            }
        } catch {
            consumerFailure = error
            continuation.finish(throwing: error)
            throw error
        }
    }

    private func drive(userID: UserID, events: AsyncThrowingStream<Void, Error>,
                       continuation: AsyncThrowingStream<Void, Error>.Continuation) async throws {
        var iterator = events.makeAsyncIterator()
        var nextIntegrityCheck = now().addingTimeInterval(max(1, integrityInterval()))
        while true {
            try Task.checkCancellation()
            if let consumerFailure { throw consumerFailure }
            do {
                let before = try await engine.progress()
                // Directory exhaustion alone is not recovery completion. A large
                // account can still be downloading bodies or proving personal
                // coverage when the timer expires; do not enqueue its rooms again.
                if before.directoryComplete && before.pendingRoomCount == 0,
                   await engine.phase == .live, now() >= nextIntegrityCheck {
                    try await engine.restartDirectory(userID: userID)
                    nextIntegrityCheck = now().addingTimeInterval(max(1, integrityInterval()))
                }
                let budget: V2RoomRecoveryBudgetResult
                do {
                    budget = try await engine.runBudget(userID: userID)
                } catch V2ClientSyncError.resetPending {
                    _ = try await personalSync.synchronizeIncludingResets()
                    try Task.checkCancellation()
                    try await engine.restartDirectory(userID: userID)
                    continue
                }
                let progress = try await engine.progress()
                if !progress.directoryComplete || progress.pendingRoomCount > 0 {
                    // Back off rounds that made no visible progress; notifications
                    // can interrupt this delay. Persistent retry deadlines survive exit.
                    let delay = max(0, progress.nextAttemptAt?.timeIntervalSince(now()) ?? 0)
                    if delay == 0 && (budget.directoryPages > 0 || budget.processedRooms > 0) {
                        await Task.yield()
                        continue
                    }
                    try await wait(&iterator, continuation: continuation, delay: progress.directoryComplete ? min(max(1, delay), max(1, nextIntegrityCheck.timeIntervalSince(now()))) : max(1, delay))
                } else {
                    let complete = try await engine.completeIfCaughtUp(using: personalSync)
                    if complete {
                        try await wait(&iterator, continuation: continuation, delay: max(1, nextIntegrityCheck.timeIntervalSince(now())))
                    } else {
                        try await wait(&iterator, continuation: continuation, delay: 1)
                    }
                }
            } catch V2RealtimeTransportError.server(code: _, retryable: true, retryAfterSeconds: let seconds, currentRevision: _) {
                // The listener stays installed and durable progress is retained.
                // Notifications must not shorten a server-requested cooldown.
                try await retrySleep(TimeInterval(max(1, seconds)))
                try Task.checkCancellation()
            }
        }
    }

    private func wait(_ iterator: inout AsyncThrowingStream<Void, Error>.Iterator,
                      continuation: AsyncThrowingStream<Void, Error>.Continuation,
                      delay: TimeInterval?) async throws {
        let timer: Task<Void, Never>? = delay.map { seconds in
            Task {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    try Task.checkCancellation()
                    continuation.yield(())
                } catch { }
            }
        }
        do {
            guard try await iterator.next(isolation: self) != nil else { throw CancellationError() }
            timer?.cancel()
            await timer?.value
            try Task.checkCancellation()
        } catch {
            timer?.cancel()
            await timer?.value
            throw error
        }
    }
}
