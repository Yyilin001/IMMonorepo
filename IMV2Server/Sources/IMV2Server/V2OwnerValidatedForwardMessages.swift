import Foundation
import IMV2Core
import SQLKit

/// Local forwarding requires both endpoints, including colocated shards.
public protocol V2OwnerValidatedForwardMessagesHandling: V2ForwardMessagesHandling {
    func forwardOwnerValidated(actorUserID: UserID, command: V2ForwardMessagesCommand,
        ownerRoutes: [RoomID: V2RoomShardRoute]) async throws -> [V2ForwardMessageResult]
}

public protocol V2OwnerValidatedForwardMessageWriteStore: V2RoomWriteStore {
    func acceptForwardOwnerValidated(request: V2RoomWriteRequest, sourceRoomID: RoomID,
        sourceOwnerRoute: V2RoomShardRoute, targetOwnerRoute: V2RoomShardRoute) async throws -> V2SendMessageOutcome
}

/// Caller owns the transaction; no lock survives across another store call.
/// All endpoints are locked in UUID order before ledger or message row locks.
func v2RequireForwardOwners(_ routes: [UUID: V2RoomShardRoute], readOnly: Bool = false,
    sql: any SQLDatabase) async throws {
    let requested = String(decoding: try JSONEncoder().encode(routes.keys.map(\.uuidString)), as: UTF8.self)
    let locking = readOnly ? "FOR SHARE" : "FOR UPDATE"
    let rows = try await sql.raw("""
        SELECT room_id, room_shard_id, owner_epoch FROM im_v2.rooms
        WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: requested)::jsonb))
        ORDER BY room_id \(unsafeRaw: locking)
        """).all(decoding: ForwardSelectedOwnerRow.self)
    guard rows.count == routes.count, rows.allSatisfy({ row in
        guard let route = routes[row.roomID] else { return false }
        return row.shardID == route.shardID && row.epoch == route.epoch
    }) else { throw V2RoomOwnerFenceError.ownerChanged }
}

private struct ForwardSelectedOwnerRow: Decodable {
    let roomID: UUID; let shardID: String; let epoch: Int64
    enum CodingKeys: String, CodingKey { case roomID = "room_id", shardID = "room_shard_id", epoch = "owner_epoch" }
}
