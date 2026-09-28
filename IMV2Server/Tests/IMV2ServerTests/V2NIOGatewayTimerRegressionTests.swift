import Foundation
import IMV2Core
import NIOCore
import NIOEmbedded
import Synchronization
@testable import IMV2Server
import Testing

@Suite("V2 NIO gateway timer regressions", .timeLimit(.minutes(1)))
struct V2NIOGatewayTimerRegressionTests {
    @Test("authentication deadline ends when auth succeeds even if a coalesced command is slow")
    func authenticatedBatchDoesNotExpireDuringSlowCommand() async throws {
        let registry = V2DeviceConnectionRegistry()
        let command = SuspendedGatewayCommand()
        let stream = try makeStream(registry: registry, handler: command)
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

        await command.release()
        try await channel.close().get()
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }

    @Test("idle check reschedules only the remaining time")
    func idleCheckUsesRemainingDeadline() async throws {
        let clock = Mutex<UInt64>(0)
        let stream = try makeStream(registry: V2DeviceConnectionRegistry(), handler: ImmediateGatewayCommand())
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

    private var version: UInt8 { UInt8(IMV2ProtocolVersion.current) }
    private var deviceID: String { "00000000-0000-0000-0000-000000000f01" }

    private func makeStream(
        registry: V2DeviceConnectionRegistry,
        handler: any V2GatewayCommandHandler
    ) throws -> V2GatewayByteStream {
        V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, version]),
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
