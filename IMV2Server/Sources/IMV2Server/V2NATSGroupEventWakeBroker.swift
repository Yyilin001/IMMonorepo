import Foundation
import IMV2Core
import Crypto
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// Dynamic room interest is deliberately separate from durable wake outbox
/// work. A broker may forget a subscription during a network split; the
/// client cursor and low-frequency recovery pull remain correct.
public protocol V2GroupEventWakeInterestManaging: Sendable {
    func activate(roomID: RoomID) async throws
    func deactivate(roomID: RoomID) async
}

public enum V2NATSGroupEventPayloadEncoding: String, Equatable, Sendable {
    /// Rollout-safe default understood by every currently deployed Gateway.
    case json
    /// Versioned binary encoding for homogeneous, protobuf-capable replicas.
    case protobufV1 = "protobuf_v1"
}

public struct V2NATSGroupEventWakeConfiguration: Equatable, Sendable {
    public let url: URL
    public let subjectPrefix: String
    public let token: String?
    /// Per-deployment secret used to derive opaque room routing subjects. It
    /// keeps stable room UUIDs out of broker ACLs, traces and subject names.
    public let routingKey: Data
    public let payloadEncoding: V2NATSGroupEventPayloadEncoding
    /// A durable wake may arrive on another publisher connection before the
    /// corresponding foreground microbatch finishes bounded aggregation.
    /// Delay only that recovery hint so an in-flight live payload can cover
    /// it; PostgreSQL remains authoritative when this deadline expires.
    public let wakeDeferralDelayMilliseconds: Int
    /// Bounds connect, command and broker PING/PONG confirmation. A TCP write
    /// alone is not evidence that NATS accepted the preceding command.
    public let acknowledgementTimeout: TimeInterval

    public init(
        url: URL,
        subjectPrefix: String,
        token: String? = nil,
        routingKey: Data,
        payloadEncoding: V2NATSGroupEventPayloadEncoding = .json,
        wakeDeferralDelayMilliseconds: Int = 60,
        acknowledgementTimeout: TimeInterval = 2
    ) throws {
        let normalizedPrefix = subjectPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.scheme?.lowercased() == "nats", url.host != nil,
              normalizedPrefix.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != true, routingKey.count >= 32,
              (0 ... 1_000).contains(wakeDeferralDelayMilliseconds),
              acknowledgementTimeout.isFinite,
              acknowledgementTimeout > 0,
              acknowledgementTimeout <= 30
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        self.url = url
        self.subjectPrefix = normalizedPrefix
        self.token = normalizedToken
        self.routingKey = routingKey
        self.payloadEncoding = payloadEncoding
        self.wakeDeferralDelayMilliseconds = wakeDeferralDelayMilliseconds
        self.acknowledgementTimeout = acknowledgementTimeout
    }
}

public enum V2NATSGroupEventWakeBrokerError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unavailable
    case invalidPayload
}

/// The NATS payload is a best-effort foreground notification.  A receiver
/// must still treat `.wake` as a cursor-pull prompt, while `.directEvent` is
/// usable only when the client has the immediately preceding cursor.
public enum V2ForegroundGroupEventNotification: Equatable, Sendable {
    case wake(V2GroupEventWake)
    case directEvent(V2DirectRoomLiveEvent)
    case groupEvents([V2DirectRoomLiveEvent])
}

/// Core NATS preserves a publisher's subject order, but a room may be written
/// by several Gateways. Their database commits allocate one ordered room
/// sequence while their independent post-commit publications can reach NATS
/// in the opposite order. Hashing a room onto one lane prevents concurrent
/// socket fan-out, and a short bounded coalescing window restores the common
/// cross-publisher inversion before every foreground client mistakes it for a
/// durable-log gap. A real missing/late payload or overload still degrades to
/// the authoritative cursor pull.
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
                if delay > .zero { try? await Task.sleep(for: delay) }
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

    /// A room is always assigned to one worker lane, so this bounded cache is
    /// worker-local and needs no lock. It records only notifications whose
    /// local socket fan-out has returned successfully. Eviction merely loses
    /// an optimization: a later durable wake is delivered as before.
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
                let clock = ContinuousClock()
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
                        try? await Task.sleep(for: reorderingDelay)
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
                                    deadline: clock.now.advanced(
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

                    let now = clock.now
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

    func submit(_ payload: Data) {
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

    func droppedPayloadCount() -> UInt64 {
        droppedPayloads.load(ordering: .relaxed)
    }

    /// Coalesces only best-effort transport notifications. The recovery cache
    /// has already observed every decoded input above, so suppressing a wake
    /// covered by the same window cannot hide durable state.
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

/// One reusable Core NATS connection per Gateway. It owns only current local
/// viewer interests, not a durable consumer per user or per room. Subject
/// subscriptions are reference-counted by `V2DeviceConnectionRegistry`.
public actor V2NATSGroupEventWakeBroker: V2GroupEventWakePublishing, V2ForegroundGroupEventHintPublishing, V2GroupEventWakeInterestManaging {
    /// Foreground payloads only accelerate a room cursor that is already
    /// durable in PostgreSQL. Requiring a broker PONG for each such payload
    /// adds a second network round trip to every microbatch without changing
    /// correctness. Durable outbox wakes and subscription lifecycle commands
    /// retain broker confirmation below.
    private enum PublicationGuarantee: Sendable {
        case brokerConfirmed
        case advisory
    }

    private static let maximumCachedSubjects = 4_096
    /// Core NATS defaults to a 1 MiB `max_payload`. The rollout-safe JSON mode
    /// expands `Data` by roughly 4/3, so this conservative raw-body limit also
    /// bounds the smaller protobuf representation without requiring an
    /// operator to raise the broker limit.
    private static let maximumGroupEventsPerPublication = 64
    private static let maximumGroupEventRawPayloadBytesPerPublication = 512 * 1_024
    /// Keep accepting the larger legacy JSON representation while replicas
    /// roll through the versioned protobuf decoder. Both encodings remain
    /// below the ordinary 1 MiB Core NATS `max_payload`.
    private static let maximumInboundNotificationPayloadBytes = 896 * 1_024

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

    private struct WireWake: Codable, Sendable {
        let roomID: String
        let highWatermark: UInt64
        let directEvent: WireDirectEvent?
        let directEvents: [WireDirectEvent]?

        enum CodingKeys: String, CodingKey {
            case roomID = "room_id"
            case highWatermark = "high_watermark"
            case directEvent = "direct_event"
            case directEvents = "direct_events"
        }

        init(
            roomID: String,
            highWatermark: UInt64,
            directEvent: WireDirectEvent?,
            directEvents: [WireDirectEvent]? = nil
        ) {
            self.roomID = roomID
            self.highWatermark = highWatermark
            self.directEvent = directEvent
            self.directEvents = directEvents
        }
    }

    private struct WireDirectEvent: Codable, Sendable {
        let sourceEventID: String
        let roomSequence: UInt64
        let projectionKind: String
        let payload: Data
        let recipientUserIDs: [String]
        let groupMembershipRevision: UInt64?
        let excludedConnectionID: UUID?

        enum CodingKeys: String, CodingKey {
            case sourceEventID = "source_event_id"
            case roomSequence = "room_sequence"
            case projectionKind = "projection_kind"
            case payload
            case recipientUserIDs = "recipient_user_ids"
            case groupMembershipRevision = "group_membership_revision"
            case excludedConnectionID = "excluded_connection_id"
        }

        init(_ event: V2DirectRoomLiveEvent) {
            sourceEventID = event.sourceEventID.rawValue
            roomSequence = event.roomSequence
            projectionKind = event.projectionKind
            payload = event.payload
            recipientUserIDs = event.recipientUserIDs.map(\.rawValue).sorted()
            groupMembershipRevision = event.groupMembershipRevision
            excludedConnectionID = event.excludedConnectionID
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
    /// Subject derivation uses a deployment-secret HMAC and hexadecimal
    /// formatting. Rooms are reused heavily on the live path, so cache the
    /// opaque result under a hard bound instead of repeating that work for
    /// every foreground publication.
    private var subjectsByRoomID: [RoomID: String] = [:]
    /// Only subscriptions captured by the in-flight connection replay need a
    /// compensating UNSUB. Keeping this exact set bounds cancellation state by
    /// live interests at handshake start instead of outage-time churn.
    private var pendingReplaySubscriptionIDs: Set<Int> = []
    private var nextSubscriptionID = 1
    private var isShutDown = false
    private var reconnectTask: Task<Void, Never>?

    public init(
        configuration: V2NATSGroupEventWakeConfiguration,
        recordRecoveryNotification: @escaping @Sendable (
            V2ForegroundGroupEventNotification
        ) -> Void = { _ in },
        metrics: (any V2GatewayTransportMetricsRecorder)? = nil,
        receiveWake: @escaping @Sendable (V2ForegroundGroupEventNotification) async -> Void
    ) {
        self.configuration = configuration
        subjectRoutingKey = SymmetricKey(data: configuration.routingKey)
        self.recordRecoveryNotification = recordRecoveryNotification
        self.metrics = metrics
        self.receiveWake = receiveWake
    }

    deinit {
        for activation in pendingActivations.values { activation.task.cancel() }
        reconnectTask?.cancel()
        pendingConnection?.cancel()
        connection?.channel.close(promise: nil)
        if !isShutDown { try? eventLoopGroup.syncShutdownGracefully() }
    }

    /// Explicit service lifecycle boundary. Production shutdown must not rely
    /// on ARC ordering for a network channel and its event-loop threads.
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

    public func publish(_ wake: V2GroupEventWake) async throws {
        try await publish(
            .wake(wake),
            roomID: wake.roomID,
            guarantee: .brokerConfirmed
        )
    }

    /// Like metadata hints, live payload delivery is advisory.  Any NATS
    /// issue degrades to the normal durable cursor pull instead of affecting
    /// an already accepted send.
    public func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        try? await publish(
            .directEvent(event),
            roomID: event.roomID,
            guarantee: .advisory
        )
    }

    /// Preserve the dispatcher's ordered Hybrid-group microbatch across the
    /// process boundary. The compatibility protocol default publishes every
    /// event separately; doing that here multiplies NATS confirmations, JSON
    /// work and remote Gateway scheduling by the batch width. Chunks remain
    /// modest so one Core NATS message stays far below its ordinary payload
    /// limit even when a room uses the largest supported message body.
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
        let payload: Data
        switch configuration.payloadEncoding {
        case .json:
            payload = try Self.encodeJSONNotification(notification)
        case .protobufV1:
            payload = try V2NATSGroupEventProtobufCodec.encode(notification)
        }
        var buffer = channel.allocator.buffer(capacity: payload.count + configuration.subjectPrefix.utf8.count + 64)
        buffer.writeString("PUB \(subject(for: roomID)) \(payload.count)\r\n")
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

    /// A foreground hint is intentionally lossy. Do not propagate a broker
    /// outage back into the sender's accepted response; durable fan-out or
    /// Hybrid wake-outbox recovery still supplies correctness.
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
        if let connection, connection.channel.isActive { return connection }
        let pending: Task<Connection, any Error>
        if let pendingConnection {
            pending = pendingConnection
        } else {
            let group = eventLoopGroup
            let host = configuration.url.host!
            let port = configuration.url.port ?? 4222
            let timeout = acknowledgementTimeout
            let token = configuration.token
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
                    host,
                    port,
                    timeout,
                    token,
                    replay,
                    recordRecoveryNotification,
                    metrics,
                    receiveWake,
                    wakeDeferralDelayMilliseconds
                ] in
                try await Self.openConnection(
                    group: group,
                    host: host,
                    port: port,
                    timeout: timeout,
                    token: token,
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
        .nanoseconds(Int64(configuration.acknowledgementTimeout * 1_000_000_000))
    }

    private static func openConnection(
        group: MultiThreadedEventLoopGroup,
        host: String,
        port: Int,
        timeout: TimeAmount,
        token: String?,
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
        let handler = V2NATSConfirmedInboundHandler(
            maximumPayloadBytes: Self.maximumInboundNotificationPayloadBytes,
            payloadDispatcher: notificationDispatcher
        )
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: timeout)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }
            .connect(host: host, port: port)
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
                decoding: try JSONEncoder().encode(Connect(token: token)),
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

    /// Shared decoder for the production NATS handler and focused contract
    /// tests. Invalid or partially authorized live payloads fail closed to a
    /// metadata wake; only a malformed room envelope is discarded entirely.
    static func decodeNotificationPayload(
        _ payload: Data
    ) -> V2ForegroundGroupEventNotification? {
        if V2NATSGroupEventProtobufCodec.recognizes(payload) {
            return V2NATSGroupEventProtobufCodec.decode(payload)
        }
        guard let wire = try? JSONDecoder().decode(WireWake.self, from: payload),
              let roomID = try? RoomID(wire.roomID)
        else { return nil }
        let wake = V2ForegroundGroupEventNotification.wake(.init(
            roomID: roomID,
            highWatermark: wire.highWatermark
        ))
        if let directEvents = wire.directEvents {
            guard wire.directEvent == nil,
                  !directEvents.isEmpty,
                  directEvents.count <= Self.maximumGroupEventsPerPublication
            else { return wake }
            var materialized: [V2DirectRoomLiveEvent] = []
            materialized.reserveCapacity(directEvents.count)
            var previousSequence: UInt64?
            var membershipRevision: UInt64?
            for direct in directEvents {
                guard direct.roomSequence > (previousSequence ?? 0),
                      direct.roomSequence > 0,
                      !direct.projectionKind.isEmpty,
                      !direct.payload.isEmpty,
                      direct.recipientUserIDs.isEmpty,
                      let revision = direct.groupMembershipRevision,
                      revision > 0,
                      direct.excludedConnectionID == nil,
                      membershipRevision == nil || membershipRevision == revision,
                      let sourceEventID = try? EventID(direct.sourceEventID)
                else { return wake }
                membershipRevision = revision
                previousSequence = direct.roomSequence
                materialized.append(.init(
                    roomID: roomID,
                    highWatermark: direct.roomSequence,
                    sourceEventID: sourceEventID,
                    roomSequence: direct.roomSequence,
                    projectionKind: direct.projectionKind,
                    payload: direct.payload,
                    recipientUserIDs: [],
                    groupMembershipRevision: revision,
                    acceptedMembershipRevision: revision,
                    excludedConnectionID: nil
                ))
            }
            guard previousSequence == wire.highWatermark else { return wake }
            return .groupEvents(materialized)
        }
        guard let direct = wire.directEvent,
              direct.roomSequence == wire.highWatermark,
              direct.roomSequence > 0,
              !direct.projectionKind.isEmpty,
              !direct.payload.isEmpty,
              let sourceEventID = try? EventID(direct.sourceEventID)
        else { return wake }
        let recipients = Set(direct.recipientUserIDs.compactMap { try? UserID($0) })
        let isExactAudience = !recipients.isEmpty
            && recipients.count == direct.recipientUserIDs.count
            && direct.groupMembershipRevision == nil
        let isGroupAudience = recipients.isEmpty
            && direct.recipientUserIDs.isEmpty
            && (direct.groupMembershipRevision ?? 0) > 0
        guard isExactAudience || isGroupAudience else { return wake }
        return .directEvent(.init(
            roomID: roomID,
            highWatermark: wire.highWatermark,
            sourceEventID: sourceEventID,
            roomSequence: direct.roomSequence,
            projectionKind: direct.projectionKind,
            payload: direct.payload,
            recipientUserIDs: recipients,
            groupMembershipRevision: direct.groupMembershipRevision,
            acceptedMembershipRevision: direct.groupMembershipRevision,
            excludedConnectionID: direct.excludedConnectionID
        ))
    }

    private static func encodeJSONNotification(
        _ notification: V2ForegroundGroupEventNotification
    ) throws -> Data {
        let wire: WireWake
        switch notification {
        case .wake(let wake):
            wire = .init(
                roomID: wake.roomID.rawValue,
                highWatermark: wake.highWatermark,
                directEvent: nil
            )
        case .directEvent(let event):
            wire = .init(
                roomID: event.roomID.rawValue,
                highWatermark: event.highWatermark,
                directEvent: .init(event)
            )
        case .groupEvents(let events):
            guard let first = events.first,
                  let last = events.last
            else { throw V2NATSGroupEventWakeBrokerError.invalidPayload }
            wire = .init(
                roomID: first.roomID.rawValue,
                highWatermark: last.highWatermark,
                directEvent: nil,
                directEvents: events.map(WireDirectEvent.init)
            )
        }
        return try JSONEncoder().encode(wire)
    }

    private func connectionClosed(_ closedID: UUID) {
        guard connection?.id == closedID else { return }
        connection = nil
        scheduleReconnectIfNeeded()
    }

    /// Core NATS keeps subscription state only on the socket. Maintain one
    /// bounded-backoff reconnect loop whenever this Gateway still has local
    /// viewers; `connectedChannel` replays the complete current subject set.
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
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
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

    /// A foreground live payload is explicitly lossy: its room-log row and a
    /// durable wake already exist before this call. Waiting for NIO's write
    /// completion still detects an inactive or failed channel, while omitting
    /// the per-publication PING/PONG removes protocol traffic and a suspended
    /// continuation from the hot path. Core NATS preserves socket order for
    /// the bytes that it does receive.
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
            connection = nil
        }
        try? await discarded.channel.close().get()
    }
}

/// Its parser state is runtime-checked against its owning event loop; all
/// application state crosses into an actor via the supplied Sendable callback.
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
        onPayload: @escaping @Sendable (Data) async -> Void
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
            case .payload(let payload):
                payloadDispatcher.submit(payload)
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
