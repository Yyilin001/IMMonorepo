import Synchronization

/// The transaction body returned successfully, but the driver did not confirm
/// COMMIT. A caller must neither refund consumed credits nor continue its turn.
struct V2RoomTransactionOutcomeUnknown: Error, Sendable {}

/// One journal per transaction attempt, not per command. Nothing is marked
/// committed until Database.transaction itself returns successfully.
final class V2RoomTransactionAttempt: Sendable {
    private let returnedToDriver = Mutex(false)

    func body<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let value = try await operation()
        returnedToDriver.withLock { $0 = true }
        return value
    }

    func classify(_ error: any Error) -> any Error {
        // PostgreSQL's deadlock/serialization errors prove transaction abort,
        // including deferred failures during COMMIT. Other commit-stage errors
        // stay uncertain even when their diagnostic text sounds retryable.
        if returnedToDriver.withLock({ $0 }),
           v2PostgresFailureDisposition(error) != .retryTransaction {
            return V2RoomTransactionOutcomeUnknown()
        }
        return error
    }
}
