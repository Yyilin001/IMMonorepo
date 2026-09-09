/// 定位附件所属权威消息的房间与消息身份，只提供可见性检查上下文，不直接授予访问权限。
public struct V2MediaMessageLocation: Equatable, Hashable, Sendable {
    /// 附件关联消息所属房间。
    public let roomID: RoomID
    /// 附件关联的权威消息身份。
    public let messageID: MessageID
    /// 保存定位字段，不检查附件关联、房间成员资格或消息可见性。
    public init(roomID: RoomID, messageID: MessageID) {
        self.roomID = roomID
        self.messageID = messageID
    }
}
