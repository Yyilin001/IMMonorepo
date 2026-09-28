import Foundation
import IMV2Core
import NIOCore
import NIOEmbedded
@testable import IMV2Server
import Testing

@Suite("V2 gateway connection drain", .timeLimit(.minutes(1)))
struct V2GatewayConnectionDrainTests {
    @Test("socket closure waits for a cancelled request and stream cleanup")
    func closeWaitsForProcessing() async throws {
        let version = UInt8(IMV2ProtocolVersion.current)
        let limits = try V2FrameLimits(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])
        let command = DrainSuspendedCommand()
        let stream = V2GatewayByteStream(
            frameLimits: limits,
            session: .init(limits: try .init(maximumInFlightRequests: 1),
                           authenticator: DrainAuthenticator(), capabilityProfile: "base",
                           commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: command, registry: V2DeviceConnectionRegistry()
        )
        let channel = NIOAsyncTestingChannel()
        let completion = V2GatewayConnectionDrainCompletion(eventLoop: channel.eventLoop)
        try await channel.testingEventLoop.executeInContext {
            try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(
                stream: stream, maximumQueuedInboundBytes: 16_384, maximumQueuedInboundChunks: 4,
                authenticationTimeoutMilliseconds: 60_000, idleTimeoutMilliseconds: 60_000,
                transportMetrics: V2GatewayTransportMetrics(), foregroundWriteScheduler: .init(),
                drained: completion
            ))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()

        let deviceID = "00000000-0000-0000-0000-000000000e01"
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
        var slow = IMV2Envelope()
        slow.requestID = 3
        slow.protocolVersion = UInt32(version)
        slow.syncPull = .init()
        let frames = try [
            (hello, UInt8(0)), (auth, version), (slow, version)
        ].map { envelope, frameVersion in
            try V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(envelope, frameVersion: frameVersion),
                                    limits: limits)
        }
        var inbound = channel.allocator.buffer(capacity: frames.reduce(0) { $0 + $1.count })
        for frame in frames { inbound.writeBytes(frame) }
        _ = try await channel.writeInbound(inbound)
        await command.waitUntilStarted()

        try await channel.close().get()
        let drain = Task<Void, Never> { _ = try? await completion.promise.futureResult.get() }
        #expect(await v2WaitForTaskDrain([drain], timeout: .milliseconds(10)) == false)

        await command.release()
        #expect(await v2WaitForTaskDrain([drain], timeout: .seconds(1)))
        _ = try await channel.finish(acceptAlreadyClosed: true)
    }
}

private struct DrainAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken _: String, deviceID _: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000e02"), expiresAt: nil)
    }
}

private actor DrainSuspendedCommand: V2GatewayCommandHandler {
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
