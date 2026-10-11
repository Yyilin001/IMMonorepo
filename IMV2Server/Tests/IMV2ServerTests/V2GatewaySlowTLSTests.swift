@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
@preconcurrency import NIOTLS
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("Gateway real TLS backpressure", .serialized, .timeLimit(.minutes(2)))
struct V2GatewaySlowTLSTests {
    @Test("a TLS peer that stops reading forces explicit required-notification closure")
    func stoppedTLSReaderClosesWithEvidence() async throws {
        let tls = try makeGatewayTestTLSContexts()
        let serverContext = tls.server, clientContext = tls.client
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        var server: (any Channel)?
        var client: (any Channel)?
        do {
            let version = UInt8(IMV2ProtocolVersion.current)
            let limits = try V2FrameLimits(maximumPayloadBytes: 4096, acceptedVersions: [0, version])
            let metrics = V2GatewayTransportMetrics()
            let stream = V2GatewayByteStream(frameLimits: limits,
                session: .init(limits: try .init(maximumInFlightRequests: 1), authenticator: SlowTLSAuthenticator(),
                    capabilityProfile: "base", commandAdmission: V2AllowingGatewayCommandAdmission()),
                handler: SlowTLSCommands(), registry: V2DeviceConnectionRegistry(foregroundFrameLimits: v2FixtureForegroundFrameLimits))
            server = try await ServerBootstrap(group: group)
                .childChannelOption(ChannelOptions.socketOption(.so_sndbuf), value: 4096)
                .childChannelInitializer { channel in
                    do {
                        return try channel.pipeline.addHandlers([
                            NIOSSLServerHandler(context: serverContext),
                            V2NIOGatewayChannelHandler(stream: stream, maximumQueuedInboundBytes: 4096,
                                maximumQueuedInboundChunks: 4, authenticationTimeoutMilliseconds: 60_000,
                                idleTimeoutMilliseconds: 60_000, transportMetrics: metrics)
                        ])
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.bind(host: "127.0.0.1", port: 0).get()
            let paused = group.next().makePromise(of: Void.self)
            client = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 4096)
                .channelInitializer { channel in
                    do {
                        return try channel.pipeline.addHandlers([
                            NIOSSLClientHandler(context: clientContext, serverHostname: "localhost"),
                            PauseAfterTLSHandshake(ready: paused)
                        ])
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.connect(host: "127.0.0.1", port: try #require(server?.localAddress?.port)).get()
            try await paused.futureResult.get()
            try #require(try await client?.getOption(ChannelOptions.autoRead).get() == false)
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(await stream.supportsRequiredNotifications()) {
                try #require(ContinuousClock.now < readyDeadline)
                await Task.yield()
            }
            // Authentication is a local fixture; notification bytes traverse the
            // actual production NIO handler, TLS encryption and loopback sockets.
            let handshakeDeviceID = UUID().uuidString
            var hello = IMV2Envelope(); hello.requestID = 1
            hello.clientHello.supportedProtocolVersions = [UInt32(version)]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            hello.clientHello.deviceID = handshakeDeviceID
            _ = try await stream.receive(V2FrameCodec.encode(
                V2ServerProtobufFrameCodec.encode(hello, frameVersion: 0), limits: limits))
            var auth = IMV2Envelope(); auth.requestID = 2; auth.protocolVersion = UInt32(version)
            auth.authenticate.accessToken = "fixture"; auth.authenticate.deviceID = handshakeDeviceID
            _ = try await stream.receive(V2FrameCodec.encode(
                V2ServerProtobufFrameCodec.encode(auth, frameVersion: version), limits: limits))
            let epoch = UUID()
            var refused = false
            var accepted = 0
            for _ in 1...100_000 {
                try Task.checkCancellation()
                let written = await stream.sendAccountRoomNotification(.resyncRequired(epoch: epoch))
                if !written { refused = true; break }
                accepted += 1
            }
            #expect(refused)
            #expect(accepted > 0)
            // NIOSSL still performs its bounded close-notify handshake after
            // the application rejects the write. Include that configured grace
            // plus event-loop scheduling margin before asserting channelInactive.
            let closedDeadline = ContinuousClock.now.advanced(by:
                .nanoseconds(serverContext.configuration.shutdownTimeout.nanoseconds + 2_000_000_000))
            while await metrics.gatewayTransportMetricsSnapshot().activeConnections > 0 {
                try #require(ContinuousClock.now < closedDeadline)
                await Task.yield()
            }
            let snapshot = await metrics.gatewayTransportMetricsSnapshot()
            let backpressure = snapshot.closureCount(for: .requiredNotificationBackpressure)
            let timeout = snapshot.closureCount(for: .requiredNotificationWriteTimeout)
            #expect(backpressure + timeout == 1)
            #expect(snapshot.closureCount(for: .requestFailure) == 0)
            print("IMV2_REAL_TLS_BACKPRESSURE accepted=\(accepted) nonwritable=\(backpressure) writeTimeout=\(timeout)")
            try? await client?.close().get()
            try await server?.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await client?.close().get()
            try? await server?.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private final class PauseAfterTLSHandshake: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let ready: EventLoopPromise<Void>
    private var resolved = false
    init(ready: EventLoopPromise<Void>) { self.ready = ready }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if !resolved, let event = event as? TLSUserEvent, case .handshakeCompleted = event {
            resolved = true
            context.channel.setOption(ChannelOptions.autoRead, value: false).cascade(to: ready)
        }
        context.fireUserInboundEventTriggered(event)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !resolved { resolved = true; ready.fail(error) }
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !resolved { resolved = true; ready.fail(ChannelError.ioOnClosedChannel) }
        context.fireChannelInactive()
    }
}

private struct SlowTLSAuthenticator: V2GatewayAuthenticator {
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        try .init(userID: .init("slow-tls-user"), expiresAt: nil)
    }
}
private struct SlowTLSCommands: V2GatewayCommandHandler {
    func handle(envelope: IMV2Envelope, identity: V2AuthenticatedConnection) async throws -> IMV2Envelope {
        throw V2RoomRecoveryReadError.invalidRequest
    }
}
