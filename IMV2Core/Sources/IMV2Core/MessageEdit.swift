import Foundation

/// 带预期消息修订号的编辑命令，身份及幂等操作由调用者提供。
///
/// 仅替换可变文本；权威事务拒绝已撤回消息的编辑，不能由客户端模型恢复已撤回内容。
public struct V2EditMessageCommand: Equatable, Sendable {
    /// 目标消息房间。
    public let roomID: RoomID
    /// 请求操作者，存在该字段不代表已经授权。
    public let actorUserID: UserID
    /// 本次编辑的稳定幂等操作身份。
    public let operationID: MessageEditOperationID
    /// 目标消息身份。
    public let messageID: MessageID
    /// 调用者观察到的消息内容修订号，由事务进行并发比较。
    public let expectedRevision: V2MessageRevision
    /// 向传输或存储暴露预期修订号的 UInt64 原始值。
    public var expectedMessageRevision: UInt64 { expectedRevision.rawValue }
    /// 替换文本的原始值，不裁剪空白或进行 Unicode 规范化。
    public let text: String

    /// 构造命令并将预期版本包装为经过范围校验的消息修订号。
    ///
    /// - Parameters:
    ///   - roomID: 消息所在房间。
    ///   - actorUserID: 操作者身份。
    ///   - operationID: 跨本次重试稳定的操作身份。
    ///   - messageID: 目标消息。
    ///   - expectedMessageRevision: 调用者观察到的消息修订号。
    ///   - text: 非空原始文本，纯空白在此仍允许。
    ///   - maximumUTF8Bytes: 必须为正的文本字节上限。
    /// - Throws: 上限非正、文本为空或超长时抛出 invalidText；修订号无效时抛出版本校验错误。
    ///
    /// 先校验文本再校验版本，不在此判断操作者权限或消息当前状态。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageEditOperationID, messageID: MessageID, expectedMessageRevision: UInt64, text: String, maximumUTF8Bytes: Int) throws {
        guard maximumUTF8Bytes > 0,
              !text.isEmpty,
              text.utf8.count <= maximumUTF8Bytes
        else { throw V2MessageEditValidationError.invalidText }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.expectedRevision = try .init(expectedMessageRevision)
        self.text = text
    }
}

/// 权威编辑处理返回的消息版本、房间事件顺序及事件身份。
///
/// 此值不执行持久化或投递，调用方负责从一致的事务结果构造。
public struct V2MessageEdit: Equatable, Sendable {
    /// 变更所属房间。
    public let roomID: RoomID
    /// 发生变更的消息。
    public let messageID: MessageID
    /// 编辑后的文本，结果构造器不重复校验非空或长度上限。
    public let text: String
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
    ///   - text: 已由业务路径校验的编辑后文本。
    ///   - messageRevision: 变更后的内容版本。
    ///   - roomSequence: 变更事件的房间序号。
    ///   - eventID: 已确定的事件身份。
    ///   - createdAt: 变更创建时间。
    /// - Throws: 任一版本或序号越界时抛出 outOfRange。
    ///
    /// 不验证相对旧版本的递增关系、创建时间或持久化状态。
    public init(roomID: RoomID, messageID: MessageID, text: String, messageRevision: UInt64, roomSequence: UInt64, eventID: EventID, createdAt: Date) throws {
        guard messageRevision > 0, messageRevision <= UInt64(Int64.max),
              roomSequence > 0, roomSequence <= UInt64(Int64.max)
        else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.text = text
        self.messageRevision = messageRevision
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.createdAt = createdAt
    }
}

/// 消息编辑输入校验错误。
public enum V2MessageEditValidationError: Error, Equatable, Sendable {
    /// 文本为空、UTF-8 字节数超过限制，或配置的上限非正。
    case invalidText
}
