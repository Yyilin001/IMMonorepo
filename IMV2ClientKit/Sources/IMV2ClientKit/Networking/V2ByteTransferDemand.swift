import Foundation
import Synchronization

/// One physical download's monotonic demand, shared by its independently
/// cancellable readers. The small synchronous registration boundary closes the
/// race between observing a new priority and enqueuing a scheduler waiter.
final class V2ByteTransferDemand: Sendable {
    private struct State: Sendable {
        var priority: V2NetworkWorkPriority
        var observers: [UUID: @Sendable (V2NetworkWorkPriority) -> Void] = [:]
    }
    private let state: Mutex<State>
    init(priority: V2NetworkWorkPriority) { state = Mutex(.init(priority: priority)) }
    var priority: V2NetworkWorkPriority { state.withLock { $0.priority } }

    func promote(to priority: V2NetworkWorkPriority) {
        let observers = state.withLock { state -> [@Sendable (V2NetworkWorkPriority) -> Void] in
            guard priority.rawValue < state.priority.rawValue else { return [] }
            state.priority = priority
            return Array(state.observers.values)
        }
        for observer in observers { observer(priority) }
    }

    func observe(_ id: UUID, change: @escaping @Sendable (V2NetworkWorkPriority) -> Void) -> V2NetworkWorkPriority {
        state.withLock { state in state.observers[id] = change; return state.priority }
    }
    func removeObserver(_ id: UUID) { _ = state.withLock { $0.observers.removeValue(forKey: id) } }
    var observerCount: Int { state.withLock { $0.observers.count } }
}

enum V2ByteTransferWorkScope {
    @TaskLocal static var demand: V2ByteTransferDemand?
}
