import FluentKit
import IMV2ActorContracts

/// Created by the activation restoration boundary; never from client input.
package struct V2RoomSendInitialization: Sendable {
    let token: V2RoomActivationToken
    let kind: String
    let directState: V2DirectRoomSendAcceptanceMemory.State?
}

/// Host owns activation validation. One SELECT reads the complete committed
/// business state in a statement snapshot, without a separate transaction.
package func v2RestoreRoomSendInitialization(database: any Database, token: V2RoomActivationToken) async throws -> V2RoomSendInitialization {
    try await v2WithRoomSnapshotConnection(database: database,
        deadline: V2RoomSQLDeadline.boundedTransactionDeadline()) { sql in
        return try await V2DirectRoomSendAcceptanceMemory.readInitialization(sql: sql, token: token)
    }
}
