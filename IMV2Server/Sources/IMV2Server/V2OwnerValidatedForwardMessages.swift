import Foundation
import IMV2Core
import SQLKit

/// 本地转发能力，要求同时给出源房间与目标房间的归属，同物理分片也不例外。
public protocol V2OwnerValidatedForwardMessagesHandling: V2ForwardMessagesHandling {
    /// 按源房间与目标房间的归属执行转发。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    ///   - ownerRoutes: 本次涉及的全部房间归属，键为房间标识。
    /// - Returns: 与目标房间对应的转发结果。
    /// - Throws: 缺少任一房间的归属、归属已变更或持久化失败时抛出。
    func forwardOwnerValidated(actorUserID: UserID, command: V2ForwardMessagesCommand,
        ownerRoutes: [RoomID: V2RoomShardRoute]) async throws -> [V2ForwardMessageResult]
}

/// 按归属执行转发写入的房间写存储能力。
public protocol V2OwnerValidatedForwardMessageWriteStore: V2RoomWriteStore {
    /// 在源房间与目标房间的归属均已校验的前提下接受一条转发消息。
    ///
    /// - Parameters:
    ///   - request: 目标房间的写入请求。
    ///   - sourceRoomID: 转发来源房间。
    ///   - sourceOwnerRoute: 来源房间的已选定归属。
    ///   - targetOwnerRoute: 目标房间的已选定归属。
    /// - Returns: 目标房间的发送结果。
    /// - Throws: 任一归属已变更、来源授权失效或持久化失败时抛出。
    func acceptForwardOwnerValidated(request: V2RoomWriteRequest, sourceRoomID: RoomID,
        sourceOwnerRoute: V2RoomShardRoute, targetOwnerRoute: V2RoomShardRoute) async throws -> V2SendMessageOutcome
}

/// 在调用方自有的事务内一次性校验全部转发端点的房间归属。
///
/// 锁不会跨存储调用存续，因此调用方必须在同一事务内先完成本次校验，再写入台账或消息行；
/// 所有端点按房间标识的 UUID 顺序加锁，避免反向转发时形成死锁。
///
/// - Parameters:
///   - routes: 本次涉及的房间归属，键为房间标识。
///   - readOnly: 为 `true` 时只加 `FOR SHARE`，不阻塞其他共享读。
///   - sql: 当前事务使用的数据库连接。
/// - Throws: 房间行数不足、缺少对应归属或分片/代次不一致时抛出
///   ``V2RoomOwnerFenceError/ownerChanged``。
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
