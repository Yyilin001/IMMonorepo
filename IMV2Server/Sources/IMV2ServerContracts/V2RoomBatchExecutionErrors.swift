import Foundation

/// 事务主体成功返回，但驱动未确认 COMMIT。
/// 调用方既不能退还已消耗额度，也不能继续轮次。
package struct V2RoomTransactionOutcomeUnknown: Error, Sendable {
    package init() {}
}

public enum V2SendMessageAdmissionBatcherError: Error, Sendable, Equatable {
    /// 批次暂存队列或其自有的数据库准入队列已满（或有界等待已超时）。
    ///
    /// 协议会把它映射为可重试的 `SERVER_BUSY`，绝不映射为持久化失败。
    case serverBusy
}
