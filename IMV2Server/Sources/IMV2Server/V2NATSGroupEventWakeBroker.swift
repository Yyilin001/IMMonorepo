import Foundation
import IMV2Core
import Crypto
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

    public init(url: URL, subjectPrefix: String, token: String? = nil, routingKey: Data) throws {
        let normalizedPrefix = subjectPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.scheme?.lowercased() == "nats", url.host != nil,
              normalizedPrefix.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != true, routingKey.count >= 32
        else { throw V2NATSGroupEventWakeBrokerError.invalidConfiguration }
        self.url = url
        self.subjectPrefix = normalizedPrefix
        self.token = normalizedToken
        self.routingKey = routingKey
    }
}

public enum V2NATSGroupEventWakeBrokerError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unavailable
    case invalidPayload
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

        enum CodingKeys: String, CodingKey {
            case roomID = "room_id"
            case highWatermark = "high_watermark"
        }
    }

    private let configuration: V2NATSGroupEventWakeConfiguration
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let receiveWake: @Sendable (V2GroupEventWake) async -> Void
    private var channel: Channel?
    private var subscriptions: [RoomID: Int] = [:]
    private var nextSubscriptionID = 1

    public init(
        configuration: V2NATSGroupEventWakeConfiguration,
        receiveWake: @escaping @Sendable (V2GroupEventWake) async -> Void
    ) {
        self.configuration = configuration
        self.receiveWake = receiveWake
    }

    deinit { try? eventLoopGroup.syncShutdownGracefully() }

    public func activate(roomID: RoomID) async throws {
        guard subscriptions[roomID] == nil else { return }
        let channel = try await connectedChannel()
        let subscriptionID = nextSubscriptionID
        nextSubscriptionID &+= 1
        try await write("SUB \(subject(for: roomID)) \(subscriptionID)\r\n", channel: channel)
        subscriptions[roomID] = subscriptionID
    }

    public func deactivate(roomID: RoomID) async {
        guard let subscriptionID = subscriptions.removeValue(forKey: roomID) else { return }
        guard let channel, channel.isActive else { return }
        do {
            try await write("UNSUB \(subscriptionID)\r\n", channel: channel)
        } catch {
            // The local registry has already removed its final viewer. A
            // reconnect will replay only still-active room interests.
            self.channel = nil
        }
    }

    public func publish(_ wake: V2GroupEventWake) async throws {
        let channel = try await connectedChannel()
        let payload = try JSONEncoder().encode(WireWake(roomID: wake.roomID.rawValue, highWatermark: wake.highWatermark))
        var buffer = channel.allocator.buffer(capacity: payload.count + configuration.subjectPrefix.utf8.count + 64)
        buffer.writeString("PUB \(subject(for: wake.roomID)) \(payload.count)\r\n")
        buffer.writeBytes(payload)
        buffer.writeString("\r\n")
        do {
            try await channel.writeAndFlush(buffer).get()
        } catch {
            self.channel = nil
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
    }

    /// A foreground hint is intentionally lossy. Do not propagate a broker
    /// outage back into the sender's accepted response; durable fan-out or
    /// Hybrid wake-outbox recovery still supplies correctness.
    public func publishForegroundHint(_ hint: V2GroupEventWake) async {
        try? await publish(hint)
    }

    private func connectedChannel() async throws -> Channel {
        if let channel, channel.isActive { return channel }
        do {
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { [receiveWake] channel in
                    let handler = V2NATSGroupEventWakeInboundHandler(
                        eventLoop: channel.eventLoop
                    ) { payload in
                        guard let wire = try? JSONDecoder().decode(WireWake.self, from: payload),
                              let roomID = try? RoomID(wire.roomID)
                        else { return }
                        await receiveWake(.init(roomID: roomID, highWatermark: wire.highWatermark))
                    }
                    return channel.pipeline.addHandler(handler)
                }
                .connect(host: configuration.url.host!, port: configuration.url.port ?? 4222)
                .get()
            let connect = String(decoding: try JSONEncoder().encode(Connect(token: configuration.token)), as: UTF8.self)
            try await write("CONNECT \(connect)\r\n", channel: channel)
            self.channel = channel
            channel.closeFuture.whenComplete { _ in
                Task { await self.connectionClosed(channel) }
            }
            // A reconnect intentionally replays exactly the current local
            // interests, not historical room membership or durable consumers.
            for (roomID, subscriptionID) in subscriptions {
                try await write("SUB \(subject(for: roomID)) \(subscriptionID)\r\n", channel: channel)
            }
            return channel
        } catch {
            self.channel = nil
            throw V2NATSGroupEventWakeBrokerError.unavailable
        }
    }

    private func connectionClosed(_ closed: Channel) {
        guard channel === closed else { return }
        channel = nil
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

    private func write(_ command: String, channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: command.utf8.count)
        buffer.writeString(command)
        try await channel.writeAndFlush(buffer).get()
    }
}

/// Its parser state is runtime-checked against its owning event loop; all
/// application state crosses into an actor via the supplied Sendable callback.
private final class V2NATSGroupEventWakeInboundHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let onPayload: @Sendable (Data) async -> Void
    private let parser: NIOLoopBoundBox<V2NATSInboundFrameParser>

    init(eventLoop: any EventLoop, onPayload: @escaping @Sendable (Data) async -> Void) {
        self.onPayload = onPayload
        parser = .init(.init(invalidMessagePolicy: .closeChannel), eventLoop: eventLoop)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readData(length: buffer.readableBytes) else { return }
        for output in parser.withValue({ $0.consume(bytes) }) {
            switch output {
            case .payload(let payload):
                Task { await onPayload(payload) }
            case .pong:
                var pong = context.channel.allocator.buffer(capacity: 6)
                pong.writeString("PONG\r\n")
                context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
            case .closeChannel:
                context.close(promise: nil)
                return
            }
        }
    }
}
