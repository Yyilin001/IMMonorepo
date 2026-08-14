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
/// preceding command before the hint is considered published. The actor keeps
/// one serial connection per publisher and discards it on any failure, avoiding
/// a TCP handshake per hint without allowing a failed channel to poison a
/// later publish. The surrounding durable wrapper intentionally ignores its
/// error after the PostgreSQL planner has completed.
public actor V2NATSFanoutPlanHintPublisher: V2FanoutPlanHintPublishing {
    private struct Connect: Encodable {
        let verbose = false
        let pedantic = false
        let token: String?
    }

    private struct Connection {
        let channel: any Channel
        let handler: V2NATSConnectionHandler
    }

    private let configuration: V2NATSFanoutHintConfiguration
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var retainedConnection: Connection?

    public init(configuration: V2NATSFanoutHintConfiguration) { self.configuration = configuration }
    deinit {
        retainedConnection?.channel.close(promise: nil)
        try? eventLoopGroup.syncShutdownGracefully()
    }

    public func publishHint(_ trigger: V2FanoutPlanTrigger) async throws {
        let timeout = TimeAmount.nanoseconds(Int64(configuration.acknowledgementTimeout * 1_000_000_000))
        let connection = try await connectedChannel(timeout: timeout)
        let channel = connection.value.channel
        let acknowledgement = try connection.value.handler.beginAcknowledgement(
            eventLoop: channel.eventLoop
        )
        let watchdog = channel.eventLoop.scheduleTask(in: timeout) {
            if connection.value.handler.timeout(acknowledgement) {
                channel.close(promise: nil)
            }
        }
        defer { watchdog.cancel() }
        do {
            let payload = try JSONEncoder().encode(V2NATSFanoutPlanHint(trigger: trigger))
            let connect = String(decoding: try JSONEncoder().encode(Connect(token: configuration.token)), as: UTF8.self)
            var buffer = channel.allocator.buffer(capacity: payload.count + connect.utf8.count + configuration.subject.utf8.count + 40)
            if connection.isNew {
                buffer.writeString("CONNECT \(connect)\r\n")
            }
            buffer.writeString("PUB \(configuration.subject) \(payload.count)\r\n")
            buffer.writeBytes(payload)
            buffer.writeString("\r\nPING\r\n")
            try await channel.writeAndFlush(buffer).get()
            try await acknowledgement.awaitBrokerConfirmation()
        } catch {
            await discardRetainedConnection(connection.value)
            throw error
        }
    }

    private func connectedChannel(timeout: TimeAmount) async throws -> (value: Connection, isNew: Bool) {
        if let retainedConnection, retainedConnection.channel.isActive {
            return (retainedConnection, false)
        }
        retainedConnection = nil
        let handler = V2NATSConnectionHandler()
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.connectTimeout, value: timeout)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
            .connect(host: configuration.url.host!, port: configuration.url.port ?? 4222)
            .get()
        let connection = Connection(channel: channel, handler: handler)
        retainedConnection = connection
        return (connection, true)
    }

    private func discardRetainedConnection(_ connection: Connection) async {
        if retainedConnection?.channel === connection.channel {
            retainedConnection = nil
        }
        try? await connection.channel.close().get()
    }
}

/// One handler owns the lifetime of a retained Core NATS connection. Besides
/// correlating the publisher's serial PING/PONG acknowledgement, it answers
/// broker-initiated PING frames while the connection is otherwise idle.
private final class V2NATSConnectionHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private struct State: Sendable {
        var pendingBytes = Data()
        var acknowledgement: V2NATSPublishAcknowledgement?
    }

    private enum InboundAction {
        case answerPing
        case confirm(V2NATSPublishAcknowledgement)
        case fail(V2NATSPublishAcknowledgement?, V2NATSPublishError)
    }

    private let state = Mutex(State())

    func beginAcknowledgement(eventLoop: any EventLoop) throws -> V2NATSPublishAcknowledgement {
        let acknowledgement = V2NATSPublishAcknowledgement(eventLoop: eventLoop)
        let installed = state.withLock { state in
            guard state.acknowledgement == nil else { return false }
            state.acknowledgement = acknowledgement
            return true
        }
        guard installed else { throw V2NATSPublishError.overlappingPublish }
        return acknowledgement
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let received = buffer.readData(length: buffer.readableBytes) else { return }
        for action in consumeLines(received) {
            switch action {
            case .answerPing:
                var response = context.channel.allocator.buffer(capacity: 6)
                response.writeString("PONG\r\n")
                context.writeAndFlush(NIOAny(response), promise: nil)
            case .confirm(let acknowledgement):
                acknowledgement.succeed()
            case .fail(let acknowledgement, let error):
                acknowledgement?.fail(error)
                context.close(promise: nil)
            }
        }
    }

    func channelInactive(context _: ChannelHandlerContext) {
        failPending(V2NATSPublishError.connectionClosedBeforeConfirmation)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failPending(error)
        context.close(promise: nil)
    }

    /// Called only by the channel's own event-loop watchdog.
    @discardableResult
    func timeout(_ acknowledgement: V2NATSPublishAcknowledgement) -> Bool {
        let shouldFail = state.withLock { state in
            guard state.acknowledgement === acknowledgement else { return false }
            state.acknowledgement = nil
            return true
        }
        if shouldFail {
            acknowledgement.fail(V2NATSPublishError.acknowledgementTimedOut)
        }
        return shouldFail
    }

    private func consumeLines(_ received: Data) -> [InboundAction] {
        state.withLock { state in
            var actions: [InboundAction] = []
            state.pendingBytes.append(received)
            guard state.pendingBytes.count <= 64 * 1_024 else {
                let acknowledgement = state.acknowledgement
                state.acknowledgement = nil
                state.pendingBytes.removeAll(keepingCapacity: false)
                return [.fail(acknowledgement, .invalidBrokerFrame)]
            }
            parsing: while let delimiter = state.pendingBytes.range(of: Data([13, 10])) {
                let line = String(data: state.pendingBytes[..<delimiter.lowerBound], encoding: .utf8)
                state.pendingBytes.removeSubrange(..<delimiter.upperBound)
                guard let line else {
                    let acknowledgement = state.acknowledgement
                    state.acknowledgement = nil
                    actions.append(.fail(acknowledgement, .invalidBrokerFrame))
                    break parsing
                }
                switch line {
                case "PING":
                    actions.append(.answerPing)
                case "PONG":
                    if let acknowledgement = state.acknowledgement {
                        state.acknowledgement = nil
                        actions.append(.confirm(acknowledgement))
                    }
                case let error where error.hasPrefix("-ERR"):
                    let acknowledgement = state.acknowledgement
                    state.acknowledgement = nil
                    actions.append(.fail(acknowledgement, .brokerRejected))
                    break parsing
                default:
                    // Initial INFO and optional +OK lines precede the PONG.
                    continue
                }
            }
            return actions
        }
    }

    private func failPending(_ error: any Error) {
        let acknowledgement = state.withLock { state in
            defer { state.acknowledgement = nil }
            return state.acknowledgement
        }
        acknowledgement?.fail(error)
    }
}

/// The acknowledgement can be completed by an event-loop callback, the
/// watchdog, or channel shutdown. A mutex keeps completion one-shot.
private final class V2NATSPublishAcknowledgement: Sendable {
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
        didResolve.withLock { didResolve in
            guard !didResolve else { return false }
            didResolve = true
            return true
        }
    }
}

private enum V2NATSPublishError: Error, Equatable, Sendable {
    case acknowledgementTimedOut
    case connectionClosedBeforeConfirmation
    case invalidBrokerFrame
    case brokerRejected
    case overlappingPublish
}

public struct V2BestEffortFanoutPlanHintPublisher: V2FanoutPlanPublisher {
    private let durablePublisher: any V2FanoutPlanPublisher
    private let hints: V2AsynchronousFanoutHintDispatcher

    public init(durablePublisher: any V2FanoutPlanPublisher, hintPublisher: any V2FanoutPlanHintPublishing) {
        self.durablePublisher = durablePublisher
        hints = .init(publisher: hintPublisher)
    }

    public func publish(_ trigger: V2FanoutPlanTrigger) async throws {
        try await durablePublisher.publish(trigger)
        hints.submit(trigger)
    }
}

/// PostgreSQL publication is the correctness boundary. Optional broker PING /
/// PONG latency belongs to one bounded background lane and never extends an
/// outbox relay transaction or delays the next durable trigger.
private final class V2AsynchronousFanoutHintDispatcher: @unchecked Sendable {
    private let continuation: AsyncStream<V2FanoutPlanTrigger>.Continuation
    private let worker: Task<Void, Never>

    init(publisher: any V2FanoutPlanHintPublishing, capacity: Int = 256) {
        precondition(capacity > 0)
        let (stream, continuation) = AsyncStream<V2FanoutPlanTrigger>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        self.continuation = continuation
        worker = Task {
            for await trigger in stream {
                guard !Task.isCancelled else { break }
                try? await publisher.publishHint(trigger)
            }
        }
    }

    func submit(_ trigger: V2FanoutPlanTrigger) {
        continuation.yield(trigger)
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }
}
