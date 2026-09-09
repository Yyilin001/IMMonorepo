import Foundation

public enum V2DeviceRegistrationCancellationRunnerError: Error, Equatable, Sendable { case alreadyRunning }

/// Independent of account credentials. The App owns run() until cancellation
/// has drained its current request, including a late successful response.
public actor V2DeviceRegistrationCancellationRunner {
    private let store: V2DeviceRegistrationStore
    private let client: any V2DeviceRegistrationCancellationClient
    private let now: @Sendable () -> Date
    private var running = false

    public init(store: V2DeviceRegistrationStore, client: any V2DeviceRegistrationCancellationClient,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.client = client; self.now = now
    }

    public func run() async throws {
        try Task.checkCancellation()
        guard !running else { throw V2DeviceRegistrationCancellationRunnerError.alreadyRunning }
        running = true
        defer { running = false }
        try await V2CommandRetryScheduler(schedule: store.cancellationRetrySchedule(), flush: { [self] in
            try await flushOnce()
        }, now: now).run()
    }

    func flushOnce() async throws {
        for job in try await store.dueCancellations(at: now()) {
            try Task.checkCancellation()
            do {
                // The local issue deadline cannot settle a bound session;
                // only the server can confirm cancellation or session expiry.
                _ = try await client.cancel(job.cancellation)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let failure = classify(error)
                let delay = max(min(300, pow(2, Double(min(job.attempts, 8) + 1))), failure.retryAfter)
                try await store.recordCancellationFailure(job, retryAt: now().addingTimeInterval(delay), pauseReason: failure.pause)
                continue
            }
            try Task.checkCancellation()
            try await store.completeCancellationJob(job)
        }
    }

    private func classify(_ error: any Error) -> (pause: V2DeviceRegistrationCancellationJob.PauseReason?, retryAfter: Double) {
        guard let error = error as? V2DeviceRegistrationCancellationClientError else { return (nil, 0) }
        switch error {
        case .networkFailure: return (nil, 0)
        case .rateLimited(let seconds): return (nil, min(86_400, max(0, Double(seconds ?? 0))))
        case .invalidResponse: return (.invalidResponse, 0)
        case .invalidEndpoint: return (.invalidRequest, 0)
        case .serverStatus(let status): return status >= 500 || status == 408 ? (nil, 0) : (.invalidRequest, 0)
        }
    }
}
