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
    private struct Connect: Encodable { let verbose = false; let pedantic = false; let token: String? }
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

    private let configuration: V2NATSGroupEventWakeConfiguration
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let sourceID = UUID()
    private let receivePresence: @Sendable (UserID, Bool, Date) async -> Void
    private let receiveTyping: @Sendable (V2TypingState) async -> Void
    private var channel: Channel?
    private var presenceSubscriptions: [UserID: Int] = [:]
    private var typingSubscriptions: [RoomID: Int] = [:]
    private var nextSubscriptionID = 1

    public init(
        configuration: V2NATSGroupEventWakeConfiguration,
        receivePresence: @escaping @Sendable (UserID, Bool, Date) async -> Void,
        receiveTyping: @escaping @Sendable (V2TypingState) async -> Void
    ) {
        self.configuration = configuration
        self.receivePresence = receivePresence
        self.receiveTyping = receiveTyping
    }

    deinit { try? eventLoopGroup.syncShutdownGracefully() }

    public func activatePresence(targetUserID: UserID) async throws {
        guard presenceSubscriptions[targetUserID] == nil else { return }
        let subscriptionID = nextSubscriptionID
        nextSubscriptionID &+= 1
        try await write("SUB \(presenceSubject(for: targetUserID)) \(subscriptionID)\r\n", channel: try await connectedChannel())
        presenceSubscriptions[targetUserID] = subscriptionID
    }

    public func deactivatePresence(targetUserID: UserID) async {
        await deactivate(subscriptionID: presenceSubscriptions.removeValue(forKey: targetUserID))
    }

    public func activateTyping(roomID: RoomID) async throws {
        guard typingSubscriptions[roomID] == nil else { return }
        let subscriptionID = nextSubscriptionID
        nextSubscriptionID &+= 1
        try await write("SUB \(typingSubject(for: roomID)) \(subscriptionID)\r\n", channel: try await connectedChannel())
        typingSubscriptions[roomID] = subscriptionID
    }

    public func deactivateTyping(roomID: RoomID) async {
        await deactivate(subscriptionID: typingSubscriptions.removeValue(forKey: roomID))
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
        guard let subscriptionID, let channel, channel.isActive else { return }
        do { try await write("UNSUB \(subscriptionID)\r\n", channel: channel) }
        catch { self.channel = nil }
    }

    private func publish(_ event: WireEvent, subject: String) async {
        guard let payload = try? JSONEncoder().encode(event) else { return }
        do {
            let channel = try await connectedChannel()
            var buffer = channel.allocator.buffer(capacity: payload.count + subject.utf8.count + 32)
            buffer.writeString("PUB \(subject) \(payload.count)\r\n")
            buffer.writeBytes(payload)
            buffer.writeString("\r\n")
            try await channel.writeAndFlush(buffer).get()
        } catch { channel = nil }
    }

    private func connectedChannel() async throws -> Channel {
        if let channel, channel.isActive { return channel }
        let handler = V2NATSLiveActivityInboundHandler { [sourceID, receivePresence, receiveTyping] payload in
            guard let event = try? JSONDecoder().decode(WireEvent.self, from: payload), event.sourceID != sourceID,
                  let userID = try? UserID(event.userID)
            else { return }
            switch event.kind {
            case .presence:
                guard let isOnline = event.isOnline else { return }
                await receivePresence(userID, isOnline, event.expiresAt)
            case .typing:
                guard let room = event.roomID.flatMap({ try? RoomID($0) }), let isTyping = event.isTyping else { return }
                await receiveTyping(.init(roomID: room, userID: userID, isTyping: isTyping, expiresAt: event.expiresAt))
            }
        }
        do {
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in channel.pipeline.addHandler(handler) }
                .connect(host: configuration.url.host!, port: configuration.url.port ?? 4222).get()
            let connect = String(decoding: try JSONEncoder().encode(Connect(token: configuration.token)), as: UTF8.self)
            try await write("CONNECT \(connect)\r\n", channel: channel)
            self.channel = channel
            channel.closeFuture.whenComplete { _ in Task { await self.connectionClosed(channel) } }
            for (userID, subscriptionID) in presenceSubscriptions { try await write("SUB \(presenceSubject(for: userID)) \(subscriptionID)\r\n", channel: channel) }
            for (roomID, subscriptionID) in typingSubscriptions { try await write("SUB \(typingSubject(for: roomID)) \(subscriptionID)\r\n", channel: channel) }
            return channel
        } catch { self.channel = nil; throw V2NATSGroupEventWakeBrokerError.unavailable }
    }

    private func connectionClosed(_ closed: Channel) { if channel === closed { channel = nil } }
    private func presenceSubject(for userID: UserID) -> String { subject(kind: "presence", identifier: userID.rawValue) }
    private func typingSubject(for roomID: RoomID) -> String { subject(kind: "typing", identifier: roomID.rawValue) }
    private func subject(kind: String, identifier: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data("\(kind):\(identifier)".utf8), using: SymmetricKey(data: configuration.routingKey))
        return "\(configuration.subjectPrefix).live.\(kind).\(digest.map { String(format: "%02x", $0) }.joined())"
    }
    private func write(_ command: String, channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: command.utf8.count)
        buffer.writeString(command)
        try await channel.writeAndFlush(buffer).get()
    }
}

private final class V2NATSLiveActivityInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let onPayload: @Sendable (Data) async -> Void
    private var pending = Data()
    private var remainingPayloadBytes: Int?
    init(onPayload: @escaping @Sendable (Data) async -> Void) { self.onPayload = onPayload }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readData(length: buffer.readableBytes) { pending.append(bytes) }
        consume(context: context)
    }
    private func consume(context: ChannelHandlerContext) {
        while true {
            if let remainingPayloadBytes {
                guard pending.count >= remainingPayloadBytes + 2 else { return }
                let payload = Data(pending.prefix(remainingPayloadBytes))
                guard pending.dropFirst(remainingPayloadBytes).starts(with: [13, 10]) else { pending.removeAll(); self.remainingPayloadBytes = nil; context.close(promise: nil); return }
                pending.removeFirst(remainingPayloadBytes + 2); self.remainingPayloadBytes = nil
                Task { await onPayload(payload) }; continue
            }
            guard let range = pending.range(of: Data([13, 10])) else { return }
            let line = String(decoding: pending[..<range.lowerBound], as: UTF8.self)
            pending.removeFirst(range.upperBound)
            if line == "PING" { var pong = context.channel.allocator.buffer(capacity: 6); pong.writeString("PONG\r\n"); context.writeAndFlush(wrapOutboundOut(pong), promise: nil); continue }
            let parts = line.split(separator: " ")
            guard parts.count == 4, parts[0] == "MSG", let count = Int(parts[3]), count >= 0 else { continue }
            remainingPayloadBytes = count
        }
    }
}
