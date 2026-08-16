import AsyncKit
import Fluent
import Foundation
import PostgresNIO

enum V2PostgresFailureDisposition: Equatable, Sendable {
    case retryTransaction
    case unavailable
    case other
}

/// Keeps database-driver details at the PostgreSQL boundary. Only failures
/// known to be transient are converted into retryable protocol responses;
/// programming errors and constraint violations still surface normally.
func v2PostgresFailureDisposition(_ error: any Error) -> V2PostgresFailureDisposition {
    if error is ConnectionPoolTimeoutError || error is ConnectionPoolError {
        return .unavailable
    }
    if let error = error as? PSQLError {
        if let state = error.serverInfo?[.sqlState] {
            return v2PostgresFailureDisposition(sqlState: state)
        }
        switch error.code {
        case .queryCancelled,
             .clientClosedConnection,
             .serverClosedConnection,
             .connectionError,
             .uncleanShutdown,
             .poolClosed:
            return .unavailable
        default:
            return .other
        }
    }
    if let error = error as? PostgresError {
        switch error {
        case .server(let message):
            guard let state = message.fields[.sqlState] else { return .other }
            return v2PostgresFailureDisposition(sqlState: state)
        case .connectionClosed:
            return .unavailable
        case .protocol:
            return .other
        }
    }
    return .other
}

private func v2PostgresFailureDisposition(sqlState: String) -> V2PostgresFailureDisposition {
    switch sqlState {
    case "40P01", "40001":
        return .retryTransaction
    case "55P03", "57014", "57P01", "57P02", "57P03":
        return .unavailable
    default:
        if sqlState.hasPrefix("08") || sqlState.hasPrefix("53") {
            return .unavailable
        }
        return .other
    }
}

/// Retries the complete transaction after PostgreSQL has rolled it back for a
/// deadlock or serialization failure. Retrying a statement inside an aborted
/// transaction is invalid, so callers must put the whole idempotent command in
/// this boundary.
func v2WithPostgresTransactionRetry<Result: Sendable>(
    database: any Database,
    maximumRetryCount: Int = 2,
    _ operation: @escaping @Sendable (any Database) async throws -> Result
) async throws -> Result {
    precondition(maximumRetryCount >= 0)
    var retryCount = 0
    while true {
        try Task.checkCancellation()
        do {
            return try await database.transaction(operation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard v2PostgresFailureDisposition(error) == .retryTransaction,
                  retryCount < maximumRetryCount
            else { throw error }
            retryCount += 1
            // Short randomized backoff prevents opposing requests from
            // immediately rebuilding the same wait-for graph.
            let lowerNanoseconds = UInt64(retryCount) * 2_000_000
            let upperNanoseconds = UInt64(retryCount) * 8_000_000
            try await Task.sleep(
                nanoseconds: UInt64.random(in: lowerNanoseconds ... upperNanoseconds)
            )
        }
    }
}
