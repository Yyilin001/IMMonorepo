import Foundation
import IMV2Core
import IMV2ActorContracts
import NIOCore
import NIOEmbedded
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerGateway

@Suite("Gateway message/control ingress isolation", .timeLimit(.minutes(1)))
struct V2GatewayIngressLaneTests {
    @Test("send bypasses suspended sync while control order and close ownership survive",
          arguments: [false, true], [false, true])
    func sendBypassesSync(coalesced: Bool, closeBeforeRelease: Bool) async throws {
        let f = try await IngressFixture.make()
        defer { Task { await f.command.release() } }
        var initial = try f.bootstrap()
        initial.append(f.pull())
        if coalesced { initial += [f.ack(), try f.send()] }
        try await f.write(initial)
        try #require(await f.wait { await f.command.pullStarted })
        if !coalesced { try await f.write([f.ack(), try f.send()]) }
        // Await the actual socket response while sync is deliberately suspended.
        let received = try await f.responses(until: 5)
        #expect(received.contains(5))
        #expect(!received.contains(3) && !received.contains(4))
        #expect(await f.command.controls == [3])
        #expect(await f.command.sends == 1)
        #expect(f.channel.isActive)

        if closeBeforeRelease {
            try await f.channel.close().get()
            let drain = Task { _ = try? await f.drained.promise.futureResult.get() }
            #expect(await v2WaitForTaskDrain([drain], timeout: .milliseconds(10)) == false)
            #expect(await f.wait { await f.registry.connectionMetricsSnapshot().activeConnections == 0 })
            // Queued syncAck is discarded; the executing sync remains owned.
            await f.command.release()
            #expect(await v2WaitForTaskDrain([drain], timeout: .seconds(2)))
            #expect(await f.command.controls == [3])
            #expect(try await f.channel.readOutbound(as: ByteBuffer.self) == nil)
        } else {
            await f.command.release()
            let controls = try await f.responses(until: 4)
            #expect(controls == [3, 4])
            #expect(await f.command.controls == [3, 4])
            try await f.channel.close().get()
            try await f.drained.promise.futureResult.get()
        }
        #expect(f.budget.metricsSnapshot().reservedBytes == 0)
        #expect(f.budget.metricsSnapshot().inFlightRequests == 0)
        _ = try await f.channel.finish(acceptAlreadyClosed: true)
    }

    @Test("executing and queued controls retain byte and batch limits", arguments: [false, true])
    func controlQueueIsBounded(byteLimit: Bool) async throws {
        let f = try await IngressFixture.make(bytes: byteLimit ? 512 : 16_384, batches: byteLimit ? 4 : 1)
        defer { Task { await f.command.release() } }
        try await f.write(f.bootstrap())
        _ = try await f.responses(until: 2)
        try await f.write([f.pull(tokenBytes: byteLimit ? 300 : 0)])
        try #require(await f.wait { await f.command.pullStarted })
        var next = f.pull(tokenBytes: byteLimit ? 300 : 0)
        next.requestID = 4
        try await f.write([next])
        #expect(await f.wait { !f.channel.isActive })
        #expect((await f.metrics.gatewayTransportMetricsSnapshot()).closureCount(for: .inboundQueueLimit) == 1)
        await f.command.release()
        try await f.drained.promise.futureResult.get()
        #expect(await f.command.controls == [3])
        _ = try await f.channel.finish(acceptAlreadyClosed: true)
    }
}

private struct IngressFixture: Sendable {
    let channel: NIOAsyncTestingChannel
    let command: IngressCommand
    let registry: V2DeviceConnectionRegistry
    let metrics: V2GatewayTransportMetrics
    let budget: V2GatewayMessageSendBudget
    let drained: V2GatewayConnectionDrainCompletion
    private var version: UInt8 { UInt8(IMV2ProtocolVersion.current) }
    private var device: String { "00000000-0000-0000-0000-000000000b01" }

    static func make(bytes: Int = 16_384, batches: Int = 4) async throws -> Self {
        let channel = NIOAsyncTestingChannel()
        let command = IngressCommand()
        let registry = V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits)
        let metrics = V2GatewayTransportMetrics()
        let budget = V2GatewayMessageSendBudget(maximumBytes: 65_536, maximumRequests: 8)
        let drained = V2GatewayConnectionDrainCompletion(eventLoop: channel.eventLoop)
        let stream = V2GatewayByteStream(
            frameLimits: try .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]),
            session: .init(limits: try .init(maximumInFlightRequests: 8),
                authenticator: IngressAuthenticator(), capabilityProfile: "base",
                commandAdmission: V2AllowingGatewayCommandAdmission()),
            handler: command, registry: registry, messageSendBudget: budget)
        try await channel.testingEventLoop.executeInContext {
            try channel.pipeline.syncOperations.addHandler(V2NIOGatewayChannelHandler(
                stream: stream, maximumQueuedInboundBytes: bytes, maximumQueuedInboundChunks: batches,
                authenticationTimeoutMilliseconds: 60_000, idleTimeoutMilliseconds: 60_000,
                transportMetrics: metrics, foregroundWriteScheduler: .init(), drained: drained))
        }
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        return .init(channel: channel, command: command, registry: registry,
            metrics: metrics, budget: budget, drained: drained)
    }
    func bootstrap() throws -> [IMV2Envelope] {
        var hello = IMV2Envelope()
        hello.requestID = 1
        hello.clientHello.deviceID = device
        hello.clientHello.supportedProtocolVersions = [UInt32(version)]
        hello.clientHello.supportedCapabilityProfiles = ["base"]
        hello.clientHello.supportsMessageSendOperations = true
        var auth = IMV2Envelope()
        auth.requestID = 2
        auth.protocolVersion = UInt32(version)
        auth.authenticate.accessToken = "opaque"
        auth.authenticate.deviceID = device
        return [hello, auth]
    }
    func pull(tokenBytes: Int = 0) -> IMV2Envelope {
        var request = IMV2Envelope()
        request.requestID = 3
        request.protocolVersion = UInt32(version)
        request.syncPull.syncToken = String(repeating: "a", count: tokenBytes)
        return request
    }
    func ack() -> IMV2Envelope {
        var request = IMV2Envelope()
        request.requestID = 4
        request.protocolVersion = UInt32(version)
        request.syncAck = .init()
        return request
    }
    func send() throws -> IMV2Envelope {
        let command = try V2MessageSendOperationCommand(command: .init(
            roomID: .init("00000000-0000-0000-0000-000000000b03"),
            senderUserID: .init("00000000-0000-0000-0000-000000000b02"),
            clientMessageID: .init(uuid: UUID()), text: "message", limits: .init(maxUTF8Bytes: 64)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1_000) + 60_000)
        var request = IMV2Envelope()
        request.requestID = 5
        request.protocolVersion = UInt32(version)
        request.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: command)
        return request
    }
    func write(_ requests: [IMV2Envelope]) async throws {
        var input = channel.allocator.buffer(capacity: 1_024)
        for request in requests {
            let frameVersion: UInt8 = request.requestID == 1 ? 0 : version
            input.writeBytes(try V2FrameCodec.encode(V2ServerProtobufFrameCodec.encode(request, frameVersion: frameVersion),
                limits: .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])))
        }
        _ = try await channel.writeInbound(input)
    }
    func responses(until id: UInt64) async throws -> [UInt64] {
        var ids: [UInt64] = []
        let deadline = ContinuousClock.now + .seconds(2)
        while !ids.contains(id), ContinuousClock.now < deadline {
            if let bytes = try await channel.readOutbound(as: ByteBuffer.self) {
                ids.append(try V2FrameCodec.decodeExactlyOne(Data(bytes.readableBytesView),
                    limits: .init(maximumPayloadBytes: 4_096, acceptedVersions: [0, version])).requestID)
            } else { try await Task.sleep(for: .milliseconds(1)) }
        }
        return ids
    }
    func wait(_ predicate: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return await predicate()
    }
}

private struct IngressAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("00000000-0000-0000-0000-000000000b02"), expiresAt: nil)
    }
}

private actor IngressCommand: V2GatewayCommandHandler {
    private(set) var pullStarted = false
    private(set) var controls: [UInt64] = []
    private(set) var sends = 0
    private var resume: CheckedContinuation<Void, Never>?
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        switch envelope.body {
        case .syncPull:
            controls.append(envelope.requestID)
            pullStarted = true
            await withCheckedContinuation { resume = $0 }
        case .syncAck: controls.append(envelope.requestID)
        case .messageSendOperation: sends += 1
        default: break
        }
        var response = IMV2Envelope()
        response.error.code = "UNAVAILABLE"
        return response
    }
    func release() { resume?.resume(); resume = nil }
}
