import Foundation
import IMV2Core

public enum V2RoomSubscriptionChannel: Hashable, Sendable {
    case roomEvents, typing, presence
}

/// A complete replacement value permits a one-element consumer buffer. A slow
/// scene cannot lose a connection reset and keep an old typing/presence lease.
public struct V2RoomSubscriptionSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable { case offline, reconciling, subscribed, revoked }
    public let roomID: RoomID
    public let connectionID: UUID?
    public let state: State
    public let recoveryID: UUID?
    public let wake: V2GroupEventAvailabilityHint?
    public let presence: V2PresenceState?
    public let typing: [V2TypingState]
}

public struct V2RoomSubscriptionLease: Sendable {
    public let id: UUID
    public let roomID: RoomID
    public let updates: AsyncStream<V2RoomSubscriptionSnapshot>
}

public enum V2RoomSubscriptionError: Error, Equatable, Sendable {
    case emptyChannels, capacityExceeded
}

/// One account/runtime owns wire subscriptions and hint consumers. Scenes own
/// only intent tokens, so closing one scene never unsubscribes another scene.
/// Domain transports keep their shared request-ID allocator; TaskLocal scope
/// binds reconciliation requests to the authenticated wire generation.
public actor V2RoomSubscriptionCoordinator {
    private struct Consumer {
        let channels: Set<V2RoomSubscriptionChannel>
        let continuation: AsyncStream<V2RoomSubscriptionSnapshot>.Continuation
        var lastSnapshot: V2RoomSubscriptionSnapshot?
    }
    private struct Room {
        var consumers: [UUID: Consumer] = [:]
        var confirmed: Set<V2RoomSubscriptionChannel> = []
        var authorized = true
        var serverRevoked = false
        var recoveryID: UUID?
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
    private let roomCursor: @Sendable (RoomID) async throws -> UInt64
    private let retryDelay: Duration
    private let refreshInterval: Duration
    private let maximumRooms: Int
    private let maximumConsumers: Int
    private var rooms: [RoomID: Room] = [:]
    private var runState: Run?
    private var flight: (id: UUID, task: Task<Void, Error>)?

    public init(
        subscriptions: any V2ClientGroupEventSubscriptionTransport,
        activity: any V2ClientLiveActivityTransport,
        groupEvents: any V2GroupEventAvailabilityHintSource,
        activityEvents: any V2LiveActivityEventSource,
        isAuthorized: @escaping @Sendable (RoomID) async throws -> Bool,
        roomCursor: @escaping @Sendable (RoomID) async throws -> UInt64,
        didUnsubscribeRoom: @escaping @Sendable (RoomID) async -> Void = { _ in },
        retryDelay: Duration = .seconds(1),
        refreshInterval: Duration = .seconds(30),
        maximumRooms: Int = 128,
        maximumConsumers: Int = 512
    ) {
        precondition(retryDelay > .zero && refreshInterval > .zero && maximumRooms > 0 && maximumConsumers > 0)
        self.subscriptions = subscriptions
        self.activity = activity
        self.groupEvents = groupEvents
        self.activityEvents = activityEvents
        self.isAuthorized = isAuthorized
        self.roomCursor = roomCursor
        self.didUnsubscribeRoom = didUnsubscribeRoom
        self.retryDelay = retryDelay
        self.refreshInterval = refreshInterval
        self.maximumRooms = maximumRooms
        self.maximumConsumers = maximumConsumers
    }

    public func acquire(roomID: RoomID, channels: Set<V2RoomSubscriptionChannel>) throws -> V2RoomSubscriptionLease {
        guard !channels.isEmpty else { throw V2RoomSubscriptionError.emptyChannels }
        guard rooms[roomID] != nil || rooms.count < maximumRooms,
              rooms.values.reduce(0, { $0 + $1.consumers.count }) < maximumConsumers
        else { throw V2RoomSubscriptionError.capacityExceeded }
        let id = UUID()
        let stream = AsyncStream<V2RoomSubscriptionSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.release(roomID: roomID, consumerID: id) } }
        rooms[roomID, default: Room()].consumers[id] = .init(channels: channels, continuation: stream.continuation)
        publish(roomID)
        requestReconciliation()
        return .init(id: id, roomID: roomID, updates: stream.stream)
    }

    public func release(roomID: RoomID, consumerID: UUID) {
        guard let consumer = rooms[roomID]?.consumers.removeValue(forKey: consumerID) else { return }
        consumer.continuation.finish()
        if runState == nil, rooms[roomID]?.consumers.isEmpty == true { rooms[roomID] = nil }
        requestReconciliation()
    }

    /// Personal-sync completion requests reconciliation after membership changes.
    public func requestReconciliation() { runState?.wake.yield(()) }

    public func authorityDidChange() {
        for roomID in rooms.keys { rooms[roomID]?.serverRevoked = false }
        requestReconciliation()
    }

    /// An actual draft change/renewal belongs to the scene and connection
    /// that observed it. Reconnecting must never replay an old typing lease.
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
        wake.continuation.yield(())
        defer {
            wake.continuation.finish()
            if runState?.id == id { runState = nil; resetConnectionFacts() }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.reconcileLoop(wakes: wake.stream, id: id) }
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
            rooms[roomID]?.wake = nil
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
                rooms[roomID]?.authorized = authorized
                for channel in [V2RoomSubscriptionChannel.presence, .typing, .roomEvents] {
                    try checkRun(id)
                    guard let room = rooms[roomID] else { break }
                    let desired = room.desired.contains(channel)
                    let confirmed = room.confirmed.contains(channel)
                    guard desired != confirmed else { continue }
                    if desired { try await subscribe(roomID: roomID, channel: channel, id: id) }
                    else { try await unsubscribe(roomID: roomID, channel: channel, id: id) }
                }
                publish(roomID)
                if rooms[roomID]?.consumers.isEmpty == true, rooms[roomID]?.confirmed.isEmpty == true {
                    rooms[roomID] = nil
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as V2RealtimeTransportError {
                if case .server(let code, _, _, _) = error, code == "FORBIDDEN" {
                    rooms[roomID]?.serverRevoked = true
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
            rooms[roomID]?.recoveryID = UUID()
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
            rooms[roomID]?.wake = nil
            await didUnsubscribeRoom(roomID)
            try checkRun(id)
        case .typing: rooms[roomID]?.typing = [:]
        case .presence: rooms[roomID]?.presence = nil
        }
    }

    private func accept(_ hint: V2GroupEventAvailabilityHint, id: UUID) throws {
        try checkRun(id)
        guard rooms[hint.roomID]?.desired.contains(.roomEvents) == true else { return }
        let previous = rooms[hint.roomID]?.wake
        var wake = previous.map { $0.coalescing(with: hint) } ?? hint
        // Unlike the socket's pending buffer, a snapshot retains its last
        // wake after consumers have applied it. A metadata ACK or an old full
        // batch must not suppress every later payload forever. Keep the newest
        // batch when merging cannot preserve it; each consumer still checks
        // its authoritative cursor and pulls on a gap.
        if wake.liveEvents.isEmpty, !hint.liveEvents.isEmpty,
           hint.highWatermark >= (previous?.highWatermark ?? 0) {
            wake = hint
        }
        rooms[hint.roomID]?.wake = wake
        publish(hint.roomID)
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
            if rooms[roomID]?.confirmed.contains(.roomEvents) == true { rooms[roomID]?.recoveryID = UUID() }
            publish(roomID)
        }
        requestReconciliation()
    }

    private func publish(_ roomID: RoomID) {
        let now = Date()
        let currentTyping = rooms[roomID]?.typing.filter { $0.value.expiresAt > now } ?? [:]
        rooms[roomID]?.typing = currentTyping
        guard let room = rooms[roomID] else { return }
        for (consumerID, consumer) in room.consumers {
            let state: V2RoomSubscriptionSnapshot.State = runState == nil ? .offline :
                !room.authorized || room.serverRevoked ? .revoked : consumer.channels.isSubset(of: room.confirmed) ? .subscribed : .reconciling
            let snapshot = V2RoomSubscriptionSnapshot(
                roomID: roomID, connectionID: runState?.connectionID, state: state,
                recoveryID: consumer.channels.contains(.roomEvents) ? room.recoveryID : nil,
                wake: consumer.channels.contains(.roomEvents) ? room.wake : nil,
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
