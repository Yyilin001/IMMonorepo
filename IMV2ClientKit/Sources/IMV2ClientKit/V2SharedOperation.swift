import Foundation

/// One owner task, independently cancellable waiters. A timed-out consumer
/// can leave without cancelling a refresh/load still needed by other callers.
final class V2SharedOperation<Value: Sendable>: Sendable {
    private let completion: Completion
    private let task: Task<Value, Error>

    init(_ operation: @escaping @Sendable () async throws -> Value) {
        let completion = Completion()
        self.completion = completion
        task = Task {
            let result: Result<Value, Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            await completion.resolve(result)
            return try result.get()
        }
    }

    var value: Value { get async throws { try await completion.wait() } }
    var result: Result<Value, Error> { get async { await task.result } }
    func cancel() { task.cancel() }

    private actor Completion {
        private var result: Result<Value, Error>?
        private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

        func wait() async throws -> Value {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if let result { return try result.get() }
                return try await withCheckedThrowingContinuation { waiters[id] = $0 }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
        func resolve(_ result: Result<Value, Error>) {
            guard self.result == nil else { return }
            self.result = result
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume(with: result) }
        }
    }
}
