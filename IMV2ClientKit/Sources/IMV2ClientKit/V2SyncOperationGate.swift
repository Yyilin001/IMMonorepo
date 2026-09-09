import Foundation

/// Shared by sync engines writing the same local store. The permit covers
/// pull/apply/ACK and snapshot activation across suspension points. Cancelling
/// a queued caller removes only its wait, never another caller's operation.
/// Operations must not recursively enter this gate.
public actor V2SyncOperationGate {
    private var owner: UUID?
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init() {}

    var waitingOperationCount: Int { waiters.count }

    func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await acquire(id)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(id)
            return result
        } catch {
            release(id)
            throw error
        }
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil { owner = id; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWait(id) }
        }
    }

    private func cancelWait(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard owner == id else { return }
        guard !waiters.isEmpty else { owner = nil; return }
        let next = waiters.removeFirst()
        owner = next.id
        next.continuation.resume()
    }
}
