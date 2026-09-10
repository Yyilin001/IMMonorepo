import Foundation
import IMV2Core
import SQLKit

/// 持久化的投递权威来源。
///
/// 投递权威与房间默认配置、载荷存放位置无关；调用方必须持有房间与消息的变更锁
/// 之后才能读取该事实，以免读到并发变更中的中间状态。
enum V2StoredMessageDeliveryAuthority: String, Decodable, Sendable {
    /// 按个人投递路径处理。
    case personal
    /// 按房间日志路径处理。
    case roomLog = "room_log"

    // Reuse the existing admission/audit-plan implementation. This conversion
    // is execution policy only; it never changes a room's group delivery mode.
    /// 该权威来源对应的执行期投递模式，仅用于执行策略，不改变房间配置的投递模式。
    var eventDeliveryMode: V2GroupDeliveryMode {
        switch self {
        case .personal: .standardFanout
        case .roomLog: .largeGroupHybrid
        }
    }
}

/// 单条消息的已接受投递事实。
struct V2MessageAcceptedDelivery: Sendable {
    /// 投递权威来源。
    let authority: V2StoredMessageDeliveryAuthority
    /// 接受事件标识。
    let eventID: UUID
    /// 接受时冻结的成员修订。
    let membershipRevision: Int64
    /// 接受事件在房间日志中的序号。
    let roomSequence: Int64

    /// 生成可见成员目标规则 JSON。
    ///
    /// - Parameters:
    ///   - reservationUpperBound: 预留的目标数上界。
    ///   - leaseID: 预留租约标识。
    ///   - leaseGeneration: 预留租约代次。
    /// - Returns: 仅包含固定 UUID 与整数持久化事实的规则 JSON。
    func targetRuleJSON(reservationUpperBound: Int, leaseID: UUID, leaseGeneration: Int64) -> String {
        // Only fixed UUID/integer persistence facts enter this JSON.
        #"{"kind":"message_visible_members","accepted_membership_revision":\#(membershipRevision),"accepted_event_id":"\#(eventID.uuidString)","accepted_room_sequence":\#(roomSequence),"reservation_upper_bound":\#(reservationUpperBound),"reservation_lease_id":"\#(leaseID.uuidString)","reservation_lease_generation":\#(leaseGeneration)}"#
    }
}

/// 读取已接受投递事实时的错误。
enum V2MessageAcceptedDeliveryError: Error, Sendable {
    /// 完成记录缺失或与消息行不一致，当前无法判定投递。
    case unavailable
}

/// 读取指定消息的已接受投递事实。
///
/// 通过消息行的既有索引沿着完成主键查询，不需要消息标识扫描，也不需要新增热写索引；
/// 已接受成员修订由完成记录提供，因为历史房间事件存储会把消息行副本留在默认值。
///
/// - Parameters:
///   - messageID: 目标消息。
///   - roomID: 目标房间。
///   - sql: 当前事务使用的数据库连接。
/// - Returns: 已接受的投递事实。
/// - Throws: 完成记录缺失、房间序号非正或与消息行不一致、成员修订为负时抛出
///   ``V2MessageAcceptedDeliveryError/unavailable``。
func v2MessageAcceptedDelivery(messageID: UUID, roomID: UUID, sql: any SQLDatabase) async throws -> V2MessageAcceptedDelivery {
    // Follow the existing completion primary key via the already indexed
    // message row. No message-id scan or new hot-write index is required.
    // Completion owns the accepted membership revision: legacy room-event
    // storage leaves the physical message-row copy at its default value.
    guard let row = try await sql.raw(v2MessageAcceptedDeliveryQuery(
        messageID: "\(bind: messageID)", roomID: "\(bind: roomID)"
    )).first(decoding: AcceptedDeliveryRow.self),
          row.messageID == messageID,
          row.roomSequence > 0, row.roomSequence == row.messageRoomSequence,
          row.membershipRevision >= 0
    else { throw V2MessageAcceptedDeliveryError.unavailable }
    return .init(authority: row.authority, eventID: row.eventID,
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
func v2MessageAcceptedDeliveryQuery(messageID: SQLQueryString, roomID: SQLQueryString) -> SQLQueryString {
    """
    SELECT completion.message_id, completion.event_id, completion.room_sequence,
           completion.accepted_membership_revision, completion.delivery_authority,
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

private struct AcceptedDeliveryRow: Decodable {
    let messageID: UUID
    let eventID: UUID
    let roomSequence: Int64
    let membershipRevision: Int64
    let authority: V2StoredMessageDeliveryAuthority
    let messageRoomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id", eventID = "event_id", roomSequence = "room_sequence"
        case membershipRevision = "accepted_membership_revision", authority = "delivery_authority"
        case messageRoomSequence = "message_room_sequence"
    }
}
