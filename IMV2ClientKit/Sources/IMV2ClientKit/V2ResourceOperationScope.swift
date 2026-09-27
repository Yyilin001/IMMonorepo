import Foundation

public enum V2ResourceOperationScopeError: Error, Equatable, Sendable {
    case busy
}

/// Owns resource journal calls as well as network work. Closing a transfer's
/// shared flight alone is insufficient: a caller can still be awaiting a local
/// transaction or starting another operation after an actor suspension.
public actor V2ResourceOperationScope {
    private struct Running: Sendable {
        let cancel: @Sendable () -> Void
        let drain: @Sendable () async -> Void
    }
    private let limit: Int
    private var closed = false
    private var running: [UUID: Running] = [:]

    public init(limit: Int = 32) {
        precondition(limit > 0)
        self.limit = limit
    }

    /// Each admission has one caller. Cancellation reaches its operation, but
    /// we still await actual completion, including non-cooperative I/O. Shared
    /// mutations below this scope retain their independent waiter semantics.
    public func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard running.count < limit else { throw V2ResourceOperationScopeError.busy }
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        running[id] = .init(cancel: { task.cancel() }, drain: { _ = await task.result })
        defer { running.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            return value
        } onCancel: { task.cancel() }
    }

    /// Terminal and safe for concurrent/repeated callers. The owner may close
    /// its database or files only after this returns. Never call from run().
    public func close() async {
        closed = true
        let admitted = Array(running.values)
        for operation in admitted { operation.cancel() }
        for operation in admitted { await operation.drain() }
    }

    // Counts only; diagnostics never expose resource identities or credentials.
    func activeCount() -> Int { running.count }
}
