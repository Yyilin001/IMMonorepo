import Foundation
import Synchronization

/// Waits for already-cancelled service tasks without allowing one
/// non-cooperative I/O operation to hold process shutdown indefinitely.
///
/// This is intentionally an unstructured race. A structured task group waits
/// for every child while leaving scope, which would defeat the deadline when a
/// database driver has not yet observed cancellation. The caller remains
/// responsible for cancelling every source task before entering this wait and
/// for closing the underlying pools after a timeout.
public func v2WaitForTaskDrain(
    _ tasks: [Task<Void, Never>],
    timeout: Duration
) async -> Bool {
    precondition(timeout > .zero)
    guard !tasks.isEmpty else { return true }

    return await withCheckedContinuation { continuation in
        let race = V2TaskDrainRace(continuation: continuation)
        let drainTask = Task {
            for task in tasks { await task.value }
            race.resolve(true)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                race.resolve(false)
            } catch {
                // The drain won and cancelled this timer.
            }
        }
        race.install(tasks: [drainTask, timeoutTask])
    }
}

private final class V2TaskDrainRace: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        var tasks: [Task<Void, Never>] = []
        var resolved = false
    }

    private let state: Mutex<State>

    init(continuation: CheckedContinuation<Bool, Never>) {
        state = Mutex(.init(continuation: continuation))
    }

    func install(tasks: [Task<Void, Never>]) {
        let cancel = state.withLock { state -> Bool in
            guard !state.resolved else { return true }
            state.tasks = tasks
            return false
        }
        if cancel { tasks.forEach { $0.cancel() } }
    }

    func resolve(_ drained: Bool) {
        let completion = state.withLock { state -> (
            CheckedContinuation<Bool, Never>?,
            [Task<Void, Never>]
        ) in
            guard !state.resolved else { return (nil, []) }
            state.resolved = true
            let continuation = state.continuation
            state.continuation = nil
            let tasks = state.tasks
            state.tasks = []
            return (continuation, tasks)
        }
        completion.1.forEach { $0.cancel() }
        completion.0?.resume(returning: drained)
    }
}
