import Foundation

/// 消息的不可变接受凭据。
package struct V2MessageAcceptanceFact: Sendable {
    /// 接受事件标识。
    package let eventID: UUID
    /// 接受时冻结的成员修订。
    package let membershipRevision: Int64
    /// 接受事件在房间日志中的序号。
    package let roomSequence: Int64

    package init(eventID: UUID, membershipRevision: Int64, roomSequence: Int64) {
        self.eventID = eventID; self.membershipRevision = membershipRevision; self.roomSequence = roomSequence
    }

}

/// 读取消息接受凭据时的错误。
package enum V2MessageAcceptanceFactError: Error, Sendable {
    /// 完成记录缺失或与消息行不一致，不能确认接受身份。
    case unavailable
}
