import Foundation
import IMV2ClientRuntime

public enum V2DirectoryServiceError: Error, Sendable { case closed, invalidInput }

/// Every observation has its own subscription; closing one window does not close another.
/// Account shutdown cancels and drains both HTTP work and producer tasks before SQLite closes.
actor V2DirectoryLifetime {
    private let onClose: @Sendable () async -> Void
    init(onClose: @escaping @Sendable () async -> Void = {}) { self.onClose = onClose }
    private let operations = V2ResourceOperationScope(limit: 128)
    private var closed = false
    private var closing: Task<Void, Never>?
    private var observers: [UUID: (task: Task<Void, Never>, finish: @Sendable () -> Void)] = [:]
    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw V2DirectoryServiceError.closed }
        let value = try await operations.run(body)
        guard !closed else { throw V2DirectoryServiceError.closed }
        try Task.checkCancellation()
        return value
    }
    func observe<T: Sendable>(_ source: @escaping @Sendable () async -> AsyncThrowingStream<T, any Error>) -> AsyncThrowingStream<T, any Error> {
        let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !closed else { continuation.finish(throwing: V2DirectoryServiceError.closed); return stream }
        let id = UUID()
        let task = Task { [weak self] in
            do {
                for try await value in await source() {
                    try Task.checkCancellation()
                    continuation.yield(value)
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            await self?.removeObserver(id)
        }
        observers[id] = (task, { continuation.finish(throwing: V2DirectoryServiceError.closed) })
        // Keep the cancelled producer registered until it has physically returned.
        // Otherwise account close could miss a still-draining source after a window closes.
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.task.cancel() }

    func close() async {
        if let closing { await closing.value; return }
        closed = true
        let captured = Array(observers.values); observers.removeAll()
        let task = Task { [operations, onClose] in
            for observer in captured { observer.task.cancel(); observer.finish() }
            await operations.close()
            for observer in captured { await observer.task.value }
            await onClose()
        }
        closing = task; await task.value
    }
}
