import Foundation

/// Explicit runtime ownership, separate from cancellation of a UI waiter.
public protocol V2CommandFlushControlling: Sendable {
    func suspendCommandFlushing() async
    func resumeCommandFlushing() async
}

/// One task owns selection, transport and durable completion for an entire
/// lane. Actor isolation alone cannot protect these steps across awaits.
actor V2CommandFlushFlight<Value: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Value, any Error>
    }
    private var flight: Flight?
    private var isSuspended = false
    private var lifecycleID = UUID()

    func run(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !isSuspended else { throw CancellationError() }
        let current: Flight
        if let flight {
            current = flight
        } else {
            current = .init(id: UUID(), task: Task { try await operation() })
            flight = current
        }
        // An individual caller cannot cancel the account-owned shared task.
        let result = await current.task.result
        if flight?.id == current.id { flight = nil }
        try Task.checkCancellation()
        return try result.get()
    }

    func suspend() {
        lifecycleID = UUID()
        isSuspended = true
        flight?.task.cancel()
    }

    func resume() async {
        let resumingID = lifecycleID
        // Drain any task cancelled by the previous connection before another
        // connection can select the same pending command.
        if let current = flight {
            _ = await current.task.result
            if flight?.id == current.id { flight = nil }
        }
        guard resumingID == lifecycleID else { return }
        isSuspended = false
    }
}
