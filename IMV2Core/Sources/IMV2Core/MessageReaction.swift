import Foundation

/// 以消息、操作者及反应字符串为键的集合操作，不共享消息内容修订号，避免不同用户的独立反应互相覆盖。
public enum V2MessageReactionAction: String, Codable, Equatable, Sendable {
    /// 将该用户的反应加入集合。
    case add
    /// 从集合移除该用户的反应。
    case remove
}

/// 独立于房间人数的反应容量限制；限制由对应命令与存储路径执行，常量本身不维护集合。
public enum V2MessageReactionLimits {
    /// 单个反应规范化后最多 16 个 UTF-8 字节。
    public static let maximumReactionBytes = 16
    /// 每位用户对单条消息最多 8 种反应，需由权威存储检查。
    public static let maximumReactionsPerActorPerMessage = 8
    /// 单条消息最多 1024 个反应集合成员，限制扇出与快照规模。
    public static let maximumReactionsPerMessage = 1_024
}

/// 变更某用户消息反应的命令，包含独立幂等操作身份，不携带预期消息内容版本。
public struct V2ChangeMessageReactionCommand: Equatable, Sendable {
    /// 目标房间身份。
    public let roomID: RoomID
    /// 反应所属用户，不表示已通过授权。
    public let actorUserID: UserID
    /// 本次反应变更的稳定幂等身份。
    public let operationID: MessageReactionOperationID
    /// 目标消息身份。
    public let messageID: MessageID
    /// 反应集合键中的字符串。
    public let reaction: String
    /// 加入或移除该用户的反应。
    public let action: V2MessageReactionAction

    /// 构造反应命令，先对字符串执行 Unicode 规范组合，再检查非空、最多 16 字节且不含空白或控制字符。
    ///
    /// 保存规范化结果，不要求必须为单个 Emoji；用户及消息集合容量由存储路径检查。
    /// - Throws: 字符串不符合要求时抛出 invalidReaction。
    public init(roomID: RoomID, actorUserID: UserID, operationID: MessageReactionOperationID, messageID: MessageID, reaction: String, action: V2MessageReactionAction) throws {
        let normalized = reaction.precomposedStringWithCanonicalMapping
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.utf8.count <= V2MessageReactionLimits.maximumReactionBytes,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              })
        else { throw V2MessageReactionValidationError.invalidReaction }
        self.roomID = roomID
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.messageID = messageID
        self.reaction = normalized
        self.action = action
    }
}

/// 消息反应变更事件及其房间顺序、扇出元数据；不在模型中执行集合变更或授权。
public struct V2MessageReactionChange: Equatable, Sendable {
    /// 目标房间身份。
    public let roomID: RoomID
    /// 目标消息身份。
    public let messageID: MessageID
    /// 反应所属用户，不表示已通过授权。
    public let actorUserID: UserID
    /// 反应集合键中的字符串。
    public let reaction: String
    /// 加入或移除该用户的反应。
    public let action: V2MessageReactionAction
    /// 变更事件的房间序号，范围为 1 到 Int64.max。
    public let roomSequence: UInt64
    /// 本次变更事件身份。
    public let eventID: EventID
    /// 对应扇出计划身份。
    public let fanoutPlanID: FanoutPlanID
    /// 事件创建时间，构造器不校验有限性。
    public let createdAt: Date

    /// 保存变更结果并校验房间序号为 1 到 Int64.max，越界抛出 outOfRange；不重复校验反应文本或日期。
    public init(roomID: RoomID, messageID: MessageID, actorUserID: UserID, reaction: String, action: V2MessageReactionAction, roomSequence: UInt64, eventID: EventID, fanoutPlanID: FanoutPlanID, createdAt: Date) throws {
        guard roomSequence > 0, roomSequence <= UInt64(Int64.max) else { throw V2RevisionValidationError.outOfRange }
        self.roomID = roomID
        self.messageID = messageID
        self.actorUserID = actorUserID
        self.reaction = reaction
        self.action = action
        self.roomSequence = roomSequence
        self.eventID = eventID
        self.fanoutPlanID = fanoutPlanID
        self.createdAt = createdAt
    }
}

/// 反应字符串格式校验错误。
public enum V2MessageReactionValidationError: Error, Equatable, Sendable {
    /// 反应为空白、超过字节上限，或包含空白与控制字符。
    case invalidReaction
}
