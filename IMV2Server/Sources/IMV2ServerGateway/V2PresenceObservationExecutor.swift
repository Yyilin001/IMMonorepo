import Foundation
import IMV2ServerContracts

/// An immutable database observation. Its original permission lifetime is never
/// restarted while waiting for a connection's writer.
struct PreparedPresenceObservationBatch: Sendable {
    let observed: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let outcomes: [V2PresenceObservationRequest: V2PresenceObservationOutcome]
}

/// Query ownership ends before any socket handoff. The coordinator separately
/// reserves bounded result capacity until each original target is settled.
actor V2PresenceObservationExecutor {
    enum Failure: Error, Equatable { case closed, capacity, duplicateAttempt, malformed, expired }
    private let maximumConcurrentAttempts: Int
    private let permissionLifetime: Duration
    private var attempts: Set<UUID> = []
    private var closed = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(maximumConcurrentAttempts: Int = 4, permissionLifetime: Duration = .seconds(30)) {
        precondition(maximumConcurrentAttempts > 0 && permissionLifetime > .zero)
        self.maximumConcurrentAttempts = maximumConcurrentAttempts
        self.permissionLifetime = permissionLifetime
    }

    func execute(attemptID: UUID, requests: [V2PresenceObservationRequest],
        reader: any V2LiveActivityStore) async throws -> PreparedPresenceObservationBatch {
        guard !closed else { throw Failure.closed }
        guard !attempts.contains(attemptID) else { throw Failure.duplicateAttempt }
        guard attempts.count < maximumConcurrentAttempts else { throw Failure.capacity }
        guard !requests.isEmpty, requests.count <= 128,
              Set(requests).count == requests.count else { throw Failure.malformed }
        try Task.checkCancellation()
        attempts.insert(attemptID)
        defer {
            attempts.remove(attemptID)
            if closed && attempts.isEmpty {
                let waiters = drainWaiters; drainWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        let observed = ContinuousClock.now
        let deadline = observed.advanced(by: permissionLifetime)
        let date = Date()
        // Shield a submitted query from caller cancellation, and explicitly join
        // its actual completion before freeing the query slot.
        let actual = Task { try await reader.presenceBatch(requests, now: date) }
        let outcomes = try await actual.value
        guard deadline > .now else { throw Failure.expired }
        guard Set(outcomes.keys) == Set(requests) else { throw Failure.malformed }
        for (request, outcome) in outcomes {
            if case .observed(let state) = outcome {
                guard state.roomID == request.roomID,
                      state.targetUserID == request.targetUserID else { throw Failure.malformed }
            }
        }
        return .init(observed: observed, deadline: deadline, outcomes: outcomes)
    }

    func finish() async {
        closed = true
        guard !attempts.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    func actualAttemptCount() -> Int { attempts.count }
}
