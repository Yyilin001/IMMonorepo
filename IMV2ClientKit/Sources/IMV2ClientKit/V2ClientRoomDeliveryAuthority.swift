import Foundation
import IMV2Core

/// 服务端宣告的房间权威副本形态。
///
/// 客户端据此决定该房间是否纳入按游标恢复的集合。刻意不从投递模式推断：投递模式描述用
/// 哪种扇出规划器并在房间创建后不可变，而权威副本形态可以按房间推进，标准群将来会以
/// `room_log` 出现而不改投递模式。
public enum V2ClientRoomDeliveryAuthority: String, Equatable, Sendable {
    /// 逐用户投递是权威副本；房间日志只是加速。
    case fanout
    /// 房间事件日志是权威副本；客户端按房间游标恢复。
    case roomLog = "room_log"

}
