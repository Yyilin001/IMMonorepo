import Foundation

/// 带预期消息修订号的撤回命令，身份及幂等操作由调用者提供。
///
/// 撤回以墓碑事件保留顺序和审计语义，模型本身不删除历史；权限、窗口及版本比较由权威事务执行。
public struct V2WithdrawMessageCommand: Equatable, Sendable {
    /// 目标消息房间。
    public let roomID: RoomID
    /// 请求操作者，存在该字段不代表已经授权。
    public let actorUserID: UserID
    /// 本次撤回的稳定幂等操作身份。
    public let operationID: MessageWithdrawalOperationID
    /// 目标消息身份。
    public let messageID: MessageID
    /// 调用者观察到的消息内容修订号，由事务进行并发比较。
    public let expectedRevision: V2MessageRevision
    /// 向传输或存储暴露预期修订号的 UInt64 原始值。
    public var expectedMessageRevision: UInt64 { expectedRevision.rawValue }

    /// 构造命令并将预期版本包装为经过范围校验的消息修订号。
    ///
    /// - Parameters:
    ///   - roomID: 消息所在房间。
    ///   - actorUserID: 操作者身份。
    ///   - operationID: 跨本次重试稳定的操作身份。
    ///   - messageID: 目标消息。
    ///   - expectedMessageRevision: 调用者观察到的消息修订号。
    /// - Throws: 预期修订号不符合 V2MessageRevision 范围时抛出版本校验错误。
    ///
    /// 不在此判断消息是否已撤回或操作者是否有权撤回。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageWithdrawalOperationID, messageID: MessageID, expectedMessageRevision: UInt64) throws {
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedRevision = try .init(expectedMessageRevision)
    }
}

/// 权威撤回处理返回的消息版本、房间事件顺序及事件身份。
///
/// 此值不执行持久化或投递，调用方负责从一致的事务结果构造。
public struct V2MessageWithdrawal: Equatable, Sendable {
    /// 变更所属房间。
    public let roomID: RoomID
    /// 发生变更的消息。
    public let messageID: MessageID
    /// 变更结果的消息修订号。
    public let messageRevision: UInt64
    /// 变更事件的房间顺序号。
    public let roomSequence: UInt64
    /// 本次变更事件身份。
    public let eventID: EventID
    /// 变更创建时间，构造器不检查有限性或当前有效性。
    public let createdAt: Date

    /// 构造变更结果，要求消息版本与房间序号均在 1 到 Int64.max 范围内。
    ///
    /// - Parameters:
    ///   - roomID: 变更所属房间。
    ///   - messageID: 目标消息。
    ///   - messageRevision: 变更后的内容版本。
    ///   - roomSequence: 变更事件的房间序号。
    ///   - eventID: 已确定的事件身份。
    ///   - createdAt: 变更创建时间。
    /// - Throws: 任一版本或序号越界时抛出 outOfRange。
    ///
    /// 不验证相对旧版本的递增关系、创建时间或持久化状态。
    public init(roomID: RoomID, messageID: MessageID, messageRevision: UInt64, roomSequence: UInt64, eventID: EventID, createdAt: Date) throws {
        guard messageRevision > 0, messageRevision <= UInt64(Int64.max),
              roomSequence > 0, roomSequence <= UInt64(Int64.max)
        else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.createdAt = createdAt
    }
}
