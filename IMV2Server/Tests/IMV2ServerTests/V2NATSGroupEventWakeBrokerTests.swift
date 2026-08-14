import Foundation
import IMV2Core
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import Synchronization
@testable import IMV2Server
import Testing

@Suite("V2 Core NATS group wake broker")
struct V2NATSGroupEventWakeBrokerTests {
    @Test("configuration bounds broker acknowledgement latency")
    func rejectsInvalidAcknowledgementTimeout() throws {
        let url = try #require(URL(string: "nats://127.0.0.1:4222"))
        let key = Data(repeating: 7, count: 32)
        #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
            _ = try V2NATSGroupEventWakeConfiguration(
                url: url,
                subjectPrefix: "imv2.test.group",
                routingKey: key,
                acknowledgementTimeout: 0
            )
        }
        #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
            _ = try V2NATSGroupEventWakeConfiguration(
                url: url,
                subjectPrefix: "imv2.test.group",
                routingKey: key,
                acknowledgementTimeout: 31
            )
        }
    }

    @Test("a silent broker cannot indefinitely retain durable wake work")
    func timesOutWithoutPong() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in channel.pipeline.addHandler(V2NATSSilentGroupWakeTestHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(port: try #require(server.localAddress?.port), timeout: 0.05)
            let startedAt = Date()
            await #expect(throws: V2NATSGroupEventWakeBrokerError.unavailable) {
                try await broker.publish(.init(
                    roomID: try RoomID("00000000-0000-0000-0000-000000000901"),
                    highWatermark: 4
                ))
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

    @Test("broker rejection fails activation instead of installing a phantom interest")
    func rejectsBrokerError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in channel.pipeline.addHandler(V2NATSRejectingGroupWakeTestHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(port: try #require(server.localAddress?.port), timeout: 1)
            await #expect(throws: V2NATSGroupEventWakeBrokerError.unavailable) {
                try await broker.activate(roomID: try RoomID("00000000-0000-0000-0000-000000000902"))
            }
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("concurrent interests share one confirmed connection and publishing waits for PONG")
    func serializesConnectionAndConfirmsCommands() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSGroupWakeTestRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(V2NATSConfirmingGroupWakeTestHandler(recorder: recorder))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(port: try #require(server.localAddress?.port), timeout: 1)
            let first = try RoomID("00000000-0000-0000-0000-000000000903")
            let second = try RoomID("00000000-0000-0000-0000-000000000904")
            async let firstActivation: Void = broker.activate(roomID: first)
            async let secondActivation: Void = broker.activate(roomID: second)
            _ = try await (firstActivation, secondActivation)
            try await broker.publish(.init(roomID: first, highWatermark: 9))

            let observation = recorder.observation()
            #expect(observation.connectionCount == 1)
            #expect(observation.subscriptionCount == 2)
            #expect(observation.publishCount == 1)
            // Both interests may be coalesced into the initial confirmed
            // replay, or the second may become one incremental SUB.
            #expect((2...3).contains(observation.pingCount))
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("deactivation during connection replay removes the broker subscription")
    func deactivationDuringReplayCompensatesSubscription() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSDelayedConfirmationRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    V2NATSDelayedConfirmationTestHandler(recorder: recorder)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(port: try #require(server.localAddress?.port), timeout: 1)
            let roomID = try RoomID("00000000-0000-0000-0000-000000000905")
            let activation = Task { try await broker.activate(roomID: roomID) }
            try await recorder.waitForInitialPing()

            await broker.deactivate(roomID: roomID)
            recorder.releaseInitialPong()
            await #expect(throws: CancellationError.self) { try await activation.value }
            try await recorder.waitForUnsubscribe()

            let observation = recorder.observation()
            #expect(observation.subscriptionCount == 1)
            #expect(observation.unsubscribeCount >= 1)
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func makeBroker(port: Int, timeout: TimeInterval) throws -> V2NATSGroupEventWakeBroker {
        let url = try #require(URL(string: "nats://127.0.0.1:\(port)"))
        return V2NATSGroupEventWakeBroker(
            configuration: try .init(
                url: url,
                subjectPrefix: "imv2.test.group",
                routingKey: Data(repeating: 9, count: 32),
                acknowledgementTimeout: timeout
            ),
            receiveWake: { _ in }
        )
    }
}

private final class V2NATSDelayedConfirmationRecorder: Sendable {
    struct Observation: Sendable {
        var subscriptionCount = 0
        var unsubscribeCount = 0
        var pingCount = 0
    }

    private struct State {
        var observation = Observation()
        var initialChannel: (any Channel)?
        var released = false
    }

    private let state = Mutex(State())

    func record(commands: String, channel: any Channel) -> Int {
        state.withLock { state in
            for line in commands.components(separatedBy: "\r\n") {
                if line.hasPrefix("SUB ") { state.observation.subscriptionCount += 1 }
                if line.hasPrefix("UNSUB ") { state.observation.unsubscribeCount += 1 }
                if line == "PING" { state.observation.pingCount += 1 }
            }
            if state.initialChannel == nil {
                state.initialChannel = channel
                return 0
            }
            return commands.components(separatedBy: "PING\r\n").count - 1
        }
    }

    func releaseInitialPong() {
        let channel = state.withLock { state -> (any Channel)? in
            state.released = true
            return state.initialChannel
        }
        guard let channel else { return }
        var response = channel.allocator.buffer(capacity: 6)
        response.writeString("PONG\r\n")
        channel.writeAndFlush(response, promise: nil)
    }

    func waitForInitialPing() async throws {
        for _ in 0..<100 {
            if state.withLock({ $0.observation.pingCount > 0 }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw V2NATSDelayedConfirmationTestError.timeout
    }

    func waitForUnsubscribe() async throws {
        for _ in 0..<100 {
            if state.withLock({ $0.observation.unsubscribeCount > 0 }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw V2NATSDelayedConfirmationTestError.timeout
    }

    func observation() -> Observation { state.withLock { $0.observation } }
}

private final class V2NATSDelayedConfirmationTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let recorder: V2NATSDelayedConfirmationRecorder

    init(recorder: V2NATSDelayedConfirmationRecorder) { self.recorder = recorder }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let commands = buffer.readString(length: buffer.readableBytes) ?? ""
        let pings = recorder.record(commands: commands, channel: context.channel)
        guard pings > 0 else { return }
        var response = context.channel.allocator.buffer(capacity: pings * 6)
        for _ in 0..<pings { response.writeString("PONG\r\n") }
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }
}

private enum V2NATSDelayedConfirmationTestError: Error { case timeout }

private final class V2NATSSilentGroupWakeTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {}
}

private final class V2NATSRejectingGroupWakeTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data _: NIOAny) {
        var response = context.channel.allocator.buffer(capacity: 34)
        response.writeString("-ERR 'Authorization Violation'\r\n")
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }
}

private final class V2NATSGroupWakeTestRecorder: Sendable {
    struct Observation: Sendable {
        var connectionCount = 0
        var subscriptionCount = 0
        var publishCount = 0
        var pingCount = 0
    }

    private let state = Mutex(Observation())

    func recordConnection() { state.withLock { $0.connectionCount += 1 } }
    func record(commands: String) -> Int {
        state.withLock { state in
            state.subscriptionCount += commands.components(separatedBy: "SUB ").count - 1
            state.publishCount += commands.components(separatedBy: "PUB ").count - 1
            let pings = commands.components(separatedBy: "PING\r\n").count - 1
            state.pingCount += pings
            return pings
        }
    }
    func observation() -> Observation { state.withLock { $0 } }
}

private final class V2NATSConfirmingGroupWakeTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let recorder: V2NATSGroupWakeTestRecorder

    init(recorder: V2NATSGroupWakeTestRecorder) { self.recorder = recorder }

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
