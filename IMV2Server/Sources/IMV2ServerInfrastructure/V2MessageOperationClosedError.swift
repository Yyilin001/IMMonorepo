import IMV2ServerApplication
import IMV2ServerContracts
import PostgresNIO

/// Only the named completion trigger means the operation is permanently closed; arbitrary SQL failures stay infrastructure errors.
func v2IsMessageOperationClosed(_ error: any Error) -> Bool {
    let state: String?, constraint: String?
    if let error = error as? PSQLError {
        state = error.serverInfo?[.sqlState]; constraint = error.serverInfo?[.constraintName]
    } else if let error = error as? PostgresError, case .server(let message) = error {
        state = message.fields[.sqlState]; constraint = message.fields[.constraintName]
    } else { return false }
    return state == "23514" && constraint == "message_operation_permanently_closed"
}

/// Translate only the named PostgreSQL completion trigger into the domain's
/// permanent negative receipt. Other database errors keep their original type.
func v2NormalizeMessageOperationClosed(_ error: any Error) -> any Error {
    v2IsMessageOperationClosed(error) ? V2RoomWriteStoreError.messageOperationClosed : error
}
