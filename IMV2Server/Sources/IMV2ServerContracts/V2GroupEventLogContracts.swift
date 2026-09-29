import Foundation
import IMV2Core

/// 房间事件日志中的一条记录。
public struct V2GroupEventLogEntry: Equatable, Sendable {
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 事件在房间日志中的序号。
    public let roomSequence: UInt64
    /// 投影类型标识。
    public let projectionKind: String
    /// 已编码的事件载荷。
    public let payload: Data

    /// 校验并保存事件记录。
    ///
    /// - Parameters:
    ///   - sourceEventID: 来源事件标识。
    ///   - roomSequence: 房间序号，需大于零且可表示为合法房间游标。
    ///   - projectionKind: 投影类型标识。
    ///   - payload: 已编码载荷。
    /// - Throws: 序号为零或超出游标表示范围时抛出
    ///   ``V2GroupEventLogError/corruptPersistenceState``。
    public init(sourceEventID: EventID, roomSequence: UInt64, projectionKind: String, payload: Data) throws {
        guard (try? V2RoomCursor(roomSequence)) != nil, roomSequence > 0 else { throw V2GroupEventLogError.corruptPersistenceState }
        self.sourceEventID = sourceEventID
        self.roomSequence = roomSequence
        self.projectionKind = projectionKind
        self.payload = payload
    }
}

/// 房间事件日志的一页。
public struct V2GroupEventLogPage: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 本页事件，按房间序号升序。
    public let events: [V2GroupEventLogEntry]
    /// 下一页的起始序号。
    public let nextRoomSequence: UInt64
    /// 是否还有后续事件。
    public let hasMore: Bool
    /// 已裁剪的历史下界：该序号之前的事件已按保留窗口移除，不再可恢复。
    ///
    /// 客户端游标低于它时必须把该房间标记为"历史不完整"并从这个下界继续拉取；
    /// 零表示该房间从未裁剪。静默少几条是明确禁止的行为。
    public let logTrimmedThroughRoomSequence: UInt64

    /// 校验并保存事件分页。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - events: 本页事件。
    ///   - nextRoomSequence: 下一页起始序号。
    ///   - hasMore: 是否还有后续事件。
    /// - Throws: 下一页序号无法表示为合法游标时抛出
    ///   ``V2GroupEventLogError/corruptPersistenceState``。
    public init(
        roomID: RoomID,
        events: [V2GroupEventLogEntry],
        nextRoomSequence: UInt64,
        hasMore: Bool,
        logTrimmedThroughRoomSequence: UInt64 = 0
    ) throws {
        guard (try? V2RoomCursor(nextRoomSequence)) != nil,
              logTrimmedThroughRoomSequence <= UInt64(Int64.max)
        else { throw V2GroupEventLogError.corruptPersistenceState }
        self.roomID = roomID
        self.events = events
        self.nextRoomSequence = nextRoomSequence
        self.hasMore = hasMore
        self.logTrimmedThroughRoomSequence = logTrimmedThroughRoomSequence
    }
}

/// 前台订阅结果。
///
/// 订阅成功只证明当前具备房间资格并给出持久化房间日志水位，它本身不是投递回执。
public struct V2GroupEventSubscription: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 订阅时刻的房间日志水位。
    public let highWatermark: UInt64
    /// 授权本次订阅的持久化成员修订。
    ///
    /// 前台群载荷只有在其提交代次与订阅代次完全相等时才会被路由，
    /// 因此成员变更后会立即收敛为拒绝投递，无需逐条消息枚举房间受众。
    public let membershipRevision: UInt64

    /// 校验并保存订阅结果。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - highWatermark: 订阅时刻水位。
    ///   - membershipRevision: 授权本次订阅的成员修订，默认零。
    /// - Throws: 水位或修订无法表示为对应游标类型时抛出
    ///   ``V2GroupEventLogError/corruptPersistenceState``。
    public init(roomID: RoomID, highWatermark: UInt64, membershipRevision: UInt64 = 0) throws {
        guard (try? V2RoomCursor(highWatermark)) != nil, (try? V2MembershipRevision(membershipRevision)) != nil else { throw V2GroupEventLogError.corruptPersistenceState }
        self.roomID = roomID
        self.highWatermark = highWatermark
        self.membershipRevision = membershipRevision
    }
}

/// 房间事件日志错误。
public enum V2GroupEventLogError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 房间不存在。
    case roomNotFound
    /// 发起者不是房间成员。
    case actorNotMember
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 房间事件日志的持久化能力。
public protocol V2GroupEventLogStore: Sendable {
    /// 按房间序号向后拉取事件分页。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号，返回的事件序号均严格大于该值。
    ///   - pageSize: 本页最多返回的事件数。
    /// - Returns: 事件分页。
    /// - Throws: 无资格、房间不存在或持久化失败时抛出。
    func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage

    /// 校验订阅资格并返回当前水位。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起订阅的用户。
    /// - Returns: 订阅结果。
    /// - Throws: 无资格、房间不存在或持久化失败时抛出。
    func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription
}

/// Receives committed log facts for optional local acceleration.
public protocol V2CommittedRoomLogObserving: Sendable {
    func recordCommittedPlainDirectMessage(_ message: V2AcceptedMessage) async
    func enqueueCommittedPlainDirectEvent(_ event: V2DirectRoomLiveEvent)
    func enqueueCommittedPlainDirectEvents(_ events: [V2DirectRoomLiveEvent])
}
