import Foundation

/// Durable state is authoritative. Notifications only request another indexed
/// read; buffering one notification is sufficient even during a long flush.
public struct V2CommandRetrySchedule: Sendable {
    let nextAttemptAt: @Sendable () async throws -> Date?
    let updates: @Sendable () async -> AsyncThrowingStream<Void, any Error>

    public init(
        nextAttemptAt: @escaping @Sendable () async throws -> Date?,
        updates: @escaping @Sendable () async -> AsyncThrowingStream<Void, any Error>
    ) {
        self.nextAttemptAt = nextAttemptAt
        self.updates = updates
    }
}

enum V2CommandRetrySchedulerError: Error, Equatable, Sendable {
    case invalidDate
}

struct V2CommandRetryScheduler: Sendable {
    let schedule: V2CommandRetrySchedule
    let flush: @Sendable () async throws -> Void
    var now: @Sendable () -> Date = Date.init

    func run() async throws {
        let signal = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Subscribe before querying. A change racing with the query or sleep
        // registration remains buffered, closing the lost-wakeup window.
        let changes = await schedule.updates()
        let observer = Task {
            do {
                for try await _ in changes { signal.continuation.yield(()) }
                signal.continuation.finish()
            } catch { signal.continuation.finish(throwing: error) }
        }
        var timer: Task<Void, Never>?
        defer {
            timer?.cancel()
            observer.cancel()
            signal.continuation.finish()
        }
        var iterator = signal.stream.makeAsyncIterator()
        while !Task.isCancelled {
            if let due = try await schedule.nextAttemptAt() {
                let current = now()
                guard due.timeIntervalSince1970.isFinite, current.timeIntervalSince1970.isFinite else {
                    throw V2CommandRetrySchedulerError.invalidDate
                }
                let delay = due.timeIntervalSince(current)
                if delay <= 0 {
                    try await flush()
                    // A bounded flush may leave ready work without changing
                    // the earliest timestamp. Re-read and continue ourselves.
                    continue
                }
                timer = Task {
                    do {
                        // Date is durable; Task.sleep uses a monotonic clock.
                        // Re-evaluate wall-clock changes at least every minute.
                        try await Task.sleep(for: .seconds(min(delay, 60)))
                        signal.continuation.yield(())
                    } catch { }
                }
            }
            guard try await iterator.next() != nil else { return }
            timer?.cancel()
            timer = nil
        }
        throw CancellationError()
    }
}
