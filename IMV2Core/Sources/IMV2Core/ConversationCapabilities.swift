import Foundation

/// 用户个人会话状态的不可变意图，操作身份用于重试。
///
/// 命令包含用户选择的免打扰期限，不包含服务端生成的更新时间；不改变其他成员的会话偏好。
public struct V2ConversationStateCommand: Equatable, Sendable {
    /// 稳定会话偏好操作身份。
    public let operationID: ConversationPreferenceOperationID
    /// 目标会话房间。
    public let roomID: RoomID
    /// 期望个人置顶状态。
    public let isPinned: Bool
    /// 期望个人归档状态。
    public let isArchived: Bool
    /// 可选免打扰截止时间，nil 表示无截止时间设置。
    public let muteUntil: Date?

    /// 构造业务命令。
    ///
    /// - Parameters:
    ///   - operationID: 稳定会话偏好操作身份。
    ///   - roomID: 目标会话房间。
    ///   - isPinned: 期望个人置顶状态。
    ///   - isArchived: 期望个人归档状态。
    ///   - muteUntil: 可选免打扰截止时间，nil 表示无截止时间设置。
    ///
    /// 有期限时，Unix 毫秒向零截断后必须可表示为正 Int64，否则抛出 invalidPositiveValue；保存原 Date，不要求期限晚于当前时间，也不对其毫秒精度进行归一化。
    public init(operationID: ConversationPreferenceOperationID, roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?) throws {
        if let muteUntil {
            guard let milliseconds = Int64(exactly: (muteUntil.timeIntervalSince1970 * 1_000).rounded(.towardZero)),
                  milliseconds > 0
            else { throw V2CoreError.invalidPositiveValue }
        }
        self.operationID = operationID
        self.roomID = roomID
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.muteUntil = muteUntil
    }
}

/// 个人消息收藏或取消收藏的稳定操作意图。
public struct V2MessageFavoriteCommand: Equatable, Sendable {
    /// 本次收藏变更的稳定身份。
    public let operationID: MessageFavoriteOperationID
    /// 消息所在房间。
    public let roomID: RoomID
    /// 目标消息。
    public let messageID: MessageID
    /// 期望收藏状态。
    public let isFavorited: Bool

    /// 构造业务命令。
    ///
    /// - Parameters:
    ///   - operationID: 本次收藏变更的稳定身份。
    ///   - roomID: 消息所在房间。
    ///   - messageID: 目标消息。
    ///   - isFavorited: 期望收藏状态。
    ///
    /// 保存字段，不检查消息可见性或读取旧收藏状态。
    public init(operationID: MessageFavoriteOperationID, roomID: RoomID, messageID: MessageID, isFavorited: Bool) {
        self.operationID = operationID; self.roomID = roomID; self.messageID = messageID; self.isFavorited = isFavorited
    }
}

/// 服务端返回的个人会话状态及更新时间。
public struct V2ConversationState: Equatable, Sendable {
    /// 不可变结果字段，具体语义见构造参数说明。
    public let roomID: RoomID; public let isPinned: Bool; public let isArchived: Bool; public let muteUntil: Date?; public let updatedAt: Date
    /// 构造领域值。
    ///
    /// - Parameters:
    ///   - roomID: 会话房间。
    ///   - isPinned: 个人置顶状态。
    ///   - isArchived: 个人归档状态。
    ///   - muteUntil: 可选免打扰期限。
    ///   - updatedAt: 服务端更新时间。
    ///
    /// 直接保存字段，不重复检查免打扰期限或日期。
    public init(roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?, updatedAt: Date) { self.roomID = roomID; self.isPinned = isPinned; self.isArchived = isArchived; self.muteUntil = muteUntil; self.updatedAt = updatedAt }
}

/// 个人消息收藏结果及更新时间。
public struct V2MessageFavorite: Equatable, Sendable {
    /// 不可变结果字段，具体语义见构造参数说明。
    public let roomID: RoomID; public let messageID: MessageID; public let isFavorited: Bool; public let updatedAt: Date
    /// 构造领域值。
    ///
    /// - Parameters:
    ///   - roomID: 消息房间。
    ///   - messageID: 目标消息。
    ///   - isFavorited: 最终收藏状态。
    ///   - updatedAt: 变更时间。
    ///
    /// 保存收藏结果，不验证日期或持久化状态。
    public init(roomID: RoomID, messageID: MessageID, isFavorited: Bool, updatedAt: Date) { self.roomID = roomID; self.messageID = messageID; self.isFavorited = isFavorited; self.updatedAt = updatedAt }
}

/// 用户选定的源消息及其当时观察的内容版本。
///
/// 重试不能重新读取更高版本来替换原意图，授权及内容获取由服务端处理。
public struct V2ForwardMessageReference: Equatable, Hashable, Codable, Sendable {
    /// 源消息房间。
    public let roomID: RoomID
    /// 源消息身份。
    public let messageID: MessageID
    /// 用户选定的内容修订号。
    public let revision: V2MessageRevision

    /// 构造领域值。
    ///
    /// - Parameters:
    ///   - roomID: 源消息房间。
    ///   - messageID: 源消息身份。
    ///   - revision: 用户选定的内容修订号。
    ///
    /// 保存已校验的标识及修订号，不读取消息或确认当前可见性。
    public init(roomID: RoomID, messageID: MessageID, revision: V2MessageRevision) {
        self.roomID = roomID
        self.messageID = messageID
        self.revision = revision
    }

    /// 源引用编码使用 roomID、messageID 与 revision 键。
    private enum CodingKeys: String, CodingKey { case roomID, messageID, revision }
    /// 将字符串标识及 UInt64 版本通过各自校验构造器解码，拒绝无效标识或版本。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(roomID: try .init(values.decode(String.self, forKey: .roomID)),
                  messageID: try .init(values.decode(String.self, forKey: .messageID)),
                  revision: try .init(values.decode(UInt64.self, forKey: .revision)))
    }
    /// 编码标识原始字符串与数值修订号，不使用包装类型的默认对象表示。
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(roomID.rawValue, forKey: .roomID)
        try values.encode(messageID.rawValue, forKey: .messageID)
        try values.encode(revision.rawValue, forKey: .revision)
    }
}

/// 多源多目标的转发意图，每个源消息与目标房间组合具有独立持久结果。
public struct V2ForwardMessagesCommand: Equatable, Sendable {
    /// 单次转发最多 100 条源消息。
    public static let maximumSourceMessages = 100
    /// 单次转发最多 10 个目标房间。
    public static let maximumTargetRooms = 10
    /// 整个转发请求的稳定操作身份。
    public let operationID: MessageForwardOperationID
    /// 保持用户顺序的源引用，最多 100 项且 messageID 唯一。
    public let sources: [V2ForwardMessageReference]
    /// 保持输入顺序的目标房间，最多 10 项且无重复。
    public let targetRoomIDs: [RoomID]
    /// 按源引用原顺序提取消息身份，不改变转发顺序。
    public var sourceMessageIDs: [MessageID] { sources.map(\.messageID) }

    /// 构造业务命令。
    ///
    /// - Parameters:
    ///   - operationID: 整个转发请求的稳定操作身份。
    ///   - sources: 保持用户顺序的源引用，最多 100 项且 messageID 唯一。
    ///   - targetRoomIDs: 保持输入顺序的目标房间，最多 10 项且无重复。
    ///
    /// 要求两个数组均非空且在上限内，源按 messageID 去重、目标按 roomID 去重，否则抛出 invalidPositiveValue；不排序、不去重修正输入，也不禁止源房间同时作为目标。
    public init(operationID: MessageForwardOperationID, sources: [V2ForwardMessageReference], targetRoomIDs: [RoomID]) throws {
        guard !sources.isEmpty, sources.count <= Self.maximumSourceMessages,
              !targetRoomIDs.isEmpty, targetRoomIDs.count <= Self.maximumTargetRooms,
              Set(sources.map(\.messageID)).count == sources.count,
              Set(targetRoomIDs).count == targetRoomIDs.count
        else { throw V2CoreError.invalidPositiveValue }
        self.operationID = operationID
        self.sources = sources
        self.targetRoomIDs = targetRoomIDs
    }
}

/// 单个源消息与目标房间组合的互斥成功或失败结果。
public struct V2ForwardMessageResult: Equatable, Sendable {
    /// 原始源消息身份。
    public let sourceMessageID: MessageID
    /// 本组合目标房间。
    public let targetRoomID: RoomID
    /// 成功创建的消息身份，失败时为 nil。
    public let messageID: MessageID?
    /// 成功消息的正房间序号，失败时为 nil。
    public let roomSequence: UInt64?
    /// 失败代码，成功时为 nil。
    public let errorCode: String?

    /// 构造领域值。
    ///
    /// - Parameters:
    ///   - sourceMessageID: 原始源消息身份。
    ///   - targetRoomID: 本组合目标房间。
    ///   - messageID: 成功创建的消息身份，失败时为 nil。
    ///   - roomSequence: 成功消息的正房间序号，失败时为 nil。
    ///   - errorCode: 失败代码，成功时为 nil。
    ///
    /// 成功要求消息与序号同时存在且错误为空；失败要求消息与序号为空且错误存在，否则抛出 invalidShape。成功序号必须为 1 到 Int64.max，否则抛出 invalidSequence；不要求失败代码非空。
    public init(sourceMessageID: MessageID, targetRoomID: RoomID, messageID: MessageID?, roomSequence: UInt64?, errorCode: String?) throws {
        guard (messageID != nil && roomSequence != nil && errorCode == nil) || (messageID == nil && roomSequence == nil && errorCode != nil) else {
            throw V2ForwardMessageResultValidationError.invalidShape
        }
        if let roomSequence, roomSequence == 0 || roomSequence > UInt64(Int64.max) {
            throw V2ForwardMessageResultValidationError.invalidSequence
        }
        self.sourceMessageID = sourceMessageID; self.targetRoomID = targetRoomID; self.messageID = messageID; self.roomSequence = roomSequence; self.errorCode = errorCode
    }
}

/// 转发结果的互斥字段组合或序号校验错误。
public enum V2ForwardMessageResultValidationError: Error, Equatable, Sendable {
    /// 成功和失败字段未满足规定的互斥组合。
    case invalidShape
    /// 成功房间序号为零或超过 Int64.max。
    case invalidSequence
}
