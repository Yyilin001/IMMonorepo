import IMV2ServerContracts
import Foundation
import IMV2Core

extension V2DirectRoomLiveEvent {
    /// 由已接受消息构造私聊实时事件。
    ///
    /// - Parameter message: 已接受消息。
    /// - Returns: 满足私聊快速路径条件时的事件；否则为 `nil`。
    public init?(_ message: V2AcceptedMessage) {
        guard let draft = V2DirectRoomLiveEventDraft(message),
              let materialized = draft.materialized()
        else { return nil }
        self = materialized
    }

    /// 编码消息对应的房间日志载荷。
    ///
    /// - Parameter message: 已接受消息。
    /// - Returns: 规范 JSON 载荷；无法投影时间戳时为 `nil`。
    static func payload(for message: V2AcceptedMessage) -> Data? {
        V2DirectRoomLogPayloadCodec.encode(message)
    }
}

/// ``V2DirectRoomLiveEventDraft`` 的群聊对应实现。
///
/// 它刻意只支持已经规范化的纯文本混合大群消息形态；更丰富的消息仍走持久化游标路径，
/// 直到其载荷契约可以在不改变语义的前提下被复用。
package struct V2GroupRoomLiveEventDraft: Equatable, Sendable {
    /// 已接受消息。
    let message: V2AcceptedMessage
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 接受事务记录的成员修订。
    let membershipRevision: UInt64
    /// 需要去重的来源连接。
    let excludedConnectionID: UUID?

    /// 由已接受消息构造群聊草稿。
    ///
    /// 群聊批次必须对所有套接字保持字节一致且受众一致：发送方可能已根据接受回执推进本地游标
    /// 并跳过该重复条目，若按事件排除来源连接就会破坏「一次编码」特性，
    /// 因此此处刻意不设置排除连接。
    ///
    /// - Parameters:
    ///   - message: 已接受消息。
    ///   - excludingConnectionID: 忽略；群聊批次不使用该参数。
    /// - Returns: 满足条件时返回草稿；否则为 `nil`。
    package init?(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID? = nil
    ) {
        guard message.groupCapacityClass == .large,
              message.media.isEmpty,
              message.mentions.isEmpty,
              message.replyTo == nil,
              let sourceEventID = message.sourceEventID,
              let membershipRevision = message.acceptedMembershipRevision
        else { return nil }
        self.message = message
        self.sourceEventID = sourceEventID
        self.membershipRevision = membershipRevision
        // 群组批次必须对每个套接字使用字节完全相同的表示和同一受众。
        // 发送方可能已根据接受确认推进本地游标，因此会跳过重复条目；
        // 若按事件排除连接，就无法做到只编码一次。
        self.excludedConnectionID = nil
    }

    /// 物化为实时事件。
    ///
    /// - Returns: 可投递事件；载荷编码失败时为 `nil`。
    package func materialized() -> V2DirectRoomLiveEvent? {
        guard let payload = V2DirectRoomLiveEvent.payload(for: message) else { return nil }
        return .init(
            roomID: message.roomID,
            highWatermark: message.roomSequence,
            sourceEventID: sourceEventID,
            roomSequence: message.roomSequence,
            projectionKind: "message",
            payload: payload,
            recipientUserIDs: [],
            groupMembershipRevision: membershipRevision,
            acceptedMembershipRevision: membershipRevision,
            excludedConnectionID: excludedConnectionID
        )
    }
}

/// 私聊实时事件草稿。
///
/// 前台提示队列只保留已提交的不可变接受数据，JSON 构造刻意推迟到队列后台中继执行时进行：
/// 不能仅因为对端当前打开了该房间，就让发送方的接受响应承担两次 JSON 转换。
package struct V2DirectRoomLiveEventDraft: Equatable, Sendable {
    /// 已接受消息。
    let message: V2AcceptedMessage
    /// 来源事件标识。
    let sourceEventID: EventID
    /// 私聊双方受众。
    let recipientUserIDs: Set<UserID>
    /// 需要去重的来源连接。
    let excludedConnectionID: UUID?

    /// 由已接受消息构造私聊草稿。
    ///
    /// 仅接受带房间事件日志、非群聊、无媒体与提及、无引用回复，且已具备来源事件标识、
    /// 接受成员修订与有效对端用户的纯文本消息。
    ///
    /// - Parameters:
    ///   - message: 已接受消息。
    ///   - excludingConnectionID: 需要去重的来源连接。
    /// - Returns: 满足条件时返回草稿；否则为 `nil`。
    package init?(
        _ message: V2AcceptedMessage,
        excludingConnectionID: UUID? = nil
    ) {
        guard message.groupCapacityClass == nil,
              message.media.isEmpty,
              message.mentions.isEmpty,
              message.replyTo == nil,
              let sourceEventID = message.sourceEventID,
              message.acceptedMembershipRevision != nil,
              let directRecipientUserID = message.directRecipientUserID,
              directRecipientUserID != message.senderUserID
        else { return nil }
        self.message = message
        self.sourceEventID = sourceEventID
        recipientUserIDs = [message.senderUserID, directRecipientUserID]
        self.excludedConnectionID = excludingConnectionID
    }

    /// 物化为实时事件。
    ///
    /// - Returns: 可投递事件；载荷编码失败时为 `nil`。
    package func materialized() -> V2DirectRoomLiveEvent? {
        guard let payload = V2DirectRoomLiveEvent.payload(for: message) else { return nil }
        return .init(
            roomID: message.roomID,
            highWatermark: message.roomSequence,
            sourceEventID: sourceEventID,
            roomSequence: message.roomSequence,
            projectionKind: "message",
            payload: payload,
            recipientUserIDs: recipientUserIDs,
            acceptedMembershipRevision: message.acceptedMembershipRevision,
            excludedConnectionID: excludedConnectionID
        )
    }
}
