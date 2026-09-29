import IMV2Core

/// 面向可选进程本地投递加速的不挂起提交后边界。
///
/// 观察者只会收到数据库工作已成功完成的结果。
/// 它必须有界入队后立即返回；
/// 持久房间日志的可见性与请求成功从不依赖该观察者。
public protocol V2CommittedMessageBatchObserving: Sendable {
    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome])
    func observeCommittedRoomSequence(roomID: RoomID, roomSequence: UInt64)
}

public extension V2CommittedMessageBatchObserving {
    func observeCommittedRoomSequence(roomID: RoomID, roomSequence: UInt64) {}
}
