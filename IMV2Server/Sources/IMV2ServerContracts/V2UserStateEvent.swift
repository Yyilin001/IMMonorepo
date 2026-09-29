import Foundation
import IMV2Core

/// 只属于用户同步流的持久事件类别；公共聊天内容必须使用房间日志。
public enum V2UserStateEventKind: String, Codable, CaseIterable, Sendable {
    case room
    case membership
    case directRoomProfile = "direct_room_profile"
    case ownReadWatermark = "own_read_watermark"
    case directReadReceipt = "direct_read_receipt"
    case readReceiptPreferences = "read_receipt_preferences"
    case conversationState = "conversation_state"
    case messageFavorite = "message_favorite"
    case contactAlias = "contact_alias"
    case timelineActivity = "timeline_activity"
    case directSendingCapability = "direct_sending_capability"
}

/// 与源操作原子提交的单个用户事件。源身份和目标用户构成稳定的重试身份。
public struct V2UserStateEvent: Equatable, Sendable {
    public let sourceEventID: EventID
    public let userID: UserID
    public let kind: V2UserStateEventKind
    public let payloadJSON: String
    package let createdAtTimestamp: V2PersistenceTimestamp
    public var createdAt: Date { createdAtTimestamp.date }

    /// 在服务端可信边界校验 JSON 对象和持久化范围，不接受聊天正文类别。
    public init(sourceEventID: EventID, userID: UserID, kind: V2UserStateEventKind, payload: Data, createdAt: Date) throws {
        guard v2PostgresTimestampCanEncode(createdAt) else { throw V2UserStateEventError.invalidEvent }
        try self.init(sourceEventID: sourceEventID, userID: userID, kind: kind, payload: payload,
            createdAt: V2PersistenceTimestamp(date: createdAt))
    }

    /// 转发已提交的源事件时，保持数据库时间戳不变。
    package init(sourceEventID: EventID, userID: UserID, kind: V2UserStateEventKind, payload: Data,
         createdAt: V2PersistenceTimestamp) throws {
        guard payload.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              v2PostgresTimestampMicrosecondsCanEncode(createdAt.microseconds),
              let json = String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)
        else { throw V2UserStateEventError.invalidEvent }
        self.sourceEventID = sourceEventID
        self.userID = userID
        self.kind = kind
        self.payloadJSON = json
        self.createdAtTimestamp = createdAt
    }
}

public enum V2UserStateEventError: Error, Equatable, Sendable {
    case invalidEvent
    case identityConflict
    case corruptPersistenceState
}

/// 来源库的租约。目标提交成功而来源确认失败时，用原事件身份重新投影。
public struct V2UserStateEventLease: Sendable {
    public let event: V2UserStateEvent
    public let token: UUID
    public let attempt: Int
    public init(event: V2UserStateEvent, token: UUID, attempt: Int) {
        self.event = event
        self.token = token
        self.attempt = attempt
    }
}

public protocol V2UserStateEventOutbox: Sendable {
    func claim(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserStateEventLease]
    func acknowledge(_ lease: V2UserStateEventLease, sequence: UInt64, now: Date) async throws -> Bool
    func retry(_ lease: V2UserStateEventLease, disposition: V2DurableRetryDisposition) async throws
}

/// 实现必须在当前用户归属的事务内完成去重、序号分配和用户日志追加。
public protocol V2UserStateEventProjecting: Sendable {
    func project(_ event: V2UserStateEvent) async throws -> UInt64
}
