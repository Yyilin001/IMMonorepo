import Foundation

public enum V2DeviceRevocationRunnerError: Error, Equatable, Sendable { case alreadyRunning }

/// App-lifetime owner, independent of any authenticated account. The caller
/// owns and cancels run(); cancellation drains its sole network flight before
/// this runner can be started again. Durable work survives that cancellation.
public actor V2DeviceRevocationRunner {
    private let store: V2DeviceRevocationStore
    private let client: any V2DeviceRevocationClient
    private let now: @Sendable () -> Date
    private var running = false

    public init(store: V2DeviceRevocationStore, client: any V2DeviceRevocationClient,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.client = client; self.now = now
    }

    public func run() async throws {
        try Task.checkCancellation()
        guard !running else { throw V2DeviceRevocationRunnerError.alreadyRunning }
        running = true
        defer { running = false }
        try await V2CommandRetryScheduler(schedule: store.retrySchedule(), flush: { [self] in
            try await flushOnce()
        }, now: now).run()
    }

    // Only run() is exposed publicly; a second foreground activation cannot
    // bypass its owner and send the same job concurrently.
    func flushOnce() async throws {
        for job in try await store.due(at: now()) {
            try Task.checkCancellation()
            let result: V2DeviceRevocationResult
            do {
                result = try await client.revoke(credential: job.intent.credential, operationID: job.intent.operationID)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failure = classify(error)
                let backoff = min(300, pow(2, Double(min(job.attempts, 8) + 1)))
                let delay = max(backoff, failure.retryAfter)
                try await store.recordFailure(job, retryAt: now().addingTimeInterval(delay), pauseReason: failure.pause)
                continue
            }
            try Task.checkCancellation()
            switch result {
            case .revoked, .expired:
                // Expiry is a recognized server deadline, not a claim that a
                // revoke transaction committed. Both settle this capability.
                try await store.complete(job)
            case .invalidCredential:
                try await store.recordFailure(job, retryAt: now(), pauseReason: .invalidCredential)
            case .operationConflict:
                try await store.recordFailure(job, retryAt: now(), pauseReason: .operationConflict)
            }
        }
    }

    private func classify(_ error: any Error) -> (pause: V2DeviceRevocationJob.PauseReason?, retryAfter: Double) {
        guard let error = error as? V2DeviceRevocationClientError else { return (nil, 0) }
        switch error {
        case .networkFailure: return (nil, 0)
        case .rateLimited(let seconds): return (nil, min(86_400, max(0, Double(seconds ?? 0))))
        case .invalidResponse: return (.invalidResponse, 0)
        case .invalidEndpoint: return (.invalidRequest, 0)
        case .serverStatus(let status):
            return status >= 500 || status == 408 ? (nil, 0) : (.invalidRequest, 0)
        }
    }
}
