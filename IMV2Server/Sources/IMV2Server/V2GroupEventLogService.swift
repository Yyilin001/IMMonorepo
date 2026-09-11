import Foundation
import IMV2Compression
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

/// 预编码事件分页所需的编码上下文。
struct V2PreparedGroupEventPageEncodingContext: Sendable {
    let requestID: UInt64
    let frameVersion: UInt8
    let compression: V2NegotiatedFrameCompression?
    let maximumUncompressedPayloadBytes: Int
    let compressionThresholdBytes: Int
    let maximumExpansionRatio: Int
    let maximumGroupEventPagePayloadBytes: Int
    let cache: V2PreparedGroupEventPageCache
}

/// 已编码的事件分页响应。
struct V2PreparedGroupEventPageResponse: Sendable {
    let frame: V2Frame
    let roomID: RoomID
    let nextRoomSequence: UInt64
    let hasMore: Bool
}

/// 预编码拉取的结果。
enum V2PreparedGroupEventPullResult: Sendable {
    /// 已按帧编码完成的响应。
    case prepared(V2PreparedGroupEventPageResponse)
    /// 未编码的普通分页。
    case page(V2GroupEventLogPage)
    /// 事件过大，无法在协商上限内编码。
    case eventTooLarge
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

/// 支持预编码分页返回的扩展持久化能力。
protocol V2PreparedGroupEventLogStore: V2GroupEventLogStore {
    /// 按编码上下文拉取可直接回传的分页。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号。
    ///   - pageSize: 本页最多返回的事件数。
    ///   - context: 帧与压缩协商上下文。
    /// - Returns: 预编码结果。
    /// - Throws: 无资格、事件过大或持久化失败时抛出。
    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult
}

// Pull is deliberately independent from user-sync ACKs. Hybrid rooms retain a
// durable local room cursor; standard rooms use it only as a foreground
// preview and keep user-sync as the acknowledgement authority. Retries are
// idempotent because projections key on source event ID.
/// 房间事件日志服务。
///
/// 拉取刻意独立于用户同步确认：混合大群使用持久化的房间游标，
/// 标准房间只把它当作前台预览，确认权威仍是用户同步。重试是幂等的，
/// 因为投影以来源事件标识为准。
public struct V2GroupEventLogService: Sendable {
    /// 单页允许的最大事件数。
    public static let maximumPageSize = 500

    private let store: any V2GroupEventLogStore
    private let directRoomLogEventCache: V2DirectRoomLogEventCache?

    /// 组合事件日志存储与可选的私聊日志缓存。
    ///
    /// - Parameters:
    ///   - store: 事件日志的持久化存储。
    ///   - directRoomLogEventCache: 私聊日志加速缓存，可选。
    public init(
        store: any V2GroupEventLogStore,
        directRoomLogEventCache: V2DirectRoomLogEventCache? = nil
    ) {
        self.store = store
        self.directRoomLogEventCache = directRoomLogEventCache
    }

    /// 拉取一页房间事件。
    ///
    /// 会校验起始序号与分页大小，并复核返回分页的单调性与边界。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号。
    ///   - pageSize: 本页最多返回的事件数，需落在 `1...maximumPageSize`。
    /// - Returns: 已校验的事件分页。
    /// - Throws: 参数越界时抛出 ``V2GroupEventLogError/invalidRequest``；
    ///   分页序号不单调或越界时抛出 ``V2GroupEventLogError/corruptPersistenceState``；
    ///   其余错误来自存储实现。
    public func pull(roomID: RoomID, actorUserID: UserID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2GroupEventLogPage {
        guard (try? V2RoomCursor(afterRoomSequence)) != nil,
              pageSize > 0,
              pageSize <= Self.maximumPageSize
        else { throw V2GroupEventLogError.invalidRequest }
        return try validatePage(await store.pull(roomID: roomID, actorUserID: actorUserID, afterRoomSequence: afterRoomSequence, pageSize: pageSize), after: afterRoomSequence)
    }

    /// 在支持预编码的存储上拉取可直接回传的分页。
    ///
    /// 存储不支持预编码时退化为普通拉取；返回预编码结果时会额外校验下一页序号与
    /// 「是否还有后续」标记的一致性。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号。
    ///   - pageSize: 本页最多返回的事件数。
    ///   - context: 帧与压缩协商上下文，帧版本需不低于 21。
    /// - Returns: 预编码拉取结果。
    /// - Throws: 参数越界时抛出 ``V2GroupEventLogError/invalidRequest``；
    ///   返回分页序号异常时抛出 ``V2GroupEventLogError/corruptPersistenceState``。
    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult {
        guard (try? V2RoomCursor(afterRoomSequence)) != nil,
              pageSize > 0,
              pageSize <= Self.maximumPageSize,
              context.frameVersion >= 21
        else { throw V2GroupEventLogError.invalidRequest }
        guard let preparedStore = store as? any V2PreparedGroupEventLogStore else {
            return .page(try validatePage(await store.pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ), after: afterRoomSequence))
        }
        let result = try await preparedStore.pullPrepared(
            roomID: roomID,
            actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        )
        if case .page(let page) = result { return .page(try validatePage(page, after: afterRoomSequence)) }
        if case .prepared(let response) = result {
            guard response.nextRoomSequence <= UInt64(Int64.max),
                  response.nextRoomSequence >= afterRoomSequence,
                  !response.hasMore || response.nextRoomSequence > afterRoomSequence
            else { throw V2GroupEventLogError.corruptPersistenceState }
        }
        return result
    }

    /// 校验分页的单调性与边界。
    ///
    /// - Parameters:
    ///   - page: 待校验分页。
    ///   - after: 本次请求的起始序号。
    /// - Returns: 通过校验的原分页。
    /// - Throws: 下一页序号小于起始值、事件序号不严格递增或超出下一页序号时抛出
    ///   ``V2GroupEventLogError/corruptPersistenceState``。
    private func validatePage(_ page: V2GroupEventLogPage, after: UInt64) throws -> V2GroupEventLogPage {
        guard page.nextRoomSequence <= UInt64(Int64.max), page.nextRoomSequence >= after,
              !page.hasMore || page.nextRoomSequence > after
        else { throw V2GroupEventLogError.corruptPersistenceState }
        var previous = after
        for event in page.events {
            guard event.roomSequence > previous, event.roomSequence <= page.nextRoomSequence else {
                throw V2GroupEventLogError.corruptPersistenceState
            }
            previous = event.roomSequence
        }
        return page
    }

    /// 校验前台连接是否可以订阅。
    ///
    /// 该检查在网关保留任何进程内观察者状态之前完成。调用方在拿到结果后仍需按游标拉取，
    /// 因为房间可能紧接着就推进了水位。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起订阅的用户。
    /// - Returns: 已校验的订阅结果。
    /// - Throws: 水位或成员修订超出可编码范围时抛出
    ///   ``V2GroupEventLogError/corruptPersistenceState``；其余错误来自存储实现。
    public func subscribe(roomID: RoomID, actorUserID: UserID) async throws -> V2GroupEventSubscription {
        let subscription = try await store.subscribe(roomID: roomID, actorUserID: actorUserID)
        guard subscription.highWatermark <= UInt64(Int64.max),
              subscription.membershipRevision <= UInt64(Int64.max)
        else { throw V2GroupEventLogError.corruptPersistenceState }
        return subscription
    }

    /// 消息事务提交后的尽力而为本地读加速。
    ///
    /// 进程重启、消息由其他网关接受，或事件不符合纯文本私聊缓存契约时，
    /// 持久化游标日志仍是恢复路径。
    ///
    /// - Parameter message: 已接受消息。
    public func recordCommittedDirectRoomLogMessage(_ message: V2AcceptedMessage) async {
        await directRoomLogEventCache?.recordCommittedPlainDirectMessage(message)
    }

    /// 复用前台投递已物化的载荷。
    ///
    /// 缓存始终是尽力而为的，绝不会成为授权来源。
    ///
    /// - Parameter event: 已提交的实时事件。
    func recordCommittedDirectRoomLogEvent(_ event: V2DirectRoomLiveEvent) async {
        // Do not make the acceptance/foreground path wait for the cache
        // actor's LRU mutation. The cache already owns a bounded, room-sharded
        // mailbox whose writer preserves per-lane order; a mailbox miss or
        // overflow merely sends the later authorized pull to PostgreSQL.
        directRoomLogEventCache?.enqueueCommittedPlainDirectEvent(event)
    }

    /// 用已校验的跨网关前台中继结果填充本网关的恢复缓存。
    ///
    /// 核心 NATS 本身允许丢消息，因此这些记录绝不替代持久化房间日志：
    /// 序号缺失、邮箱溢出或进程重启仍会回退到 PostgreSQL。
    /// 在通知套接字之前先入队，可消除客户端看到更高水位后立刻要求本网关补洞的常见竞态；
    /// 缓存候选不携带身份信息，每个分页仍受存储的最新成员修订栅栏约束。
    ///
    /// - Parameter events: 已校验的实时事件列表。
    public func recordRelayedForegroundEvents(_ events: [V2DirectRoomLiveEvent]) {
        guard let directRoomLogEventCache else { return }
        directRoomLogEventCache.enqueueCommittedPlainDirectEvents(events)
    }
}
