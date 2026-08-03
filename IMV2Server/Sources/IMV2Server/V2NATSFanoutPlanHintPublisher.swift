import Foundation
import Synchronization
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// A non-authoritative wake hint. Consumers reload every durable fact from
/// PostgreSQL; a lost or duplicated hint cannot decide work completion.
public struct V2NATSFanoutPlanHint: Codable, Equatable, Sendable {
    public let sourceEventID: String
    public let planID: String

    public init(trigger: V2FanoutPlanTrigger) {
        sourceEventID = trigger.sourceEventID.rawValue
        planID = trigger.planID.rawValue
    }
}

public struct V2NATSFanoutHintConfiguration: Equatable, Sendable {
    public let url: URL
    public let subject: String
    public let token: String?
    /// Bounds an optional wake hint. Durable PostgreSQL progression must never
    /// wait indefinitely for an unresponsive broker connection.
    public let acknowledgementTimeout: TimeInterval

    public init(
        url: URL,
        subject: String,
        token: String? = nil,
        acknowledgementTimeout: TimeInterval = 2
    ) throws {
        guard url.scheme?.lowercased() == "nats", url.host != nil,
              subject.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil,
              acknowledgementTimeout.isFinite,
              acknowledgementTimeout > 0,
              acknowledgementTimeout <= 30
        else { throw V2NATSFanoutHintConfigurationError.invalidConfiguration }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != true else { throw V2NATSFanoutHintConfigurationError.invalidConfiguration }
        self.url = url
        self.subject = subject
        self.token = normalizedToken
        self.acknowledgementTimeout = acknowledgementTimeout
    }
}

public enum V2NATSFanoutHintConfigurationError: Error, Equatable, Sendable { case invalidConfiguration }

public protocol V2FanoutPlanHintPublishing: Sendable {
    func publishHint(_ trigger: V2FanoutPlanTrigger) async throws
}

/// Minimal Core NATS CONNECT/PUB publisher built only on the runtime's NIO
/// dependencies. A `PING` after `PUB` requires the broker to parse every
/// preceding command before the hint is considered published. Each hint obtains
/// a fresh connection, so a failed channel is never retained. The surrounding
/// durable wrapper intentionally ignores its error after the PostgreSQL
/// planner has completed.
public actor V2NATSFanoutPlanHintPublisher: V2FanoutPlanHintPublishing {
    private struct Connect: Encodable {
        let verbose = false
        let pedantic = false
        let token: String?
    }

    private let configuration: V2NATSFanoutHintConfiguration
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public init(configuration: V2NATSFanoutHintConfiguration) { self.configuration = configuration }
    deinit { try? eventLoopGroup.syncShutdownGracefully() }

    public func publishHint(_ trigger: V2FanoutPlanTrigger) async throws {
        let timeout = TimeAmount.nanoseconds(Int64(configuration.acknowledgementTimeout * 1_000_000_000))
        // The group has one loop, so this promise is created on the same event
        // loop that invokes the handler. Keeping the state inside the handler
        // avoids touching NIO objects from the actor executor.
        let acknowledgement = V2NATSPublishAcknowledgement(eventLoop: eventLoopGroup.next())
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.connectTimeout, value: timeout)
            .channelInitializer { channel in channel.pipeline.addHandler(acknowledgement) }
            .connect(host: configuration.url.host!, port: configuration.url.port ?? 4222)
            .get()
        defer { channel.close(promise: nil) }
        let watchdog = channel.eventLoop.scheduleTask(in: timeout) {
            acknowledgement.timeout()
        }
        defer { watchdog.cancel() }
        let payload = try JSONEncoder().encode(V2NATSFanoutPlanHint(trigger: trigger))
        let connect = String(decoding: try JSONEncoder().encode(Connect(token: configuration.token)), as: UTF8.self)
        var buffer = channel.allocator.buffer(capacity: payload.count + connect.utf8.count + configuration.subject.utf8.count + 40)
        buffer.writeString("CONNECT \(connect)\r\nPUB \(configuration.subject) \(payload.count)\r\n")
        buffer.writeBytes(payload)
        buffer.writeString("\r\nPING\r\n")
        try await channel.writeAndFlush(buffer).get()
        try await acknowledgement.awaitBrokerConfirmation()
    }
}

/// The acknowledgement can be completed by an event-loop callback, the
/// watchdog, or channel shutdown. A mutex makes that one-shot state explicit
/// instead of relying on an unchecked Sendable conformance.
private final class V2NATSPublishAcknowledgement: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private struct State: Sendable {
        var pendingBytes = Data()
        var didResolve = false
    }

    private enum InboundResolution {
        case confirmed
        case invalidFrame
        case brokerRejected
    }

    private let confirmation: EventLoopPromise<Void>
    private let state = Mutex(State())

    init(eventLoop: any EventLoop) {
        confirmation = eventLoop.makePromise(of: Void.self)
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let received = buffer.readData(length: buffer.readableBytes) else { return }
        switch consumeLines(received) {
        case .confirmed:
            confirmation.succeed(())
        case .invalidFrame:
            confirmation.fail(V2NATSPublishError.invalidBrokerFrame)
        case .brokerRejected:
            confirmation.fail(V2NATSPublishError.brokerRejected)
        case nil:
            break
        }
    }

    func channelInactive(context _: ChannelHandlerContext) {
        failIfPending(V2NATSPublishError.connectionClosedBeforeConfirmation)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failIfPending(error)
        context.close(promise: nil)
    }

    func awaitBrokerConfirmation() async throws {
        try await confirmation.futureResult.get()
    }

    /// Called only by the channel's own event-loop watchdog.
    func timeout() {
        failIfPending(V2NATSPublishError.acknowledgementTimedOut)
    }

    private func consumeLines(_ received: Data) -> InboundResolution? {
        state.withLock { state in
            guard !state.didResolve else { return nil }
            state.pendingBytes.append(received)
            while let delimiter = state.pendingBytes.range(of: Data([13, 10])) {
                let line = String(data: state.pendingBytes[..<delimiter.lowerBound], encoding: .utf8)
                state.pendingBytes.removeSubrange(..<delimiter.upperBound)
                guard let line else {
                    state.didResolve = true
                    return .invalidFrame
                }
                switch line {
                case "PONG":
                    state.didResolve = true
                    return .confirmed
                case let error where error.hasPrefix("-ERR"):
                    state.didResolve = true
                    return .brokerRejected
                default:
                    // Initial INFO and optional +OK lines precede the PONG.
                    continue
                }
            }
            return nil
        }
    }

    private func failIfPending(_ error: any Error) {
        let shouldFail = state.withLock { state in
            guard !state.didResolve else { return false }
            state.didResolve = true
            return true
        }
        if shouldFail {
            confirmation.fail(error)
        }
    }
}

private enum V2NATSPublishError: Error, Equatable, Sendable {
    case acknowledgementTimedOut
    case connectionClosedBeforeConfirmation
    case invalidBrokerFrame
    case brokerRejected
}

public struct V2BestEffortFanoutPlanHintPublisher: V2FanoutPlanPublisher {
    private let durablePublisher: any V2FanoutPlanPublisher
    private let hintPublisher: any V2FanoutPlanHintPublishing

    public init(durablePublisher: any V2FanoutPlanPublisher, hintPublisher: any V2FanoutPlanHintPublishing) {
        self.durablePublisher = durablePublisher
        self.hintPublisher = hintPublisher
    }

    public func publish(_ trigger: V2FanoutPlanTrigger) async throws {
        try await durablePublisher.publish(trigger)
        try? await hintPublisher.publishHint(trigger)
    }
}
