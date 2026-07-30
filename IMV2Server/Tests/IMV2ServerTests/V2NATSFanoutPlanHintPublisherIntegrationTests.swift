import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@testable import IMV2Server
import Testing

@Suite("V2 Core NATS fan-out hint")
struct V2NATSFanoutPlanHintPublisherIntegrationTests {
    @Test("a real broker delivers the privacy-safe trigger envelope to a subscriber")
    func publishesToRealBroker() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["IMV2_NATS_TEST_URL"],
              let url = URL(string: rawURL)
        else {
            // The disposable Docker suite supplies this endpoint. Keeping the
            // ordinary native package suite broker-free preserves its local
            // unit-test contract.
            return
        }
        let configuration = try V2NATSFanoutHintConfiguration(
            url: url,
            subject: "imv2.test.fanout.wake"
        )
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let handler = NATSSubscriberHandler(eventLoop: eventLoopGroup.next())
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }
            .connect(host: try #require(url.host), port: url.port ?? 4222)
            .get()
        do {
            var subscription = channel.allocator.buffer(capacity: 128)
            subscription.writeString("CONNECT {\"verbose\":false,\"pedantic\":false}\r\nSUB \(configuration.subject) 1\r\nPING\r\n")
            try await channel.writeAndFlush(subscription).get()
            try await handler.awaitSubscriptionConfirmation()

            let trigger = try V2FanoutPlanTrigger(
                sourceEventID: .init("00000000-0000-0000-0000-000000000971"),
                planID: .init("00000000-0000-0000-0000-000000000972")
            )
            try await V2NATSFanoutPlanHintPublisher(configuration: configuration).publishHint(trigger)

            let payload = try await handler.awaitPayload()
            #expect(try JSONDecoder().decode(V2NATSFanoutPlanHint.self, from: payload) == .init(trigger: trigger))
            try await channel.close().get()
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            try? await channel.close().get()
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    @Test("a broker that never acknowledges is bounded and cannot stall the durable caller")
    func timesOutWhenBrokerNeverSendsPong() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: eventLoopGroup)
            .childChannelInitializer { channel in channel.pipeline.addHandler(NATSSilentBrokerHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let port = try #require(server.localAddress?.port)
            let configuration = try V2NATSFanoutHintConfiguration(
                url: try #require(URL(string: "nats://127.0.0.1:\(port)")),
                subject: "imv2.test.fanout.timeout",
                acknowledgementTimeout: 0.05
            )
            let trigger = try V2FanoutPlanTrigger(
                sourceEventID: .init("00000000-0000-0000-0000-000000000973"),
                planID: .init("00000000-0000-0000-0000-000000000974")
            )
            let startedAt = Date()
            await #expect(throws: (any Error).self) {
                try await V2NATSFanoutPlanHintPublisher(configuration: configuration).publishHint(trigger)
            }
            // Closing the test server waits for its child channel; keep the
            // assertion about bounded publication rather than teardown speed.
            #expect(Date().timeIntervalSince(startedAt) < 2)
            try await server.close().get()
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    @Test("publisher acknowledgement timeout is bounded configuration")
    func rejectsInvalidAcknowledgementTimeout() throws {
        let url = try #require(URL(string: "nats://127.0.0.1:4222"))
        #expect(throws: V2NATSFanoutHintConfigurationError.invalidConfiguration) {
            _ = try V2NATSFanoutHintConfiguration(url: url, subject: "imv2.test", acknowledgementTimeout: 0)
        }
        #expect(throws: V2NATSFanoutHintConfigurationError.invalidConfiguration) {
            _ = try V2NATSFanoutHintConfiguration(url: url, subject: "imv2.test", acknowledgementTimeout: 31)
        }
    }

    @Test("a silent broker hint never blocks durable fan-out publication")
    func preservesDurablePublicationWhenBrokerIsUnavailable() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: eventLoopGroup)
            .childChannelInitializer { channel in channel.pipeline.addHandler(NATSSilentBrokerHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let port = try #require(server.localAddress?.port)
            let configuration = try V2NATSFanoutHintConfiguration(
                url: try #require(URL(string: "nats://127.0.0.1:\(port)")),
                subject: "imv2.test.fanout.unavailable",
                acknowledgementTimeout: 0.05
            )
            let trigger = try V2FanoutPlanTrigger(
                sourceEventID: .init("00000000-0000-0000-0000-000000000975"),
                planID: .init("00000000-0000-0000-0000-000000000976")
            )
            let durable = RecordingDurablePublisher()
            try await V2BestEffortFanoutPlanHintPublisher(
                durablePublisher: durable,
                hintPublisher: V2NATSFanoutPlanHintPublisher(configuration: configuration)
            ).publish(trigger)
            #expect(await durable.triggers() == [trigger])
            try await server.close().get()
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }
}

private actor RecordingDurablePublisher: V2FanoutPlanPublisher {
    private var values: [V2FanoutPlanTrigger] = []

    func publish(_ trigger: V2FanoutPlanTrigger) {
        values.append(trigger)
    }

    func triggers() -> [V2FanoutPlanTrigger] { values }
}

private final class NATSSilentBrokerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {
        // Deliberately consume every client byte without returning a PONG.
    }
}

/// All mutable parser state is touched only by this handler's assigned NIO
/// event loop. Futures are the thread-safe hand-off to the async test task.
private final class NATSSubscriberHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let subscriptionConfirmed: EventLoopPromise<Void>
    private let payload: EventLoopPromise<Data>
    private var pendingBytes = Data()
    private var expectedPayloadLength: Int?
    private var didResolveSubscription = false
    private var didResolvePayload = false

    init(eventLoop: any EventLoop) {
        subscriptionConfirmed = eventLoop.makePromise(of: Void.self)
        payload = eventLoop.makePromise(of: Data.self)
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let received = buffer.readData(length: buffer.readableBytes) else { return }
        pendingBytes.append(received)
        consumePendingFrames()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failPending(error)
        context.close(promise: nil)
    }

    func awaitSubscriptionConfirmation() async throws {
        try await subscriptionConfirmed.futureResult.get()
    }

    func awaitPayload() async throws -> Data {
        try await payload.futureResult.get()
    }

    private func consumePendingFrames() {
        while true {
            if let expectedPayloadLength {
                guard pendingBytes.count >= expectedPayloadLength + 2 else { return }
                let message = pendingBytes.prefix(expectedPayloadLength)
                let delimiterStart = pendingBytes.index(pendingBytes.startIndex, offsetBy: expectedPayloadLength)
                let delimiterEnd = pendingBytes.index(delimiterStart, offsetBy: 2)
                guard pendingBytes[delimiterStart..<delimiterEnd] == Data([13, 10]) else {
                    failPending(NATSSubscriberError.invalidFrame)
                    return
                }
                pendingBytes.removeFirst(expectedPayloadLength + 2)
                self.expectedPayloadLength = nil
                resolvePayload(Data(message))
                continue
            }

            guard let delimiter = pendingBytes.range(of: Data([13, 10])) else { return }
            let line = String(data: pendingBytes[..<delimiter.lowerBound], encoding: .utf8)
            pendingBytes.removeSubrange(..<delimiter.upperBound)
            guard let line else {
                failPending(NATSSubscriberError.invalidFrame)
                return
            }
            if line == "PONG" {
                resolveSubscription()
            } else if line.hasPrefix("-ERR") {
                failPending(NATSSubscriberError.brokerRejected)
                return
            } else if line.hasPrefix("MSG ") {
                let components = line.split(separator: " ")
                guard components.count == 4, let length = Int(components[3]), length >= 0 else {
                    failPending(NATSSubscriberError.invalidFrame)
                    return
                }
                expectedPayloadLength = length
            }
        }
    }

    private func resolveSubscription() {
        guard !didResolveSubscription else { return }
        didResolveSubscription = true
        subscriptionConfirmed.succeed(())
    }

    private func resolvePayload(_ value: Data) {
        guard !didResolvePayload else { return }
        didResolvePayload = true
        payload.succeed(value)
    }

    private func failPending(_ error: any Error) {
        if !didResolveSubscription {
            didResolveSubscription = true
            subscriptionConfirmed.fail(error)
        }
        if !didResolvePayload {
            didResolvePayload = true
            payload.fail(error)
        }
    }
}

private enum NATSSubscriberError: Error {
    case invalidFrame
    case brokerRejected
}
