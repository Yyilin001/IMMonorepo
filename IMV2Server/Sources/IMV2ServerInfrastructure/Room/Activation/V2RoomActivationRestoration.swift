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

/// Created by the activation restoration boundary; never from client input.
package struct V2RoomSendInitialization: Sendable {
    let token: V2RoomActivationToken
    let kind: String
    let directState: V2DirectRoomSendAcceptanceMemory.State?
}

/// One restoration transaction owns validation and the consistent room read.
package func v2RestoreRoomSendInitialization(database: any Database, token: V2RoomActivationToken,
    validateActivation: Bool = true) async throws -> V2RoomSendInitialization {
    try await v2WithRoomScopedTransaction(database: database) { transaction in
        guard let sql = transaction as? any SQLDatabase else { throw V2SchemaReadinessError.unsupportedDatabase }
        if validateActivation { try await v2RequireRoomActivation(token: token, sql: sql) }
        return try await V2DirectRoomSendAcceptanceMemory.readInitialization(sql: sql, token: token)
    }
}
