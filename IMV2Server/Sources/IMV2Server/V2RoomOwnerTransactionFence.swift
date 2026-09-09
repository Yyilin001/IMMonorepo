import Foundation
import SQLKit

public enum V2RoomOwnerFenceError: Error, Equatable, Sendable { case ownerChanged }

/// Call inside the mutation transaction after its operation lock and before
/// any receipt replay. The room lock is retained through business commit.
func v2RequireRoomOwner(roomID: UUID, route: V2RoomShardRoute, sql: any SQLDatabase) async throws {
    guard let room = try await sql.raw("""
        SELECT room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE
        """).first(decoding: RoomOwnerFenceRow.self),
          room.shardID == route.shardID, room.epoch == route.epoch
    else { throw V2RoomOwnerFenceError.ownerChanged }
}

private struct RoomOwnerFenceRow: Decodable {
    let shardID: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey { case shardID = "room_shard_id", epoch = "owner_epoch" }
}
