import Foundation
import SQLKit

/// 把刚加入房间的成员的已读线初始化到当前房间头。
///
/// 房间读模型以 `rooms.room_sequence` 与 `room_read_receipts.read_through_room_sequence`
/// 之差计算未读。房间头之前的消息对刚加入的用户不可见（房间内容的可见性按
/// “事件发生时成员 ∩ 当前成员”判定），因此它们不得计为未读；同时房间日志的保留
/// 下限取活跃用户已读线的下界，缺少初始已读线会把下限钉在零，使日志无法裁剪。
///
/// - Important: 调用方只能传入**本次真正加入**的用户。对存量成员重复调用会把他们的
///   未读误标为已读。角色变更、昵称变更等虽然会开启新的成员区间，但成员资格并未中断，
///   不得调用本函数。
///
/// - Parameters:
///   - roomID: 目标房间。
///   - userID: 本次加入的用户。
///   - now: 服务端统一授时时刻。
///   - sql: 已处于加入事务中的数据库句柄；房间行需已锁定并写入新的房间序号。
/// - Throws: 时钟不可编码或持久化失败。
func v2InitializeJoinedMemberReadWatermark(
    roomID: UUID,
    userID: UUID,
    now: Date,
    sql: any SQLDatabase
) async throws {
    guard v2PostgresTimestampCanEncode(now) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    try await sql.raw("""
        INSERT INTO im_v2.room_read_receipts AS receipt
            (room_id, user_id, read_through_room_sequence, updated_at)
        SELECT room.room_id, \(bind: userID), room.room_sequence, \(bind: now)
        FROM im_v2.rooms AS room
        WHERE room.room_id = \(bind: roomID) AND room.room_sequence > 0
        ON CONFLICT (room_id, user_id) DO UPDATE
        SET read_through_room_sequence = GREATEST(
                receipt.read_through_room_sequence,
                EXCLUDED.read_through_room_sequence
            ),
            updated_at = GREATEST(receipt.updated_at, EXCLUDED.updated_at)
        """).run()
}

/// 在**房间创建事务内**为全部初始成员初始化已读线到房间头。
///
/// 只有房间创建事务可以调用：该事务中这个房间的全部活跃成员都是本次新加入的成员，
/// 因此“为所有活跃成员初始化”等价于“为本次加入的成员初始化”。任何其他场景都必须
/// 使用 ``v2InitializeJoinedMemberReadWatermark(roomID:userID:now:sql:)``，否则会把存量
/// 成员的未读误标为已读。
///
/// - Parameters:
///   - roomID: 刚创建的房间。
///   - now: 服务端统一授时时刻。
///   - sql: 已插入房间与初始成员、且成员事务仍持有房间行的数据库句柄。
/// - Throws: 时钟不可编码或持久化失败。
func v2InitializeNewRoomReadWatermarks(
    roomID: UUID,
    now: Date,
    sql: any SQLDatabase
) async throws {
    guard v2PostgresTimestampCanEncode(now) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    try await sql.raw("""
        INSERT INTO im_v2.room_read_receipts AS receipt
            (room_id, user_id, read_through_room_sequence, updated_at)
        SELECT member.room_id, member.user_id, room.room_sequence, \(bind: now)
        FROM im_v2.room_memberships AS member
        JOIN im_v2.rooms AS room ON room.room_id = member.room_id
        WHERE member.room_id = \(bind: roomID)
          AND member.left_revision IS NULL
          AND room.room_sequence > 0
        ON CONFLICT (room_id, user_id) DO UPDATE
        SET read_through_room_sequence = GREATEST(
                receipt.read_through_room_sequence,
                EXCLUDED.read_through_room_sequence
            ),
            updated_at = GREATEST(receipt.updated_at, EXCLUDED.updated_at)
        """).run()
}
