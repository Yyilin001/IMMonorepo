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
    case timelineActivity = "timeline_activity"
    case directSendingCapability = "direct_sending_capability"
}

/// 与源操作原子提交的单个用户事件。源身份和目标用户构成稳定的重试身份。
public struct V2UserStateEvent: Equatable, Sendable {
    public let sourceEventID: EventID
    public let userID: UserID
    public let kind: V2UserStateEventKind
    public let payloadJSON: String
    let createdAtTimestamp: V2PostgresTimestamp
    public var createdAt: Date { createdAtTimestamp.date }

    /// 在服务端可信边界校验 JSON 对象和持久化范围，不接受聊天正文类别。
    public init(sourceEventID: EventID, userID: UserID, kind: V2UserStateEventKind, payload: Data, createdAt: Date) throws {
        guard v2PostgresTimestampCanEncode(createdAt) else { throw V2UserStateEventError.invalidEvent }
        try self.init(sourceEventID: sourceEventID, userID: userID, kind: kind, payload: payload,
            createdAt: V2PostgresTimestamp(date: createdAt))
    }

    /// 转发已提交的源事件时，保持数据库时间戳不变。
    init(sourceEventID: EventID, userID: UserID, kind: V2UserStateEventKind, payload: Data,
         createdAt: V2PostgresTimestamp) throws {
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

/// 独立于消息扇出的用户状态派发器。失败只影响对应事件，不跳过持久恢复。
public struct V2UserStateEventWorker: Sendable {
    private let outbox: any V2UserStateEventOutbox
    private let projector: any V2UserStateEventProjecting
    private let retryPolicy: V2DurableRetryPolicy
    private let now: @Sendable () -> Date

    public init(outbox: any V2UserStateEventOutbox, projector: any V2UserStateEventProjecting,
                retryPolicy: V2DurableRetryPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.outbox = outbox
        self.projector = projector
        self.retryPolicy = retryPolicy
        self.now = now
    }

    /// 返回已被来源库确认的事件数；目标完成但租约失效不计为本轮完成。
    public func runOnce(limit: Int, leaseDuration: TimeInterval = 30) async throws -> Int {
        let leases = try await outbox.claim(now: now(), leaseDuration: leaseDuration, limit: limit)
        var completed = 0
        for lease in leases {
            try Task.checkCancellation()
            do {
                let sequence = try await projector.project(lease.event)
                try Task.checkCancellation()
                if try await outbox.acknowledge(lease, sequence: sequence, now: now()) { completed += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let kind: V2DurableWorkFailureKind = error is V2UserStateEventError
                    ? .deterministic : v2DurableWorkFailureKind(for: error)
                try await outbox.retry(lease, disposition: retryPolicy.disposition(
                    attempt: lease.attempt, claimToken: lease.token, now: now(), kind: kind
                ))
            }
        }
        return completed
    }
}
