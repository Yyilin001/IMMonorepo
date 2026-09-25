import Foundation

/// 授权仅适用于一次激活和一次协调尝试。没有事务的激活栅栏时，
/// 它不授予数据库写入权限。
public struct V2RoomReservation: Hashable, Codable, Sendable {
    public let token: V2RoomActivationToken
    public let requestID: UUID
    public let reservationID: UUID

    public init(token: V2RoomActivationToken, requestID: UUID, reservationID: UUID) {
        self.token = token
        self.requestID = requestID
        self.reservationID = reservationID
    }
}

/// 只有收到每个房间派发确认的协调者才能开始执行 SQL。
/// 完成状态未知时，所有参与的激活都要退役。
public enum V2RoomReservationCompletion: String, Codable, Sendable {
    case committed
    case rolledBack
    case outcomeUnknown
}
