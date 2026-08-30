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

public struct V2NATSGroupEventWakeConfiguration: Equatable, Sendable {
    public let url: URL
    public let subjectPrefix: String
    public let token: String?
    /// Per-deployment secret used to derive opaque room routing subjects. It
    /// keeps stable room UUIDs out of broker ACLs, traces and subject names.
    public let routingKey: Data
    /// Bounds connect, command and broker PING/PONG confirmation. A TCP write
    /// alone is not evidence that NATS accepted the preceding command.
    public let acknowledgementTimeout: TimeInterval

    public init(
        url: URL,
        subjectPrefix: String,
        token: String? = nil,
        routingKey: Data,
        acknowledgementTimeout: TimeInterval = 2
    ) throws {
        let normalizedPrefix = subjectPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.scheme?.lowercased() == "nats", url.host != nil,
              normalizedPrefix.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != true, routingKey.count >= 32,
              acknowledgementTimeout.isFinite,
              acknowledgementTimeout > 0,
              acknowledgementTimeout <= 30
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        self.url = url
        self.subjectPrefix = normalizedPrefix
        self.token = normalizedToken
        self.routingKey = routingKey
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
public enum V2ForegroundGroupEventNotification: Sendable {
    case wake(V2GroupEventWake)
    case directEvent(V2DirectRoomLiveEvent)
}

/// One reusable Core NATS connection per Gateway. It owns only current local
/// viewer interests, not a durable consumer per user or per room. Subject
/// subscriptions are reference-counted by `V2DeviceConnectionRegistry`.
public actor V2NATSGroupEventWakeBroker: V2GroupEventWakePublishing, V2ForegroundGroupEventHintPublishing, V2GroupEventWakeInterestManaging {
    private struct Connect: Encodable {
        let verbose = false
        let pedantic = false
        let token: String?
    }

    private struct WireWake: Codable, Sendable {
        let roomID: String
        let highWatermark: UInt64
        let directEvent: WireDirectEvent?

        enum CodingKeys: String, CodingKey {
            case roomID = "room_id"
            case highWatermark = "high_watermark"
            case directEvent = "direct_event"
        }
    }

    private struct WireDirectEvent: Codable, Sendable {
        let sourceEventID: String
        let roomSequence: UInt64
        let projectionKind: String
        let payload: Data
        let recipientUserIDs: [String]
        let excludedConnectionID: UUID?

        enum CodingKeys: String, CodingKey {
            case sourceEventID = "source_event_id"
            case roomSequence = "room_sequence"
            case projectionKind = "projection_kind"
            case payload
            case recipientUserIDs = "recipient_user_ids"
            case excludedConnectionID = "excluded_connection_id"
        }

        init(_ event: V2DirectRoomLiveEvent) {
            sourceEventID = event.sourceEventID.rawValue
            roomSequence = event.roomSequence
            projectionKind = event.projectionKind
            payload = event.payload
            recipientUserIDs = event.recipientUserIDs.map(\.rawValue).sorted()
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
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let receiveNotification: @Sendable (V2ForegroundGroupEventNotification) async -> Void
    private var connection: Connection?
    private var pendingConnection: Task<Connection, any Error>?
    private var pendingActivations: [RoomID: PendingActivation] = [:]
    private var subscriptions: [RoomID: Int] = [:]
    private var subscriptionsRemovedWhileConnecting: Set<Int> = []
    /// Only subscriptions captured by the in-flight connection replay need a
    /// compensating UNSUB. Keeping this exact set bounds cancellation state by
    /// live interests at handshake start instead of outage-time churn.
    private var pendingReplaySubscriptionIDs: Set<Int> = []
    private var nextSubscriptionID = 1
    private var isShutDown = false

    public init(
        configuration: V2NATSGroupEventWakeConfiguration,
        receiveWake: @escaping @Sendable (V2ForegroundGroupEventNotification) async -> Void
    ) {
        self.configuration = configuration
        receiveNotification = receiveWake
    }

    deinit {
        for activation in pendingActivations.values { activation.task.cancel() }
        pendingConnection?.cancel()
        connection?.channel.close(promise: nil)
        if !isShutDown { try? eventLoopGroup.syncShutdownGracefully() }
    }

    /// Explicit service lifecycle boundary. Production shutdown must not rely
    /// on ARC ordering for a network channel and its event-loop threads.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
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
        try? await eventLoopGroup.shutdownGracefully()
    }

    public func activate(roomID: RoomID) async throws {
        if let pending = pendingActivations[roomID] {
            try await pending.task.value
            return
        }
        guard subscriptions[roomID] == nil else { return }
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
        try await publish(.init(
            roomID: wake.roomID.rawValue,
            highWatermark: wake.highWatermark,
            directEvent: nil
        ), roomID: wake.roomID)
    }

    /// Like metadata hints, live payload delivery is advisory.  Any NATS
    /// issue degrades to the normal durable cursor pull instead of affecting
    /// an already accepted send.
    public func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        try? await publish(.init(
            roomID: event.roomID.rawValue,
            highWatermark: event.highWatermark,
            directEvent: .init(event)
        ), roomID: event.roomID)
    }

    private func publish(_ wake: WireWake, roomID: RoomID) async throws {
        let connection = try await connectedChannel()
        let channel = connection.channel
        let payload = try JSONEncoder().encode(wake)
        var buffer = channel.allocator.buffer(capacity: payload.count + configuration.subjectPrefix.utf8.count + 64)
        buffer.writeString("PUB \(subject(for: roomID)) \(payload.count)\r\n")
        buffer.writeBytes(payload)
        buffer.writeString("\r\n")
        do {
            try await writeConfirmed(buffer, connection: connection)
        } catch {
            await discard(connection)
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
    }

    /// A foreground hint is intentionally lossy. Do not propagate a broker
    /// outage back into the sender's accepted response; durable fan-out or
    /// Hybrid wake-outbox recovery still supplies correctness.
    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        try? await publish(hint)
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
            let receiveNotification = self.receiveNotification
            let token = configuration.token
            let replay = subscriptions.map { roomID, subscriptionID in
                (subject(for: roomID), subscriptionID)
            }
            pendingReplaySubscriptionIDs = Set(replay.map(\.1))
            pending = Task { [group, host, port, timeout, token, replay, receiveNotification] in
                try await Self.openConnection(
                    group: group,
                    host: host,
                    port: port,
                    timeout: timeout,
                    token: token,
                    replay: replay,
                    receiveNotification: receiveNotification
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
        receiveNotification: @escaping @Sendable (V2ForegroundGroupEventNotification) async -> Void
    ) async throws -> Connection {
        let handler = V2NATSConfirmedInboundHandler(onPayload: { payload in
            guard let wire = try? JSONDecoder().decode(WireWake.self, from: payload),
                  let roomID = try? RoomID(wire.roomID)
            else { return }
            guard let direct = wire.directEvent else {
                await receiveNotification(.wake(.init(roomID: roomID, highWatermark: wire.highWatermark)))
                return
            }
            guard direct.roomSequence == wire.highWatermark,
                  direct.roomSequence > 0,
                  !direct.projectionKind.isEmpty,
                  !direct.payload.isEmpty,
                  let sourceEventID = try? EventID(direct.sourceEventID)
            else {
                await receiveNotification(.wake(.init(roomID: roomID, highWatermark: wire.highWatermark)))
                return
            }
            let recipients = Set(direct.recipientUserIDs.compactMap { try? UserID($0) })
            guard !recipients.isEmpty, recipients.count == direct.recipientUserIDs.count else {
                await receiveNotification(.wake(.init(roomID: roomID, highWatermark: wire.highWatermark)))
                return
            }
            await receiveNotification(.directEvent(.init(
                roomID: roomID,
                highWatermark: wire.highWatermark,
                sourceEventID: sourceEventID,
                roomSequence: direct.roomSequence,
                projectionKind: direct.projectionKind,
                payload: direct.payload,
                recipientUserIDs: recipients,
                excludedConnectionID: direct.excludedConnectionID
            )))
        })
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
            let connect = String(decoding: try JSONEncoder().encode(Connect(token: token)), as: UTF8.self)
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

    private func connectionClosed(_ closedID: UUID) {
        guard connection?.id == closedID else { return }
        connection = nil
    }

    private func subject(for roomID: RoomID) -> String {
        let key = SymmetricKey(data: configuration.routingKey)
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(roomID.rawValue.utf8),
            using: key
        )
        let routingKey = digest.map { String(format: "%02x", $0) }.joined()
        return "\(configuration.subjectPrefix).\(routingKey)"
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

    private let payloadDispatcher: V2NATSPayloadDispatcher
    private let parser = Mutex(V2NATSInboundFrameParser(invalidMessagePolicy: .closeChannel))
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
        onPayload: @escaping @Sendable (Data) async -> Void
    ) {
        payloadDispatcher = .init(onPayload: onPayload)
        parser.withLock { $0 = .init(invalidMessagePolicy: invalidMessagePolicy) }
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
