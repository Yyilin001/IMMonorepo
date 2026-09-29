import IMV2ServerContracts
import Foundation
import IMV2Core

// 拉取有意与用户同步 ACK 独立。混合房间保留持久化本地房间游标；
// 标准房间只将其作为前台预览，仍由用户同步负责确认。
// 投影按源事件 ID 建键，因此重试具备幂等性。
/// 房间事件日志服务。
///
/// 拉取刻意独立于用户同步确认：混合大群使用持久化的房间游标，
/// 标准房间只把它当作前台预览，确认权威仍是用户同步。重试是幂等的，
/// 因为投影以来源事件标识为准。
public struct V2GroupEventLogService: Sendable {
    /// 单页允许的最大事件数。
    public static let maximumPageSize = 500

    let store: any V2GroupEventLogStore
    private let directRoomLogEventCache: (any V2CommittedRoomLogObserving)?

    /// 组合事件日志存储与可选的私聊日志缓存。
    ///
    /// - Parameters:
    ///   - store: 事件日志的持久化存储。
    ///   - directRoomLogEventCache: 私聊日志加速缓存，可选。
    public init(
        store: any V2GroupEventLogStore,
        directRoomLogEventCache: (any V2CommittedRoomLogObserving)? = nil
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

    /// 校验分页的单调性与边界。
    ///
    /// - Parameters:
    ///   - page: 待校验分页。
    ///   - after: 本次请求的起始序号。
    /// - Returns: 通过校验的原分页。
    /// - Throws: 下一页序号小于起始值、事件序号不严格递增或超出下一页序号时抛出
    ///   ``V2GroupEventLogError/corruptPersistenceState``。
    func validatePage(_ page: V2GroupEventLogPage, after: UInt64) throws -> V2GroupEventLogPage {
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
    package func recordCommittedDirectRoomLogEvent(_ event: V2DirectRoomLiveEvent) async {
        // 不要让接受或前台路径等待缓存 Actor 修改 LRU。
        // 缓存已有按房间分片的有界邮箱，其写者保持每条通道内的顺序；
        // 邮箱未命中或溢出只会让后续已授权的拉取转向 PostgreSQL。
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
