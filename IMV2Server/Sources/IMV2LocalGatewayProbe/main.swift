import Foundation
import IMV2Core
import IMV2Server
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

/// A deliberately narrow client used only by `verify_v2_local_account_stack`.
/// It proves that credentials issued through the local HTTPS account edge can
/// authenticate and exchange ordinary direct-chat commands over the real
/// TLS/protobuf gateway. It does not expose a gateway route, persist
/// credentials, or print identity/credential material.
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
            let completion = group.next().makePromise(of: ProbeResult.self)

            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(context: sslContext, serverHostname: configuration.serverName)
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            GatewayProbeHandler(configuration: configuration, completion: completion)
                        )
                    }
                }
                .connect(host: configuration.host, port: configuration.port)
                .get()
            let result = try await completion.futureResult.get()
            try await channel.close().get()
            try await group.shutdownGracefully()
            print(result.standardOutput)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private struct Configuration: Sendable {
    enum Mode: String, Sendable {
        case authenticate
        case sendDirectMessage
        case receiveDirectMessage
    }

    let accessToken: String
    let deviceID: DeviceID
    let mode: Mode
    let targetUserID: UserID?
    let expectedRoomID: RoomID?
    let expectedMessageID: MessageID?
    let host: String
    let port: Int
    let serverName: String
    let caPath: String

    static let messageText = "local-gateway-smoke-message"

    init(environment: [String: String]) throws {
        guard let accessToken = environment["IM_V2_GATEWAY_PROBE_ACCESS_TOKEN"], !accessToken.isEmpty,
              let rawDeviceID = environment["IM_V2_GATEWAY_PROBE_DEVICE_ID"],
              let deviceID = try? DeviceID(rawDeviceID),
              let mode = Mode(rawValue: environment["IM_V2_GATEWAY_PROBE_MODE"] ?? Mode.authenticate.rawValue)
        else { throw ProbeError.invalidConfiguration }
        self.accessToken = accessToken
        self.deviceID = deviceID
        self.mode = mode
        targetUserID = try environment["IM_V2_GATEWAY_PROBE_TARGET_USER_ID"].map(UserID.init)
        expectedRoomID = try environment["IM_V2_GATEWAY_PROBE_EXPECTED_ROOM_ID"].map(RoomID.init)
        expectedMessageID = try environment["IM_V2_GATEWAY_PROBE_EXPECTED_MESSAGE_ID"].map(MessageID.init)
        switch mode {
        case .authenticate:
            guard targetUserID == nil, expectedRoomID == nil, expectedMessageID == nil else {
                throw ProbeError.invalidConfiguration
            }
        case .sendDirectMessage:
            guard targetUserID != nil, expectedRoomID == nil, expectedMessageID == nil else {
                throw ProbeError.invalidConfiguration
            }
        case .receiveDirectMessage:
            guard targetUserID == nil, expectedRoomID != nil, expectedMessageID != nil else {
                throw ProbeError.invalidConfiguration
            }
        }
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
    case messageDeliveryNotObserved
    case connectionClosed
}

private enum ProbeResult: Sendable {
    case authenticated
    case messageAccepted(roomID: RoomID, messageID: MessageID)
    case messageDelivered

    var standardOutput: String {
        switch self {
        case .authenticated:
            return "local V2 gateway authentication: current protocol verified"
        case .messageAccepted(let roomID, let messageID):
            // The shell verifier captures this line rather than logging it.
            // IDs are only passed to the recipient-side probe as short-lived
            // local process environment, never written to disk.
            return "\(roomID.rawValue) \(messageID.rawValue)"
        case .messageDelivered:
            return "local V2 gateway direct message sync: verified"
        }
    }
}

private final class GatewayProbeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let configuration: Configuration
    private let completion: EventLoopPromise<ProbeResult>
    private let limits = try! V2FrameLimits(
        maximumPayloadBytes: 65_536,
        acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
    )
    private var decoder: V2FrameDecoder
    private var stage: Stage = .awaitingHello
    private var nextRequestID: UInt64 = 3
    private var nextSyncToken: String?
    private var deliveryPolls = 0
    private var finished = false

    init(configuration: Configuration, completion: EventLoopPromise<ProbeResult>) {
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
        // Availability hints are deliberately best effort and may arrive while
        // a request is in flight. They must not be confused with its response.
        if frame.requestID == 0, case .syncAvailable? = envelope.body {
            return
        }
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
            switch configuration.mode {
            case .authenticate:
                finish(context: context, result: .success(.authenticated), closeChannel: false)
            case .sendDirectMessage:
                try sendOpenDirectRoom(context: context)
            case .receiveDirectMessage:
                try sendSyncPull(context: context)
            }

        case .awaitingDirectRoom(let requestID):
            guard frame.requestID == requestID,
                  case .directRoomOpened(let response)? = envelope.body,
                  response.targetUserID == configuration.targetUserID?.rawValue,
                  let roomID = try? RoomID(response.roomID)
            else { throw ProbeError.unexpectedResponse }
            try sendMessage(roomID: roomID, context: context)

        case .awaitingMessageAcceptance(let requestID, let roomID):
            guard frame.requestID == requestID,
                  case .messageAccepted(let response)? = envelope.body,
                  response.roomID == roomID.rawValue,
                  response.roomSequence > 0,
                  response.mediaIds.isEmpty,
                  response.mentionedUserIds.isEmpty,
                  !response.mentionsEveryone,
                  let messageID = try? MessageID(response.messageID)
            else { throw ProbeError.unexpectedResponse }
            finish(context: context, result: .success(.messageAccepted(roomID: roomID, messageID: messageID)), closeChannel: false)

        case .awaitingSync(let requestID):
            guard frame.requestID == requestID,
                  case .syncBatch(let batch)? = envelope.body,
                  batch.generation > 0,
                  !batch.nextSyncToken.isEmpty,
                  !batch.syncReceipt.isEmpty,
                  batch.capabilityProfile == "base"
            else { throw ProbeError.unexpectedResponse }
            if containsExpectedMessage(batch.records) {
                finish(context: context, result: .success(.messageDelivered), closeChannel: false)
                return
            }
            nextSyncToken = batch.nextSyncToken
            deliveryPolls += 1
            guard deliveryPolls < 50 else { throw ProbeError.messageDeliveryNotObserved }
            let delay: TimeAmount = batch.hasMore_p ? .milliseconds(1) : .milliseconds(100)
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let boundContext = context.loopBound
            context.eventLoop.scheduleTask(in: delay) {
                let handler = handler.value
                let context = boundContext.value
                guard !handler.finished else { return }
                do {
                    try handler.sendSyncPull(context: context)
                } catch {
                    handler.finish(context: context, result: .failure(error))
                }
            }
        }
    }

    private func sendOpenDirectRoom(context: ChannelHandlerContext) throws {
        guard let targetUserID = configuration.targetUserID else { throw ProbeError.invalidConfiguration }
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.openDirectRoom = .init()
        request.openDirectRoom.operationID = UUID().uuidString
        request.openDirectRoom.targetUserID = targetUserID.rawValue
        stage = .awaitingDirectRoom(requestID)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func sendMessage(roomID: RoomID, context: ChannelHandlerContext) throws {
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.sendMessage = .init()
        request.sendMessage.roomID = roomID.rawValue
        request.sendMessage.clientMessageID = UUID().uuidString
        request.sendMessage.content = .init()
        request.sendMessage.content.text = Configuration.messageText
        stage = .awaitingMessageAcceptance(requestID, roomID)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func sendSyncPull(context: ChannelHandlerContext) throws {
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.syncPull = .init()
        request.syncPull.syncToken = nextSyncToken ?? ""
        request.syncPull.maxRecords = 100
        stage = .awaitingSync(requestID)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func containsExpectedMessage(_ records: [IMV2SyncRecord]) -> Bool {
        guard let expectedRoomID = configuration.expectedRoomID,
              let expectedMessageID = configuration.expectedMessageID
        else { return false }
        return records.contains { record in
            guard record.projectionKind == "message",
                  let object = try? JSONSerialization.jsonObject(with: record.payload) as? [String: Any],
                  object["event_type"] as? String == "message.accepted",
                  object["room_id"] as? String == expectedRoomID.rawValue,
                  object["message_id"] as? String == expectedMessageID.rawValue,
                  object["text"] as? String == Configuration.messageText
            else { return false }
            return true
        }
    }

    private func takeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
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
        result: Result<ProbeResult, Error>,
        closeChannel: Bool = true
    ) {
        guard !finished else { return }
        finished = true
        completion.completeWith(result)
        if closeChannel {
            context.close(promise: nil)
        }
    }

    private enum Stage {
        case awaitingHello
        case awaitingAuthentication
        case awaitingDirectRoom(UInt64)
        case awaitingMessageAcceptance(UInt64, RoomID)
        case awaitingSync(UInt64)
    }
}
