import FluentKit
import Foundation

/// Carries a granted call's absolute SQL budget across domain layers. This is
/// scheduling context only: it never supplies or substitutes an activation
/// token, owner fence, or authorization decision.
enum V2RoomSQLDeadline {
    @TaskLocal static var current: ContinuousClock.Instant?
    static let maximumTransactionDuration: Duration = .seconds(10)

    static func boundedTransactionDeadline() -> ContinuousClock.Instant {
        let limit = ContinuousClock.now + maximumTransactionDuration
        return current.map { min($0, limit) } ?? limit
    }

    nonisolated(nonsending) static func withDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        let selected = current.map { min($0, deadline) } ?? deadline
        return try await $current.withValue(selected, operation: operation)
    }

    /// A batcher selects work from several callers. It must replace the
    /// inherited task context with the earliest deadline in that selection.
    nonisolated(nonsending) static func withSelectedDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant?,
        _ operation: () async throws -> Value
    ) async rethrows -> Value {
        try await $current.withValue(deadline, operation: operation)
    }
}

/// Only room-scoped call sites opt in. A direct token-scoped store call gets a
/// fixed ten-second budget; an admitted call uses the earlier host deadline.
/// Legacy control calls retain Fluent's transaction implementation.
func v2WithRoomScopedTransaction<Value: Sendable>(
    database: any Database,
    timeouts: V2RoomActivationSQLTimeouts = .default,
    useRoomDeadline: Bool = true,
    _ operation: @escaping @Sendable (any Database) async throws -> Value
) async throws -> Value {
    if useRoomDeadline {
        return try await v2WithRoomActivationTransaction(
            database: database, deadline: V2RoomSQLDeadline.boundedTransactionDeadline(),
            timeouts: timeouts, operation)
    }
    return try await database.transaction(operation)
}
