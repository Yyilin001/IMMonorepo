import Foundation
import IMV2Core
import Crypto
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

/// 动态房间订阅与持久化唤醒发件箱工作刻意分离。
///
/// 网络分区期间代理可能丢失订阅，但客户端游标与低频恢复拉取依然保证正确性。
public protocol V2GroupEventWakeInterestManaging: Sendable {
    /// 订阅指定房间的事件唤醒。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Throws: 连接或订阅失败时抛出。
    func activate(roomID: RoomID) async throws

    /// 取消指定房间的事件唤醒订阅。
    ///
    /// - Parameter roomID: 目标房间。
    func deactivate(roomID: RoomID) async
}

/// NATS 群事件唤醒的发布配置。
public struct V2NATSGroupEventWakeConfiguration: Equatable, Sendable {
    /// NATS 服务地址，仅支持 `nats` 或 `tls` 方案。
    public let url: URL
    /// 主题前缀，需符合以点分隔的标识符格式。
    public let subjectPrefix: String
    /// 可选的认证令牌。
    public let token: String?
    /// 用于派生不透明房间路由主题的部署级密钥。
    ///
    /// 它使稳定的房间 UUID 不会出现在消息代理的 ACL、链路追踪或主题名中。
    public let routingKey: Data
    /// 内部 NATS TLS 端点可选的私有信任根与 SNI 覆盖。
    ///
    /// 省略时使用系统信任库与地址中的主机名。
    public let tlsCAPath: String?
    /// 可选的 TLS 服务端名称。
    public let tlsServerName: String?
    /// 持久化唤醒的延迟发布毫秒数。
    ///
    /// 持久化唤醒可能在对应的前台微批完成有界聚合之前就经另一条发布连接到达。
    /// 这里只延迟该恢复提示，让在途实时载荷有机会覆盖它；截止时间到期后仍以 PostgreSQL 为准。
    public let wakeDeferralDelayMilliseconds: Int
    /// 连接、命令与代理 PING/PONG 确认的超时秒数。
    ///
    /// 仅完成一次 TCP 写入并不能证明 NATS 已接受前置命令。
    public let acknowledgementTimeout: TimeInterval
    let acknowledgementTimeoutNanoseconds: Int64

    /// 校验并保存 NATS 配置。
    ///
    /// 会校验方案、主机、主题前缀格式、令牌与 TLS 组合、路由密钥长度以及延迟与超时范围；
    /// 非回环地址必须使用 TLS 并携带令牌，且在未启用 TLS 时不得指定 CA 或 SNI。
    ///
    /// - Parameters:
    ///   - url: NATS 服务地址。
    ///   - subjectPrefix: 主题前缀。
    ///   - token: 认证令牌。
    ///   - routingKey: 路由密钥，至少 32 字节。
    ///   - tlsCAPath: 可选的私有信任根路径。
    ///   - tlsServerName: 可选的 TLS 服务端名称。
    ///   - wakeDeferralDelayMilliseconds: 唤醒延迟毫秒数，需落在 `0...1000`。
    ///   - acknowledgementTimeout: 确认超时秒数，需为正且不超过 30。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2NATSGroupEventWakeBrokerError/invalidConfiguration``。
    /// 组合 NATS 配置、恢复记录回调与接收回调。
    ///
    /// - Parameters:
    ///   - configuration: NATS 连接与主题配置。
    ///   - recordRecoveryNotification: 记录恢复通知的回调，默认忽略。
    ///   - metrics: 可选的传输指标记录器。
    ///   - receiveWake: 收到前台群事件通知时的回调。
    public init(
        url: URL,
        subjectPrefix: String,
        token: String? = nil,
        routingKey: Data,
        tlsCAPath: String? = nil,
        tlsServerName: String? = nil,
        wakeDeferralDelayMilliseconds: Int = 60,
        acknowledgementTimeout: TimeInterval = 2
    ) throws {
        let normalizedPrefix = subjectPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = url.scheme?.lowercased(),
              ["nats", "tls"].contains(scheme),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              normalizedPrefix.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        let normalizedCAPath = tlsCAPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServerName = tlsServerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != true,
              (isLoopback || normalizedToken != nil),
              (scheme == "tls" || isLoopback),
              (scheme == "tls" || (normalizedCAPath == nil && normalizedServerName == nil)),
              normalizedCAPath?.hasPrefix("/") != false,
              normalizedServerName?.isEmpty != true,
              routingKey.count >= 32,
              (0 ... 1_000).contains(wakeDeferralDelayMilliseconds),
              let timeoutNanoseconds = v2TimeoutNanoseconds(acknowledgementTimeout),
              acknowledgementTimeout <= 30
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        self.url = url
        self.subjectPrefix = normalizedPrefix
        self.token = normalizedToken
        self.routingKey = routingKey
        self.tlsCAPath = normalizedCAPath
        self.tlsServerName = normalizedServerName
        self.wakeDeferralDelayMilliseconds = wakeDeferralDelayMilliseconds
        self.acknowledgementTimeout = acknowledgementTimeout
        self.acknowledgementTimeoutNanoseconds = timeoutNanoseconds
    }

    var usesTLS: Bool { url.scheme?.lowercased() == "tls" }
}

/// 群事件唤醒代理错误。
public enum V2NATSGroupEventWakeBrokerError: Error, Equatable, Sendable {
    /// 代理配置不合法。
    case invalidConfiguration
    /// 代理当前不可用。
    case unavailable
    /// 载荷不满足当前编码契约。
    case invalidPayload
}

/// 前台群事件通知。
///
/// NATS 载荷只是尽力而为的前台通知：接收方仍必须把 `.wake` 当作触发游标拉取的提示，
/// 而 `.directEvent` 只有在客户端已持有紧邻的前一个游标时才可使用。
public enum V2ForegroundGroupEventNotification: Equatable, Sendable {
    /// 房间水位唤醒，需要按游标拉取。
    case wake(V2GroupEventWake)
    /// 单条私聊实时事件。
    case directEvent(V2DirectRoomLiveEvent)
    /// 一批群实时事件。
    case groupEvents([V2DirectRoomLiveEvent])
}

/// 群事件通知分发器。
///
/// 核心 NATS 保证单个发布者的主题内顺序，但同一房间可能被多个网关写入：
/// 数据库提交会分配唯一的房间序号，而各自独立的提交后发布却可能以相反顺序抵达 NATS。
/// 把房间哈希到固定通道可避免并发套接字扇出，短期有界合并窗口则能在前台客户端把常见反转
/// 误判为持久化日志缺口之前修复它。真正丢失或延迟的载荷以及过载情况仍会降级为权威游标拉取。
final class V2NATSGroupNotificationDispatcher: V2NATSPayloadSubmitting, Sendable {
    private static let maximumGroupEventsPerNotification = 64
    private static let recentLiveRoomCapacityPerLane = 4_096
    private static let maximumDeferredWakeRoomsPerLane = 4_096

    private struct Lane: Sendable {
        let mailbox: Mailbox
        let worker: Task<Void, Never>
    }

    private final class Mailbox: Sendable {
        private struct State: Sendable {
            var pending: [V2ForegroundGroupEventNotification] = []
            var finished = false
        }

        let signals: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let capacity: Int
        private let state = Mutex(State())

        init(capacity: Int) {
            self.capacity = capacity
            let stream = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            signals = stream.stream
            continuation = stream.continuation
        }

        func enqueue(_ notification: V2ForegroundGroupEventNotification) -> Bool {
            let dropped = state.withLock { state in
                guard !state.finished else { return true }
                let dropped = state.pending.count == capacity
                if dropped { state.pending.removeFirst() }
                state.pending.append(notification)
                return dropped
            }
            continuation.yield()
            return dropped
        }

        func drain() -> [V2ForegroundGroupEventNotification] {
            state.withLock { state in
                let pending = state.pending
                state.pending.removeAll(keepingCapacity: true)
                return pending
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

        func signal(after delay: Duration) {
            let continuation = continuation
            Task(priority: .high) {
                if delay > .zero { try? await v2Sleep(for: delay) }
                guard !Task.isCancelled else { return }
                continuation.yield()
            }
        }
    }

    private struct RoomWindow {
        var events: [V2DirectRoomLiveEvent] = []
        var maximumWakeHighWatermark: UInt64 = 0
        var firstOrdinal: Int
    }

    private struct OrderedNotification {
        let ordinal: Int
        let roomID: RoomID
        let highWatermark: UInt64
        let notification: V2ForegroundGroupEventNotification
    }

    private struct DeferredWake {
        var wake: V2GroupEventWake
        let deadline: ContinuousClock.Instant
    }

    /// 最近实时高水位缓存。
    ///
    /// 一个房间始终只分配给单个工作通道，因此该有界缓存是工作协程本地的，无需加锁。
    /// 它只记录本地套接字扇出已成功返回的通知。
    /// 淘汰只会失去一次优化：之后的持久唤醒仍会照常投递。
    private struct RecentLiveHighWatermarks {
        private let capacity: Int
        private var values: [RoomID: UInt64] = [:]
        private var roomRing: [RoomID] = []
        private var nextVictim = 0

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
            values.reserveCapacity(capacity)
            roomRing.reserveCapacity(capacity)
        }

        func covers(_ wake: V2GroupEventWake) -> Bool {
            values[wake.roomID, default: 0] >= wake.highWatermark
        }

        mutating func recordDeliveredLive(
            _ notification: V2ForegroundGroupEventNotification
        ) {
            let roomID: RoomID
            let deliveredSequence: UInt64
            switch notification {
            case .wake:
                return
            case .directEvent(let event):
                // A recipient-filtered or sender-excluding notification does
                // not prove that every local room viewer received the event.
                guard event.groupMembershipRevision != nil,
                      event.recipientUserIDs.isEmpty,
                      event.excludedConnectionID == nil
                else { return }
                roomID = event.roomID
                deliveredSequence = event.roomSequence
            case .groupEvents(let events):
                guard let first = events.first else { return }
                roomID = first.roomID
                deliveredSequence = events.last?.roomSequence ?? 0
            }
            guard deliveredSequence > 0 else { return }

            if let previous = values[roomID] {
                values[roomID] = max(previous, deliveredSequence)
                return
            }
            if roomRing.count < capacity {
                roomRing.append(roomID)
            } else {
                let victim = roomRing[nextVictim]
                values.removeValue(forKey: victim)
                roomRing[nextVictim] = roomID
                nextVictim = (nextVictim + 1) % capacity
            }
            values[roomID] = deliveredSequence
        }
    }

    private let recordRecoveryNotification: @Sendable (
        V2ForegroundGroupEventNotification
    ) -> Void
    private let droppedPayloadObserver: @Sendable () -> Void
    private let coveredWakeSuppressedObserver: @Sendable () -> Void
    private let wakeDeferredObserver: @Sendable () -> Void
    private let deferredWakeDeliveredObserver: @Sendable () -> Void
    private let lanes: [Lane]
    private let droppedPayloads = Atomic<UInt64>(0)

    init(
        laneCount: Int = 8,
        capacityPerLane: Int = 64,
        reorderingDelay: Duration = .milliseconds(20),
        recordRecoveryNotification: @escaping @Sendable (
            V2ForegroundGroupEventNotification
        ) -> Void = { _ in },
        droppedPayloadObserver: @escaping @Sendable () -> Void = {},
        coveredWakeSuppressedObserver: @escaping @Sendable () -> Void = {},
        wakeDeferralDelay: Duration = .milliseconds(20),
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        wakeDeferredObserver: @escaping @Sendable () -> Void = {},
        deferredWakeDeliveredObserver: @escaping @Sendable () -> Void = {},
        receiveNotification: @escaping @Sendable (
            V2ForegroundGroupEventNotification
        ) async -> Void
    ) {
        precondition(
            laneCount > 0 && capacityPerLane > 0 && reorderingDelay >= .zero
                && wakeDeferralDelay >= .zero
                && wakeDeferralDelay <= .seconds(1)
        )
        self.recordRecoveryNotification = recordRecoveryNotification
        self.droppedPayloadObserver = droppedPayloadObserver
        self.coveredWakeSuppressedObserver = coveredWakeSuppressedObserver
        self.wakeDeferredObserver = wakeDeferredObserver
        self.deferredWakeDeliveredObserver = deferredWakeDeliveredObserver
        lanes = (0 ..< laneCount).map { _ in
            let mailbox = Mailbox(capacity: capacityPerLane)
            let worker = Task(priority: .high) {
                var recentLive = RecentLiveHighWatermarks(
                    capacity: Self.recentLiveRoomCapacityPerLane
                )
                var deferredWakes: [RoomID: DeferredWake] = [:]
                deferredWakes.reserveCapacity(
                    Self.maximumDeferredWakeRoomsPerLane
                )
                for await _ in mailbox.signals {
                    guard !Task.isCancelled else { break }
                    if reorderingDelay > .zero {
                        try? await v2Sleep(for: reorderingDelay)
                    }
                    for notification in Self.coalesced(mailbox.drain()) {
                        guard !Task.isCancelled else { return }
                        if case .wake(let wake) = notification,
                           recentLive.covers(wake) {
                            coveredWakeSuppressedObserver()
                            continue
                        }
                        if case .wake(let wake) = notification,
                           wakeDeferralDelay > .zero {
                            if var existing = deferredWakes[wake.roomID] {
                                existing.wake = .init(
                                    roomID: wake.roomID,
                                    highWatermark: max(
                                        existing.wake.highWatermark,
                                        wake.highWatermark
                                    )
                                )
                                deferredWakes[wake.roomID] = existing
                            } else {
                                if deferredWakes.count
                                    >= Self.maximumDeferredWakeRoomsPerLane,
                                   let victimRoomID = deferredWakes.keys.first,
                                   let victim = deferredWakes.removeValue(
                                    forKey: victimRoomID
                                   ) {
                                    await receiveNotification(.wake(victim.wake))
                                    deferredWakeDeliveredObserver()
                                }
                                deferredWakes[wake.roomID] = .init(
                                    wake: wake,
                                    deadline: monotonicNow().advanced(
                                        by: wakeDeferralDelay
                                    )
                                )
                                wakeDeferredObserver()
                                mailbox.signal(after: wakeDeferralDelay)
                            }
                            continue
                        }
                        await receiveNotification(notification)
                        recentLive.recordDeliveredLive(notification)
                        let roomID = Self.roomID(of: notification)
                        if let pending = deferredWakes[roomID],
                           recentLive.covers(pending.wake) {
                            deferredWakes.removeValue(forKey: roomID)
                            coveredWakeSuppressedObserver()
                        }
                    }

                    let now = monotonicNow()
                    let due = deferredWakes.values
                        .filter { $0.deadline <= now }
                        .sorted {
                            if $0.deadline != $1.deadline {
                                return $0.deadline < $1.deadline
                            }
                            return $0.wake.roomID.rawValue
                                < $1.wake.roomID.rawValue
                        }
                    for pending in due {
                        guard !Task.isCancelled else { return }
                        guard deferredWakes.removeValue(
                            forKey: pending.wake.roomID
                        ) != nil else { continue }
                        if recentLive.covers(pending.wake) {
                            coveredWakeSuppressedObserver()
                            continue
                        }
                        await receiveNotification(.wake(pending.wake))
                        deferredWakeDeliveredObserver()
                    }
                }
            }
            return .init(mailbox: mailbox, worker: worker)
        }
    }

    func submit(subject _: String, payload: Data) {
        guard let notification =
            V2NATSGroupEventWakeBroker.decodeNotificationPayload(payload)
        else { return }
        // Recovery-cache ingestion must not wait behind socket fan-out. The
        // latter can legitimately stall on one actor traversing many local
        // connections; the former is a bounded, non-suspending mailbox write
        // that makes any later cursor gap locally repairable.
        recordRecoveryNotification(notification)
        let lane = lanes[Self.laneIndex(
            roomID: Self.roomID(of: notification),
            laneCount: lanes.count
        )]
        if lane.mailbox.enqueue(notification) {
            _ = droppedPayloads.wrappingAdd(1, ordering: .relaxed)
            droppedPayloadObserver()
        }
    }

    /// 直接提交一段载荷。
    ///
    /// 解码器/顺序的定向测试在外层投递器已隔离传输认证之后，会直接走这一阶段。
    ///
    /// - Parameter payload: 待提交的载荷字节。
    func submit(_ payload: Data) {
        submit(subject: "imv2.test", payload: payload)
    }

    func droppedPayloadCount() -> UInt64 {
        droppedPayloads.load(ordering: .relaxed)
    }

    /// 只对尽力而为的传输通知做合并。
    ///
    /// 恢复缓存已在上游观察到每一个已解码输入，
    /// 因此抑制一条落在同一窗口内的唤醒不可能隐藏持久状态。
    ///
    /// - Parameter notifications: 本次待合并的前台群事件通知。
    /// - Returns: 合并后的通知列表。
    private static func coalesced(
        _ notifications: [V2ForegroundGroupEventNotification]
    ) -> [V2ForegroundGroupEventNotification] {
        guard notifications.count > 1 else { return notifications }
        var rooms: [RoomID: RoomWindow] = [:]
        var passthrough: [OrderedNotification] = []
        passthrough.reserveCapacity(notifications.count)

        for (ordinal, notification) in notifications.enumerated() {
            switch notification {
            case .wake(let wake):
                var window = rooms[wake.roomID] ?? .init(firstOrdinal: ordinal)
                window.firstOrdinal = min(window.firstOrdinal, ordinal)
                window.maximumWakeHighWatermark = max(
                    window.maximumWakeHighWatermark,
                    wake.highWatermark
                )
                rooms[wake.roomID] = window
            case .directEvent(let event)
                where event.groupMembershipRevision != nil
                    && event.recipientUserIDs.isEmpty
                    && event.excludedConnectionID == nil:
                var window = rooms[event.roomID] ?? .init(firstOrdinal: ordinal)
                window.firstOrdinal = min(window.firstOrdinal, ordinal)
                window.events.append(event)
                rooms[event.roomID] = window
            case .groupEvents(let events):
                guard let first = events.first else { continue }
                var window = rooms[first.roomID] ?? .init(firstOrdinal: ordinal)
                window.firstOrdinal = min(window.firstOrdinal, ordinal)
                window.events.append(contentsOf: events)
                rooms[first.roomID] = window
            default:
                let roomID = Self.roomID(of: notification)
                let highWatermark: UInt64
                switch notification {
                case .wake(let wake): highWatermark = wake.highWatermark
                case .directEvent(let event): highWatermark = event.highWatermark
                case .groupEvents(let events):
                    highWatermark = events.last?.highWatermark ?? 0
                }
                passthrough.append(.init(
                    ordinal: ordinal,
                    roomID: roomID,
                    highWatermark: highWatermark,
                    notification: notification
                ))
            }
        }

        var output = passthrough
        output.reserveCapacity(notifications.count)
        for (roomID, window) in rooms {
            let sorted = window.events.sorted { lhs, rhs in
                if lhs.roomSequence != rhs.roomSequence {
                    return lhs.roomSequence < rhs.roomSequence
                }
                return lhs.sourceEventID.rawValue < rhs.sourceEventID.rawValue
            }
            var unique: [V2DirectRoomLiveEvent] = []
            unique.reserveCapacity(sorted.count)
            var conflictedSequences: Set<UInt64> = []
            for event in sorted {
                guard let previous = unique.last,
                      previous.roomSequence == event.roomSequence
                else {
                    unique.append(event)
                    continue
                }
                if previous != event {
                    conflictedSequences.insert(event.roomSequence)
                }
            }
            if !conflictedSequences.isEmpty {
                unique.removeAll {
                    conflictedSequences.contains($0.roomSequence)
                }
            }

            var run: [V2DirectRoomLiveEvent] = []
            func flushRun() {
                guard !run.isEmpty else { return }
                var lowerBound = 0
                while lowerBound < run.count {
                    let upperBound = min(
                        lowerBound + maximumGroupEventsPerNotification,
                        run.count
                    )
                    let batch = Array(run[lowerBound..<upperBound])
                    output.append(.init(
                        ordinal: window.firstOrdinal,
                        roomID: roomID,
                        highWatermark: batch.last?.highWatermark ?? 0,
                        notification: .groupEvents(batch)
                    ))
                    lowerBound = upperBound
                }
                run.removeAll(keepingCapacity: true)
            }
            for event in unique {
                if let previous = run.last,
                   (event.roomSequence != previous.roomSequence + 1
                        || event.groupMembershipRevision
                            != previous.groupMembershipRevision) {
                    flushRun()
                }
                run.append(event)
            }
            flushRun()

            let maximumEventSequence = unique.last?.roomSequence ?? 0
            if window.maximumWakeHighWatermark > maximumEventSequence {
                output.append(.init(
                    ordinal: window.firstOrdinal,
                    roomID: roomID,
                    highWatermark: window.maximumWakeHighWatermark,
                    notification: .wake(.init(
                        roomID: roomID,
                        highWatermark: window.maximumWakeHighWatermark
                    ))
                ))
            }
        }
        return output.sorted { lhs, rhs in
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            if lhs.roomID != rhs.roomID {
                return lhs.roomID.rawValue < rhs.roomID.rawValue
            }
            return lhs.highWatermark < rhs.highWatermark
        }
            .map(\.notification)
    }

    private static func roomID(
        of notification: V2ForegroundGroupEventNotification
    ) -> RoomID {
        switch notification {
        case .wake(let wake): wake.roomID
        case .directEvent(let event): event.roomID
        case .groupEvents(let events):
            // The decoder rejects an empty or mixed-room group batch.
            events[0].roomID
        }
    }

    private static func laneIndex(roomID: RoomID, laneCount: Int) -> Int {
        // A stable FNV-1a hash avoids process-randomized `Hasher` output and
        // keeps every event for one room on the same lane for this lifetime.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in roomID.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(laneCount))
    }
}

/// 每个 Gateway 一条可复用的 Core NATS 连接。
///
/// 它只持有当前本地观看者兴趣，而不是每用户或每房间的持久消费者。
/// 主题订阅由 `V2DeviceConnectionRegistry` 做引用计数。
public actor V2NATSGroupEventWakeBroker: V2GroupEventWakePublishing, V2ForegroundGroupEventHintPublishing, V2GroupEventWakeInterestManaging {
    /// 发布保证级别。
    ///
    /// 前台载荷只是加速一个已在 PostgreSQL 持久化的房间游标。
    /// 为每个此类载荷都要求 broker PONG，会给每个微批增加一次额外网络往返，
    /// 却不改变正确性。持久发件箱唤醒与订阅生命周期命令仍在下方保留 broker 确认。
    private enum PublicationGuarantee: Sendable {
        case brokerConfirmed
        case advisory
    }

    private static let maximumCachedSubjects = 4_096
    /// Core NATS 默认 `max_payload` 为 1 MiB。
    ///
    /// 有界批次为 protobuf 信封和鉴权封装预留空间。
    private static let maximumGroupEventsPerPublication = 64
    private static let maximumGroupEventRawPayloadBytesPerPublication = 512 * 1_024
    /// protobuf 正文与信封保持在 Core NATS 常规 1 MiB 上限之下。
    private static let maximumInboundNotificationPayloadBytes = 640 * 1_024
        + V2NATSAuthenticatedPayloadCodec.overheadBytes

    private struct Connect: Encodable {
        let verbose = false
        let pedantic = false
        let token: String?

        enum CodingKeys: String, CodingKey {
            case verbose
            case pedantic
            case token = "auth_token"
        }
    }

    private struct Connection: Sendable {
        let id: UUID
        let channel: any Channel
        let handler: V2NATSConfirmedInboundHandler
        let replayedSubscriptionIDs: Set<Int>
    }

    private struct PendingActivation {
        let subscriptionID: Int
        let task: Task<Void, any Error>
    }

    private let configuration: V2NATSGroupEventWakeConfiguration
    private let subjectRoutingKey: SymmetricKey
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let recordRecoveryNotification: @Sendable (
        V2ForegroundGroupEventNotification
    ) -> Void
    private let metrics: (any V2GatewayTransportMetricsRecorder)?
    private let receiveWake: @Sendable (
        V2ForegroundGroupEventNotification
    ) async -> Void
    private var connection: Connection?
    private var pendingConnection: Task<Connection, any Error>?
    private var pendingActivations: [RoomID: PendingActivation] = [:]
    private var subscriptions: [RoomID: Int] = [:]
    private var subscriptionsRemovedWhileConnecting: Set<Int> = []
    /// 主题推导使用部署密钥 HMAC 与十六进制格式化。
    ///
    /// 房间在实时路径上会被大量复用，因此在硬上限内缓存这个不透明结果，
    /// 而不是为每次前台发布重复计算。
    private var subjectsByRoomID: [RoomID: String] = [:]
    /// 只有被在途连接重放捕获的订阅才需要补偿性 UNSUB。
    ///
    /// 精确记录这一集合，可把取消状态按握手开始时的实时兴趣量界定，
    /// 而不是随故障期间的变化不断膨胀。
    private var pendingReplaySubscriptionIDs: Set<Int> = []
    private var nextSubscriptionID = 1
    private var isShutDown = false
    private var reconnectTask: Task<Void, Never>?
    private let coverageLost: @Sendable () async -> Void

    public init(
        configuration: V2NATSGroupEventWakeConfiguration,
        recordRecoveryNotification: @escaping @Sendable (
            V2ForegroundGroupEventNotification
        ) -> Void = { _ in },
        metrics: (any V2GatewayTransportMetricsRecorder)? = nil,
        coverageLost: @escaping @Sendable () async -> Void = {},
        receiveWake: @escaping @Sendable (V2ForegroundGroupEventNotification) async -> Void
    ) {
        self.configuration = configuration
        subjectRoutingKey = SymmetricKey(data: configuration.routingKey)
        self.recordRecoveryNotification = recordRecoveryNotification
        self.metrics = metrics
        self.receiveWake = receiveWake
        self.coverageLost = coverageLost
    }

    deinit {
        for activation in pendingActivations.values { activation.task.cancel() }
        reconnectTask?.cancel()
        pendingConnection?.cancel()
        connection?.channel.close(promise: nil)
        if !isShutDown { try? eventLoopGroup.syncShutdownGracefully() }
    }

    /// 显式的服务生命周期边界。
    ///
    /// 生产关闭流程不能依赖 ARC 析构顺序来决定网络通道与其事件循环线程的释放时机。
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        let reconnect = reconnectTask
        reconnectTask = nil
        reconnect?.cancel()
        for activation in pendingActivations.values { activation.task.cancel() }
        pendingActivations.removeAll(keepingCapacity: false)
        let pending = pendingConnection
        pending?.cancel()
        pendingConnection = nil
        subscriptions.removeAll(keepingCapacity: false)
        let channel = connection?.channel
        connection = nil
        if let channel { try? await channel.close().get() }
        // Cancellation is cooperative. Wait until a connect already executing
        // on the NIO group has either closed itself or yielded its channel
        // before shutting down that group's threads.
        if let pending, let opened = try? await pending.value {
            try? await opened.channel.close().get()
        }
        if let reconnect { await reconnect.value }
        try? await eventLoopGroup.shutdownGracefully()
    }

    /// 订阅指定房间的事件唤醒。
    ///
    /// 重复订阅同一房间不会重复建立主题订阅。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Throws: 服务已关闭或订阅失败时抛出。
    public func activate(roomID: RoomID) async throws {
        if let pending = pendingActivations[roomID] {
            try await pending.task.value
            return
        }
        if subscriptions[roomID] != nil {
            // A live registry interest may outlast its Core NATS socket. A
            // repeated activation must heal that transport instead of treating
            // the in-memory subscription dictionary as proof of broker state.
            _ = try await connectedChannel()
            return
        }
        let subscriptionID = nextSubscriptionID
        nextSubscriptionID &+= 1
        subscriptions[roomID] = subscriptionID
        let task = Task { try await self.confirmActivation(roomID: roomID, subscriptionID: subscriptionID) }
        pendingActivations[roomID] = .init(subscriptionID: subscriptionID, task: task)
        do {
            try await task.value
            if pendingActivations[roomID]?.subscriptionID == subscriptionID {
                pendingActivations.removeValue(forKey: roomID)
            }
        } catch {
            if pendingActivations[roomID]?.subscriptionID == subscriptionID {
                pendingActivations.removeValue(forKey: roomID)
            }
            if subscriptions[roomID] == subscriptionID {
                subscriptions.removeValue(forKey: roomID)
            }
            if error is CancellationError { throw error }
            if let connection {
                await discard(connection)
            }
            throw error
        }
    }

    /// 取消指定房间的事件唤醒订阅。
    ///
    /// - Parameter roomID: 目标房间。
    public func deactivate(roomID: RoomID) async {
        guard let subscriptionID = subscriptions.removeValue(forKey: roomID) else { return }
        if subscriptions.isEmpty {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        if pendingActivations[roomID]?.subscriptionID == subscriptionID {
            pendingActivations[roomID]?.task.cancel()
            pendingActivations.removeValue(forKey: roomID)
        }
        guard let connection, connection.channel.isActive else {
            if pendingConnection != nil,
               pendingReplaySubscriptionIDs.contains(subscriptionID) {
                subscriptionsRemovedWhileConnecting.insert(subscriptionID)
            }
            return
        }
        do {
            try await writeConfirmed("UNSUB \(subscriptionID)\r\n", connection: connection)
        } catch {
            // The local registry has already removed its final viewer. A
            // reconnect will replay only still-active room interests.
            await discard(connection)
        }
    }

    /// 发布一条持久化唤醒。
    ///
    /// - Parameter wake: 待发布的唤醒内容。
    /// - Throws: 连接或写入失败时抛出。
    public func publish(_ wake: V2GroupEventWake) async throws {
        try await publish(
            .wake(wake),
            roomID: wake.roomID,
            guarantee: .brokerConfirmed
        )
    }

    /// 尽力而为地发布一条前台私聊实时事件。
    ///
    /// 与元数据提示一样，实时载荷投递是建议性的。
    /// 任何 NATS 问题都会退化为常规的持久游标拉取，而不会影响一个已被接受的发送。
    ///
    /// 发布失败不会向上抛出；调用方仍以持久化游标为准。
    ///
    /// - Parameter event: 待发布的实时事件。
    public func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        try? await publish(
            .directEvent(event),
            roomID: event.roomID,
            guarantee: .advisory
        )
    }

    /// 尽力而为地发布一批前台群实时事件。
    ///
    /// 跨进程边界保留投递器排好序的混合群组微批，避免逐条发布事件；
    /// 若在此照做，会把 NATS 确认、载荷处理以及远端 Gateway 调度都放大到批次宽度倍。
    /// 分块保持适度，使单条 Core NATS 消息即使面对房间允许的最大消息正文，
    /// 也远低于其常规载荷上限。
    ///
    /// - Parameter events: 待发布的实时事件列表。
    public func publishForegroundGroupEvents(
        _ events: [V2DirectRoomLiveEvent]
    ) async {
        guard let first = events.first,
              let membershipRevision = first.groupMembershipRevision,
              first.recipientUserIDs.isEmpty,
              first.excludedConnectionID == nil,
              events.allSatisfy({ event in
                  event.roomID == first.roomID
                      && event.groupMembershipRevision == membershipRevision
                      && event.recipientUserIDs.isEmpty
                      && event.excludedConnectionID == nil
              })
        else {
            for event in events { await publishForegroundDirectEvent(event) }
            return
        }
        let ordered = v2GroupEventsOrderedByRoomSequence(events)
        var lowerBound = 0
        while lowerBound < ordered.count {
            var upperBound = lowerBound
            var rawPayloadBytes = 0
            while upperBound < ordered.count,
                  upperBound - lowerBound < Self.maximumGroupEventsPerPublication {
                let nextPayloadBytes = ordered[upperBound].payload.count
                if nextPayloadBytes > Self.maximumGroupEventRawPayloadBytesPerPublication {
                    break
                }
                if upperBound > lowerBound,
                   rawPayloadBytes + nextPayloadBytes
                       > Self.maximumGroupEventRawPayloadBytesPerPublication {
                    break
                }
                rawPayloadBytes += nextPayloadBytes
                upperBound += 1
            }
            if upperBound == lowerBound {
                // A single live payload is too large for the conservative
                // Core NATS envelope. The durable room log remains authority.
                await publishForegroundHint(.init(
                    roomID: first.roomID,
                    highWatermark: ordered[lowerBound].roomSequence
                ))
                lowerBound += 1
                continue
            }
            let chunk = ordered[lowerBound..<upperBound]
            guard let highWatermark = chunk.last?.roomSequence else { return }
            do {
                let events = Array(chunk)
                precondition(events.last?.highWatermark == highWatermark)
                try await publish(
                    .groupEvents(events),
                    roomID: first.roomID,
                    guarantee: .advisory
                )
            } catch {
                // Foreground delivery is advisory; the durable room log and
                // later metadata wake remain the recovery authority.
                return
            }
            lowerBound = upperBound
        }
    }

    private func publish(
        _ notification: V2ForegroundGroupEventNotification,
        roomID: RoomID,
        guarantee: PublicationGuarantee
    ) async throws {
        guard !isShutDown else {
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
        let connection = try await connectedChannel()
        let channel = connection.channel
        let encodedPayload = try V2NATSGroupEventProtobufCodec.encode(notification)
        let publishSubject = subject(for: roomID)
        let payload = V2NATSAuthenticatedPayloadCodec.seal(
            encodedPayload,
            subject: publishSubject,
            routingKey: configuration.routingKey
        )
        var buffer = channel.allocator.buffer(capacity: payload.count + configuration.subjectPrefix.utf8.count + 64)
        buffer.writeString("PUB \(publishSubject) \(payload.count)\r\n")
        buffer.writeBytes(payload)
        buffer.writeString("\r\n")
        do {
            switch guarantee {
            case .brokerConfirmed:
                try await writeConfirmed(buffer, connection: connection)
            case .advisory:
                try await writeAdvisory(buffer, connection: connection)
            }
        } catch {
            await discard(connection)
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
    }

    /// 尽力而为地发布一条前台唤醒提示。
    ///
    /// 前台提示刻意允许丢失。不要把 broker 故障回传进发送方已接受的响应；
    /// 持久扇出或混合唤醒发件箱的恢复仍能保证正确性。
    ///
    /// - Parameter hint: 房间水位提示。
    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        try? await publish(
            .wake(hint),
            roomID: hint.roomID,
            guarantee: .advisory
        )
    }

    private func confirmActivation(roomID: RoomID, subscriptionID: Int) async throws {
        let connection = try await connectedChannel()
        try Task.checkCancellation()
        // A newly opened connection replays the interest inserted above. An
        // existing connection needs the incremental SUB explicitly.
        if !connection.replayedSubscriptionIDs.contains(subscriptionID) {
            try await writeConfirmed(
                "SUB \(subject(for: roomID)) \(subscriptionID)\r\n",
                connection: connection
            )
        }
        guard !Task.isCancelled,
              subscriptions[roomID] == subscriptionID
        else {
            // Deactivation may reenter while the broker is confirming SUB.
            // A second UNSUB is harmless and closes the last timing window in
            // which a cancelled interest could survive on the broker.
            try? await writeConfirmed("UNSUB \(subscriptionID)\r\n", connection: connection)
            throw CancellationError()
        }
    }

    private func connectedChannel() async throws -> Connection {
        guard !isShutDown else { throw V2NATSGroupEventWakeBrokerError.unavailable }
        if let connection, !connection.channel.isActive {
            await connectionClosed(connection.id)
        }
        guard !isShutDown else { throw V2NATSGroupEventWakeBrokerError.unavailable }
        if let connection, connection.channel.isActive { return connection }
        let pending: Task<Connection, any Error>
        if let pendingConnection {
            pending = pendingConnection
        } else {
            let group = eventLoopGroup
            let timeout = acknowledgementTimeout
            let configuration = self.configuration
            let recordRecoveryNotification = self.recordRecoveryNotification
            let metrics = self.metrics
            let receiveWake = self.receiveWake
            let wakeDeferralDelayMilliseconds = configuration
                .wakeDeferralDelayMilliseconds
            let replay = subscriptions.map { roomID, subscriptionID in
                (subject(for: roomID), subscriptionID)
            }
            pendingReplaySubscriptionIDs = Set(replay.map(\.1))
            pending = Task {
                [
                    group,
                    timeout,
                    configuration,
                    replay,
                    recordRecoveryNotification,
                    metrics,
                    receiveWake,
                    wakeDeferralDelayMilliseconds
                ] in
                try await Self.openConnection(
                    group: group,
                    configuration: configuration,
                    timeout: timeout,
                    replay: replay,
                    recordRecoveryNotification: recordRecoveryNotification,
                    metrics: metrics,
                    receiveWake: receiveWake,
                    wakeDeferralDelayMilliseconds:
                        wakeDeferralDelayMilliseconds
                )
            }
            pendingConnection = pending
        }
        var attemptedConnection: Connection?
        do {
            let opened = try await pending.value
            attemptedConnection = opened
            pendingConnection = nil
            guard !isShutDown else {
                try? await opened.channel.close().get()
                throw V2NATSGroupEventWakeBrokerError.unavailable
            }
            if let connection, connection.channel.isActive {
                if connection.channel !== opened.channel {
                    try? await opened.channel.close().get()
                }
                return connection
            }
            self.connection = opened
            let connectionID = opened.id
            opened.channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                Task { [weak self] in await self?.connectionClosed(connectionID) }
            }
            if !subscriptionsRemovedWhileConnecting.isEmpty {
                let removed = subscriptionsRemovedWhileConnecting
                let commands = removed.sorted().map { "UNSUB \($0)\r\n" }.joined()
                try await writeConfirmed(commands, connection: opened)
                subscriptionsRemovedWhileConnecting.subtract(removed)
            }
            pendingReplaySubscriptionIDs.removeAll(keepingCapacity: false)
            return opened
        } catch {
            pendingConnection = nil
            pendingReplaySubscriptionIDs.removeAll(keepingCapacity: false)
            subscriptionsRemovedWhileConnecting.removeAll(keepingCapacity: false)
            if let attemptedConnection,
               connection?.channel === attemptedConnection.channel {
                await discard(attemptedConnection)
            }
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
    }

    private var acknowledgementTimeout: TimeAmount {
        .nanoseconds(configuration.acknowledgementTimeoutNanoseconds)
    }

    private static func openConnection(
        group: MultiThreadedEventLoopGroup,
        configuration: V2NATSGroupEventWakeConfiguration,
        timeout: TimeAmount,
        replay: [(subject: String, subscriptionID: Int)],
        recordRecoveryNotification: @escaping @Sendable (
            V2ForegroundGroupEventNotification
        ) -> Void,
        metrics: (any V2GatewayTransportMetricsRecorder)?,
        receiveWake: @escaping @Sendable (
            V2ForegroundGroupEventNotification
        ) async -> Void,
        wakeDeferralDelayMilliseconds: Int
    ) async throws -> Connection {
        let notificationDispatcher = V2NATSGroupNotificationDispatcher(
            recordRecoveryNotification: recordRecoveryNotification,
            droppedPayloadObserver: {
                metrics?.foregroundGroupInboundNotificationDropped()
            },
            coveredWakeSuppressedObserver: {
                metrics?.foregroundGroupCoveredWakeSuppressed()
            },
            wakeDeferralDelay: .milliseconds(
                wakeDeferralDelayMilliseconds
            ),
            wakeDeferredObserver: {
                metrics?.foregroundGroupWakeDeferred()
            },
            deferredWakeDeliveredObserver: {
                metrics?.foregroundGroupDeferredWakeDelivered()
            },
            receiveNotification: receiveWake
        )
        let authenticatedDispatcher = V2NATSAuthenticatedPayloadDispatcher(
            routingKey: configuration.routingKey,
            invalidPayload: {
                metrics?.foregroundGroupInboundNotificationDropped()
            },
            downstream: notificationDispatcher
        )
        let handler = V2NATSConfirmedInboundHandler(
            maximumPayloadBytes: Self.maximumInboundNotificationPayloadBytes,
            payloadDispatcher: authenticatedDispatcher
        )
        let sslContext: NIOSSLContext?
        if configuration.usesTLS {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.minimumTLSVersion = .tlsv13
            if let path = configuration.tlsCAPath {
                tls.trustRoots = .certificates(
                    try NIOSSLCertificate.fromPEMFile(path)
                )
            }
            sslContext = try NIOSSLContext(configuration: tls)
        } else {
            sslContext = nil
        }
        let serverName = configuration.tlsServerName ?? configuration.url.host!
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: timeout)
            .channelInitializer { channel in
                do {
                    if let sslContext {
                        let tlsHandler = try NIOSSLClientHandler(
                                context: sslContext,
                                serverHostname: serverName
                            )
                        try channel.pipeline.syncOperations.addHandler(tlsHandler)
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(
                host: configuration.url.host!,
                port: configuration.url.port ?? 4222
            )
            .get()
        do {
            guard !Task.isCancelled else { throw CancellationError() }
            guard let acknowledgement = handler.beginAcknowledgement(eventLoop: channel.eventLoop) else {
                throw V2NATSGroupEventWakeBrokerError.unavailable
            }
            let watchdog = channel.eventLoop.scheduleTask(in: timeout) {
                if handler.timeout(acknowledgement) { channel.close(promise: nil) }
            }
            defer { watchdog.cancel() }
            let connect = String(
                decoding: try JSONEncoder().encode(Connect(token: configuration.token)),
                as: UTF8.self
            )
            var command = channel.allocator.buffer(capacity: connect.utf8.count + replay.count * 96 + 20)
            command.writeString("CONNECT \(connect)\r\n")
            for item in replay {
                command.writeString("SUB \(item.subject) \(item.subscriptionID)\r\n")
            }
            command.writeString("PING\r\n")
            try await channel.writeAndFlush(command)
            try await acknowledgement.awaitBrokerConfirmation()
            return Connection(
                id: UUID(),
                channel: channel,
                handler: handler,
                replayedSubscriptionIDs: Set(replay.map(\.subscriptionID))
            )
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    /// 生产 NATS 处理器与聚焦契约测试共用的解码器。
    ///
    /// 非法或只获得部分授权的实时载荷会安全失败并降级为元数据唤醒；
    /// 只有畸形的房间信封才会被整体丢弃。
    ///
    /// - Parameter payload: 待解码的通知载荷。
    /// - Returns: 解码成功的前台群事件通知；无法安全解码时为 `nil`。
    static func decodeNotificationPayload(
        _ payload: Data
    ) -> V2ForegroundGroupEventNotification? {
        V2NATSGroupEventProtobufCodec.decode(payload)
    }

    private func connectionClosed(_ closedID: UUID) async {
        guard connection?.id == closedID else { return }
        connection = nil
        await coverageLost()
        scheduleReconnectIfNeeded()
    }

    /// Core NATS 只在套接字上保存订阅状态。
    ///
    /// 只要该 Gateway 仍有本地观看者，就维持唯一一条有界退避的重连循环；
    /// `connectedChannel` 会重放当前完整主题集合。
    private func scheduleReconnectIfNeeded() {
        guard !isShutDown, !subscriptions.isEmpty, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnectWhileInterested()
        }
    }

    private func reconnectWhileInterested() async {
        var delayMilliseconds = 50
        defer {
            reconnectTask = nil
            if !isShutDown,
               !subscriptions.isEmpty,
               connection?.channel.isActive != true {
                scheduleReconnectIfNeeded()
            }
        }
        while !Task.isCancelled, !isShutDown, !subscriptions.isEmpty {
            do {
                _ = try await connectedChannel()
                return
            } catch {
                guard !Task.isCancelled else { return }
                try? await v2Sleep(for: .milliseconds(delayMilliseconds))
                delayMilliseconds = min(delayMilliseconds * 2, 5_000)
            }
        }
    }

    private func subject(for roomID: RoomID) -> String {
        if let cached = subjectsByRoomID[roomID] { return cached }
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(roomID.rawValue.utf8),
            using: subjectRoutingKey
        )
        let routingKey = digest.map { String(format: "%02x", $0) }.joined()
        let subject = "\(configuration.subjectPrefix).\(routingKey)"
        if subjectsByRoomID.count >= Self.maximumCachedSubjects,
           let evictedRoom = subjectsByRoomID.keys.first {
            subjectsByRoomID.removeValue(forKey: evictedRoom)
        }
        subjectsByRoomID[roomID] = subject
        return subject
    }

    /// 把建议性写入的热路径从 continuation 中剥离：对于它确实收到的字节，
    /// 核心 NATS 仍会保持套接字顺序。
    ///
    /// 前台实时载荷显式允许丢失：在本次调用之前，其房间日志行与持久唤醒就已存在。
    /// 等待 NIO 写入完成仍能检测到失活或失败的通道，
    /// 而省去每次发布的 PING/PONG 则消除了协议流量以及一次挂起。
    private func writeAdvisory(
        _ command: ByteBuffer,
        connection: Connection
    ) async throws {
        let channel = connection.channel
        guard channel.isActive else {
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
        try await channel.writeAndFlush(command)
    }

    private func writeConfirmed(_ command: String, connection: Connection) async throws {
        var buffer = connection.channel.allocator.buffer(capacity: command.utf8.count + 6)
        buffer.writeString(command)
        try await writeConfirmed(buffer, connection: connection)
    }

    private func writeConfirmed(_ command: ByteBuffer, connection: Connection) async throws {
        let channel = connection.channel
        guard let acknowledgement = connection.handler.beginAcknowledgement(eventLoop: channel.eventLoop) else {
            channel.close(promise: nil)
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
        let watchdog = channel.eventLoop.scheduleTask(in: acknowledgementTimeout) {
            if connection.handler.timeout(acknowledgement) {
                channel.close(promise: nil)
            }
        }
        var command = command
        command.writeString("PING\r\n")
        do {
            // Enqueue the command synchronously immediately after its
            // acknowledgement. Actor reentrancy may overlap callers, but NIO
            // write ordering and the handler's FIFO keep confirmations paired.
            try await channel.writeAndFlush(command)
            try await acknowledgement.awaitBrokerConfirmation()
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            if connection.handler.timeout(acknowledgement) {
                channel.close(promise: nil)
            }
            throw error
        }
    }

    private func discard(_ discarded: Connection) async {
        if connection?.channel === discarded.channel {
            await connectionClosed(discarded.id)
        }
        try? await discarded.channel.close().get()
    }
}

/// 已确认的入站处理器。
///
/// 其解析器状态会针对所属事件循环做运行时校验；
/// 所有应用状态都经由所提供的 Sendable 回调跨入 actor。
final class V2NATSConfirmedInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let payloadDispatcher: any V2NATSPayloadSubmitting
    private let parser: Mutex<V2NATSInboundFrameParser>
    private static let maximumPendingAcknowledgements = 1_024
    private struct AcknowledgementQueue {
        var values: [V2NATSGroupEventWakeAcknowledgement] = []
        var head = 0

        var count: Int { values.count - head }

        mutating func append(_ value: V2NATSGroupEventWakeAcknowledgement) -> Bool {
            guard count < V2NATSConfirmedInboundHandler.maximumPendingAcknowledgements else {
                return false
            }
            values.append(value)
            return true
        }

        mutating func popFirst() -> V2NATSGroupEventWakeAcknowledgement? {
            guard head < values.count else { return nil }
            let value = values[head]
            head += 1
            if head == values.count {
                values.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= values.count {
                values.removeFirst(head)
                head = 0
            }
            return value
        }

        func contains(_ value: V2NATSGroupEventWakeAcknowledgement) -> Bool {
            values[head...].contains(where: { $0 === value })
        }

        mutating func removeAll() -> [V2NATSGroupEventWakeAcknowledgement] {
            let pending = Array(values[head...])
            values.removeAll(keepingCapacity: true)
            head = 0
            return pending
        }
    }
    private let acknowledgements = Mutex(AcknowledgementQueue())

    init(
        invalidMessagePolicy: V2NATSInboundFrameParser.InvalidMessagePolicy = .closeChannel,
        maximumPayloadBytes: Int = V2NATSInboundFrameParser.defaultMaximumPayloadBytes,
        onPayload: @escaping @Sendable (String, Data) async -> Void
    ) {
        payloadDispatcher = V2NATSPayloadDispatcher(onPayload: onPayload)
        parser = Mutex(.init(
            invalidMessagePolicy: invalidMessagePolicy,
            maximumPayloadBytes: maximumPayloadBytes
        ))
    }

    init(
        invalidMessagePolicy: V2NATSInboundFrameParser.InvalidMessagePolicy = .closeChannel,
        maximumPayloadBytes: Int = V2NATSInboundFrameParser.defaultMaximumPayloadBytes,
        payloadDispatcher: any V2NATSPayloadSubmitting
    ) {
        self.payloadDispatcher = payloadDispatcher
        parser = Mutex(.init(
            invalidMessagePolicy: invalidMessagePolicy,
            maximumPayloadBytes: maximumPayloadBytes
        ))
    }

    func beginAcknowledgement(eventLoop: any EventLoop) -> V2NATSGroupEventWakeAcknowledgement? {
        let acknowledgement = V2NATSGroupEventWakeAcknowledgement(eventLoop: eventLoop)
        return acknowledgements.withLock {
            $0.append(acknowledgement) ? acknowledgement : nil
        }
    }

    func timeout(_ acknowledgement: V2NATSGroupEventWakeAcknowledgement) -> Bool {
        let timedOut = acknowledgements.withLock { pending -> [V2NATSGroupEventWakeAcknowledgement] in
            guard pending.contains(acknowledgement) else { return [] }
            return pending.removeAll()
        }
        for acknowledgement in timedOut {
            acknowledgement.fail(V2NATSGroupEventWakeBrokerError.unavailable)
        }
        return !timedOut.isEmpty
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readData(length: buffer.readableBytes) else { return }
        for output in parser.withLock({ $0.consume(bytes) }) {
            switch output {
            case .payload(let subject, let payload):
                payloadDispatcher.submit(subject: subject, payload: payload)
            case .ping:
                var pong = context.channel.allocator.buffer(capacity: 6)
                pong.writeString("PONG\r\n")
                context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
            case .pong:
                let acknowledgement = acknowledgements.withLock { $0.popFirst() }
                acknowledgement?.succeed()
            case .brokerError, .closeChannel:
                failAll()
                context.close(promise: nil)
                return
            }
        }
    }

    func channelInactive(context _: ChannelHandlerContext) {
        failAll()
    }

    func errorCaught(context: ChannelHandlerContext, error _: any Error) {
        failAll()
        context.close(promise: nil)
    }

    private func failAll() {
        let pending = acknowledgements.withLock { $0.removeAll() }
        for acknowledgement in pending {
            acknowledgement.fail(V2NATSGroupEventWakeBrokerError.unavailable)
        }
    }
}

final class V2NATSGroupEventWakeAcknowledgement: Sendable {
    private let confirmation: EventLoopPromise<Void>
    private let didResolve = Mutex(false)

    init(eventLoop: any EventLoop) {
        confirmation = eventLoop.makePromise(of: Void.self)
    }

    func awaitBrokerConfirmation() async throws {
        try await confirmation.futureResult.get()
    }

    func succeed() {
        guard markResolved() else { return }
        confirmation.succeed(())
    }

    func fail(_ error: any Error) {
        guard markResolved() else { return }
        confirmation.fail(error)
    }

    private func markResolved() -> Bool {
        didResolve.withLock { resolved in
            guard !resolved else { return false }
            resolved = true
            return true
        }
    }
}
