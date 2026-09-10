import Foundation
import SQLKit

/// 房间归属栅栏校验错误。
public enum V2RoomOwnerFenceError: Error, Equatable, Sendable { case ownerChanged }

/// 在变更事务内、取得操作锁之后、回执重放之前调用，确认房间仍属于预期归属。
///
/// 校验会以 `FOR UPDATE` 锁定房间行并持有到业务提交，因此同一事务内的后续写入都不会
/// 与迁移并发；分片或代次任一不符即拒绝整个事务。
///
/// - Parameters:
///   - roomID: 需要校验的房间。
///   - route: 路由层选定的分片与代次。
///   - sql: 当前变更事务使用的数据库连接。
/// - Throws: 房间不存在或归属与 `route` 不一致时抛出
///   ``V2RoomOwnerFenceError/ownerChanged``。
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
