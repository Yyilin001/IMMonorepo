import Synchronization

/// Two independent implicit transactions may share the protocol. A transaction
/// with BEGIN/COMMIT first drains them and excludes all other connection work.
/// Waiters are only the connection worker's bounded child turns, never room queues.
final class V2MessageWriteConnectionGate: Sendable {
    private struct Waiter {
        let shared: Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private struct State {
        var shared = 0
        var exclusive = false
        var waiters: [Waiter] = []
        mutating func take(shared wantsShared: Bool) -> Bool {
            guard waiters.isEmpty, !exclusive, wantsShared || shared == 0 else { return false }
            if wantsShared { shared += 1 } else { exclusive = true }
            return true
        }
    }
    private let state = Mutex(State())
    func withAccess<Value: Sendable>(shared: Bool,
        _ operation: @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if !state.withLock({ $0.take(shared: shared) }) {
            await withCheckedContinuation { continuation in
                let acquired = state.withLock { s in
                    if s.take(shared: shared) { return true }
                    s.waiters.append(.init(shared: shared, continuation: continuation))
                    return false
                }
                if acquired { continuation.resume() }
            }
        }
        defer { release(shared: shared) }
        // An already running SQL cycle has a finite deadline. Cancellation of a
        // waiting child is observed after it drains, without escaping its lease.
        try Task.checkCancellation()
        return try await operation()
    }
    private func release(shared: Bool) {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            if shared { s.shared -= 1 } else { s.exclusive = false }
            var ready: [CheckedContinuation<Void, Never>] = []
            while let first = s.waiters.first, !s.exclusive {
                if !first.shared && s.shared > 0 { break }
                s.waiters.removeFirst()
                if first.shared { s.shared += 1 } else { s.exclusive = true }
                ready.append(first.continuation)
            }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }
}
