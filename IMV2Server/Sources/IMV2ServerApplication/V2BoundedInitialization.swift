import Foundation
import Synchronization

/// Queued jobs are data, not suspended tasks. A step owns a bounded execution
/// slot through actual completion; retries return to FIFO or one deadline heap.
package actor V2BoundedInitialization {
    package enum Step: Sendable { case finished, again(at: ContinuousClock.Instant) }
    package enum Failure: Error, Sendable { case closed, overloaded }
    package struct Ticket: Sendable {
        let id: UUID
        private let completion: Completion
        private let owner: V2BoundedInitialization
        fileprivate init(id: UUID, completion: Completion, owner: V2BoundedInitialization) {
            self.id = id; self.completion = completion; self.owner = owner
        }
        package func wait() async throws { try await completion.wait() }
        package func cancelAndDrain() async { await owner.cancelAndDrain(id) }
        package func waitCurrent() async throws { try await owner.waitCurrent(id, fallback: completion) }
    }
    private struct Job: Sendable {
        let operation: @Sendable () async throws -> Step
        let completion: Completion
        var task: Task<Void, Never>?
        var cancelled = false
        var requestedAgain = false
    }
    private let maximumConcurrent: Int
    private let maximumJobs: Int
    private var jobs: [UUID: Job] = [:]
    private var ready = V2IndexedFIFO<UUID, UUID>()
    private var deadlines = V2IndexedDeadlines<UUID>()
    private var active = 0
    private var closed = false
    private var timer: Task<Void, Never>?
    private var timerAt: ContinuousClock.Instant?
    private var timerGeneration: UInt64 = 0
    package init(maximumConcurrent: Int, maximumJobs: Int) {
        precondition(maximumConcurrent > 0 && maximumJobs >= maximumConcurrent)
        self.maximumConcurrent = maximumConcurrent; self.maximumJobs = maximumJobs
    }
    package func submit(id: UUID, repeatExisting: Bool = false, operation: @escaping @Sendable () async throws -> Step) throws -> Ticket {
        guard !closed else { throw Failure.closed }
        if var job = jobs[id] {
            if repeatExisting {
                job.requestedAgain = true; jobs[id] = job
            }
            return Ticket(id: id, completion: job.completion, owner: self)
        }
        guard jobs.count < maximumJobs else { throw Failure.overloaded }
        let completion = Completion()
        jobs[id] = Job(operation: operation, completion: completion)
        ready.append(id, key: id)
        pump()
        return Ticket(id: id, completion: completion, owner: self)
    }
    private func pump() {
        guard !closed else { return }
        let cut = ContinuousClock.now
        while let id = deadlines.popDue(at: cut) { ready.append(id, key: id) }
        while active < maximumConcurrent, let id = ready.removeFirst() {
            guard var job = jobs[id], !job.cancelled else { continue }
            job.requestedAgain = false
            active += 1
            let operation = job.operation
            job.task = Task {
                let result: Result<Step, any Error>
                do { try Task.checkCancellation(); result = .success(try await operation()) }
                catch { result = .failure(error) }
                self.finished(id, result: result)
            }
            jobs[id] = job
        }
        scheduleTimer()
    }
    private func finished(_ id: UUID, result: Result<Step, any Error>) {
        guard var job = jobs[id], job.task != nil else { return }
        active -= 1; job.task = nil
        if closed || job.cancelled {
            jobs.removeValue(forKey: id); job.completion.finish(.failure(CancellationError()))
        } else {
            switch result {
            case .success(.again(let at)):
                jobs[id] = job
                if at <= .now { ready.append(id, key: id) } else { deadlines.set(id, at: at) }
            case .success(.finished):
                if job.requestedAgain {
                    jobs[id] = job; ready.append(id, key: id)
                } else {
                    jobs.removeValue(forKey: id); job.completion.finish(.success(()))
                }
            case .failure(let error):
                jobs.removeValue(forKey: id); job.completion.finish(.failure(error))
            }
        }
        pump()
    }
    private func scheduleTimer() {
        guard !closed else { timer?.cancel(); timer = nil; timerAt = nil; return }
        let at = deadlines.firstDeadline
        guard at != timerAt else { return }
        timer?.cancel(); timer = nil; timerAt = at; timerGeneration &+= 1
        guard let at else { return }
        let generation = timerGeneration
        timer = Task {
            do { try await Task.sleep(until: at, clock: .continuous) } catch { return }
            guard !closed, generation == timerGeneration else { return }
            timerAt = nil; timer = nil
            pump()
        }
    }
    private func cancel(_ id: UUID) {
        guard var job = jobs[id] else { return }
        if let task = job.task {
            job.cancelled = true; jobs[id] = job; task.cancel()
        } else {
            _ = ready.remove(id); deadlines.remove(id); jobs.removeValue(forKey: id)
            job.completion.finish(.failure(CancellationError())); scheduleTimer()
        }
    }
    private func cancelAndDrain(_ id: UUID) async {
        guard let completion = jobs[id]?.completion else { return }
        cancel(id)
        await completion.drain()
    }
    private func waitCurrent(_ id: UUID, fallback: Completion) async throws {
        let completion = jobs[id]?.completion ?? fallback
        try await completion.wait()
    }
    package func shutdown() async {
        closed = true; timer?.cancel()
        let timer = timer
        let ids = Array(jobs.keys)
        let completions = jobs.values.map(\.completion)
        for id in ids { cancel(id) }
        for completion in completions { await completion.drain() }
        await timer?.value
    }
    package var snapshot: (active: Int, ready: Int, delayed: Int, jobs: Int) {
        (active, ready.count, deadlines.count, jobs.count)
    }
    fileprivate final class Completion: Sendable {
        private struct State: Sendable {
            var result: Result<Void, any Error>?
            var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
            var cancelled: Set<UUID> = []
        }
        private let state = Mutex(State())
        func drain() async {
            _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result = state.withLock { value -> Result<Void, any Error>? in
                    if let result = value.result { return result }
                    value.waiters[UUID()] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        }
        func wait() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result = state.withLock { value -> Result<Void, any Error>? in
                        if value.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                        if let result = value.result { return result }
                        value.waiters[id] = continuation
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                let waiter = self.state.withLock { value -> CheckedContinuation<Void, any Error>? in
                    if let waiter = value.waiters.removeValue(forKey: id) { return waiter }
                    if value.result == nil { value.cancelled.insert(id) }
                    return nil
                }
                waiter?.resume(throwing: CancellationError())
            }
        }
        func finish(_ result: Result<Void, any Error>) {
            let waiters = state.withLock { value -> [CheckedContinuation<Void, any Error>] in
                guard value.result == nil else { return [] }
                value.result = result
                let waiters = Array(value.waiters.values)
                value.waiters.removeAll(); value.cancelled.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume(with: result) }
        }
    }
}
