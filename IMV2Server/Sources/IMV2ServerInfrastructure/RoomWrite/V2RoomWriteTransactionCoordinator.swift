import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit

/// A borrowed operation transaction has not committed when its write body returns.
/// Only its outer receipt owner may publish a durable completion.
enum V2RoomWriteTransactionOwnership: Sendable {
    case store
    case operationReceipt

    var borrowsTransaction: Bool { self == .operationReceipt }
}

/// Owns transaction entry and completion. Path components only
/// receive the borrowed connection and cannot choose a different commit boundary.
struct V2RoomWriteTransactionCoordinator: Sendable {
    let database: any Database
    let ownership: V2RoomWriteTransactionOwnership
    let hasActivationScope: Bool

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Value {
        try await v2WithPostgresTransactionRetry(database: database,
            classifyCommitFailure: hasActivationScope, useRoomDeadline: hasActivationScope,
            existingTransaction: ownership.borrowsTransaction) { transaction in
            let result = try await operation(transaction)
            return result
        }
    }

    func runWithFenceContext<Value: Sendable>(
        _ operation: @escaping @Sendable (any Database, V2ConfiguredRoomFenceContext?) async throws -> Value
    ) async throws -> Value {
        try await v2WithPostgresTransactionRetryWithRoomContext(database: database,
            classifyCommitFailure: hasActivationScope, useRoomDeadline: hasActivationScope,
            existingTransaction: ownership.borrowsTransaction) { transaction, context in
            let result = try await operation(transaction, context)
            return result
        }
    }
}
