import Foundation
import IMV2Core

/// 房间订阅通道。
public enum V2RoomSubscriptionChannel: Hashable, Sendable {
    /// 房间事件。
    case roomEvents
    /// 正在输入提示。
    case typing
    /// 在线状态。
    case presence
}

/// 房间订阅快照。
///
/// 它是完整替换值，因此消费者只需保留一个元素的缓冲：缓慢的场景不会漏掉连接重置，
/// 从而不会继续持有过期的正在输入或在线状态租约。
public struct V2RoomSubscriptionSnapshot: Equatable, Sendable {
    /// 订阅状态。
    public enum State: Equatable, Sendable { case offline, reconciling, subscribed, revoked }
    /// 目标房间。
    public let roomID: RoomID
    /// 当前连接标识。
    public let connectionID: UUID?
    /// 当前订阅状态。
    public let state: State
    /// 恢复流程标识。
    public let recoveryID: UUID?
    /// 本地订阅/权限代次；即使中间 revoked 快照被合并，也不能复用旧作者 nonce。
    public let authorPresentationGeneration: UUID?
    /// 房间事件可用性提示。
    public let wake: V2GroupEventAvailabilityHint?
    /// 固定安装基线；后续可用性提示不会抬高这个值。
    public let baselineHead: UInt64?
    /// 已原子提交的本设备游标。订阅确认不代表已补齐基线。
    public let appliedThrough: UInt64?
    public var isCaughtUp: Bool {
        guard state == .subscribed, let baselineHead, let appliedThrough else { return false }
        return appliedThrough >= baselineHead
    }
    /// 当前在线状态。
    public let presence: V2PresenceState?
    /// 当前正在输入的用户状态列表。
    public let typing: [V2TypingState]
}

/// 房间订阅租约。
public struct V2RoomSubscriptionLease: Sendable {
    /// 租约标识，释放时需原样传回。
    public let id: UUID
    /// 目标房间。
    public let roomID: RoomID
    /// 该租约对应的快照流。
    public let updates: AsyncStream<V2RoomSubscriptionSnapshot>
}

/// 房间订阅错误。
public enum V2RoomSubscriptionError: Error, Equatable, Sendable {
    /// 未指定任何订阅通道。
    case emptyChannels
    /// 订阅容量已满。
    case capacityExceeded
}

/// 房间订阅协调器。
///
/// 单个账号或运行时持有线路订阅与提示消费者；场景只持有意图令牌，
/// 因此关闭一个场景不会取消其他场景的订阅。领域传输保留其共享请求标识分配器，
/// 任务局部作用域则把协调请求绑定到当前已认证的线路代次。
public actor V2RoomSubscriptionCoordinator {
    private struct Consumer {
        let channels: Set<V2RoomSubscriptionChannel>
        let observesAuthorChanges: Bool
        let continuation: AsyncStream<V2RoomSubscriptionSnapshot>.Continuation
        var lastSnapshot: V2RoomSubscriptionSnapshot?
    }
    private struct Room {
        var consumers: [UUID: Consumer] = [:]
        var confirmed: Set<V2RoomSubscriptionChannel> = []
        var authorized = true
        var serverRevoked = false
        var recoveryID: UUID?
        var authorPresentationGeneration = UUID()
        var baselineHead: UInt64?
        var appliedThrough: UInt64?
        var wake: V2GroupEventAvailabilityHint?
        var presence: V2PresenceState?
        var typing: [UserID: V2TypingState] = [:]
        var desired: Set<V2RoomSubscriptionChannel> {
            authorized && !serverRevoked ? consumers.values.reduce(into: []) { $0.formUnion($1.channels) } : []
        }
    }
    private struct Run {
        let id: UUID
        let connectionID: UUID
        let wake: AsyncStream<Void>.Continuation
    }
    private let subscriptions: any V2ClientGroupEventSubscriptionTransport
    private let activity: any V2ClientLiveActivityTransport
    private let groupEvents: any V2GroupEventAvailabilityHintSource
    private let activityEvents: any V2LiveActivityEventSource
    private let isAuthorized: @Sendable (RoomID) async throws -> Bool
    private let didUnsubscribeRoom: @Sendable (RoomID) async -> Void
    private let receiveAccountEvent: @Sendable (V2GroupEventAvailabilityHint) async throws -> Bool
    private let recoverAccountEvent: @Sendable (V2GroupEventAvailabilityHint) async throws -> Void
    private let recoveryGrace: Duration
    private struct PendingAccountEvent {
        var hint: V2GroupEventAvailabilityHint
        let deadline: ContinuousClock.Instant
    }
    private var pendingAccountEvents: [RoomID: PendingAccountEvent] = [:]
    private var pendingAccountBytes = 0
    private var recoveryWake: AsyncStream<Void>.Continuation?
    private let roomCursor: @Sendable (RoomID) async throws -> UInt64
    private let retryDelay: Duration
    private let refreshInterval: Duration
    private let maximumRooms: Int
    private let maximumConsumers: Int
    private var rooms: [RoomID: Room] = [:]
    private var runState: Run?
    private var flight: (id: UUID, task: Task<Void, Error>)?

    /// 组合活动服务、订阅实现与容量上限。
    ///
    /// - Parameters:
    ///   - subscriptions: 房间事件订阅实现。
    ///   - activity: 正在输入与在线状态服务。
    ///   - groupEvents: 房间事件可用性提示来源。
    ///   - activityEvents: 实时活动事件来源。
    ///   - isAuthorized: 判断房间当前是否授权的闭包。
    ///   - roomCursor: 读取房间当前持久化游标的闭包。
    ///   - didUnsubscribeRoom: 取消订阅后的回调，默认忽略。
    ///   - receiveAccountEvent: 应用连续正文；只有持久游标已追平 H 时返回 true。
    ///   - recoverAccountEvent: 缺口超过等待期限后保留可靠恢复任务。
    ///   - recoveryGrace: 首次缺口的固定等待上限，默认 100 ms，须大于零。
    ///   - retryDelay: 重试退避间隔，需大于零。
    ///   - refreshInterval: 周期刷新间隔，需大于零。
    ///   - maximumRooms: 允许同时订阅的房间上限，需大于零，默认 128。
    ///   - maximumConsumers: 允许的消费者上限，需大于零，默认 512。
    ///
    /// 间隔或上限非法时直接失败，避免出现无界订阅或零间隔空转。
    public init(
        subscriptions: any V2ClientGroupEventSubscriptionTransport,
        activity: any V2ClientLiveActivityTransport,
        groupEvents: any V2GroupEventAvailabilityHintSource,
        activityEvents: any V2LiveActivityEventSource,
        isAuthorized: @escaping @Sendable (RoomID) async throws -> Bool,
        roomCursor: @escaping @Sendable (RoomID) async throws -> UInt64,
        didUnsubscribeRoom: @escaping @Sendable (RoomID) async -> Void = { _ in },
        receiveAccountEvent: @escaping @Sendable (V2GroupEventAvailabilityHint) async throws -> Bool = { _ in true },
        recoverAccountEvent: @escaping @Sendable (V2GroupEventAvailabilityHint) async throws -> Void = { _ in },
        recoveryGrace: Duration = .milliseconds(100),
        retryDelay: Duration = .seconds(1),
        refreshInterval: Duration = .seconds(30),
        maximumRooms: Int = 128,
        maximumConsumers: Int = 512
    ) {
        precondition(retryDelay > .zero && refreshInterval > .zero && recoveryGrace > .zero && maximumRooms > 0 && maximumConsumers > 0)
        self.subscriptions = subscriptions
        self.activity = activity
        self.groupEvents = groupEvents
        self.activityEvents = activityEvents
        self.isAuthorized = isAuthorized
        self.roomCursor = roomCursor
        self.didUnsubscribeRoom = didUnsubscribeRoom
        self.receiveAccountEvent = receiveAccountEvent
        self.recoverAccountEvent = recoverAccountEvent
        self.recoveryGrace = recoveryGrace
        self.retryDelay = retryDelay
        self.refreshInterval = refreshInterval
        self.maximumRooms = maximumRooms
        self.maximumConsumers = maximumConsumers
    }

    /// 获取房间订阅租约。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - channels: 需要的订阅通道集合，需非空。
    /// - Returns: 订阅租约。
    /// - Throws: 通道为空时抛出 ``V2RoomSubscriptionError/emptyChannels``；
    ///   超出房间容量时抛出 ``V2RoomSubscriptionError/capacityExceeded``。
    public func acquire(roomID: RoomID, channels: Set<V2RoomSubscriptionChannel>) throws -> V2RoomSubscriptionLease {
        try acquire(roomID: roomID, channels: channels, observesAuthorChanges: false)
    }

    func acquireAuthorPresentationRoom(roomID: RoomID) throws -> V2RoomSubscriptionLease {
        try acquire(roomID: roomID, channels: [.roomEvents], observesAuthorChanges: true)
    }

    private func acquire(roomID: RoomID, channels: Set<V2RoomSubscriptionChannel>, observesAuthorChanges: Bool) throws -> V2RoomSubscriptionLease {
        guard !channels.isEmpty else { throw V2RoomSubscriptionError.emptyChannels }
        guard rooms[roomID] != nil || rooms.count < maximumRooms,
              rooms.values.reduce(0, { $0 + $1.consumers.count }) < maximumConsumers
        else { throw V2RoomSubscriptionError.capacityExceeded }
        let id = UUID()
        let stream = AsyncStream<V2RoomSubscriptionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.release(roomID: roomID, consumerID: id) } }
        rooms[roomID, default: Room()].consumers[id] = .init(channels: channels, observesAuthorChanges: observesAuthorChanges, continuation: stream.continuation)
        publish(roomID)
        requestReconciliation()
        return .init(id: id, roomID: roomID, updates: stream.stream)
    }

    /// 释放指定消费者在房间上的订阅。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - consumerID: 消费者标识。
    public func release(roomID: RoomID, consumerID: UUID) {
        guard let consumer = rooms[roomID]?.consumers.removeValue(forKey: consumerID) else { return }
        consumer.continuation.finish()
        if runState == nil, rooms[roomID]?.consumers.isEmpty == true { rooms[roomID] = nil }
        requestReconciliation()
    }

    /// 请求一次协调。
    ///
    /// 个人同步在成员关系变化完成后会调用它触发协调。
    public func requestReconciliation() { runState?.wake.yield(()) }

    /// 通知授权状态发生变化。
    ///
    /// 会清除各房间的服务端吊销标记并请求一次协调，使订阅按新的授权重新建立。
    public func authorityDidChange() {
        for roomID in rooms.keys {
            if rooms[roomID]?.serverRevoked == true { rooms[roomID]?.confirmed.remove(.roomEvents) }
            rooms[roomID]?.serverRevoked = false
            rooms[roomID]?.authorPresentationGeneration = UUID()
            publish(roomID, authorOnly: true)
        }
        requestReconciliation()
    }

    /// Optional author work uses the same live room intent and connection as
    /// ordinary synchronization, including membership revocation and reconnect.
    struct AuthorPresentationScope: Equatable, Sendable {
        let connectionID: UUID
        let generation: UUID
    }
    func authorPresentationScope(roomID: RoomID, consumerID: UUID) -> AuthorPresentationScope? {
        guard rooms[roomID]?.consumers[consumerID]?.channels.contains(.roomEvents) == true,
              rooms[roomID]?.desired.contains(.roomEvents) == true,
              rooms[roomID]?.confirmed.contains(.roomEvents) == true,
              let generation = rooms[roomID]?.authorPresentationGeneration,
              let connectionID = runState?.connectionID else { return nil }
        return .init(connectionID: connectionID, generation: generation)
    }

    func authorSubscriptionWasRejected(roomID: RoomID, consumerID: UUID, scope: AuthorPresentationScope) {
        guard authorPresentationScope(roomID: roomID, consumerID: consumerID) == scope else { return }
        rooms[roomID]?.serverRevoked = true
        rooms[roomID]?.authorPresentationGeneration = UUID()
        rooms[roomID]?.wake = nil; rooms[roomID]?.presence = nil; rooms[roomID]?.typing = [:]
        publish(roomID)
        requestReconciliation()
    }

    /// 设置正在输入状态。
    ///
    /// 真正的草稿变更或续期属于观察到它的场景与连接；重连绝不能重放过期的正在输入租约。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - consumerID: 消费者标识。
    ///   - connectionID: 观察到该状态的连接。
    ///   - isTyping: 是否正在输入。
    /// - Throws: 连接或订阅状态不匹配时抛出 `CancellationError`；其余失败来自活动服务。
    public func setTyping(roomID: RoomID, consumerID: UUID, connectionID: UUID, isTyping: Bool) async throws {
        try Task.checkCancellation()
        guard let run = runState, run.connectionID == connectionID,
              rooms[roomID]?.consumers[consumerID]?.channels.contains(.typing) == true,
              rooms[roomID]?.desired.contains(.typing) == true,
              rooms[roomID]?.confirmed.contains(.typing) == true
        else { throw CancellationError() }
        try await V2ConnectionRequestScope.$connectionID.withValue(connectionID) {
            try await activity.setTyping(roomID: roomID, isTyping: isTyping)
        }
        try checkRun(run.id)
    }

    /// 在指定连接上持续运行协调循环。
    ///
    /// 新的运行会先取消并等待上一轮完全收敛，使同一时刻只有一个在途协调任务。
    ///
    /// - Parameter connectionID: 本次运行绑定的连接标识。
    /// - Throws: 任务取消时抛出 `CancellationError`；其余错误来自订阅实现。
    public func run(connectionID: UUID) async throws {
        while let previous = flight {
            previous.task.cancel()
            _ = await previous.task.result
            try Task.checkCancellation()
            if flight?.id == previous.id { flight = nil }
        }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task {
            try await V2ConnectionRequestScope.$connectionID.withValue(connectionID) {
                try await self.runGeneration(id: id, connectionID: connectionID)
            }
        }
        flight = (id, task)
        defer { if flight?.id == id { flight = nil } }
        try await withTaskCancellationHandler(operation: {
            let result = await task.result
            try Task.checkCancellation()
            try result.get()
        }, onCancel: { task.cancel() })
    }

    private func runGeneration(id: UUID, connectionID: UUID) async throws {
        let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        runState = .init(id: id, connectionID: connectionID, wake: wake.continuation)
        resetConnectionFacts()
        let recovery = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        recoveryWake = recovery.continuation
        wake.continuation.yield(())
        defer {
            recovery.continuation.finish()
            recoveryWake = nil
            pendingAccountEvents.removeAll(); pendingAccountBytes = 0
            wake.continuation.finish()
            if runState?.id == id { runState = nil; resetConnectionFacts() }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.reconcileLoop(wakes: wake.stream, id: id) }
            group.addTask { try await self.recoverAccountLoop(wakes: recovery.stream, id: id) }
            group.addTask {
                while !Task.isCancelled {
                    let hint = try await self.groupEvents.nextGroupEventAvailabilityHint()
                    try await self.accept(hint, id: id)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    let event = try await self.activityEvents.nextLiveActivityEvent()
                    try await self.accept(event, id: id)
                }
            }
            group.addTask { [refreshInterval] in
                while !Task.isCancelled {
                    try await Task.sleep(for: refreshInterval)
                    try await self.refresh(id: id)
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func checkRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard runState?.id == id else { throw CancellationError() }
    }

    private func resetConnectionFacts() {
        for roomID in Array(rooms.keys) {
            rooms[roomID]?.confirmed = []
            rooms[roomID]?.authorized = true
            rooms[roomID]?.serverRevoked = false
            rooms[roomID]?.recoveryID = nil
            rooms[roomID]?.authorPresentationGeneration = UUID()
            rooms[roomID]?.wake = nil
            rooms[roomID]?.baselineHead = nil
            rooms[roomID]?.appliedThrough = nil
            rooms[roomID]?.presence = nil
            rooms[roomID]?.typing = [:]
            if rooms[roomID]?.consumers.isEmpty == true { rooms[roomID] = nil }
            else { publish(roomID) }
        }
    }

    private func reconcileLoop(wakes: AsyncStream<Void>, id: UUID) async throws {
        for await _ in wakes {
            try checkRun(id)
            let failed = try await reconcile(id: id)
            if failed {
                // One bounded retry clock for the coordinator, never one per
                // room. Desired tokens survive a failed or lost subscribe ACK.
                try await Task.sleep(for: retryDelay)
                try checkRun(id)
                requestReconciliation()
            }
        }
    }

    private func reconcile(id: UUID) async throws -> Bool {
        var failed = false
        for roomID in rooms.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                let authorized = try await isAuthorized(roomID)
                try checkRun(id)
                if rooms[roomID]?.authorized != authorized {
                    rooms[roomID]?.authorized = authorized
                    rooms[roomID]?.authorPresentationGeneration = UUID()
                    publish(roomID, authorOnly: true)
                }
                for channel in [V2RoomSubscriptionChannel.presence, .typing, .roomEvents] {
                    try checkRun(id)
                    guard let room = rooms[roomID] else { break }
                    let desired = room.desired.contains(channel)
                    let confirmed = room.confirmed.contains(channel)
                    guard desired != confirmed else { continue }
                    if desired { try await subscribe(roomID: roomID, channel: channel, id: id) }
                    else { try await unsubscribe(roomID: roomID, channel: channel, id: id) }
                }
                if rooms[roomID]?.confirmed.contains(.roomEvents) == true {
                    let applied = try await roomCursor(roomID)
                    try checkRun(id)
                    rooms[roomID]?.appliedThrough = applied
                }
                publish(roomID)
                if rooms[roomID]?.consumers.isEmpty == true, rooms[roomID]?.confirmed.isEmpty == true {
                    rooms[roomID] = nil
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as V2RealtimeTransportError {
                if case .server(let code, _, _, _) = error, code == "FORBIDDEN" {
                    rooms[roomID]?.serverRevoked = true
                    rooms[roomID]?.authorPresentationGeneration = UUID()
                    rooms[roomID]?.presence = nil
                    rooms[roomID]?.typing = [:]
                    rooms[roomID]?.wake = nil
                    publish(roomID)
                    requestReconciliation()
                    // A later personal-sync wake re-evaluates local authority.
                } else { failed = true }
            } catch { failed = true }
        }
        return failed
    }

    private func subscribe(roomID: RoomID, channel: V2RoomSubscriptionChannel, id: UUID) async throws {
        switch channel {
        case .roomEvents:
            let cursor = try await roomCursor(roomID)
            try checkRun(id)
            let subscription = try await subscriptions.subscribeToGroupEvents(roomID: roomID, afterRoomSequence: cursor)
            try checkRun(id)
            guard subscription.roomID == roomID else { throw V2RealtimeTransportError.unexpectedResponse }
            let hint = V2GroupEventAvailabilityHint(roomID: roomID, highWatermark: subscription.highWatermark)
            let wake = rooms[roomID]?.wake.map { $0.coalescing(with: hint) } ?? hint
            rooms[roomID]?.wake = wake
            rooms[roomID]?.baselineHead = subscription.highWatermark
            rooms[roomID]?.appliedThrough = cursor
            rooms[roomID]?.recoveryID = UUID()
            rooms[roomID]?.authorPresentationGeneration = UUID()
        case .typing:
            try await activity.subscribeTyping(roomID: roomID)
        case .presence:
            let presence = try await activity.subscribePresence(roomID: roomID)
            try checkRun(id)
            guard presence.roomID == roomID else { throw V2RealtimeTransportError.unexpectedResponse }
            rooms[roomID]?.presence = presence
        }
        try checkRun(id)
        rooms[roomID]?.confirmed.insert(channel)
        publish(roomID)
    }

    private func unsubscribe(roomID: RoomID, channel: V2RoomSubscriptionChannel, id: UUID) async throws {
        do {
        switch channel {
        case .roomEvents: try await subscriptions.unsubscribeFromGroupEvents(roomID: roomID)
        case .typing:
            try await activity.setTyping(roomID: roomID, isTyping: false)
            try checkRun(id)
            try await activity.unsubscribeTyping(roomID: roomID)
        case .presence: try await activity.unsubscribePresence(roomID: roomID)
        }
        } catch let error as V2RealtimeTransportError {
            guard case .server(let code, _, _, _) = error, code == "FORBIDDEN" else { throw error }
            // A revoked subscription is already unusable; do not spin trying
            // to authorize its cleanup. Server delivery still enforces access.
        }
        try checkRun(id)
        rooms[roomID]?.confirmed.remove(channel)
        switch channel {
        case .roomEvents:
            rooms[roomID]?.baselineHead = nil
            rooms[roomID]?.appliedThrough = nil
            rooms[roomID]?.wake = nil
            await didUnsubscribeRoom(roomID)
            try checkRun(id)
        case .typing: rooms[roomID]?.typing = [:]
        case .presence: rooms[roomID]?.presence = nil
        }
    }

    private func accept(_ hint: V2GroupEventAvailabilityHint, id: UUID) async throws {
        try checkRun(id)
        // Retain a bounded sparse batch before applying. A later body can close
        // the gap even when it has the same (or a lower) advertised H.
        let previousAccount = pendingAccountEvents[hint.roomID]
        let merged = previousAccount.map { $0.hint.coalescing(with: hint) } ?? hint
        let bytes = pendingAccountBytes - (previousAccount?.hint.estimatedLiveBytes ?? 0) + merged.estimatedLiveBytes
        guard (previousAccount != nil || pendingAccountEvents.count < 4096), bytes <= 16 * 1024 * 1024 else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        pendingAccountEvents[hint.roomID] = .init(hint: merged,
            deadline: previousAccount?.deadline ?? ContinuousClock.now.advanced(by: recoveryGrace))
        pendingAccountBytes = bytes
        let caughtUp = try await receiveAccountEvent(merged)
        try checkRun(id)
        if caughtUp, pendingAccountEvents[hint.roomID]?.hint == merged {
            removePendingAccountEvent(hint.roomID)
        }
        if pendingAccountEvents[hint.roomID] != nil { recoveryWake?.yield(()) }
        guard rooms[hint.roomID]?.desired.contains(.roomEvents) == true else { return }
        let previous = rooms[hint.roomID]?.wake
        let wake = previous.map { $0.coalescing(with: hint) } ?? hint
        rooms[hint.roomID]?.wake = wake
        publish(hint.roomID)
    }

    private func removePendingAccountEvent(_ roomID: RoomID) {
        if let old = pendingAccountEvents.removeValue(forKey: roomID) {
            pendingAccountBytes -= old.hint.estimatedLiveBytes
        }
    }

    /// One structured worker per connection; new hints never extend a room's
    /// first-gap deadline. Cancellation/error drains with the connection group.
    private func recoverAccountLoop(wakes: AsyncStream<Void>, id: UUID) async throws {
        for await _ in wakes {
            try checkRun(id)
            while let deadline = pendingAccountEvents.values.lazy.map(\.deadline).min() {
                try await ContinuousClock().sleep(until: deadline)
                try checkRun(id)
                let now = ContinuousClock.now
                let due = pendingAccountEvents.filter { $0.value.deadline <= now }
                for (roomID, pending) in due {
                    try checkRun(id)
                    // Keep a newer arrival independent of this expired attempt.
                    guard let current = pendingAccountEvents[roomID], current.deadline == pending.deadline else { continue }
                    removePendingAccountEvent(roomID)
                    let caughtUp = try await receiveAccountEvent(current.hint)
                    try checkRun(id)
                    if !caughtUp {
                        try await recoverAccountEvent(current.hint)
                        try checkRun(id)
                    }
                }
            }
        }
    }

    private func accept(_ event: V2LiveActivityEvent, id: UUID) throws {
        try checkRun(id)
        let roomID: RoomID
        switch event {
        case .presence(let value):
            roomID = value.roomID
            guard rooms[roomID]?.desired.contains(.presence) == true else { return }
            rooms[roomID]?.presence = value
        case .typing(let value):
            roomID = value.roomID
            guard rooms[roomID]?.desired.contains(.typing) == true else { return }
            if !value.isTyping || value.expiresAt <= Date() { rooms[roomID]?.typing[value.userID] = nil }
            else if rooms[roomID]?.typing[value.userID] != nil || (rooms[roomID]?.typing.count ?? 0) < 64 {
                rooms[roomID]?.typing[value.userID] = value
            }
        }
        publish(roomID)
    }

    private func refresh(id: UUID) throws {
        try checkRun(id)
        for roomID in rooms.keys {
            // Activity expiry refresh must not schedule message history pulls.
            // Message recovery is driven by received heads and the account runner.
            publish(roomID)
        }
        requestReconciliation()
    }

    private func publish(_ roomID: RoomID, authorOnly: Bool = false) {
        let now = Date()
        let currentTyping = rooms[roomID]?.typing.filter { $0.value.expiresAt > now } ?? [:]
        rooms[roomID]?.typing = currentTyping
        guard let room = rooms[roomID] else { return }
        for (consumerID, consumer) in room.consumers {
            if authorOnly && !consumer.observesAuthorChanges { continue }
            let state: V2RoomSubscriptionSnapshot.State = runState == nil ? .offline :
                !room.authorized || room.serverRevoked ? .revoked : consumer.channels.isSubset(of: room.confirmed) ? .subscribed : .reconciling
            let snapshot = V2RoomSubscriptionSnapshot(
                roomID: roomID, connectionID: runState?.connectionID, state: state,
                recoveryID: consumer.channels.contains(.roomEvents) ? room.recoveryID : nil,
                authorPresentationGeneration: consumer.observesAuthorChanges ? room.authorPresentationGeneration : nil,
                wake: consumer.channels.contains(.roomEvents) ? room.wake : nil,
                baselineHead: consumer.channels.contains(.roomEvents) ? room.baselineHead : nil,
                appliedThrough: consumer.channels.contains(.roomEvents) ? room.appliedThrough : nil,
                presence: consumer.channels.contains(.presence) && (room.presence?.expiresAt ?? .distantPast) > now ? room.presence : nil,
                typing: consumer.channels.contains(.typing) ? room.typing.values.filter { $0.expiresAt > now }.sorted { $0.userID.rawValue < $1.userID.rawValue } : []
            )
            if snapshot != consumer.lastSnapshot {
                rooms[roomID]?.consumers[consumerID]?.lastSnapshot = snapshot
                consumer.continuation.yield(snapshot)
            }
        }
    }
}
