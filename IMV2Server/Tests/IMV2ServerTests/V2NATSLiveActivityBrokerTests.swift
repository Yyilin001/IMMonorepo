import Foundation
import IMV2Core
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import Synchronization
@testable import IMV2Server
import Testing

@Suite("V2 Core NATS live activity broker")
struct V2NATSLiveActivityBrokerTests {
    @Test("a silent broker bounds presence activation latency")
    func timesOutPresenceActivationWithoutPong() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(V2NATSSilentLiveActivityTestHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port), timeout: 0.05
            )
            let startedAt = Date()
            await #expect(throws: V2NATSGroupEventWakeBrokerError.unavailable) {
                try await broker.activatePresence(
                    targetUserID: try UserID("00000000-0000-0000-0000-000000000a01")
                )
            }
            #expect(Date().timeIntervalSince(startedAt) < 2)
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("concurrent identical interests share one confirmed subscription")
    func deduplicatesConcurrentPresenceActivation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSLiveActivityTestRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    V2NATSConfirmingLiveActivityTestHandler(recorder: recorder)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port), timeout: 1
            )
            let userID = try UserID("00000000-0000-0000-0000-000000000a02")
            async let first: Void = broker.activatePresence(targetUserID: userID)
            async let second: Void = broker.activatePresence(targetUserID: userID)
            _ = try await (first, second)

            let observation = recorder.observation()
            #expect(observation.connectionCount == 1)
            #expect(observation.subscriptionCount == 1)
            #expect(observation.pingCount == 1)
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func makeBroker(port: Int, timeout: TimeInterval) throws -> V2NATSLiveActivityBroker {
        let url = try #require(URL(string: "nats://127.0.0.1:\(port)"))
        return V2NATSLiveActivityBroker(
            configuration: try .init(
                url: url,
                subjectPrefix: "imv2.test.group",
                routingKey: Data(repeating: 3, count: 32),
                acknowledgementTimeout: timeout
            ),
            receivePresence: { _, _, _ in },
            receiveTyping: { _ in }
        )
    }
}

private final class V2NATSSilentLiveActivityTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {}
}

private final class V2NATSLiveActivityTestRecorder: Sendable {
    struct Observation: Sendable {
        var connectionCount = 0
        var subscriptionCount = 0
        var pingCount = 0
    }

    private let state = Mutex(Observation())

    func recordConnection() { state.withLock { $0.connectionCount += 1 } }

    func record(commands: String) -> Int {
        state.withLock { state in
            state.subscriptionCount += commands.components(separatedBy: "SUB ").count - 1
            let pings = commands.components(separatedBy: "PING\r\n").count - 1
            state.pingCount += pings
            return pings
        }
    }

    func observation() -> Observation { state.withLock { $0 } }
}

private final class V2NATSConfirmingLiveActivityTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let recorder: V2NATSLiveActivityTestRecorder

    init(recorder: V2NATSLiveActivityTestRecorder) { self.recorder = recorder }

    func channelActive(context: ChannelHandlerContext) {
        recorder.recordConnection()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let commands = buffer.readString(length: buffer.readableBytes) ?? ""
        let pings = recorder.record(commands: commands)
        guard pings > 0 else { return }
        var response = context.channel.allocator.buffer(capacity: pings * 6)
        for _ in 0..<pings { response.writeString("PONG\r\n") }
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }
}
