import FluentKit
import IMV2ActorContracts
import SQLKit

/// Created by the activation restoration boundary; never from client input.
package struct V2RoomSendInitialization: Sendable {
    let token: V2RoomActivationToken
    let kind: String
    let directState: V2DirectRoomSendAcceptanceMemory.State?
}

/// Host owns activation validation; this transaction reads consistent business state.
package func v2RestoreRoomSendInitialization(database: any Database, token: V2RoomActivationToken) async throws -> V2RoomSendInitialization {
    try await v2WithRoomScopedTransaction(database: database) { transaction in
        guard let sql = transaction as? any SQLDatabase else { throw V2SchemaReadinessError.unsupportedDatabase }
        return try await V2DirectRoomSendAcceptanceMemory.readInitialization(sql: sql, token: token)
    }
}
