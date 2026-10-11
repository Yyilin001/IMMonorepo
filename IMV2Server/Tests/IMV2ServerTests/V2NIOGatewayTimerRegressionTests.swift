@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("V2 NIO gateway timer regressions", .timeLimit(.minutes(1)))
struct V2NIOGatewayTimerRegressionTests {
    @Test("authenticated suspended requests neither expire nor retain a disconnected registration", arguments: [false, true], [1, 256])
    func authenticatedBatchDoesNotExpireDuringSlowCommand(closeBeforeRelease: Bool, frameBatchLimit: Int) async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let command = SuspendedGatewayCommand()
        let stream = try makeStream(registry: registry, handler: command, frameBatchLimit: frameBatchLimit)
        let channel = NIOAsyncTestingChannel()
        let metrics = V2GatewayTransportMetrics()
        try await channel.testingEventLoop.executeInContext {
            try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(
                stream: stream,
                maximumQueuedInboundBytes: 16_384,
                maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 100,
                idleTimeoutMilliseconds: 60_000,
                transportMetrics: metrics
            ))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()

        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello.deviceID = deviceID
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        var auth = IMV2Envelope()
        auth.requestID = 2
        auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "opaque"
        auth.authenticate.deviceID = deviceID
        var commandFrame = IMV2Envelope()
        commandFrame.requestID = 3
        commandFrame.protocolVersion = UInt32(version)
        commandFrame.syncPull = .init()
        let bytes = try encoded(hello, version: 0) + encoded(auth, version: version)
            + encoded(commandFrame, version: version)
        var inbound = channel.allocator.buffer(capacity: bytes.count)
        inbound.writeBytes(bytes)
        _ = try await channel.writeInbound(inbound)
        await command.waitUntilStarted()

        await channel.testingEventLoop.advanceTime(by: .milliseconds(101))
        #expect(channel.isActive)
        #expect((await metrics.gatewayTransportMetricsSnapshot()).closureCount(for: .authenticationTimeout) == 0)

        #expect(await registry.connectionMetricsSnapshot().activeConnections == 1)
        if closeBeforeRelease {
            try await channel.close().get()
            #expect((await metrics.gatewayTransportMetricsSnapshot()).closureCount(for: .peerDisconnected) == 1)
            let deadline = ContinuousClock.now + .seconds(2)
            while await registry.connectionMetricsSnapshot().activeConnections != 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            // The command ignores cancellation until its gate is released.
            // Transport retirement must not wait for that release.
            #expect(await registry.connectionMetricsSnapshot().activeConnections == 0)
        }

        await command.release()
        if !closeBeforeRelease { try await channel.close().get() }
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("idle check reschedules only the remaining time")
    func idleCheckUsesRemainingDeadline() async throws {
        let clock = Mutex<UInt64>(0)
        let stream = try makeStream(registry: V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits), handler: ImmediateGatewayCommand())
        let channel = NIOAsyncTestingChannel()
        let metrics = V2GatewayTransportMetrics()
        try await channel.testingEventLoop.executeInContext {
            try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(
                stream: stream,
                maximumQueuedInboundBytes: 4_096,
                maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 1_000,
                idleTimeoutMilliseconds: 100,
                transportMetrics: metrics,
                foregroundWriteScheduler: .init(),
                now: { NIODeadline.uptimeNanoseconds(clock.withLock { $0 }) }
            ))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()

        clock.withLock { $0 = 40_000_000 }
        await channel.testingEventLoop.advanceTime(by: .milliseconds(40))
        var partialFrame = channel.allocator.buffer(capacity: 1)
        partialFrame.writeInteger(UInt8(0))
        _ = try await channel.writeInbound(partialFrame)
        clock.withLock { $0 = 100_000_000 }
        await channel.testingEventLoop.advanceTime(by: .milliseconds(60))
        #expect(channel.isActive)
        clock.withLock { $0 = 139_000_000 }
        await channel.testingEventLoop.advanceTime(by: .milliseconds(39))
        #expect(channel.isActive)
        clock.withLock { $0 = 140_000_000 }
        await channel.testingEventLoop.advanceTime(by: .milliseconds(1))
        try await channel.closeFuture.get()
        #expect(!channel.isActive)
        #expect((await metrics.gatewayTransportMetricsSnapshot()).closureCount(for: .idleTimeout) == 1)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("transport keeps fragmented frames until complete and diagnoses partial EOF")
    func fragmentedFrameAndPartialEOF() async throws {
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let stream = try makeStream(registry: registry, handler: ImmediateGatewayCommand(), frameBatchLimit: 1)
        let channel = NIOAsyncTestingChannel()
        let metrics = V2GatewayTransportMetrics()
        try await channel.testingEventLoop.executeInContext {
            try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(
                stream: stream, maximumQueuedInboundBytes: 16_384, maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 60_000, idleTimeoutMilliseconds: 60_000,
                transportMetrics: metrics))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello.deviceID = deviceID
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        let bytes = try encoded(hello, version: 0)
        // Feed the header and payload separately. No complete request exists
        // at the first boundary, so the channel must not produce a response.
        var prefix = channel.allocator.buffer(capacity: V2Frame.headerLength - 1)
        prefix.writeBytes(bytes.prefix(V2Frame.headerLength - 1))
        _ = try await channel.writeInbound(prefix)
        #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
        var suffix = channel.allocator.buffer(capacity: bytes.count)
        suffix.writeBytes(bytes.dropFirst(V2Frame.headerLength - 1))
        _ = try await channel.writeInbound(suffix)
        var response: ByteBuffer?
        let deadline = ContinuousClock.now + .seconds(2)
        while response == nil, ContinuousClock.now < deadline {
            response = try await channel.readOutbound(as: ByteBuffer.self)
            if response == nil { try await Task.sleep(for: .milliseconds(1)) }
        }
        let complete = try #require(response)
        #expect(try V2FrameCodec.decodeExactlyOne(Data(complete.readableBytesView),
            limits: .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])).requestID == 1)
        var partial = channel.allocator.buffer(capacity: 1)
        partial.writeInteger(UInt8(0))
        _ = try await channel.writeInbound(partial)
        try await channel.close().get()
        #expect((await metrics.gatewayTransportMetricsSnapshot()).closureCount(for: .requestFailure) == 1)
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("transport large-frame limit changes only after negotiated authentication", arguments: [false, true])
    func negotiatedLargeTransportFrame(authenticate: Bool) async throws {
        let limits = try V2FrameLimits(maximumPayloadBytes: 256, maximumMessageSendPayloadBytes: 4_096,
            maximumFramesPerAppend: 1, acceptedVersions: [0, version])
        let command = CountingGatewayCommand()
        let stream = V2GatewayByteStream(frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 4),
                authenticator: GatewayTimerAuthenticator(), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: command, registry: V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits))
        let channel = NIOAsyncTestingChannel()
        let metrics = V2GatewayTransportMetrics()
        try await channel.testingEventLoop.executeInContext {
            try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(
                stream: stream, maximumQueuedInboundBytes: 16_384, maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 60_000, idleTimeoutMilliseconds: 60_000,
                transportMetrics: metrics))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        if authenticate {
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello.deviceID = deviceID
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            hello.clientHello.supportsMessageSendOperations = true
            var auth = IMV2Envelope()
            auth.requestID = 2
            auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "opaque"
            auth.authenticate.deviceID = deviceID
            var input = channel.allocator.buffer(capacity: 512)
            for (envelope, frameVersion) in [(hello, UInt8(0)), (auth, version)] {
                input.writeBytes(try V2FrameCodec.encode(
                    V2ServerProtobufFrameCodec.encode(envelope, frameVersion: frameVersion), limits: limits))
            }
            _ = try await channel.writeInbound(input)
            let deadline = ContinuousClock.now + .seconds(2)
            while !(await stream.isAuthenticated()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await stream.isAuthenticated())
        }
        let send = try V2MessageSendOperationCommand(command: .init(
            roomID: .init("00000000-0000-0000-0000-000000000f03"),
            senderUserID: .init("00000000-0000-0000-0000-000000000f02"),
            clientMessageID: .init(uuid: UUID()), text: String(repeating: "a", count: 512),
            limits: .init(maxUTF8Bytes: 1_024)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 60_000)
        var envelope = IMV2Envelope()
        envelope.requestID = 3
        envelope.protocolVersion = UInt32(version)
        envelope.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: send)
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version)
        #expect(frame.payload.count > limits.maximumPayloadBytes)
        var input = channel.allocator.buffer(capacity: 1_024)
        input.writeBytes(try V2FrameCodec.encode(frame, limits: limits))
        _ = try await channel.writeInbound(input)
        let deadline = ContinuousClock.now + .seconds(2)
        if authenticate {
            while await command.count == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await command.count == 1)
            #expect(channel.isActive)
            try await channel.close().get()
        } else {
            try await channel.closeFuture.get()
            #expect(await command.count == 0)
            #expect((await metrics.gatewayTransportMetricsSnapshot()).closureCount(for: .frameLimitViolation) == 1)
        }
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    private var version: UInt8 { UInt8(IMV2ProtocolVersion.current) }
    private var deviceID: String { "00000000-0000-0000-0000-000000000f01" }

    private func makeStream(
        registry: V2DeviceConnectionRegistry,
        handler: any V2GatewayCommandHandler,
        frameBatchLimit: Int = 256
    ) throws -> V2GatewayByteStream {
        V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, maximumFramesPerAppend: frameBatchLimit, acceptedVersions: [0, version]),
            session: .init(
                limits: try .init(maximumInFlightRequests: 1),
                authenticator: GatewayTimerAuthenticator(),
                capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()
            ),
            handler: handler,
            registry: registry
        )
    }

    private func encoded(_ envelope: IMV2Envelope, version: UInt8) throws -> Data {
        try V2FrameCodec.encode(
            V2ServerProtobufFrameCodec.encode(envelope, frameVersion: version),
            limits: .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, self.version])
        )
    }
}

private struct GatewayTimerAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000f02"), expiresAt: nil)
    }
}

private actor SuspendedGatewayCommand: V2GatewayCommandHandler {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { resume = $0 }
        var response = IMV2Envelope()
        response.error.code = "UNAVAILABLE"
        return response
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() { resume?.resume(); resume = nil }
}

private struct ImmediateGatewayCommand: V2GatewayCommandHandler {
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        .init()
    }
}

private actor CountingGatewayCommand: V2GatewayCommandHandler {
    private(set) var count = 0
    func handle(envelope _: IMV2Envelope, identity _: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        count += 1
        var response = IMV2Envelope()
        response.error.code = "UNAVAILABLE"
        return response
    }
}
