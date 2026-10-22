import Foundation
import IMV2Core

/// One activation owns one admission domain. HTTP activities remain available while
/// the realtime gateway reconnects; no transport's readiness authorizes another one.
public actor V2AccountRuntime {
    public enum ActivityState: Sendable, Equatable { case starting, running, finished, cancelled, failed }
    public enum ObservationError: Error { case tooManyObservers }
    private var activityStates: [String: ActivityState] = [:]
    private var activityObservers: [UUID: AsyncStream<[String: ActivityState]>.Continuation] = [:]
    public nonisolated let ownerID: UUID
    public nonisolated let ownProfileQueries: V2QueryCoordinator<V2ProfileView>
    public nonisolated let scheduler: V2AccountWorkScheduler
    public nonisolated let qualityObserver: V2QualityObserver
    public nonisolated let httpExecutor: V2HTTPExecutor
    public nonisolated let networkDiagnostics: V2NetworkDiagnostics
    private var activities: [String: Task<Void, Never>] = [:]
    private var activityGenerations: [String: UUID] = [:]
    private var activityDrains: [String: Task<Void, Never>] = [:]
    private var closingTask: Task<Void, Never>?
    private var realtime: V2ClientRuntime?
    private var realtimeGeneration: UInt64 = 0
    private var closed = false
    public init(ownerID: UUID = UUID(), configuration: V2AccountWorkScheduler.Configuration = .init()) {
        self.ownerID = ownerID
        self.ownProfileQueries = V2QueryCoordinator()
        let scheduler = V2AccountWorkScheduler(configuration: configuration)
        self.scheduler = scheduler
        let qualityObserver = V2QualityObserver()
        self.qualityObserver = qualityObserver
        let diagnostics = V2NetworkDiagnostics()
        self.networkDiagnostics = diagnostics
        self.httpExecutor = V2HTTPExecutor(scheduler: scheduler, qualityObserver: qualityObserver, metrics: { diagnostics.record($0) })
    }
    public nonisolated func queryScope(accountID: String, authorizationDomain: String, generation: UInt64 = 0) -> V2QueryScope {
        .init(accountID: accountID, authorizationDomain: authorizationDomain, activationID: ownerID, generation: generation)
    }
    public func activitySnapshot() -> [String: ActivityState] { activityStates }
    /// No transport errors or payloads are exposed through this UI-facing stream.
    /// A failed activity remains visible until explicitly replaced or the account closes.
    public func activityUpdates() throws -> AsyncStream<[String: ActivityState]> {
        guard activityObservers.count < 8 else { throw ObservationError.tooManyObservers }
        let id = UUID()
        let pair = AsyncStream<[String: ActivityState]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(activityStates)
        if closed { pair.continuation.finish(); return pair.stream }
        activityObservers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeActivityObserver(id) } }
        return pair.stream
    }
    private func removeActivityObserver(_ id: UUID) { activityObservers[id] = nil }
    private func publishActivityStates() {
        for observer in activityObservers.values { observer.yield(activityStates) }
    }
    private func finishActivity(id: String, generation: UUID, state: ActivityState) {
        guard !closed, activityGenerations[id] == generation else { return }
        activityStates[id] = state
        publishActivityStates()
    }
    /// Account-owned durable loops are independent of TCP. Replacing a loop drains its old owner.
    /// IDs come from application registrations, not remote input. Every registered
    /// loop must start; silently capping this registry can disable durable sends.
    public func startActivity(id: String, operation: @escaping @Sendable () async throws -> Void,
                              onFailure: @escaping @Sendable (any Error) async -> Void = { _ in }) async {
        guard !closed else { return }
        let generation = UUID()
        activityGenerations[id] = generation
        activityStates[id] = .starting
        publishActivityStates()
        let previous = activities.removeValue(forKey: id) ?? activityDrains[id]
        if let previous { activityDrains[id] = previous }
        previous?.cancel(); await previous?.value
        guard !closed, activityGenerations[id] == generation else { return }
        activityDrains[id] = nil
        activityStates[id] = .running
        publishActivityStates()
        activities[id] = Task {
            do {
                try await operation()
                finishActivity(id: id, generation: generation, state: Task.isCancelled ? .cancelled : .finished)
            }
            catch is CancellationError { finishActivity(id: id, generation: generation, state: .cancelled) }
            catch {
                finishActivity(id: id, generation: generation, state: .failed)
                // A replaced activity cannot deliver failure into its successor.
                if !closed, activityGenerations[id] == generation { await onFailure(error) }
            }
        }
    }
    /// Foreground lifecycle caller owns this suspended function and cancels it on backgrounding.
    public func runRealtime(_ runtime: V2ClientRuntime,
                            onConnected: @escaping @Sendable () async -> Void = {}) async throws {
        guard !closed else { throw CancellationError() }
        realtimeGeneration &+= 1
        let generation = realtimeGeneration
        realtime = runtime
        var attempt = 0
        while !Task.isCancelled && !closed && generation == realtimeGeneration {
            do {
                _ = try await runtime.start()
                let establishedAt = ContinuousClock.now
                try Task.checkCancellation()
                guard !closed, generation == realtimeGeneration else { throw CancellationError() }
                await onConnected()
                await runtime.waitUntilStopped()
                try Task.checkCancellation()
                guard !closed, generation == realtimeGeneration else { throw CancellationError() }
                await runtime.stop()
                if establishedAt.duration(to: .now) >= .seconds(15) { attempt = 0 }
            } catch is CancellationError { throw CancellationError() }
            catch V2RealtimeSessionCoordinatorError.authenticationRequired { throw V2RealtimeSessionCoordinatorError.authenticationRequired }
            catch { /* Keep local projections and independent HTTP activities available. */ }
            guard !closed && generation == realtimeGeneration else { throw CancellationError() }
            let ceiling = min(30, pow(2, Double(min(attempt, 5))))
            // Full jitter avoids synchronized recovery; a small floor prevents a hot loop.
            try await Task.sleep(for: .seconds(max(0.05, Double.random(in: 0...ceiling))))
            attempt += 1
        }
        throw CancellationError()
    }
    public func suspendRealtime() async {
        realtimeGeneration &+= 1
        let previous = realtime; realtime = nil
        await previous?.stop()
    }
    public func close() async {
        if let closingTask { await closingTask.value; return }
        closed = true
        for id in activityStates.keys { activityStates[id] = .cancelled }
        publishActivityStates()
        for observer in activityObservers.values { observer.finish() }
        activityObservers.removeAll()
        let loops = Array(activities.values) + Array(activityDrains.values)
        activities.removeAll(); activityDrains.removeAll(); activityGenerations.removeAll()
        realtimeGeneration &+= 1
        let previousRealtime = realtime; realtime = nil
        let drain = Task { [scheduler, ownProfileQueries, networkDiagnostics] in
            await scheduler.beginClose()
            await ownProfileQueries.beginClose()
            for task in loops { task.cancel() }
            await previousRealtime?.stop()
            for task in loops { await task.value }
            await ownProfileQueries.closeAndDrain()
            await scheduler.closeAndDrain()
            networkDiagnostics.close()
        }
        closingTask = drain
        await drain.value
    }
}
