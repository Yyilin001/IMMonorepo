import Foundation

/// Each page owns a reader and a serial refresh worker. Ordinary invalidations
/// merge into one pending pass. Urgent ones cancel the active pass immediately;
/// the worker drains it before starting the latest read. No overlapping reads,
/// orphan refresh tasks, or unbounded queue of cancelled tasks are created.
@MainActor
final class V2ProjectionRefreshObserver {
    private let refresh: @MainActor @Sendable () async -> Void
    private var pending = false
    private var active: Task<Void, Never>?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    init(refresh: @escaping @MainActor @Sendable () async -> Void) { self.refresh = refresh }

    static func run(_ updates: V2ProjectionChangeNotifier.Subscription,
                    refresh: @escaping @MainActor @Sendable () async -> Void) async {
        await V2ProjectionRefreshObserver(refresh: refresh).run(updates)
    }

    func run(_ updates: V2ProjectionChangeNotifier.Subscription) async {
        let owner = self
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await request in updates {
                    guard !Task.isCancelled else { return }
                    await owner.submit(request)
                }
            }
            group.addTask { await owner.work() }
            _ = await group.next()
            group.cancelAll()
            // The group drains both children; work also drains its active read.
        }
    }

    func submit(_ request: V2ProjectionChangeNotifier.Request) {
        guard !Task.isCancelled else { return }
        pending = true
        if request.requiresImmediateRefresh { active?.cancel() }
        if let waiter {
            self.waiter = nil
            pending = false
            waiter.continuation.resume(returning: true)
        }
    }

    private func work() async {
        while !Task.isCancelled, await takePending() {
            guard !Task.isCancelled else { return }
            let refresh = refresh
            let task = Task { @MainActor in
                guard !Task.isCancelled else { return }
                await refresh()
            }
            active = task
            await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            active = nil
        }
    }

    private func takePending() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else if pending { pending = false; continuation.resume(returning: true) }
                else { waiter = (id, continuation) }
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
    }

    private func cancelWaiter(_ id: UUID) {
        guard waiter?.id == id else { return }
        waiter?.continuation.resume(returning: false)
        waiter = nil
    }
}
