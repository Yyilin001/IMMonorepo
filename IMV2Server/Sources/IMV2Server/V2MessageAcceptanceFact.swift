import Foundation
import IMV2Core
import SQLKit

/// 消息的不可变接受凭据。
struct V2MessageAcceptanceFact: Sendable {
    /// 接受事件标识。
    let eventID: UUID
    /// 接受时冻结的成员修订。
    let membershipRevision: Int64
    /// 接受事件在房间日志中的序号。
    let roomSequence: Int64

}

/// 读取消息接受凭据时的错误。
enum V2MessageAcceptanceFactError: Error, Sendable {
    /// 完成记录缺失或与消息行不一致，不能确认接受身份。
    case unavailable
}

/// 读取指定消息的接受凭据。
///
/// 通过消息行的既有索引沿着完成主键查询，不需要消息标识扫描，也不需要新增热写索引；
/// 已接受成员修订由完成记录提供，作为不同房间事件存储形式共用的权威值。
///
/// - Parameters:
///   - messageID: 目标消息。
///   - roomID: 目标房间。
///   - sql: 当前事务使用的数据库连接。
/// - Returns: 消息接受凭据。
/// - Throws: 完成记录缺失、房间序号非正或与消息行不一致、成员修订为负时抛出
///   ``V2MessageAcceptanceFactError/unavailable``。
func v2MessageAcceptanceFact(messageID: UUID, roomID: UUID, sql: any SQLDatabase) async throws -> V2MessageAcceptanceFact {
    // 通过已有索引的消息行查找现有完成记录的主键。
    // 无需扫描消息 ID，也无需新增高频写入索引。
    // 两种受支持的房间日志存储形式，都由完成记录持有已接受的成员版本。
    guard let row = try await sql.raw(v2MessageAcceptanceFactQuery(
        messageID: "\(bind: messageID)", roomID: "\(bind: roomID)"
    )).first(decoding: MessageAcceptanceFactRow.self),
          row.messageID == messageID,
          row.roomSequence > 0, row.roomSequence == row.messageRoomSequence,
          row.membershipRevision >= 0
    else { throw V2MessageAcceptanceFactError.unavailable }
    return .init(eventID: row.eventID,
        membershipRevision: row.membershipRevision, roomSequence: row.roomSequence)
}

/// 供命令路径与事件日志读取共用的可组合索引查询。
///
/// 传入的 SQL 片段始终由服务端构造，绝不接受客户端提供的 SQL。
///
/// - Parameters:
///   - messageID: 已绑定参数的消息标识表达式。
///   - roomID: 已绑定参数的房间标识表达式。
/// - Returns: 查询已接受投递事实的 SQL 片段。
func v2MessageAcceptanceFactQuery(messageID: SQLQueryString, roomID: SQLQueryString) -> SQLQueryString {
    """
    SELECT completion.message_id, completion.event_id, completion.room_sequence,
           completion.accepted_membership_revision,
           message.room_sequence AS message_room_sequence
    FROM im_v2.messages AS message
    JOIN im_v2.message_send_completions AS completion
      ON completion.room_id = message.room_id
     AND completion.sender_user_id = message.sender_user_id
     AND completion.client_message_id = message.client_message_id
    WHERE message.message_id = \(messageID) AND message.room_id = \(roomID)
      AND completion.message_id = message.message_id
      AND completion.room_sequence = message.room_sequence
    """
}

private struct MessageAcceptanceFactRow: Decodable {
    let messageID: UUID
    let eventID: UUID
    let roomSequence: Int64
    let membershipRevision: Int64
    let messageRoomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", eventID = "event_id", roomSequence = "room_sequence"
        case membershipRevision = "accepted_membership_revision"
        case messageRoomSequence = "message_room_sequence"
    }
}
