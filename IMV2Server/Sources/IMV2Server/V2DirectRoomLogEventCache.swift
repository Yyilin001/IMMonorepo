import Foundation
import IMV2Core
import Synchronization

/// 面向普通、规范的私聊与混合群组房间日志事件的有界进程本地加速缓存。
///
/// 它刻意不是授权缓存：调用方在返回候选分页之前，必须先从 PostgreSQL 取得新的成员栅栏；
/// 任何不确定的区间都会回退到持久日志。
///
/// 房间状态按哈希分片，使无关会话不会在单个 actor 上串行。
/// 每个分片各自持有一个 O(1) 的房间 LRU，以及全局条目/字节预算中的精确份额；
/// 总量绝不会超过配置上限。
public final class V2DirectRoomLogEventCache: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let maximumEvents: Int
        public let maximumBytes: Int
        public let maximumEventsPerRoom: Int
        public let shardCount: Int
        public let maximumPendingWrites: Int

        public init(
            maximumEvents: Int,
            maximumBytes: Int,
            maximumEventsPerRoom: Int,
            shardCount: Int = 16,
            maximumPendingWrites: Int = 4_096
        ) {
            precondition(maximumEvents > 0)
            precondition(maximumBytes > 0)
            precondition(maximumEventsPerRoom > 0)
            precondition(shardCount > 0)
            precondition(maximumPendingWrites > 0)
            self.maximumEvents = maximumEvents
            self.maximumBytes = maximumBytes
            self.maximumEventsPerRoom = maximumEventsPerRoom
            self.shardCount = shardCount
            self.maximumPendingWrites = maximumPendingWrites
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let cachedEvents: Int
        public let cachedRooms: Int
        public let cachedBytes: Int
        public let hits: UInt64
        public let misses: UInt64
        public let bypassedIneligibleEvents: UInt64
        public let pendingWrites: Int
        public let droppedWrites: UInt64

        public init(
            cachedEvents: Int,
            cachedRooms: Int,
            cachedBytes: Int,
            hits: UInt64,
            misses: UInt64,
            bypassedIneligibleEvents: UInt64,
            pendingWrites: Int = 0,
            droppedWrites: UInt64 = 0
        ) {
            self.cachedEvents = cachedEvents
            self.cachedRooms = cachedRooms
            self.cachedBytes = cachedBytes
            self.hits = hits
            self.misses = misses
            self.bypassedIneligibleEvents = bypassedIneligibleEvents
            self.pendingWrites = pendingWrites
            self.droppedWrites = droppedWrites
        }

        static let empty = Self(
            cachedEvents: 0,
            cachedRooms: 0,
            cachedBytes: 0,
            hits: 0,
            misses: 0,
            bypassedIneligibleEvents: 0,
            pendingWrites: 0,
            droppedWrites: 0
        )

        static func + (lhs: Self, rhs: Self) -> Self {
            .init(
                cachedEvents: lhs.cachedEvents + rhs.cachedEvents,
                cachedRooms: lhs.cachedRooms + rhs.cachedRooms,
                cachedBytes: lhs.cachedBytes + rhs.cachedBytes,
                hits: lhs.hits &+ rhs.hits,
                misses: lhs.misses &+ rhs.misses,
                bypassedIneligibleEvents:
                    lhs.bypassedIneligibleEvents &+ rhs.bypassedIneligibleEvents,
                pendingWrites: lhs.pendingWrites + rhs.pendingWrites,
                droppedWrites: lhs.droppedWrites &+ rhs.droppedWrites
            )
        }
    }

    /// 在持久授权读取之前捕获的不可变缓存覆盖信息。
    ///
    /// 它不携带任何身份，本身也无法授权任何响应。
    struct Candidate: Sendable {
        struct Event: Sendable {
            let entry: V2GroupEventLogEntry
            let membershipRevision: UInt64
        }

        let roomID: RoomID
        let afterRoomSequence: UInt64
        let pageSize: Int
        let events: [Event]

        func authorizedPage(
            actorJoinedRevision: UInt64,
            actorLeftRevision: UInt64?,
            currentHighWatermark: UInt64
        ) -> V2GroupEventLogPage? {
            guard afterRoomSequence <= currentHighWatermark else { return nil }
            if afterRoomSequence == currentHighWatermark {
                return try? .init(
                    roomID: roomID,
                    events: [],
                    nextRoomSequence: afterRoomSequence,
                    hasMore: false
                )
            }
            guard let first = events.first,
                  afterRoomSequence < UInt64.max,
                  first.entry.roomSequence == afterRoomSequence + 1,
                  let last = events.last,
                  last.entry.roomSequence <= currentHighWatermark
            else { return nil }
            for event in events {
                guard actorJoinedRevision <= event.membershipRevision,
                      actorLeftRevision == nil || actorLeftRevision! > event.membershipRevision
                else { return nil }
            }
            // 捕获不可变缓存候选后，持久高水位可能继续推进。
            // 较短的连续页面对返回的游标范围仍是完整的；
            // 设置 `hasMore` 让客户端继续拉取，避免通过开销大得多的
            // 持久查询重建同一批事件。若房间已推进而候选为空，
            // 上方仍会拒绝，因为它无法推进调用方的游标。
            return try? .init(
                roomID: roomID,
                events: events.map(\.entry),
                nextRoomSequence: last.entry.roomSequence,
                hasMore: last.entry.roomSequence < currentHighWatermark
            )
        }
    }

    enum PreparedPageResult: Sendable {
        case prepared(V2PreparedGroupEventPageResponse)
        case eventTooLarge
        case miss
    }

    fileprivate struct PreparedEvent: Sendable {
        let roomID: RoomID
        let entry: V2GroupEventLogEntry
        let membershipRevision: UInt64
        let byteCost: Int
    }

    private struct Lane: Sendable {
        let cache: V2DirectRoomLogEventCacheShard
        let mailbox: V2DirectRoomLogEventCacheMailbox
    }

    private let lanes: [Lane]

    public init(configuration: Configuration) {
        // 每个分片都必须能以配置的单房间深度保留至少一个房间。
        // 否则拆分较小的测试或开发预算时，房间还未形成连续页面就可能被淘汰。
        let perRoomCapacity = min(
            configuration.maximumEvents,
            configuration.maximumEventsPerRoom
        )
        let maximumUsefulShards = max(1, configuration.maximumEvents / perRoomCapacity)
        let count = max(
            1,
            min(
                configuration.shardCount,
                maximumUsefulShards,
                configuration.maximumBytes,
                configuration.maximumPendingWrites
            )
        )
        lanes = (0..<count).map { index in
            .init(
                cache: V2DirectRoomLogEventCacheShard(configuration: .init(
                    maximumEvents: Self.partition(
                        configuration.maximumEvents,
                        among: count,
                        index: index
                    ),
                    maximumBytes: Self.partition(
                        configuration.maximumBytes,
                        among: count,
                        index: index
                    ),
                    maximumEventsPerRoom: configuration.maximumEventsPerRoom
                )),
                mailbox: V2DirectRoomLogEventCacheMailbox(maximumPending: Self.partition(
                    configuration.maximumPendingWrites,
                    among: count,
                    index: index
                ))
            )
        }
    }

    /// 只记录已提交的普通房间日志消息。
    ///
    /// 载荷构建发生在进入房间分片之前，从而把 JSON 计算的 CPU 开销挡在分片隔离域之外。
    ///
    /// - Parameter message: 已提交的普通私聊消息。
    public func recordCommittedPlainDirectMessage(_ message: V2AcceptedMessage) async {
        guard let prepared = Self.prepare(message) else {
            await lane(for: message.roomID).cache.recordBypass()
            return
        }
        await lane(for: message.roomID).cache.record(prepared)
    }

    /// 在可用性提示发布之前，记录一个已物化的提交后载荷。
    ///
    /// 这建立了「先缓存、后提示」的顺序，同时无需重新编码 JSON 或涉及 PostgreSQL。
    ///
    /// - Parameter event: 已物化的提交后实时事件。
    func recordCommittedPlainDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        guard let prepared = Self.prepare(event) else {
            await lane(for: event.roomID).cache.recordBypass()
            return
        }
        await lane(for: prepared.roomID).cache.record(prepared)
    }

    /// 持久消息提交之后使用的热路径入口。
    ///
    /// 已接受的响应只需等待一次有界的分片信箱追加；
    /// JSON 构建、排序与 LRU 变更都在运行时拥有的写者任务中执行。
    ///
    /// - Parameter message: 已提交的普通私聊消息。
    public func enqueueCommittedPlainDirectMessage(_ message: V2AcceptedMessage) {
        guard let prepared = Self.prepare(message) else {
            lane(for: message.roomID).mailbox.recordBypass()
            return
        }
        lane(for: prepared.roomID).mailbox.enqueue(prepared)
    }

    /// 首选的生产入口。
    ///
    /// 前台实时事件与本缓存共享同一份不可变编码载荷，
    /// 因此提交后加速不再执行两次 JSON 编码，也不会保留两份完整消息值。
    ///
    /// - Parameter event: 已物化的提交后实时事件。
    func enqueueCommittedPlainDirectEvent(_ event: V2DirectRoomLiveEvent) {
        guard let prepared = Self.prepare(event) else {
            lane(for: event.roomID).mailbox.recordBypass()
            return
        }
        lane(for: prepared.roomID).mailbox.enqueue(prepared)
    }

    /// 跨 Gateway 中继使用的批量对应实现。
    ///
    /// 一条已解码的 NATS 微批通常属于同一房间/通道；
    /// 让这种批量形态贯穿信箱与分片 actor，而不是把它重新拆成每个事件一次互斥获取、
    /// 一次流信号与一次 actor 跳转。
    ///
    /// 按通道分组也使该方法对包含多个房间的兼容输入保持正确。
    /// 每个通道内的相对顺序与输入顺序完全一致，
    /// 分片的序号围栏对重复或罕见乱序仍是权威。
    ///
    /// - Parameter events: 本批待入队的提交后实时事件。
    func enqueueCommittedPlainDirectEvents(_ events: [V2DirectRoomLiveEvent]) {
        guard !events.isEmpty else { return }
        var preparedByLane: [Int: [PreparedEvent]] = [:]
        preparedByLane.reserveCapacity(min(events.count, lanes.count))
        for event in events {
            guard let prepared = Self.prepare(event) else {
                lane(for: event.roomID).mailbox.recordBypass()
                continue
            }
            let index = laneIndex(for: prepared.roomID)
            preparedByLane[index, default: []].append(prepared)
        }
        for (index, batch) in preparedByLane {
            lanes[index].mailbox.enqueue(batch)
        }
    }

    /// 由单个运行时任务持有该循环。
    ///
    /// 每条通道由单独的子任务排空，既保持房间内顺序，
    /// 又不把无关的房间哈希串行化。
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for lane in lanes {
                group.addTask { await Self.run(lane: lane) }
            }
            await group.waitForAll()
        }
    }

    public func finish() async {
        for lane in lanes { lane.mailbox.finish() }
    }

    /// 捕获连续的本地覆盖信息，既不查询也不携带授权。
    ///
    /// 确定未命中会在此记录，使调用方可以跳过单独的轻量授权查询，
    /// 直接执行带授权的持久 SQL。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - afterRoomSequence: 分页起点之后的位置。
    ///   - pageSize: 请求的分页条数，必须大于零。
    /// - Returns: 本地候选覆盖；无法覆盖时为 `nil`。
    func candidate(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) async -> Candidate? {
        precondition(pageSize > 0)
        let lane = lane(for: roomID)
        // 提交后提示可能先到达前台客户端，此时缓存写者尚未消费邮箱信号。
        // 在判定覆盖缺失前，先物化已提交的有界批次；否则拉取操作会
        // 无谓地执行开销更大的持久事件重建查询。
        // 无身份信息的候选形成后，授权仍由调用方执行。
        await Self.materializePending(lane)
        return await lane.cache.candidate(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        )
    }

    /// 廉价且不含身份的覆盖探测。
    ///
    /// 在决定该请求是花费一次小型授权查询，还是直接走完整的持久分页查询之前使用。
    /// 它不会复制任何事件数组。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - afterRoomSequence: 分页起点之后的位置。
    ///   - pageSize: 请求的分页条数，必须大于零。
    /// - Returns: 本地是否已覆盖所需分页。
    func hasPreparedPageCoverage(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) async -> Bool {
        precondition(pageSize > 0)
        let lane = lane(for: roomID)
        await Self.materializePending(lane)
        return await lane.cache.hasCoverage(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        )
    }

    /// 应用新的持久成员栅栏，在房间分片内推导编码分页指纹，
    /// 并在构建任何候选/领域/protobuf 事件数组之前先查询共享载荷缓存。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - actorJoinedRevision: 请求发起者的加入修订。
    ///   - actorLeftRevision: 请求发起者的离开修订，仍在房间内时为空。
    ///   - currentHighWatermark: 当前持久高水位。
    ///   - afterRoomSequence: 分页起点之后的位置。
    ///   - pageSize: 请求的分页条数。
    ///   - context: 编码分页所需的上下文。
    /// - Returns: 已准备分页的结果。
    /// - Throws: 编码或状态校验失败时抛出。
    func preparedPage(
        roomID: RoomID,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> PreparedPageResult {
        let result = try await lane(for: roomID).cache.preparedPage(
            roomID: roomID,
            actorJoinedRevision: actorJoinedRevision,
            actorLeftRevision: actorLeftRevision,
            currentHighWatermark: currentHighWatermark,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        )
        switch result {
        case .prepared, .eventTooLarge:
            await lane(for: roomID).cache.recordLookup(hit: true)
        case .miss:
            await lane(for: roomID).cache.recordLookup(hit: false)
        }
        return result
    }

    /// 对不可变候选应用新的持久成员栅栏。
    ///
    /// 候选永远不是权威；该方法只集中处理可见性/连续性检查以及命中/未命中统计。
    ///
    /// - Parameters:
    ///   - candidate: 待校验的不可变候选。
    ///   - actorJoinedRevision: 请求发起者的加入修订。
    ///   - actorLeftRevision: 请求发起者的离开修订，仍在房间内时为空。
    ///   - currentHighWatermark: 当前持久高水位。
    /// - Returns: 通过栅栏校验的分页；不可见或不连续时返回 `nil`。
    func page(
        candidate: Candidate,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64
    ) async -> V2GroupEventLogPage? {
        let page = candidate.authorizedPage(
            actorJoinedRevision: actorJoinedRevision,
            actorLeftRevision: actorLeftRevision,
            currentHighWatermark: currentHighWatermark
        )
        await lane(for: candidate.roomID).cache.recordLookup(hit: page != nil)
        return page
    }

    /// 面向已持有持久栅栏调用方的兼容/测试便捷入口。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间标识。
    ///   - actorJoinedRevision: 请求发起者的加入修订。
    ///   - actorLeftRevision: 请求发起者的离开修订，仍在房间内时为空。
    ///   - currentHighWatermark: 当前持久高水位。
    ///   - afterRoomSequence: 分页起点之后的位置。
    ///   - pageSize: 请求的分页条数。
    /// - Returns: 通过栅栏校验的分页；不可见或不连续时返回 `nil`。
    public func page(
        roomID: RoomID,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) async -> V2GroupEventLogPage? {
        guard let candidate = await candidate(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize
        ) else { return nil }
        return await page(
            candidate: candidate,
            actorJoinedRevision: actorJoinedRevision,
            actorLeftRevision: actorLeftRevision,
            currentHighWatermark: currentHighWatermark
        )
    }

    func recordMiss(roomID: RoomID) async {
        await lane(for: roomID).cache.recordLookup(hit: false)
    }

    public func snapshot() async -> Snapshot {
        await withTaskGroup(of: Snapshot.self, returning: Snapshot.self) { group in
            for lane in lanes {
                group.addTask {
                    let cache = await lane.cache.snapshot()
                    let mailbox = lane.mailbox.snapshot()
                    return cache + mailbox
                }
            }
            var aggregate = Snapshot.empty
            for await value in group { aggregate = aggregate + value }
            return aggregate
        }
    }

    private func lane(for roomID: RoomID) -> Lane {
        lanes[laneIndex(for: roomID)]
    }

    private func laneIndex(for roomID: RoomID) -> Int {
        Self.shardIndex(for: roomID.rawValue, count: lanes.count)
    }

    private static func run(lane: Lane) async {
        for await _ in lane.mailbox.signals {
            if Task.isCancelled { return }
            await materializePending(lane)
        }
    }

    private static func materializePending(_ lane: Lane) async {
        let events = lane.mailbox.drain()
        guard !events.isEmpty else { return }
        await lane.cache.record(events)
    }

    private static func isEligible(_ message: V2AcceptedMessage) -> Bool {
        message.groupCapacityClass != .standard &&
            message.media.isEmpty &&
            message.mentions.isEmpty &&
            message.replyTo == nil &&
            message.sourceEventID != nil &&
            message.acceptedMembershipRevision != nil
    }

    private static func prepare(_ message: V2AcceptedMessage) -> PreparedEvent? {
        guard isEligible(message),
              let sourceEventID = message.sourceEventID,
              let membershipRevision = message.acceptedMembershipRevision,
              let payload = V2DirectRoomLogPayloadCodec.encode(message)
        else { return nil }
        return try? .init(
            roomID: message.roomID,
            entry: try .init(
                sourceEventID: sourceEventID,
                roomSequence: message.roomSequence,
                projectionKind: "message",
                payload: payload
            ),
            membershipRevision: membershipRevision,
            byteCost: payload.count + 128
        )
    }

    private static func prepare(_ event: V2DirectRoomLiveEvent) -> PreparedEvent? {
        guard event.projectionKind == "message",
              let membershipRevision = event.acceptedMembershipRevision
        else { return nil }
        return try? .init(
            roomID: event.roomID,
            entry: try .init(
                sourceEventID: event.sourceEventID,
                roomSequence: event.roomSequence,
                projectionKind: event.projectionKind,
                payload: event.payload
            ),
            membershipRevision: membershipRevision,
            byteCost: event.payload.count + 128
        )
    }

    private static func partition(_ total: Int, among count: Int, index: Int) -> Int {
        total / count + (index < total % count ? 1 : 0)
    }

    private static func shardIndex(for value: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

private final class V2DirectRoomLogEventCacheMailbox: Sendable {
    private struct State: Sendable {
        var pending: [V2DirectRoomLogEventCache.PreparedEvent]
        var dropped: UInt64 = 0
        var bypassed: UInt64 = 0
        var finished = false
    }

    let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let maximumPending: Int
    private let state: Mutex<State>

    init(maximumPending: Int) {
        precondition(maximumPending > 0)
        self.maximumPending = maximumPending
        var pending: [V2DirectRoomLogEventCache.PreparedEvent] = []
        pending.reserveCapacity(maximumPending)
        state = Mutex(.init(pending: pending))
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = stream.stream
        continuation = stream.continuation
    }

    func enqueue(_ event: V2DirectRoomLogEventCache.PreparedEvent) {
        enqueue([event])
    }

    func enqueue(_ events: [V2DirectRoomLogEventCache.PreparedEvent]) {
        guard !events.isEmpty else { return }
        let accepted = state.withLock { state in
            guard !state.finished else { return false }
            let available = maximumPending - state.pending.count
            guard available > 0 else {
                state.dropped &+= UInt64(events.count)
                return false
            }
            let acceptedCount = min(available, events.count)
            state.pending.append(contentsOf: events.prefix(acceptedCount))
            state.dropped &+= UInt64(events.count - acceptedCount)
            return true
        }
        if accepted { continuation.yield() }
    }

    func recordBypass() {
        state.withLock { $0.bypassed &+= 1 }
    }

    func drain() -> [V2DirectRoomLogEventCache.PreparedEvent] {
        state.withLock { state in
            guard !state.pending.isEmpty else { return [] }
            let batch = state.pending
            state.pending.removeAll(keepingCapacity: true)
            return batch
        }
    }

    func snapshot() -> V2DirectRoomLogEventCache.Snapshot {
        state.withLock {
            .init(
                cachedEvents: 0,
                cachedRooms: 0,
                cachedBytes: 0,
                hits: 0,
                misses: 0,
                bypassedIneligibleEvents: $0.bypassed,
                pendingWrites: $0.pending.count,
                droppedWrites: $0.dropped
            )
        }
    }

    func finish() {
        let shouldFinish = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            state.pending.removeAll(keepingCapacity: false)
            return true
        }
        if shouldFinish { continuation.finish() }
    }
}

private actor V2DirectRoomLogEventCacheShard {
    struct Configuration: Sendable {
        let maximumEvents: Int
        let maximumBytes: Int
        let maximumEventsPerRoom: Int
    }

    private struct CachedEvent: Sendable {
        let entry: V2GroupEventLogEntry
        let membershipRevision: UInt64
        let byteCost: Int
    }

    /// 刻意使用局限在 actor 内的引用类型存储。
    ///
    /// 若保持为值类型，`rooms[roomKey]` 与本地变更会共享同一份数组缓冲区，
    /// 于是对已饱和房间的每次追加都会触发整段保留窗口的写时复制克隆。
    /// 该实例绝不会跨越分片 actor 边界。
    private final class RoomEntries {
        var events: [CachedEvent]
        /// 保留窗口的逻辑头部下标。
        ///
        /// 若用 `Array.removeFirst()` 移除最旧事件，一旦热房间达到容量，
        /// 每条新消息都会搬移所有保留载荷。推进该游标是 O(1)；
        /// 偶发的压缩则摊薄存储回收成本。
        var firstEventIndex: Int
        var previousRoom: String?
        var nextRoom: String?

        init(
            events: [CachedEvent],
            firstEventIndex: Int,
            previousRoom: String?,
            nextRoom: String?
        ) {
            self.events = events
            self.firstEventIndex = firstEventIndex
            self.previousRoom = previousRoom
            self.nextRoom = nextRoom
        }

        var eventCount: Int { events.count - firstEventIndex }

        func removeFirstEvent() -> CachedEvent {
            precondition(firstEventIndex < events.count)
            let event = events[firstEventIndex]
            firstEventIndex += 1
            if firstEventIndex >= 1_024 && firstEventIndex * 2 >= events.count {
                events.removeFirst(firstEventIndex)
                firstEventIndex = 0
            }
            return event
        }

    }

    private let configuration: Configuration
    private var rooms: [String: RoomEntries] = [:]
    private var leastRecentlyUsedRoom: String?
    private var mostRecentlyUsedRoom: String?
    private var cachedEventCount = 0
    private var cachedByteCount = 0
    private var hits: UInt64 = 0
    private var misses: UInt64 = 0
    private var bypassedIneligibleEvents: UInt64 = 0

    init(configuration: Configuration) {
        precondition(configuration.maximumEvents > 0 && configuration.maximumBytes > 0)
        self.configuration = configuration
    }

    func record(_ prepared: V2DirectRoomLogEventCache.PreparedEvent) {
        guard prepared.byteCost <= configuration.maximumBytes else {
            recordBypass()
            return
        }
        let roomKey = prepared.roomID.rawValue
        let room = rooms[roomKey] ?? .init(
            events: [],
            firstEventIndex: 0,
            previousRoom: nil,
            nextRoom: nil
        )
        if room.firstEventIndex < room.events.count,
           prepared.entry.roomSequence < room.events[room.firstEventIndex].entry.roomSequence {
            // 早于保留滑动窗口的重试无法改善未来任何游标页面；
            // 持久化日志仍覆盖该事件。
            touch(roomKey)
            return
        }
        // 常规路径中已提交的房间序号单调递增，可直接追加，
        // 无须扫描或排序保留的房间窗口。重试及罕见的跨任务乱序
        // 使用对数时间查询，并保留原有的重复一致性围栏。
        var lowerBound = room.firstEventIndex
        var upperBound = room.events.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if room.events[middle].entry.roomSequence < prepared.entry.roomSequence {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        if lowerBound < room.events.count,
           room.events[lowerBound].entry.roomSequence == prepared.entry.roomSequence {
            let existingIndex = lowerBound
            let existing = room.events[existingIndex]
            guard existing.entry.sourceEventID == prepared.entry.sourceEventID,
                  existing.membershipRevision == prepared.membershipRevision,
                  existing.entry.payload == prepared.entry.payload
            else {
                removeRoom(roomKey)
                recordBypass()
                return
            }
            rooms[roomKey] = room
            touch(roomKey)
            return
        }

        let cached = CachedEvent(
            entry: prepared.entry,
            membershipRevision: prepared.membershipRevision,
            byteCost: prepared.byteCost
        )
        if lowerBound == room.events.endIndex {
            room.events.append(cached)
        } else {
            room.events.insert(cached, at: lowerBound)
        }
        cachedEventCount += 1
        cachedByteCount += prepared.byteCost
        while room.eventCount > configuration.maximumEventsPerRoom {
            let evicted = room.removeFirstEvent()
            cachedEventCount -= 1
            cachedByteCount -= evicted.byteCost
        }
        rooms[roomKey] = room
        touch(roomKey)
        evictIfNeeded()
    }

    /// 让中继微批跨越 actor 边界时保持成批形态。
    ///
    /// `record(_:)` 仍会对每条记录应用完全相同的去重、排序与预算规则；
    /// 该方法只是省去逐事件的执行器调度。
    ///
    /// - Parameter prepared: 本批已准备好的缓存事件。
    func record(_ prepared: [V2DirectRoomLogEventCache.PreparedEvent]) {
        for event in prepared {
            record(event)
        }
    }

    func recordBypass() {
        bypassedIneligibleEvents &+= 1
    }

    func hasCoverage(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) -> Bool {
        guard let room = rooms[roomID.rawValue],
              coverageRange(
                  room: room,
                  afterRoomSequence: afterRoomSequence,
                  pageSize: pageSize
              ) != nil
        else { return false }
        touch(roomID.rawValue)
        return true
    }

    func preparedPage(
        roomID: RoomID,
        actorJoinedRevision: UInt64,
        actorLeftRevision: UInt64?,
        currentHighWatermark: UInt64,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) throws -> V2DirectRoomLogEventCache.PreparedPageResult {
        let roomKey = roomID.rawValue
        guard afterRoomSequence <= currentHighWatermark,
              let room = rooms[roomKey],
              let candidateRange = coverageRange(
                  room: room,
                  afterRoomSequence: afterRoomSequence,
                  pageSize: pageSize
              )
        else { return .miss }

        if afterRoomSequence == currentHighWatermark {
            let key = V2PreparedGroupEventPageCache.PageKey(
                protocolVersion: context.frameVersion,
                roomID: roomKey,
                firstEventID: "",
                lastEventID: "",
                firstRoomSequence: 0,
                lastRoomSequence: 0,
                eventCount: 0,
                nextRoomSequence: afterRoomSequence,
                hasMore: false
            )
            let frame = try context.cache.frame(
                for: key,
                requestID: context.requestID,
                compression: context.compression,
                maximumUncompressedPayloadBytes: context.maximumUncompressedPayloadBytes,
                compressionThresholdBytes: context.compressionThresholdBytes,
                maximumExpansionRatio: context.maximumExpansionRatio
            ) {
                var envelope = IMV2Envelope()
                envelope.requestID = context.requestID
                envelope.protocolVersion = UInt32(context.frameVersion)
                envelope.groupEventPage = .init()
                envelope.groupEventPage.roomID = roomKey
                envelope.groupEventPage.nextRoomSequence = afterRoomSequence
                return envelope
            }
            touch(roomKey)
            return .prepared(.init(
                frame: frame,
                roomID: roomID,
                nextRoomSequence: afterRoomSequence,
                hasMore: false
            ))
        }

        guard !candidateRange.isEmpty,
              let firstCandidate = room.events[candidateRange].first,
              let lastCandidate = room.events[candidateRange].last,
              firstCandidate.entry.roomSequence == afterRoomSequence + 1,
              lastCandidate.entry.roomSequence <= currentHighWatermark
        else { return .miss }
        for index in candidateRange {
            let event = room.events[index]
            guard actorJoinedRevision <= event.membershipRevision,
                  actorLeftRevision == nil || actorLeftRevision! > event.membershipRevision
            else { return .miss }
        }

        let candidateHasMore =
            lastCandidate.entry.roomSequence < currentHighWatermark
        var eventFieldBytes = 0
        var includedCount = 0
        var finalHasMore = candidateHasMore
        for (offset, index) in candidateRange.enumerated() {
            let event = room.events[index]
            let candidateEventFieldBytes = eventFieldBytes
                + v2PreparedGroupEventRepeatedFieldBytes(event.entry)
            let hasMore = candidateHasMore || offset < candidateRange.count - 1
            guard v2PreparedGroupEventPageEnvelopeBytes(
                roomID: roomKey,
                eventFieldBytes: candidateEventFieldBytes,
                nextRoomSequence: event.entry.roomSequence,
                hasMore: hasMore
            ) <= context.maximumGroupEventPagePayloadBytes else {
                break
            }
            includedCount += 1
            eventFieldBytes = candidateEventFieldBytes
            finalHasMore = hasMore
        }
        guard includedCount > 0 else {
            touch(roomKey)
            return .eventTooLarge
        }

        let includedRange = candidateRange.lowerBound
            ..< (candidateRange.lowerBound + includedCount)
        let first = room.events[includedRange.lowerBound].entry
        let last = room.events[includedRange.index(before: includedRange.endIndex)].entry
        let key = V2PreparedGroupEventPageCache.PageKey(
            protocolVersion: context.frameVersion,
            roomID: roomKey,
            firstEventID: first.sourceEventID.rawValue,
            lastEventID: last.sourceEventID.rawValue,
            firstRoomSequence: first.roomSequence,
            lastRoomSequence: last.roomSequence,
            eventCount: includedCount,
            nextRoomSequence: last.roomSequence,
            hasMore: finalHasMore
        )
        let frame = try context.cache.frame(
            for: key,
            requestID: context.requestID,
            compression: context.compression,
            maximumUncompressedPayloadBytes: context.maximumUncompressedPayloadBytes,
            compressionThresholdBytes: context.compressionThresholdBytes,
            maximumExpansionRatio: context.maximumExpansionRatio
        ) {
            var envelope = IMV2Envelope()
            envelope.requestID = context.requestID
            envelope.protocolVersion = UInt32(context.frameVersion)
            envelope.groupEventPage = .init()
            envelope.groupEventPage.roomID = roomKey
            var events: [IMV2GroupEvent] = []
            events.reserveCapacity(includedCount)
            for index in includedRange {
                let entry = room.events[index].entry
                var event = IMV2GroupEvent()
                event.sourceEventID = entry.sourceEventID.rawValue
                event.roomSequence = entry.roomSequence
                event.projectionKind = entry.projectionKind
                event.payload = entry.payload
                events.append(event)
            }
            envelope.groupEventPage.events = events
            envelope.groupEventPage.nextRoomSequence = last.roomSequence
            envelope.groupEventPage.hasMore_p = finalHasMore
            return envelope
        }
        touch(roomKey)
        return .prepared(.init(
            frame: frame,
            roomID: roomID,
            nextRoomSequence: last.roomSequence,
            hasMore: finalHasMore,
            authorSample: context.captureAuthorSample ? .init(roomID: roomID,
                events: includedRange.lazy.map { room.events[$0].entry }) : nil
        ))
    }

    func candidate(
        roomID: RoomID,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) -> V2DirectRoomLogEventCache.Candidate? {
        let roomKey = roomID.rawValue
        guard let room = rooms[roomKey], afterRoomSequence < UInt64.max else {
            misses &+= 1
            return nil
        }
        let expectedFirst = afterRoomSequence + 1
        var expected = expectedFirst
        var result: [V2DirectRoomLogEventCache.Candidate.Event] = []
        result.reserveCapacity(min(pageSize, room.eventCount))
        for event in room.events[room.firstEventIndex...] where event.entry.roomSequence >= expectedFirst {
            if result.count == pageSize { break }
            guard event.entry.roomSequence == expected else {
                misses &+= 1
                return nil
            }
            result.append(.init(
                entry: event.entry,
                membershipRevision: event.membershipRevision
            ))
            guard expected < UInt64.max else { break }
            expected += 1
        }
        touch(roomKey)
        return .init(
            roomID: roomID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            events: result
        )
    }

    private func coverageRange(
        room: RoomEntries,
        afterRoomSequence: UInt64,
        pageSize: Int
    ) -> Range<Int>? {
        guard afterRoomSequence < UInt64.max else { return nil }
        let expectedFirst = afterRoomSequence + 1
        var lowerBound = room.firstEventIndex
        var upperBound = room.events.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if room.events[middle].entry.roomSequence < expectedFirst {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        let start = lowerBound
        var expected = expectedFirst
        var index = start
        while index < room.events.count, index - start < pageSize {
            let sequence = room.events[index].entry.roomSequence
            guard sequence == expected else { return nil }
            index += 1
            guard expected < UInt64.max else { break }
            expected += 1
        }
        return start..<index
    }

    func recordLookup(hit: Bool) {
        if hit { hits &+= 1 } else { misses &+= 1 }
    }

    func snapshot() -> V2DirectRoomLogEventCache.Snapshot {
        .init(
            cachedEvents: cachedEventCount,
            cachedRooms: rooms.count,
            cachedBytes: cachedByteCount,
            hits: hits,
            misses: misses,
            bypassedIneligibleEvents: bypassedIneligibleEvents
        )
    }

    private func touch(_ roomKey: String) {
        guard mostRecentlyUsedRoom != roomKey, let room = rooms[roomKey] else { return }
        unlink(roomKey, room: room)
        room.previousRoom = mostRecentlyUsedRoom
        room.nextRoom = nil
        if let mostRecentlyUsedRoom, let previous = rooms[mostRecentlyUsedRoom] {
            previous.nextRoom = roomKey
        } else {
            leastRecentlyUsedRoom = roomKey
        }
        mostRecentlyUsedRoom = roomKey
    }

    private func unlink(_ roomKey: String, room: RoomEntries) {
        if let previousRoom = room.previousRoom, let previous = rooms[previousRoom] {
            previous.nextRoom = room.nextRoom
        } else if leastRecentlyUsedRoom == roomKey {
            leastRecentlyUsedRoom = room.nextRoom
        }
        if let nextRoom = room.nextRoom, let next = rooms[nextRoom] {
            next.previousRoom = room.previousRoom
        } else if mostRecentlyUsedRoom == roomKey {
            mostRecentlyUsedRoom = room.previousRoom
        }
    }

    private func removeRoom(_ roomKey: String) {
        guard let room = rooms.removeValue(forKey: roomKey) else { return }
        unlink(roomKey, room: room)
        cachedEventCount -= room.eventCount
        cachedByteCount -= room.events[room.firstEventIndex...].reduce(into: 0) {
            $0 += $1.byteCost
        }
    }

    private func evictIfNeeded() {
        while cachedEventCount > configuration.maximumEvents ||
                cachedByteCount > configuration.maximumBytes {
            guard let leastRecentlyUsedRoom else { return }
            removeRoom(leastRecentlyUsedRoom)
        }
    }

}

private func v2PreparedGroupEventPageEnvelopeBytes(
    roomID: String,
    eventFieldBytes: Int,
    nextRoomSequence: UInt64,
    hasMore: Bool
) -> Int {
    let pageBytes =
        v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 1,
            payloadBytes: roomID.utf8.count
        )
        + eventFieldBytes
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 3,
            value: nextRoomSequence
        )
        + (hasMore
            ? v2PreparedProtobufVarintFieldBytes(fieldNumber: 4, value: 1)
            : 0)

    return v2PreparedProtobufVarintFieldBytes(fieldNumber: 1, value: .max)
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 2,
            value: UInt64(IMV2ProtocolVersion.current)
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 62,
            payloadBytes: pageBytes
        )
}

private func v2PreparedGroupEventRepeatedFieldBytes(
    _ entry: V2GroupEventLogEntry
) -> Int {
    let eventBytes =
        v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 1,
            payloadBytes: entry.sourceEventID.rawValue.utf8.count
        )
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 2,
            value: entry.roomSequence
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 3,
            payloadBytes: entry.projectionKind.utf8.count
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 4,
            payloadBytes: entry.payload.count
        )
    return v2PreparedProtobufLengthDelimitedFieldBytes(
        fieldNumber: 2,
        payloadBytes: eventBytes
    )
}

private func v2PreparedProtobufLengthDelimitedFieldBytes(
    fieldNumber: Int,
    payloadBytes: Int
) -> Int {
    v2PreparedProtobufTagBytes(fieldNumber: fieldNumber, wireType: 2)
        + v2PreparedProtobufVarintByteCount(UInt64(payloadBytes))
        + payloadBytes
}

private func v2PreparedProtobufVarintFieldBytes(
    fieldNumber: Int,
    value: UInt64
) -> Int {
    guard value != 0 else { return 0 }
    return v2PreparedProtobufTagBytes(fieldNumber: fieldNumber, wireType: 0)
        + v2PreparedProtobufVarintByteCount(value)
}

private func v2PreparedProtobufTagBytes(
    fieldNumber: Int,
    wireType: UInt64
) -> Int {
    v2PreparedProtobufVarintByteCount((UInt64(fieldNumber) << 3) | wireType)
}

private func v2PreparedProtobufVarintByteCount(_ value: UInt64) -> Int {
    var remaining = value
    var count = 1
    while remaining >= 0x80 {
        remaining >>= 7
        count += 1
    }
    return count
}
