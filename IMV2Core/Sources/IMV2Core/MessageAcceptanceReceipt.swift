import Foundation

/// 消息发送提交后的不可变接受回执，只携带身份、顺序及投递元数据。
///
/// 不携带文本、实体、URL 或附件内容，内容擦除后仍可重放接受结果。读取内容必须走正常授权投影或查询路径。
/// 该结构不执行事务或验证提交证明，生产值应来自权威接受边界。
public struct V2MessageAcceptanceReceipt: Equatable, Sendable {
    /// 服务端分配的消息身份。
    public let messageID: MessageID
    /// 消息所属房间。
    public let roomID: RoomID
    /// 接受时记录的房间顺序值。
    public let roomSequence: UInt64
    /// 接受时记录的时间线顺序值，与房间顺序分开保存。
    public let timelineSequence: UInt64
    /// 原消息发送者。
    public let senderUserID: UserID
    /// 客户端发送幂等身份。
    public let clientMessageID: ClientMessageID
    /// 接受时的可选群投递模式。
    public let groupDeliveryMode: V2GroupDeliveryMode?
    /// 该接受结果是否使用房间事件日志路径。
    public let usesRoomEventLog: Bool
    /// 可选源事件身份。
    public let sourceEventID: EventID?
    /// 接受时绑定的可选成员修订号。
    public let acceptedMembershipRevision: UInt64?
    /// 私聊路径的可选接收者。
    public let directRecipientUserID: UserID?
    /// 原接受结果的创建时间，幂等重放不应改为重试时间。
    public let createdAt: Date

    /// 保存完整接受元数据，不校验序号范围、日期或不同投递字段的组合关系。
    ///
    /// 调用方应从同一已提交接受结果构造回执，不能混用不同尝试的事件、顺序或成员版本。
    public init(
        messageID: MessageID, roomID: RoomID, roomSequence: UInt64,
        timelineSequence: UInt64, senderUserID: UserID, clientMessageID: ClientMessageID,
        groupDeliveryMode: V2GroupDeliveryMode?, usesRoomEventLog: Bool,
        sourceEventID: EventID?, acceptedMembershipRevision: UInt64?,
        directRecipientUserID: UserID?, createdAt: Date
    ) {
        self.messageID = messageID
        self.roomID = roomID
        self.roomSequence = roomSequence
        self.timelineSequence = timelineSequence
        self.senderUserID = senderUserID
        self.clientMessageID = clientMessageID
        self.groupDeliveryMode = groupDeliveryMode
        self.usesRoomEventLog = usesRoomEventLog
        self.sourceEventID = sourceEventID
        self.acceptedMembershipRevision = acceptedMembershipRevision
        self.directRecipientUserID = directRecipientUserID
        self.createdAt = createdAt
    }
}

public extension V2AcceptedMessage {
    /// 从已接受消息提取无内容回执，逐项保留原身份、顺序与投递元数据，不读取外部状态。
    var receipt: V2MessageAcceptanceReceipt {
        .init(
            messageID: messageID, roomID: roomID, roomSequence: roomSequence,
            timelineSequence: timelineSequence, senderUserID: senderUserID,
            clientMessageID: clientMessageID, groupDeliveryMode: groupDeliveryMode,
            usesRoomEventLog: usesRoomEventLog, sourceEventID: sourceEventID,
            acceptedMembershipRevision: acceptedMembershipRevision,
            directRecipientUserID: directRecipientUserID, createdAt: createdAt
        )
    }
}
