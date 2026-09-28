import Foundation

/// A frozen target state with a revision fence. Mute timestamps use wire millisecond precision.
public struct V2ConversationStateCommand: Equatable, Codable, Sendable {
    public let operationID: ConversationPreferenceOperationID
    public let roomID: RoomID
    public let isPinned: Bool
    public let isArchived: Bool
    public let muteUntil: Date?
    public let expectedRevision: V2PersonalPreferenceRevision
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public init(
        operationID: ConversationPreferenceOperationID, roomID: RoomID, isPinned: Bool, isArchived: Bool,
        muteUntil: Date?,
        expectedRevision: V2PersonalPreferenceRevision, firstSubmissionDeadlineMilliseconds: UInt64
    ) throws {
        guard firstSubmissionDeadlineMilliseconds > 0, firstSubmissionDeadlineMilliseconds <= UInt64(Int64.max) else {
            throw V2PersonalPreferenceOperationError.invalidDeadline
        }
        if let muteUntil {
            guard let ms = Int64(exactly: (muteUntil.timeIntervalSince1970 * 1000).rounded(.towardZero)), ms > 0 else {
                throw V2CoreError.invalidPositiveValue
            }
            self.muteUntil = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            self.muteUntil = nil
        }
        self.operationID = operationID
        self.roomID = roomID
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.expectedRevision = expectedRevision
        self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
    }
    public func identity(actorUserID: UserID) throws -> V2OperationIdentity {
        try .init(accountID: actorUserID, scope: .room(roomID), operation: .conversationPreference(operationID))
    }
    public func fingerprint(actorUserID: UserID) throws -> V2OperationFingerprint {
        try .init(
            kind: .conversationPreference,
            fields: [
                .init("actor", .text(actorUserID.rawValue)), .init("operation", .text(operationID.rawValue)),
                .init("room", .text(roomID.rawValue)), .init("pinned", .flag(isPinned)),
                .init("archived", .flag(isArchived)),
                .init(
                    "muteUntil",
                    muteUntil.map { .unsigned(UInt64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? .absent),
                .init("expectedRevision", .unsigned(expectedRevision.rawValue)),
                .init("firstSubmissionDeadline", .unsigned(firstSubmissionDeadlineMilliseconds)),
            ])
    }
    private enum CodingKeys: String, CodingKey {
        case operationID, roomID, isPinned, isArchived, muteUntil, expectedRevision, firstSubmissionDeadlineMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            operationID: v.decode(ConversationPreferenceOperationID.self, forKey: .operationID),
            roomID: v.decode(RoomID.self, forKey: .roomID),
            isPinned: v.decode(Bool.self, forKey: .isPinned), isArchived: v.decode(Bool.self, forKey: .isArchived),
            muteUntil: v.decodeIfPresent(Date.self, forKey: .muteUntil),
            expectedRevision: v.decode(V2PersonalPreferenceRevision.self, forKey: .expectedRevision),
            firstSubmissionDeadlineMilliseconds: v.decode(UInt64.self, forKey: .firstSubmissionDeadlineMilliseconds))
    }
}
public struct V2MessageFavoriteCommand: Equatable, Codable, Sendable {
    public let operationID: MessageFavoriteOperationID
    public let roomID: RoomID
    public let messageID: MessageID
    public let isFavorited: Bool
    public let expectedRevision: V2PersonalPreferenceRevision
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public init(
        operationID: MessageFavoriteOperationID, roomID: RoomID, messageID: MessageID, isFavorited: Bool,
        expectedRevision: V2PersonalPreferenceRevision, firstSubmissionDeadlineMilliseconds: UInt64
    ) throws {
        guard firstSubmissionDeadlineMilliseconds > 0, firstSubmissionDeadlineMilliseconds <= UInt64(Int64.max) else {
            throw V2PersonalPreferenceOperationError.invalidDeadline
        }
        self.operationID = operationID
        self.roomID = roomID
        self.messageID = messageID
        self.isFavorited = isFavorited
        self.expectedRevision = expectedRevision
        self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
    }
    public func identity(actorUserID: UserID) throws -> V2OperationIdentity {
        try .init(accountID: actorUserID, scope: .message(roomID, messageID), operation: .messageFavorite(operationID))
    }
    public func fingerprint(actorUserID: UserID) throws -> V2OperationFingerprint {
        try .init(
            kind: .messageFavorite,
            fields: [
                .init("actor", .text(actorUserID.rawValue)), .init("operation", .text(operationID.rawValue)),
                .init("room", .text(roomID.rawValue)), .init("message", .text(messageID.rawValue)),
                .init("favorited", .flag(isFavorited)),
                .init("expectedRevision", .unsigned(expectedRevision.rawValue)),
                .init("firstSubmissionDeadline", .unsigned(firstSubmissionDeadlineMilliseconds)),
            ])
    }
    private enum CodingKeys: String, CodingKey {
        case operationID, roomID, messageID, isFavorited, expectedRevision, firstSubmissionDeadlineMilliseconds
    }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            operationID: v.decode(MessageFavoriteOperationID.self, forKey: .operationID),
            roomID: v.decode(RoomID.self, forKey: .roomID),
            messageID: v.decode(MessageID.self, forKey: .messageID),
            isFavorited: v.decode(Bool.self, forKey: .isFavorited),
            expectedRevision: v.decode(V2PersonalPreferenceRevision.self, forKey: .expectedRevision),
            firstSubmissionDeadlineMilliseconds: v.decode(UInt64.self, forKey: .firstSubmissionDeadlineMilliseconds))
    }
}
public struct V2ConversationState: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let isPinned: Bool
    public let isArchived: Bool
    public let muteUntil: Date?
    public let updatedAt: Date
    public let revision: V2PersonalPreferenceRevision
    public init(
        roomID: RoomID, isPinned: Bool, isArchived: Bool, muteUntil: Date?, updatedAt: Date,
        revision: V2PersonalPreferenceRevision
    ) {
        self.roomID = roomID
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.muteUntil = muteUntil
        self.updatedAt = updatedAt
        self.revision = revision
    }
}
public struct V2MessageFavorite: Equatable, Codable, Sendable {
    public let roomID: RoomID
    public let messageID: MessageID
    public let isFavorited: Bool
    public let updatedAt: Date
    public let revision: V2PersonalPreferenceRevision
    public init(
        roomID: RoomID, messageID: MessageID, isFavorited: Bool, updatedAt: Date, revision: V2PersonalPreferenceRevision
    ) {
        self.roomID = roomID
        self.messageID = messageID
        self.isFavorited = isFavorited
        self.updatedAt = updatedAt
        self.revision = revision
    }
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
public struct V2ForwardMessagesCommand: Equatable, Codable, Sendable {
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
    private enum CodingKeys: String, CodingKey { case operationID, sources, targetRoomIDs }
    public init(from decoder: any Decoder) throws {
        let v=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(operationID:v.decode(MessageForwardOperationID.self,forKey:.operationID),
            sources:v.decode([V2ForwardMessageReference].self,forKey:.sources),targetRoomIDs:v.decode([RoomID].self,forKey:.targetRoomIDs))
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
