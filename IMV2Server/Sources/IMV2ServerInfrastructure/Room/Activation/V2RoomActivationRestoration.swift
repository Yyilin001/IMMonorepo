import FluentKit
import IMV2ActorContracts
import SQLKit

/// Checks the durable activation before the composition owner publishes handlers.
/// Inherits the caller's absolute SQL deadline and releases the transaction first.
package func v2ValidateRoomActivation(database: any Database, token: V2RoomActivationToken) async throws {
    try await v2WithRoomScopedTransaction(database: database) { transaction in
        guard let sql = transaction as? any SQLDatabase else {
            throw V2SchemaReadinessError.unsupportedDatabase
        }
        try await v2RequireRoomActivation(token: token, sql: sql)
    }
}
