import Foundation

/// App-owned restore shared by scene and Push callers. Each caller may leave
/// independently; the owner has its own work deadline and is retained until
/// it actually drains, so a late disk callback cannot overlap a second owner.
@MainActor
final class V2SessionRestoration {
    enum Failure: Error { case deadlineReached }
    private var owner: (id: UUID, task: Task<Void, Never>)?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var timer: Task<Void, Never>?
    private var expired = false
    private let workDuration: Duration

    var isRestoring: Bool { owner != nil }

    init(workDuration: Duration = .seconds(25)) { self.workDuration = workDuration }
    deinit { owner?.task.cancel(); timer?.cancel() }

    func run(until deadline: ContinuousClock.Instant? = nil,
             operation: @escaping @MainActor @Sendable () async -> Void) async throws {
        try Task.checkCancellation()
        if let deadline, deadline <= .now { throw Failure.deadlineReached }
        if owner == nil {
            let id = UUID()
            expired = false
            owner = (id, Task { [weak self] in
                await operation()
                self?.finish(id)
            })
            timer = Task { [weak self, workDuration] in
                do { try await Task.sleep(for: workDuration) } catch { return }
                self?.expire(id)
            }
        }
        if expired { throw Failure.deadlineReached }
        if let deadline {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.wait() }
                group.addTask {
                    try await ContinuousClock().sleep(until: deadline)
                    throw Failure.deadlineReached
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } else { try await wait() }
    }

    private func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if expired { throw Failure.deadlineReached }
            guard owner != nil else { return }
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    private func expire(_ id: UUID) {
        guard owner?.id == id else { return }
        expired = true
        owner?.task.cancel()
        resolve(.failure(Failure.deadlineReached))
    }
    private func finish(_ id: UUID) {
        guard owner?.id == id else { return }
        timer?.cancel(); timer = nil
        owner = nil
        resolve(expired ? .failure(Failure.deadlineReached) : .success(()))
    }
    private func resolve(_ result: Result<Void, Error>) {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
}
