import Foundation
import IMV2Core
import IMV2Server
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

/// A deliberately narrow client used only by `verify_v2_local_account_stack`.
/// It proves that a credential issued through the local HTTPS account edge can
/// authenticate over the real TLS/protobuf gateway. It does not expose a
/// gateway route, persist credentials, or print identity/credential material.
@main
enum IMV2LocalGatewayProbe {
    static func main() async throws {
        let configuration = try Configuration(environment: ProcessInfo.processInfo.environment)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.minimumTLSVersion = .tlsv13
            tls.maximumTLSVersion = .tlsv13
            tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(configuration.caPath))
            let sslContext = try NIOSSLContext(configuration: tls)
            let completion = group.next().makePromise(of: Void.self)

            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: sslContext, serverHostname: configuration.serverName)
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            GatewayAuthenticationProbeHandler(configuration: configuration, completion: completion)
                        )
                    }
                }
                .connect(host: configuration.host, port: configuration.port)
                .get()
            try await completion.futureResult.get()
            try await channel.close().get()
            try await group.shutdownGracefully()
            print("local V2 gateway authentication: protocol v1 verified")
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private struct Configuration: Sendable {
    let accessToken: String
    let deviceID: DeviceID
    let host: String
    let port: Int
    let serverName: String
    let caPath: String

    init(environment: [String: String]) throws {
        guard let accessToken = environment["IM_V2_GATEWAY_PROBE_ACCESS_TOKEN"], !accessToken.isEmpty,
              let rawDeviceID = environment["IM_V2_GATEWAY_PROBE_DEVICE_ID"],
              let deviceID = try? DeviceID(rawDeviceID)
        else { throw ProbeError.invalidConfiguration }
        self.accessToken = accessToken
        self.deviceID = deviceID
        host = environment["IM_V2_GATEWAY_PROBE_HOST"] ?? "127.0.0.1"
        serverName = environment["IM_V2_GATEWAY_PROBE_SERVER_NAME"] ?? "localhost"
        caPath = environment["IM_V2_GATEWAY_PROBE_CA_PATH"] ?? "/caddy/caddy/pki/authorities/local/root.crt"
        let rawPort = environment["IM_V2_GATEWAY_PROBE_PORT"] ?? "7443"
        guard let port = Int(rawPort), (1...65_535).contains(port),
              !host.isEmpty, !serverName.isEmpty, !caPath.isEmpty
        else { throw ProbeError.invalidConfiguration }
        self.port = port
    }
}

private enum ProbeError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unexpectedResponse
    case timedOut
    case connectionClosed
}

private final class GatewayAuthenticationProbeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let configuration: Configuration
    private let completion: EventLoopPromise<Void>
    private let limits = try! V2FrameLimits(
        maximumPayloadBytes: 65_536,
        acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
    )
    private var decoder: V2FrameDecoder
    private var stage: Stage = .awaitingHello
    private var finished = false

    init(configuration: Configuration, completion: EventLoopPromise<Void>) {
        self.configuration = configuration
        self.completion = completion
        decoder = .init(limits: limits)
    }

    func channelActive(context: ChannelHandlerContext) {
        do {
            var hello = IMV2Envelope()
            hello.requestID = 1
            hello.clientHello = .init()
            hello.clientHello.supportedProtocolVersions = [IMV2ProtocolVersion.current]
            hello.clientHello.supportedCapabilityProfiles = ["base"]
            hello.clientHello.deviceID = configuration.deviceID.rawValue
            try write(hello, frameVersion: 0, context: context)
        } catch {
            finish(context: context, result: .failure(error))
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            let bytes = Data(unwrapInboundIn(data).readableBytesView)
            for frame in try decoder.append(bytes) {
                try receive(frame, context: context)
            }
        } catch {
            finish(context: context, result: .failure(error))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(context: context, result: .failure(ProbeError.connectionClosed), closeChannel: false)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(context: context, result: .failure(error))
    }

    private func receive(_ frame: V2Frame, context: ChannelHandlerContext) throws {
        let envelope = try V2ServerProtobufFrameCodec.decode(frame)
        switch stage {
        case .awaitingHello:
            guard frame.requestID == 1,
                  case .serverHello(let response)? = envelope.body,
                  response.selectedProtocolVersion == IMV2ProtocolVersion.current,
                  response.selectedCapabilityProfile == "base"
            else { throw ProbeError.unexpectedResponse }
            stage = .awaitingAuthentication
            var authenticate = IMV2Envelope()
            authenticate.requestID = 2
            authenticate.protocolVersion = IMV2ProtocolVersion.current
            authenticate.authenticate = .init()
            authenticate.authenticate.accessToken = configuration.accessToken
            authenticate.authenticate.deviceID = configuration.deviceID.rawValue
            try write(authenticate, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)

        case .awaitingAuthentication:
            guard frame.requestID == 2,
                  case .authenticated(let response)? = envelope.body,
                  response.deviceID == configuration.deviceID.rawValue,
                  response.selectedCapabilityProfile == "base",
                  !response.userID.isEmpty
            else { throw ProbeError.unexpectedResponse }
            // `main` owns the graceful channel close after observing this
            // completion. Closing here as well races that close and makes
            // NIO report `Already closed` on Linux.
            finish(context: context, result: .success(()), closeChannel: false)
        }
    }

    private func write(_ envelope: IMV2Envelope, frameVersion: UInt8, context: ChannelHandlerContext) throws {
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: frameVersion)
        let bytes = try V2FrameCodec.encode(frame, limits: limits)
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func finish(
        context: ChannelHandlerContext,
        result: Result<Void, Error>,
        closeChannel: Bool = true
    ) {
        guard !finished else { return }
        finished = true
        completion.completeWith(result)
        if closeChannel {
            context.close(promise: nil)
        }
    }

    private enum Stage { case awaitingHello, awaitingAuthentication }
}
