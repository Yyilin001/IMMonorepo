import IMV2Core
import IMV2ActorContracts

/// 面向可选进程本地投递加速的不挂起提交后边界。
///
/// 观察者只会收到业务写入与持久发布责任均已提交的结果。
/// 它必须有界入队后立即返回；
/// ACK 不等待在线扇出、套接字写入或权限恢复。
/// 持久房间日志及事务内登记的发布责任不依赖该观察者；
/// 观察者的邮箱溢出或进程退出不得撤销 durable 发布责任。
public protocol V2CommittedMessageBatchObserving: Sendable {
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken)
    func observeCommittedRoomSequence(roomID: RoomID, roomSequence: UInt64, activation: V2RoomActivationToken)
}

public extension V2CommittedMessageBatchObserving {
    func observeCommittedRoomSequence(roomID: RoomID, roomSequence: UInt64, activation: V2RoomActivationToken) {}
}
