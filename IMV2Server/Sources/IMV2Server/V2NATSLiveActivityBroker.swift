import Foundation
import IMV2Core
import Crypto
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// Best-effort cross-gateway fan-out for ephemeral activity. Privacy and
/// presence authority stay in Postgres; this broker only avoids waiting for a
/// view to be reopened when the peer connects on another gateway replica.
public protocol V2LiveActivityInterestManaging: Sendable {
    func activatePresence(targetUserID: UserID) async throws
    func deactivatePresence(targetUserID: UserID) async
    func activateTyping(roomID: RoomID) async throws
    func deactivateTyping(roomID: RoomID) async
}

public protocol V2LiveActivityPublishing: Sendable {
    func publishPresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async
    func publishTyping(_ state: V2TypingState) async
}

/// Reuses the gateway's NATS URL, credential and deployment routing key. The
/// live-activity subjects use a distinct suffix and HMAC-derived identifiers,
/// so raw user and room UUIDs never become broker subject names.
public actor V2NATSLiveActivityBroker: V2LiveActivityInterestManaging, V2LiveActivityPublishing {
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
    private struct WireEvent: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case presence, typing }
        let sourceID: UUID
        let kind: Kind
        let userID: String
        let isOnline: Bool?
        let expiresAt: Date
        let roomID: String?
        let isTyping: Bool?
        enum CodingKeys: String, CodingKey {
            case sourceID = "source_id", kind, userID = "user_id", isOnline = "is_online", expiresAt = "expires_at", roomID = "room_id", isTyping = "is_typing"
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

    private enum Interest: Sendable {
        case presence(UserID)
        case typing(RoomID)
    }

    private let configuration: V2NATSGroupEventWakeConfiguration
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let sourceID = UUID()
    private let receivePresence: @Sendable (UserID, Bool, Date) async -> Void
    private let receiveTyping: @Sendable (V2TypingState) async -> Void
    private var connection: Connection?
    private var pendingConnection: Task<Connection, any Error>?
    private var pendingPresenceActivations: [UserID: PendingActivation] = [:]
    private var pendingTypingActivations: [RoomID: PendingActivation] = [:]
    private var subscriptionsRemovedWhileConnecting: Set<Int> = []
    private var pendingReplaySubscriptionIDs: Set<Int> = []
    private var presenceSubscriptions: [UserID: Int] = [:]
    private var typingSubscriptions: [RoomID: Int] = [:]
    private var nextSubscriptionID = 1
    private var isShutDown = false

    public init(
        configuration: V2NATSGroupEventWakeConfiguration,
        receivePresence: @escaping @Sendable (UserID, Bool, Date) async -> Void,
        receiveTyping: @escaping @Sendable (V2TypingState) async -> Void
    ) {
        self.configuration = configuration
        self.receivePresence = receivePresence
        self.receiveTyping = receiveTyping
    }

    deinit {
        for activation in pendingPresenceActivations.values { activation.task.cancel() }
        for activation in pendingTypingActivations.values { activation.task.cancel() }
        pendingConnection?.cancel()
        connection?.channel.close(promise: nil)
        if !isShutDown { try? eventLoopGroup.syncShutdownGracefully() }
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for activation in pendingPresenceActivations.values { activation.task.cancel() }
        for activation in pendingTypingActivations.values { activation.task.cancel() }
        pendingPresenceActivations.removeAll(keepingCapacity: false)
        pendingTypingActivations.removeAll(keepingCapacity: false)
        let pending = pendingConnection
        pending?.cancel()
        pendingConnection = nil
        presenceSubscriptions.removeAll(keepingCapacity: false)
        typingSubscriptions.removeAll(keepingCapacity: false)
        let channel = connection?.channel
        connection = nil
        if let channel { try? await channel.close().get() }
        if let pending, let opened = try? await pending.value {
            try? await opened.channel.close().get()
        }
        try? await eventLoopGroup.shutdownGracefully()
    }

    public func activatePresence(targetUserID: UserID) async throws {
        if let pending = pendingPresenceActivations[targetUserID] {
            try await pending.task.value
            return
        }
        guard presenceSubscriptions[targetUserID] == nil else { return }
        let subscriptionID = nextSubscriptionID
        nextSubscriptionID &+= 1
        presenceSubscriptions[targetUserID] = subscriptionID
        let task = Task {
            try await self.confirmActivation(
                subject: self.presenceSubject(for: targetUserID),
                subscriptionID: subscriptionID,
                interest: .presence(targetUserID)
            )
        }
        pendingPresenceActivations[targetUserID] = .init(subscriptionID: subscriptionID, task: task)
        do {
            try await task.value
            if pendingPresenceActivations[targetUserID]?.subscriptionID == subscriptionID {
                pendingPresenceActivations.removeValue(forKey: targetUserID)
            }
        } catch {
            if pendingPresenceActivations[targetUserID]?.subscriptionID == subscriptionID {
                pendingPresenceActivations.removeValue(forKey: targetUserID)
            }
            if presenceSubscriptions[targetUserID] == subscriptionID {
                presenceSubscriptions.removeValue(forKey: targetUserID)
            }
            if error is CancellationError { throw error }
            if let connection { await discard(connection) }
            throw error
        }
    }

    public func deactivatePresence(targetUserID: UserID) async {
        guard let subscriptionID = presenceSubscriptions.removeValue(forKey: targetUserID) else { return }
        if pendingPresenceActivations[targetUserID]?.subscriptionID == subscriptionID {
            pendingPresenceActivations[targetUserID]?.task.cancel()
            pendingPresenceActivations.removeValue(forKey: targetUserID)
        }
        await deactivate(subscriptionID: subscriptionID)
    }

    public func activateTyping(roomID: RoomID) async throws {
        if let pending = pendingTypingActivations[roomID] {
            try await pending.task.value
            return
        }
        guard typingSubscriptions[roomID] == nil else { return }
        let subscriptionID = nextSubscriptionID
        nextSubscriptionID &+= 1
        typingSubscriptions[roomID] = subscriptionID
        let task = Task {
            try await self.confirmActivation(
                subject: self.typingSubject(for: roomID),
                subscriptionID: subscriptionID,
                interest: .typing(roomID)
            )
        }
        pendingTypingActivations[roomID] = .init(subscriptionID: subscriptionID, task: task)
        do {
            try await task.value
            if pendingTypingActivations[roomID]?.subscriptionID == subscriptionID {
                pendingTypingActivations.removeValue(forKey: roomID)
            }
        } catch {
            if pendingTypingActivations[roomID]?.subscriptionID == subscriptionID {
                pendingTypingActivations.removeValue(forKey: roomID)
            }
            if typingSubscriptions[roomID] == subscriptionID {
                typingSubscriptions.removeValue(forKey: roomID)
            }
            if error is CancellationError { throw error }
            if let connection { await discard(connection) }
            throw error
        }
    }

    public func deactivateTyping(roomID: RoomID) async {
        guard let subscriptionID = typingSubscriptions.removeValue(forKey: roomID) else { return }
        if pendingTypingActivations[roomID]?.subscriptionID == subscriptionID {
            pendingTypingActivations[roomID]?.task.cancel()
            pendingTypingActivations.removeValue(forKey: roomID)
        }
        await deactivate(subscriptionID: subscriptionID)
    }

    public func publishPresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        await publish(
            .init(sourceID: sourceID, kind: .presence, userID: targetUserID.rawValue, isOnline: isOnline, expiresAt: expiresAt, roomID: nil, isTyping: nil),
            subject: presenceSubject(for: targetUserID)
        )
    }

    public func publishTyping(_ state: V2TypingState) async {
        await publish(
            .init(sourceID: sourceID, kind: .typing, userID: state.userID.rawValue, isOnline: nil, expiresAt: state.expiresAt, roomID: state.roomID.rawValue, isTyping: state.isTyping),
            subject: typingSubject(for: state.roomID)
        )
    }

    private func deactivate(subscriptionID: Int?) async {
        guard let subscriptionID else { return }
        guard let connection, connection.channel.isActive else {
            if pendingConnection != nil,
               pendingReplaySubscriptionIDs.contains(subscriptionID) {
                subscriptionsRemovedWhileConnecting.insert(subscriptionID)
            }
            return
        }
        do { try await writeConfirmed("UNSUB \(subscriptionID)\r\n", connection: connection) }
        catch { await discard(connection) }
    }

    private func publish(_ event: WireEvent, subject: String) async {
        guard let payload = try? JSONEncoder().encode(event) else { return }
        do {
            let connection = try await connectedChannel()
            let channel = connection.channel
            var buffer = channel.allocator.buffer(capacity: payload.count + subject.utf8.count + 32)
            buffer.writeString("PUB \(subject) \(payload.count)\r\n")
            buffer.writeBytes(payload)
            buffer.writeString("\r\n")
            try await writeConfirmed(buffer, connection: connection)
        } catch {
            if let connection { await discard(connection) }
        }
    }

    private func confirmActivation(
        subject: String,
        subscriptionID: Int,
        interest: Interest
    ) async throws {
        let connection = try await connectedChannel()
        try Task.checkCancellation()
        if !connection.replayedSubscriptionIDs.contains(subscriptionID) {
            try await writeConfirmed(
                "SUB \(subject) \(subscriptionID)\r\n", connection: connection
            )
        }
        guard !Task.isCancelled, isActive(interest, subscriptionID: subscriptionID)
        else {
            try? await writeConfirmed("UNSUB \(subscriptionID)\r\n", connection: connection)
            throw CancellationError()
        }
    }

    private func isActive(_ interest: Interest, subscriptionID: Int) -> Bool {
        switch interest {
        case let .presence(userID):
            presenceSubscriptions[userID] == subscriptionID
        case let .typing(roomID):
            typingSubscriptions[roomID] == subscriptionID
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
            let sourceID = self.sourceID
            let receivePresence = self.receivePresence
            let receiveTyping = self.receiveTyping
            let replay = presenceSubscriptions.map {
                (presenceSubject(for: $0.key), $0.value)
            } + typingSubscriptions.map {
                (typingSubject(for: $0.key), $0.value)
            }
            pendingReplaySubscriptionIDs = Set(replay.map(\.1))
            pending = Task { [group, host, port, timeout, token, sourceID, receivePresence, receiveTyping, replay] in
                try await Self.openConnection(
                    group: group, host: host, port: port, timeout: timeout,
                    token: token, sourceID: sourceID,
                    receivePresence: receivePresence, receiveTyping: receiveTyping,
                    replay: replay
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
            connection = opened
            let connectionID = opened.id
            opened.channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                Task { [weak self] in await self?.connectionClosed(connectionID) }
            }
            if !subscriptionsRemovedWhileConnecting.isEmpty {
                let removed = subscriptionsRemovedWhileConnecting
                let command = removed.sorted().map { "UNSUB \($0)\r\n" }.joined()
                try await writeConfirmed(command, connection: opened)
                subscriptionsRemovedWhileConnecting.subtract(removed)
            }
            pendingReplaySubscriptionIDs.removeAll(keepingCapacity: false)
            return opened
        } catch {
            pendingConnection = nil
            pendingReplaySubscriptionIDs.removeAll(keepingCapacity: false)
            subscriptionsRemovedWhileConnecting.removeAll(keepingCapacity: false)
            if let attemptedConnection, connection?.channel === attemptedConnection.channel {
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
        sourceID: UUID,
        receivePresence: @escaping @Sendable (UserID, Bool, Date) async -> Void,
        receiveTyping: @escaping @Sendable (V2TypingState) async -> Void,
        replay: [(subject: String, subscriptionID: Int)]
    ) async throws -> Connection {
        let handler = V2NATSConfirmedInboundHandler(invalidMessagePolicy: .ignore) { payload in
            guard let event = try? JSONDecoder().decode(WireEvent.self, from: payload),
                  event.sourceID != sourceID,
                  let userID = try? UserID(event.userID)
            else { return }
            switch event.kind {
            case .presence:
                guard let isOnline = event.isOnline else { return }
                await receivePresence(userID, isOnline, event.expiresAt)
            case .typing:
                guard let room = event.roomID.flatMap({ try? RoomID($0) }),
                      let isTyping = event.isTyping
                else { return }
                await receiveTyping(.init(
                    roomID: room, userID: userID, isTyping: isTyping,
                    expiresAt: event.expiresAt
                ))
            }
        }
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: timeout)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }
            .connect(host: host, port: port)
            .get()
        do {
            guard !Task.isCancelled,
                  let acknowledgement = handler.beginAcknowledgement(eventLoop: channel.eventLoop)
            else { throw CancellationError() }
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
            return .init(
                id: UUID(), channel: channel, handler: handler,
                replayedSubscriptionIDs: Set(replay.map(\.subscriptionID))
            )
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    private func connectionClosed(_ closedID: UUID) {
        if connection?.id == closedID { connection = nil }
    }
    private func presenceSubject(for userID: UserID) -> String { subject(kind: "presence", identifier: userID.rawValue) }
    private func typingSubject(for roomID: RoomID) -> String { subject(kind: "typing", identifier: roomID.rawValue) }
    private func subject(kind: String, identifier: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data("\(kind):\(identifier)".utf8), using: SymmetricKey(data: configuration.routingKey))
        return "\(configuration.subjectPrefix).live.\(kind).\(digest.map { String(format: "%02x", $0) }.joined())"
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
            if connection.handler.timeout(acknowledgement) { channel.close(promise: nil) }
        }
        var command = command
        command.writeString("PING\r\n")
        do {
            try await channel.writeAndFlush(command)
            try await acknowledgement.awaitBrokerConfirmation()
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            if connection.handler.timeout(acknowledgement) { channel.close(promise: nil) }
            throw error
        }
    }

    private func discard(_ discarded: Connection) async {
        if connection?.channel === discarded.channel { connection = nil }
        try? await discarded.channel.close().get()
    }
}
