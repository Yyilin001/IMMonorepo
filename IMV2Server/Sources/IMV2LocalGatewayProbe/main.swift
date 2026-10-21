import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2Server
import IMV2ServerInfrastructure
import IMV2ToolHTTP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
import IMV2ServerGateway

/// 仅由 `verify_v2_local_account_stack` 使用的窄客户端。
///
/// 它用于证明：通过本地 HTTPS 账号边缘签发的凭据，能够在真实的 TLS/protobuf 网关上完成认证
/// 并交换普通私聊命令。它不暴露任何网关路由，不持久化凭据，
/// 也不会打印身份或凭据材料。
/// `sendDirectMessage` 可选 CLIENT_MESSAGE_ID；提供时须同时提供原 SEND_DEADLINE_MS，确保跨进程恢复冻结指纹不变。
/// `sendRoomMediaMessage` 另要求 EXPECTED_ROOM_ID、MEDIA_ID、CLIENT_MESSAGE_ID；
/// 它只输出接受结果的 room/message ID，供外部 smoke 在 SQL 中校验唯一消息与媒体归属。
@main
enum IMV2LocalGatewayProbe {
    static func main() async throws {
        let configuration = try Configuration(environment: ProcessInfo.processInfo.environment)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let sendTasks = V2ToolHTTPSendTaskOwner()
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
                            NIOSSLClientHandler(context: sslContext, serverHostname: configuration.sniServerName)
                        )
                        try channel.pipeline.syncOperations.addHandler(
                            GatewayProbeHandler(configuration: configuration, completion: completion, sendTasks: sendTasks)
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
            await sendTasks.closeAndDrain()
            try await group.shutdownGracefully()
            print(result.standardOutput)
        } catch {
            await sendTasks.closeAndDrain()
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
        case sendKnownRoomMessage
        case sendKnownRoomExpectDenied
        case barrierRoomSend
        case relationshipRequest
        case relationshipAccept
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
    let sendDeadlineMilliseconds: UInt64
    let heldReadyPath: String?
    let heldReleasePath: String?
    let heldDisableStartedPath: String?
    let batchReadyPath: String?
    let batchReleasePath: String?
    let host: String
    let port: Int
    let serverName: String
    let accountBaseURL:URL
    let caPath: String

    // IP endpoints are verified against the connected peer address. TLS SNI
    // accepts DNS names only; keep full certificate verification enabled.
    var sniServerName: String? {
        (try? SocketAddress(ipAddress: serverName, port: port)) == nil ? serverName : nil
    }

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
        if let rawDeadline = environment["IM_V2_GATEWAY_PROBE_SEND_DEADLINE_MS"] {
            guard let deadline = UInt64(rawDeadline), deadline > 0, deadline <= UInt64(Int64.max) else { throw ProbeError.invalidConfiguration }
            sendDeadlineMilliseconds = deadline
        } else {
            // A caller-supplied ID must carry the same frozen deadline on replay.
            guard clientMessageID == nil else { throw ProbeError.invalidConfiguration }
            sendDeadlineMilliseconds = UInt64(Date().timeIntervalSince1970 * 1_000) + 86_400_000
        }
        heldReadyPath = environment["IM_V2_GATEWAY_PROBE_HELD_READY_PATH"]
        heldReleasePath = environment["IM_V2_GATEWAY_PROBE_HELD_RELEASE_PATH"]
        heldDisableStartedPath = environment["IM_V2_GATEWAY_PROBE_HELD_DISABLE_STARTED_PATH"]
        batchReadyPath = environment["IM_V2_GATEWAY_PROBE_BATCH_READY_PATH"]
        batchReleasePath = environment["IM_V2_GATEWAY_PROBE_BATCH_RELEASE_PATH"]
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
        case .relationshipRequest, .relationshipAccept:
            guard targetUserID != nil, expectedRoomID == nil, expectedMessageID == nil,
                  mediaID == nil, clientMessageID == nil else {
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
        case .sendKnownRoomMessage, .sendKnownRoomExpectDenied, .barrierRoomSend:
            guard targetUserID == nil, expectedRoomID != nil, expectedMessageID == nil,
                  mediaID == nil, clientMessageID != nil else {
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
        if mode == .barrierRoomSend {
            guard let batchReadyPath, let batchReleasePath,
                  batchReadyPath.hasPrefix("/run/im-v2-remote-batch/"),
                  batchReleasePath.hasPrefix("/run/im-v2-remote-batch/"),
                  batchReadyPath != batchReleasePath else { throw ProbeError.invalidConfiguration }
        } else {
            guard batchReadyPath == nil, batchReleasePath == nil else {
                throw ProbeError.invalidConfiguration
            }
        }
        guard let accountBaseURL=URL(string:environment["IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL"] ?? "https://localhost:8443") else { throw ProbeError.invalidConfiguration }
        self.accountBaseURL=accountBaseURL
        host = environment["IM_V2_GATEWAY_PROBE_HOST"] ?? "127.0.0.1"
        serverName = environment["IM_V2_GATEWAY_PROBE_SERVER_NAME"] ?? "localhost"
        caPath = environment["IM_V2_GATEWAY_PROBE_CA_PATH"] ?? "/caddy/caddy/pki/authorities/local/root.crt"
        let rawPort = environment["IM_V2_GATEWAY_PROBE_PORT"] ?? "7443"
        guard let port = Int(rawPort), (1...65_535).contains(port),
              !host.isEmpty, !serverName.isEmpty, !caPath.isEmpty
        else { throw ProbeError.invalidConfiguration }
        if let expectedAddress = try? SocketAddress(ipAddress: serverName, port: port) {
            // With no SNI name, NIOSSL checks the peer IP. Require that peer
            // to be the explicitly requested certificate identity.
            guard let hostAddress = try? SocketAddress(ipAddress: host, port: port),
                  hostAddress == expectedAddress
            else { throw ProbeError.invalidConfiguration }
        }
        self.port = port
    }
}

private enum ProbeError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unexpectedResponse
    case messageDeliveryNotObserved
    case connectionClosed
    case heldBarrierTimedOut
    case serverRejected(String)
    case sendResponseCorrelation, sendResponseType, sendResultPending, sendReceiptMismatch
}

private enum ProbeResult: Sendable {
    case authenticated
    case messageAccepted(roomID: RoomID, messageID: MessageID)
    case messageDelivered
    case heldRequestDenied(reason: String)
    case knownRoomDenied(reason: String)
    case relationshipChanged

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
        case .knownRoomDenied(let reason):
            return "denied-\(reason)"
        case .relationshipChanged:
            return "local V2 relationship accepted or requested"
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
    private let sendTasks: V2ToolHTTPSendTaskOwner
    private var sendTaskID: UUID?
    private var finished = false
    private var authenticatedUserID: UserID?
    private var heldAuthenticated = false
    private var heldRequestDispatched = false
    private var heldStartedAt: Date?

    init(configuration: Configuration, completion: EventLoopPromise<ProbeResult>, sendTasks: V2ToolHTTPSendTaskOwner) {
        self.sendTasks = sendTasks
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
            hello.clientHello.supportsMessageSendOperations = true
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
        if let sendTaskID { sendTasks.cancel(id: sendTaskID) }
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
        if frame.requestID == 0, case .realtimeCoverage? = envelope.body {
            // Coverage changes are unsolicited control notifications, not a
            // response to the pending durable send (including a cold Owner).
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
            authenticatedUserID = try UserID(response.userID)
            switch configuration.mode {
            case .authenticate:
                finish(context: context, result: .success(.authenticated), closeChannel: false)
            case .sendDirectMessage:
                try sendOpenDirectRoom(actor:UserID(response.userID),context:context)
            case .relationshipRequest, .relationshipAccept:
                try sendRelationshipChange(actor:UserID(response.userID),context:context)
            case .receiveDirectMessage:
                try sendRoomEventPull(context: context)
            case .sendRoomMediaMessage:
                guard let roomID = configuration.expectedRoomID else { throw ProbeError.invalidConfiguration }
                try sendMessage(roomID: roomID, context: context)
            case .sendKnownRoomMessage, .sendKnownRoomExpectDenied:
                guard let roomID = configuration.expectedRoomID else { throw ProbeError.invalidConfiguration }
                try sendMessage(roomID: roomID, context: context)
            case .barrierRoomSend:
                try holdBatchSend(context: context)
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

        case .holdingBatchSend:
            throw ProbeError.unexpectedResponse

        case .awaitingMessageSend(let requestID, let command):
            guard frame.requestID == requestID else { throw ProbeError.sendResponseCorrelation }
            if case .error(let error)? = envelope.body,
               configuration.mode == .heldRoomSend || configuration.mode == .sendKnownRoomExpectDenied,
               error.code == "UNAUTHENTICATED" || error.code == "FORBIDDEN" || error.code == "DIRECT_MESSAGE_RESTRICTED" {
                let result: ProbeResult = configuration.mode == .heldRoomSend
                    ? .heldRequestDenied(reason: error.code) : .knownRoomDenied(reason: error.code)
                finish(context: context, result: .success(result))
                return
            }
            if case .error(let error)? = envelope.body {
                guard !error.code.isEmpty, error.code.utf8.count <= 64,
                      error.code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 })
                else { throw ProbeError.unexpectedResponse }
                throw ProbeError.serverRejected(error.code)
            }
            guard case .messageSendOperationResult(let wire)? = envelope.body else { throw ProbeError.sendResponseType }
            guard case .receipt(let receipt) = try V2MessageSendOperationWireCodec.decode(result: wire)
            else { throw ProbeError.sendResultPending }
            guard receipt.validates(identity: try command.identity, fingerprint: try command.fingerprint)
            else { throw ProbeError.sendReceiptMismatch }
            switch receipt.outcome {
            case .accepted(let acceptance):
                guard configuration.mode != .heldRoomSend, configuration.mode != .sendKnownRoomExpectDenied else {
                    throw ProbeError.unexpectedResponse
                }
                finish(context: context, result: .success(.messageAccepted(roomID: command.command.roomID,
                    messageID: acceptance.messageID)), closeChannel: false)
            case .rejected(let reason) where reason == .permissionDenied || reason == .directPolicyDenied:
                let code = reason == .directPolicyDenied ? "DIRECT_MESSAGE_RESTRICTED" : "FORBIDDEN"
                if configuration.mode == .heldRoomSend {
                    finish(context: context, result: .success(.heldRequestDenied(reason: code)))
                } else if configuration.mode == .sendKnownRoomExpectDenied {
                    finish(context: context, result: .success(.knownRoomDenied(reason: code)))
                } else { throw ProbeError.unexpectedResponse }
            default: throw ProbeError.unexpectedResponse
            }

        case .awaitingHTTP:
            if case .error? = envelope.body { throw ProbeError.unexpectedResponse }
            return

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

    private func holdBatchSend(context: ChannelHandlerContext) throws {
        guard let path = configuration.batchReadyPath else { throw ProbeError.invalidConfiguration }
        stage = .holdingBatchSend
        heldStartedAt = Date()
        try Data("authenticated\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        pollBatchRelease(context: context)
    }

    private func pollBatchRelease(context: ChannelHandlerContext) {
        guard !finished, case .holdingBatchSend = stage,
              let path = configuration.batchReleasePath,
              let startedAt = heldStartedAt else { return }
        if FileManager.default.fileExists(atPath: path) {
            do {
                guard let roomID = configuration.expectedRoomID else { throw ProbeError.invalidConfiguration }
                try sendMessage(roomID: roomID, context: context)
            } catch {
                finish(context: context, result: .failure(error))
            }
            return
        }
        guard Date().timeIntervalSince(startedAt) < 60 else {
            finish(context: context, result: .failure(ProbeError.heldBarrierTimedOut))
            return
        }
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        let boundContext = context.loopBound
        context.eventLoop.scheduleTask(in: .milliseconds(5)) {
            handler.value.pollBatchRelease(context: boundContext.value)
        }
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

    private func sendOpenDirectRoom(actor:UserID,context:ChannelHandlerContext) throws {
        guard let target=configuration.targetUserID else { throw ProbeError.invalidConfiguration }
        let configuration=self.configuration,operationID=try DirectRoomOperationID(UUID().uuidString)
        let command=try V2DirectRoomOperationCommand(actorUserID:actor,operationID:operationID,
            targetUserID:target,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600_000)
        stage = .awaitingHTTP
        let handler=NIOLoopBound(self,eventLoop:context.eventLoop),boundContext=context.loopBound
        context.eventLoop.makeFutureWithTask {
            try await V2ToolOperationHTTP.scoped(baseURL:configuration.accountBaseURL,caPath:configuration.caPath) { client in
                try await client.openDirectRoom(command:command,token:configuration.accessToken,deviceID:configuration.deviceID.rawValue)
            }
        }.whenComplete { result in
            let handler=handler.value,context=boundContext.value
            guard !handler.finished,context.channel.isActive else { return }
            do { try handler.sendMessage(roomID:result.get(),context:context) }
            catch { handler.finish(context:context,result:.failure(error)) }
        }
    }

    private func sendRelationshipChange(actor:UserID,context:ChannelHandlerContext) throws {
        guard let target=configuration.targetUserID else { throw ProbeError.invalidConfiguration }
        let configuration=self.configuration
        stage = .awaitingHTTP
        let handler=NIOLoopBound(self,eventLoop:context.eventLoop),boundContext=context.loopBound
        context.eventLoop.makeFutureWithTask {
            try await V2ToolOperationHTTP.scoped(baseURL:configuration.accountBaseURL,caPath:configuration.caPath) { client in
                try await client.changeRelationship(actor:actor,target:target,action:configuration.mode == .relationshipRequest ? .request:.accept,token:configuration.accessToken,deviceID:configuration.deviceID.rawValue)
            }
        }.whenComplete { result in
            let handler=handler.value,context=boundContext.value
            guard !handler.finished,context.channel.isActive else { return }
            switch result {
            case .success:handler.finish(context:context,result:.success(.relationshipChanged))
            case .failure(let error):handler.finish(context:context,result:.failure(error))
            }
        }
    }

    private func sendMessage(roomID: RoomID, context: ChannelHandlerContext) throws {
        guard let actor = authenticatedUserID else { throw ProbeError.unexpectedResponse }
        let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
            senderUserID: actor, clientMessageID: configuration.clientMessageID ?? .init(UUID().uuidString),
            text: Configuration.messageText, media: configuration.mediaID.map { [.init(mediaID: $0)] } ?? [],
            limits: .init(maxUTF8Bytes: 65_536)),
            firstSubmissionDeadlineMilliseconds: configuration.sendDeadlineMilliseconds)
        let requestID = takeRequestID()
        var request = IMV2Envelope()
        request.requestID = requestID
        request.protocolVersion = IMV2ProtocolVersion.current
        request.messageSendOperation = try V2MessageSendOperationWireCodec.encode(command: command)
        stage = .awaitingMessageSend(requestID, command)
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
        case holdingBatchSend
        case awaitingHTTP
        case awaitingMessageSend(UInt64, V2MessageSendOperationCommand)
        case awaitingRoomEventPage(UInt64, UInt64)
    }
}
