import Foundation
import IMV2Core
import IMV2Server
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

/// 仅由 `verify_v2_local_account_stack` 使用的窄客户端。
///
/// 它用于证明：通过本地 HTTPS 账号边缘签发的凭据，能够在真实的 TLS/protobuf 网关上完成认证
/// 并交换普通私聊命令。它不暴露任何网关路由，不持久化凭据，
/// 也不会打印身份或凭据材料。
/// `sendDirectMessage` 可选 CLIENT_MESSAGE_ID，用于测试进程故障后按原业务操作重放。
/// `sendRoomMediaMessage` 另要求 EXPECTED_ROOM_ID、MEDIA_ID、CLIENT_MESSAGE_ID；
/// 它只输出接受结果的 room/message ID，供外部 smoke 在 SQL 中校验唯一消息与媒体归属。
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
            // A disabled account may proactively close this authenticated
            // socket before the held probe issues its post-disable request.
            // The handler has already classified that terminal event. Only
            // an already-closed cleanup race may be ignored here.
            if channel.isActive {
                do {
                    try await channel.close().get()
                } catch ChannelError.alreadyClosed {
                    // The peer closed between isActive and close().
                }
            }
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
        case sendRoomMediaMessage
        case heldRoomSend
        case heldRoomRead
    }

    let accessToken: String
    let deviceID: DeviceID
    let mode: Mode
    let targetUserID: UserID?
    let expectedRoomID: RoomID?
    let expectedMessageID: MessageID?
    let mediaID: MediaID?
    let clientMessageID: ClientMessageID?
    let heldReadyPath: String?
    let heldReleasePath: String?
    let heldDisableStartedPath: String?
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
        mediaID = try environment["IM_V2_GATEWAY_PROBE_MEDIA_ID"].map(MediaID.init)
        clientMessageID = try environment["IM_V2_GATEWAY_PROBE_CLIENT_MESSAGE_ID"].map(ClientMessageID.init)
        heldReadyPath = environment["IM_V2_GATEWAY_PROBE_HELD_READY_PATH"]
        heldReleasePath = environment["IM_V2_GATEWAY_PROBE_HELD_RELEASE_PATH"]
        heldDisableStartedPath = environment["IM_V2_GATEWAY_PROBE_HELD_DISABLE_STARTED_PATH"]
        switch mode {
        case .authenticate:
            guard targetUserID == nil, expectedRoomID == nil, expectedMessageID == nil,
                  mediaID == nil, clientMessageID == nil else {
                throw ProbeError.invalidConfiguration
            }
        case .sendDirectMessage:
            guard targetUserID != nil, expectedRoomID == nil, expectedMessageID == nil,
                  mediaID == nil else {
                throw ProbeError.invalidConfiguration
            }
        case .receiveDirectMessage:
            guard targetUserID == nil, expectedRoomID != nil, expectedMessageID != nil,
                  mediaID == nil, clientMessageID == nil else {
                throw ProbeError.invalidConfiguration
            }
        case .sendRoomMediaMessage:
            guard targetUserID == nil, expectedRoomID != nil, expectedMessageID == nil,
                  mediaID != nil, clientMessageID != nil else {
                throw ProbeError.invalidConfiguration
            }
        case .heldRoomSend:
            guard targetUserID == nil, expectedRoomID != nil, expectedMessageID == nil,
                  mediaID == nil, clientMessageID != nil else { throw ProbeError.invalidConfiguration }
        case .heldRoomRead:
            guard targetUserID == nil, expectedRoomID != nil, expectedMessageID != nil,
                  mediaID == nil, clientMessageID == nil else { throw ProbeError.invalidConfiguration }
        }
        switch mode {
        case .heldRoomSend, .heldRoomRead:
            guard let heldReadyPath, let heldReleasePath, let heldDisableStartedPath,
                  heldReadyPath.hasPrefix("/run/im-v2-cross-entry/"),
                  heldReleasePath.hasPrefix("/run/im-v2-cross-entry/"),
                  heldDisableStartedPath.hasPrefix("/run/im-v2-cross-entry/"),
                  heldReadyPath != heldReleasePath,
                  heldReadyPath != heldDisableStartedPath,
                  heldReleasePath != heldDisableStartedPath else { throw ProbeError.invalidConfiguration }
        default:
            guard heldReadyPath == nil, heldReleasePath == nil, heldDisableStartedPath == nil
            else { throw ProbeError.invalidConfiguration }
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
    case heldBarrierTimedOut
}

private enum ProbeResult: Sendable {
    case authenticated
    case messageAccepted(roomID: RoomID, messageID: MessageID)
    case messageDelivered
    case heldRequestDenied(reason: String)

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
            return "local V2 gateway direct room-log delivery: verified"
        case .heldRequestDenied(let reason):
            return "denied-\(reason)"
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
    private var nextRoomSequence: UInt64 = 0
    private var deliveryPolls = 0
    private var finished = false
    private var heldAuthenticated = false
    private var heldRequestDispatched = false
    private var heldStartedAt: Date?

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
            try receiveDecodedFrames(try decoder.append(bytes), context: context)
            while decoder.hasBufferedBytes {
                let frames = try decoder.append(Data())
                guard !frames.isEmpty else { break }
                try receiveDecodedFrames(frames, context: context)
            }
        } catch {
            finish(context: context, result: .failure(error))
        }
    }

    private func receiveDecodedFrames(_ frames: [V2Frame], context: ChannelHandlerContext) throws {
        for frame in frames { try receive(frame, context: context) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if heldAuthenticated {
            let reason = heldCloseReason()
            markHeldConnectionClosed()
            finish(context: context, result: .success(.heldRequestDenied(
                reason: reason)),
                closeChannel: false)
        } else {
            finish(context: context, result: .failure(ProbeError.connectionClosed), closeChannel: false)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if heldAuthenticated {
            let reason = heldCloseReason()
            markHeldConnectionClosed()
            finish(context: context, result: .success(.heldRequestDenied(
                reason: reason)))
        } else {
            finish(context: context, result: .failure(error))
        }
    }

    private func receive(_ frame: V2Frame, context: ChannelHandlerContext) throws {
        let envelope = try V2ServerProtobufFrameCodec.decode(frame)
        // Availability hints are best effort and may arrive while a durable
        // room-log pull is in flight. They are not responses to this probe.
        if frame.requestID == 0,
           case .syncAvailable? = envelope.body {
            return
        }
        if frame.requestID == 0,
           case .groupEventAvailable? = envelope.body {
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
                try sendRoomEventPull(context: context)
            case .sendRoomMediaMessage:
                guard let roomID = configuration.expectedRoomID else { throw ProbeError.invalidConfiguration }
                try sendMessage(roomID: roomID, context: context)
            case .heldRoomSend, .heldRoomRead:
                heldAuthenticated = true
                if configuration.mode == .heldRoomRead {
                    try sendHeldWarmRoomEventPull(context: context)
                } else {
                    try holdAuthenticated(context: context)
                }
            }

        case .awaitingHeldWarmPage(let requestID):
            guard frame.requestID == requestID,
                  case .groupEventPage(let page)? = envelope.body,
                  page.roomID == configuration.expectedRoomID?.rawValue,
                  containsExpectedMessage(page.events)
            else { throw ProbeError.unexpectedResponse }
            try holdAuthenticated(context: context)

        case .holdingAuthenticated:
            if case .error(let error)? = envelope.body,
               error.code == "UNAUTHENTICATED" || error.code == "FORBIDDEN" {
                finish(context: context, result: .success(.heldRequestDenied(
                    reason: heldDisableStarted() ? error.code : "rejected-before-disable")))
                return
            }
            throw ProbeError.unexpectedResponse

        case .awaitingDirectRoom(let requestID):
            guard frame.requestID == requestID,
                  case .directRoomOpened(let response)? = envelope.body,
                  response.targetUserID == configuration.targetUserID?.rawValue,
                  let roomID = try? RoomID(response.roomID)
            else { throw ProbeError.unexpectedResponse }
            try sendMessage(roomID: roomID, context: context)

        case .awaitingMessageAcceptance(let requestID, let roomID):
            if configuration.mode == .heldRoomSend {
                try finishHeldRejection(frame: frame, envelope: envelope,
                    expectedRequestID: requestID, context: context)
                return
            }
            guard frame.requestID == requestID,
                  case .messageAccepted(let response)? = envelope.body,
                  response.roomID == roomID.rawValue,
                  response.roomSequence > 0,
                  Int64(exactly: response.roomSequence) != nil,
                  response.serverCreatedAtMs >= 0,
                  let messageID = try? MessageID(response.messageID)
            else { throw ProbeError.unexpectedResponse }
            finish(context: context, result: .success(.messageAccepted(roomID: roomID, messageID: messageID)), closeChannel: false)

        case .awaitingRoomEventPage(let requestID, let requestedAfterRoomSequence):
            if configuration.mode == .heldRoomRead {
                try finishHeldRejection(frame: frame, envelope: envelope,
                    expectedRequestID: requestID, context: context)
                return
            }
            guard frame.requestID == requestID,
                  case .groupEventPage(let page)? = envelope.body,
                  page.roomID == configuration.expectedRoomID?.rawValue,
                  page.nextRoomSequence >= requestedAfterRoomSequence,
                  page.events.count <= 100,
                  page.events.first.map({ $0.roomSequence > requestedAfterRoomSequence }) ?? true,
                  zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
                  (page.events.last?.roomSequence ?? requestedAfterRoomSequence) <= page.nextRoomSequence,
                  (!page.hasMore_p || page.events.last?.roomSequence == page.nextRoomSequence)
            else { throw ProbeError.unexpectedResponse }
            if containsExpectedMessage(page.events) {
                finish(context: context, result: .success(.messageDelivered), closeChannel: false)
                return
            }
            nextRoomSequence = page.nextRoomSequence
            deliveryPolls += 1
            guard deliveryPolls < 50 else { throw ProbeError.messageDeliveryNotObserved }
            let delay: TimeAmount = page.hasMore_p ? .milliseconds(1) : .milliseconds(100)
            let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
            let boundContext = context.loopBound
            context.eventLoop.scheduleTask(in: delay) {
                let handler = handler.value
                let context = boundContext.value
                guard !handler.finished else { return }
                do {
                    try handler.sendRoomEventPull(context: context)
                } catch {
                    handler.finish(context: context, result: .failure(error))
                }
            }
        }
    }

    private func markHeldConnectionClosed() {
        guard let path = configuration.heldReadyPath else { return }
        try? Data("closed\n".utf8).write(to: URL(fileURLWithPath: path + ".closed"), options: .atomic)
    }

    private func heldCloseReason() -> String {
        guard heldDisableStarted() else { return "closed-before-disable" }
        return heldRequestDispatched ? "closed-after-dispatch" : "closed-held"
    }

    private func heldDisableStarted() -> Bool {
        guard let path = configuration.heldDisableStartedPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func sendHeldWarmRoomEventPull(context: ChannelHandlerContext) throws {
        guard let roomID = configuration.expectedRoomID else { throw ProbeError.invalidConfiguration }
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.groupEventPull = .init()
        request.groupEventPull.roomID = roomID.rawValue
        request.groupEventPull.afterRoomSequence = 0
        request.groupEventPull.pageSize = 100
        stage = .awaitingHeldWarmPage(requestID)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func holdAuthenticated(context: ChannelHandlerContext) throws {
        guard let path = configuration.heldReadyPath else { throw ProbeError.invalidConfiguration }
        stage = .holdingAuthenticated
        heldStartedAt = Date()
        try Data("authenticated\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        pollHeldRelease(context: context)
    }

    private func finishHeldRejection(
        frame: V2Frame, envelope: IMV2Envelope, expectedRequestID: UInt64,
        context: ChannelHandlerContext
    ) throws {
        guard frame.requestID == expectedRequestID,
              case .error(let error)? = envelope.body,
              error.code == "UNAUTHENTICATED" || error.code == "FORBIDDEN"
        else { throw ProbeError.unexpectedResponse }
        finish(context: context, result: .success(.heldRequestDenied(
            reason: error.code)))
    }

    private func pollHeldRelease(context: ChannelHandlerContext) {
        guard !finished else { return }
        guard case .holdingAuthenticated = stage else { return }
        guard let path = configuration.heldReleasePath,
              let startedAt = heldStartedAt else { return }
        if FileManager.default.fileExists(atPath: path) {
            do {
                heldRequestDispatched = true
                switch configuration.mode {
                case .heldRoomSend:
                    guard let roomID = configuration.expectedRoomID else { throw ProbeError.invalidConfiguration }
                    try sendMessage(roomID: roomID, context: context)
                case .heldRoomRead:
                    try sendRoomEventPull(context: context)
                default:
                    throw ProbeError.invalidConfiguration
                }
            } catch {
                finish(context: context, result: .failure(error))
            }
            return
        }
        guard Date().timeIntervalSince(startedAt) < 180 else {
            finish(context: context, result: .failure(ProbeError.heldBarrierTimedOut))
            return
        }
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        context.eventLoop.scheduleTask(in: .milliseconds(25)) {
            handler.value.pollHeldRelease(context: boundContext.value)
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
        request.sendMessage.clientMessageID = configuration.clientMessageID?.rawValue ?? UUID().uuidString
        request.sendMessage.content = .init()
        request.sendMessage.content.text = Configuration.messageText
        if let mediaID = configuration.mediaID {
            request.sendMessage.content.mediaIds = [mediaID.rawValue]
        }
        stage = .awaitingMessageAcceptance(requestID, roomID)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func sendRoomEventPull(context: ChannelHandlerContext) throws {
        guard let roomID = configuration.expectedRoomID else { throw ProbeError.invalidConfiguration }
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.groupEventPull = .init()
        request.groupEventPull.roomID = roomID.rawValue
        request.groupEventPull.afterRoomSequence = nextRoomSequence
        request.groupEventPull.pageSize = 100
        stage = .awaitingRoomEventPage(requestID, nextRoomSequence)
        try write(request, frameVersion: UInt8(IMV2ProtocolVersion.current), context: context)
    }

    private func containsExpectedMessage(_ records: [IMV2GroupEvent]) -> Bool {
        guard let expectedRoomID = configuration.expectedRoomID,
              let expectedMessageID = configuration.expectedMessageID
        else { return false }
        return records.contains { record in
            guard record.roomSequence > 0,
                  !record.sourceEventID.isEmpty,
                  record.projectionKind == "message",
                  let object = try? JSONSerialization.jsonObject(with: record.payload) as? [String: Any],
                  object["event_type"] as? String == "message.accepted",
                  let roomID = object["room_id"] as? String,
                  let messageID = object["message_id"] as? String,
                  UUID(uuidString: roomID) == UUID(uuidString: expectedRoomID.rawValue),
                  UUID(uuidString: messageID) == UUID(uuidString: expectedMessageID.rawValue),
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
        case awaitingHeldWarmPage(UInt64)
        case holdingAuthenticated
        case awaitingDirectRoom(UInt64)
        case awaitingMessageAcceptance(UInt64, RoomID)
        case awaitingRoomEventPage(UInt64, UInt64)
    }
}
