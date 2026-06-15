import Foundation
import NIOCore
import NIOPosix
import Vapor

enum IMTCPChannelWriter {
    static func writePacket<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        on channel: any Channel,
        metrics: RoutingMetrics? = nil,
        dropWhenNotWritable: Bool = false,
        channelIsWritable: Bool? = nil,
        slowWriteThresholdMilliseconds: Int = 1000,
        slowWriteHandler: (@Sendable (Int) -> Void)? = nil,
        writeCompletionHandler: (@Sendable (Bool) -> Void)? = nil
    ) {
        let isWritable = channelIsWritable ?? channel.isWritable
        if dropWhenNotWritable, !isWritable {
            if let metrics {
                Task {
                    await metrics.recordTCPWriteBackpressure()
                    await metrics.recordTCPWriteDroppedBackpressure()
                }
            }
            return
        }
        do {
            let data = try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
            var buffer = channel.allocator.buffer(capacity: data.count + 4)
            buffer.writeInteger(UInt32(data.count), endianness: .big)
            buffer.writeBytes(data)
            writeAndFlush(
                buffer,
                on: channel,
                metrics: metrics,
                dropWhenNotWritable: dropWhenNotWritable,
                channelIsWritable: isWritable,
                slowWriteThresholdMilliseconds: slowWriteThresholdMilliseconds,
                slowWriteHandler: slowWriteHandler,
                writeCompletionHandler: writeCompletionHandler
            )
        } catch {
            channel.close(promise: nil)
        }
    }

    static func writeEncodedPacket(
        _ data: Data,
        on channel: any Channel,
        metrics: RoutingMetrics? = nil,
        dropWhenNotWritable: Bool = false,
        channelIsWritable: Bool? = nil,
        slowWriteThresholdMilliseconds: Int = 1000,
        slowWriteHandler: (@Sendable (Int) -> Void)? = nil,
        writeCompletionHandler: (@Sendable (Bool) -> Void)? = nil
    ) {
        let isWritable = channelIsWritable ?? channel.isWritable
        if dropWhenNotWritable, !isWritable {
            if let metrics {
                Task {
                    await metrics.recordTCPWriteBackpressure()
                    await metrics.recordTCPWriteDroppedBackpressure()
                }
            }
            return
        }
        var buffer = channel.allocator.buffer(capacity: data.count + 4)
        buffer.writeInteger(UInt32(data.count), endianness: .big)
        buffer.writeBytes(data)
        writeAndFlush(
            buffer,
            on: channel,
            metrics: metrics,
            dropWhenNotWritable: dropWhenNotWritable,
            channelIsWritable: isWritable,
            slowWriteThresholdMilliseconds: slowWriteThresholdMilliseconds,
            slowWriteHandler: slowWriteHandler,
            writeCompletionHandler: writeCompletionHandler
        )
    }

    static func sendKickAndClose(
        on channel: any Channel,
        reason: IMTCPKickReason,
        message: String,
        metrics: RoutingMetrics? = nil
    ) {
        writePacket(
            type: .kick,
            requestID: nil,
            payload: IMTCPKickPayload(reason: reason, message: message),
            on: channel,
            metrics: metrics
        )
        channel.close(promise: nil)
    }

    private static func writeAndFlush(
        _ buffer: ByteBuffer,
        on channel: any Channel,
        metrics: RoutingMetrics?,
        dropWhenNotWritable: Bool = false,
        channelIsWritable: Bool? = nil,
        slowWriteThresholdMilliseconds: Int = 1000,
        slowWriteHandler: (@Sendable (Int) -> Void)? = nil,
        writeCompletionHandler: (@Sendable (Bool) -> Void)? = nil
    ) {
        let isWritable = channelIsWritable ?? channel.isWritable
        if let metrics, !isWritable {
            Task {
                await metrics.recordTCPWriteBackpressure()
                if dropWhenNotWritable {
                    await metrics.recordTCPWriteDroppedBackpressure()
                }
            }
            if dropWhenNotWritable {
                return
            }
        }
        guard let metrics else {
            channel.writeAndFlush(buffer, promise: nil)
            return
        }

        let startedAt = Date()
        let slowWriteThresholdMilliseconds = max(0, slowWriteThresholdMilliseconds)
        channel.writeAndFlush(buffer).whenComplete { result in
            let latencyMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            let didWriteSlow = slowWriteThresholdMilliseconds > 0
                && latencyMilliseconds >= slowWriteThresholdMilliseconds
            if didWriteSlow {
                slowWriteHandler?(latencyMilliseconds)
            }
            writeCompletionHandler?(didWriteSlow)
            Task {
                if didWriteSlow {
                    await metrics.recordTCPWriteSlow(latencyMilliseconds: latencyMilliseconds)
                }
                switch result {
                case .success:
                    await metrics.recordTCPWriteCompleted(latencyMilliseconds: latencyMilliseconds)
                case .failure:
                    await metrics.recordTCPWriteFailed(latencyMilliseconds: latencyMilliseconds)
                }
            }
        }
    }
}

final class IMTCPFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = Data

    private let maxFrameBytes: Int

    init(maxFrameBytes: Int) {
        self.maxFrameBytes = maxFrameBytes
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex, endianness: .big) else {
            return .needMoreData
        }
        guard length <= UInt32(maxFrameBytes) else {
            throw IMTCPProtocolError.frameTooLarge
        }

        let frameLength = Int(length)
        guard buffer.readableBytes >= 4 + frameLength else {
            return .needMoreData
        }

        buffer.moveReaderIndex(forwardBy: 4)
        guard let bytes = buffer.readBytes(length: frameLength) else {
            return .needMoreData
        }
        context.fireChannelRead(Self.wrapInboundOut(Data(bytes)))
        return .continue
    }
}

final class IMTCPConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Data

    private enum State {
        case waitingForAuth
        case authenticating
        case authenticated(IMAuthenticatedConnection)
        case closing
    }

    private let application: Application
    private let traceID = UUID()
    private var state: State = .waitingForAuth
    private var closeReason: String?
    private var lastError: String?
    private var lastDebugError: String?
    private var didReceiveInputClosed = false
    private var authTimeoutTask: Scheduled<Void>?

    init(application: Application) {
        self.application = application
    }

    func channelActive(context: ChannelHandlerContext) {
        let timeout = application.imTCPConfiguration.authTimeout
        let delay = TimeAmount.milliseconds(Int64(timeout * 1000))
        let channel = context.channel
        Task {
            await self.application.routingMetrics.recordTCPChannelActive()
        }
        application.logger.debug(
            "IM TCP channel active",
            metadata: logMetadata(channel: channel)
        )

        authTimeoutTask = channel.eventLoop.scheduleTask(in: delay) { [weak self, channel] in
            guard let self else {
                return
            }

            guard case .waitingForAuth = self.state else {
                return
            }

            self.sendKickAndClose(
                channel: channel,
                reason: .protocolError,
                message: "Authentication timeout.",
                closeReason: "auth_timeout"
            )
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        authTimeoutTask?.cancel()
        authTimeoutTask = nil

        if case .authenticated(let connection) = state {
            Task {
                await self.application.connectionRoutingService.remove(connectionID: connection.connectionID)
            }
        }

        Task {
            await self.application.routingMetrics.recordTCPChannelInactive(
                closeReason: self.closeReason,
                state: self.stateName
            )
        }
        application.logger.debug(
            "IM TCP channel inactive",
            metadata: logMetadata(channel: context.channel, extra: [
                "close_reason": .string(closeReason ?? "peer_or_unknown"),
                "input_closed": .stringConvertible(didReceiveInputClosed),
                "last_error": .string(lastError ?? ""),
                "last_debug_error": .string(lastDebugError ?? "")
            ])
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        do {
            let packet = try IMTCPProtobufCodec.decode(frame)
            if packet.type == .auth {
                Task {
                    await self.application.routingMetrics.recordTCPAuthReceived()
                }
                application.logger.debug(
                    "IM TCP auth received",
                    metadata: logMetadata(channel: context.channel, extra: [
                        "requestID": .string(packet.requestID?.uuidString ?? "")
                    ])
                )
            }
            handle(packet: packet, channel: context.channel)
        } catch let error as IMTCPProtocolError {
            application.logger.debug(
                "IM TCP protocol error",
                metadata: ["error": .string(error.localizedDescription)]
            )
            sendKickAndClose(
                channel: context.channel,
                reason: .protocolError,
                message: error.localizedDescription,
                closeReason: "kick:protocol_error"
            )
        } catch {
            application.logger.debug(
                "IM TCP decode error",
                metadata: ["error": .string(String(describing: error))]
            )
            sendKickAndClose(
                channel: context.channel,
                reason: .protocolError,
                message: "Invalid packet.",
                closeReason: "kick:protocol_error"
            )
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        let errorText = String(describing: error)
        let debugErrorText = String(reflecting: error)
        lastError = errorText
        lastDebugError = debugErrorText
        closeReason = Self.closeReason(for: error, errorText: errorText, debugErrorText: debugErrorText)
        Task {
            await self.application.routingMetrics.recordTCPErrorCaught()
        }
        application.logger.warning(
            "IM TCP connection error",
            metadata: logMetadata(context: context, extra: [
                "error": .string(errorText),
                "debugError": .string(debugErrorText),
                "close_reason": .string(closeReason ?? "")
            ])
        )
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let closeReasonEvent = event as? IMTCPConnectionCloseReasonEvent {
            closeReason = closeReasonEvent.reason
            application.logger.debug(
                "IM TCP close reason event",
                metadata: logMetadata(context: context, extra: [
                    "close_reason": .string(closeReasonEvent.reason)
                ])
            )
            return
        }

        if let channelEvent = event as? ChannelEvent {
            switch channelEvent {
            case .inputClosed:
                didReceiveInputClosed = true
                if closeReason == nil {
                    closeReason = "peer_input_closed"
                }
                application.logger.debug(
                    "IM TCP input closed",
                    metadata: logMetadata(context: context, extra: [
                        "close_reason": .string(closeReason ?? "")
                    ])
                )
                context.close(promise: nil)
                return
            default:
                break
            }
        }

        if let idleEvent = event as? IdleStateHandler.IdleStateEvent {
            switch idleEvent {
            case .read:
                Task {
                    await self.application.routingMetrics.recordTCPIdleTimeout()
                }
                application.logger.info(
                    "IM TCP idle timeout",
                    metadata: logMetadata(context: context)
                )
                sendKickAndClose(
                    channel: context.channel,
                    reason: .protocolError,
                    message: "Connection idle timeout.",
                    closeReason: "idle_timeout"
                )
            case .write, .all:
                break
            }
            return
        }

        context.fireUserInboundEventTriggered(event)
    }

    private func handle(packet: IMTCPInboundPacket, channel: any Channel) {
        switch state {
        case .waitingForAuth:
            guard packet.type == .auth else {
                sendKickAndClose(
                    channel: channel,
                    reason: .protocolError,
                    message: IMTCPProtocolError.authRequired.localizedDescription
                )
                return
            }

            do {
                let payload = try packet.payload.decodePayload(IMTCPAuthRequestPayload.self)
                try beginAuthentication(
                    payload: payload,
                    requestID: packet.requestID,
                    protocolVersion: packet.protocolVersion,
                    channel: channel
                )
            } catch {
                sendAuthErrorAndClose(
                    channel: channel,
                    requestID: packet.requestID,
                    code: "invalid_auth_payload",
                    message: "Invalid auth payload."
                )
            }

        case .authenticating:
            sendKickAndClose(
                channel: channel,
                reason: .protocolError,
                message: "Authentication already in progress."
            )

        case .authenticated:
            handleAuthenticated(packet: packet, channel: channel)

        case .closing:
            return
        }
    }

    private func beginAuthentication(
        payload: IMTCPAuthRequestPayload,
        requestID: UUID?,
        protocolVersion: Int,
        channel: any Channel
    ) throws {
        guard protocolVersion == application.imTCPConfiguration.protocolVersion else {
            throw IMTCPProtocolError.unsupportedProtocolVersion(protocolVersion)
        }

        state = .authenticating

        let remoteIPAddress = channel.remoteAddress?.ipAddress
        let authenticator = IMTCPAuthenticator(app: application, db: application.db)
        application.logger.debug(
            "IM TCP auth started",
            metadata: logMetadata(channel: channel, extra: [
                "requestID": .string(requestID?.uuidString ?? ""),
                "deviceID": .string(payload.deviceID ?? ""),
                "protocolVersion": .stringConvertible(protocolVersion)
            ])
        )

        Task {
            do {
                let connection = try await authenticator.authenticate(
                    accessToken: payload.accessToken,
                    remoteIPAddress: remoteIPAddress,
                    deviceID: payload.deviceID,
                    deviceName: payload.deviceName,
                    platform: payload.platform,
                    appVersion: payload.appVersion
                )

                let control = IMConnectionControl(
                    connectionID: connection.connectionID,
                    channel: channel,
                    metrics: self.application.routingMetrics,
                    slowWriteThresholdMilliseconds: self.application.imTCPConfiguration.slowWriteThresholdMilliseconds,
                    slowWriteCloseConsecutiveCount: self.application.imTCPConfiguration.slowWriteCloseConsecutiveCount
                )

                try await application.connectionRoutingService.bind(connection, control: control)

                channel.eventLoop.execute {
                    self.authTimeoutTask?.cancel()
                    self.authTimeoutTask = nil
                    self.state = .authenticated(connection)
                    Task {
                        await self.application.routingMetrics.recordTCPAuthOKSent()
                    }

                    let response = IMTCPAuthAcceptedPayload(
                        connectionID: connection.connectionID,
                        userID: connection.userID,
                        sessionID: connection.sessionID,
                        heartbeatIntervalSeconds: Int(self.application.imTCPConfiguration.heartbeatInterval),
                        serverTime: Date()
                    )
                    self.writePacket(
                        type: .authOK,
                        requestID: requestID,
                        payload: response,
                        channel: channel
                    )
                    self.application.logger.debug(
                        "IM TCP auth OK sent",
                        metadata: self.logMetadata(channel: channel, extra: [
                            "requestID": .string(requestID?.uuidString ?? ""),
                            "connectionID": .string(connection.connectionID.uuidString),
                            "userID": .string(connection.userID.uuidString),
                            "sessionID": .string(connection.sessionID.uuidString)
                        ])
                    )
                }
            } catch {
                channel.eventLoop.execute {
                    self.application.logger.info(
                        "IM TCP auth failed",
                        metadata: self.logMetadata(channel: channel, extra: [
                            "requestID": .string(requestID?.uuidString ?? ""),
                            "error": .string(String(describing: error)),
                            "debugError": .string(String(reflecting: error))
                        ])
                    )
                    self.sendAuthErrorAndClose(
                        channel: channel,
                        requestID: requestID,
                        code: "invalid_token",
                        message: "Current login is invalid. Please sign in again."
                    )
                }
            }
        }
    }

    private func handleAuthenticated(packet: IMTCPInboundPacket, channel: any Channel) {
        switch packet.type {
        case .heartbeat:
            let payload = (try? packet.payload.decodePayload(IMTCPHeartbeatPayload.self)) ?? IMTCPHeartbeatPayload(sequence: 0)
            if case .authenticated(let connection) = state {
                Task {
                    await self.application.connectionRoutingService.refreshActiveConversationPresence(
                        connectionID: connection.connectionID
                    )
                }
            }
            writePacket(
                type: .heartbeatAck,
                requestID: packet.requestID,
                payload: payload,
                channel: channel
            )

        case .auth:
            sendKickAndClose(
                channel: channel,
                reason: .protocolError,
                message: IMTCPProtocolError.duplicateAuth.localizedDescription
            )

        case .sendMessage:
            guard
                let payload = try? packet.payload.decodePayload(IMTCPMessagePayload.self),
                case .authenticated(let connection) = state
            else {
                sendKickAndClose(
                    channel: channel,
                    reason: .protocolError,
                    message: "Invalid message payload."
                )
                return
            }

            let requestID = packet.requestID
            let service = IMRealtimeMessageService(app: application)

            Task {
                do {
                    try await AuthService(app: self.application, db: self.application.db)
                        .validateActiveSession(id: connection.sessionID, userID: connection.userID)

                    let result = try await service.persistIncomingMessage(
                        payload,
                        senderUserID: connection.userID
                    )

                    channel.eventLoop.execute {
                        self.writePacket(
                            type: .ack,
                            requestID: requestID,
                            payload: result.acknowledgement,
                            channel: channel
                        )
                    }

                } catch AuthError.sessionRevoked, AuthError.sessionExpired, AuthError.invalidToken {
                    channel.eventLoop.execute {
                        self.sendKickAndClose(
                            channel: channel,
                            reason: .sessionRevoked,
                            message: "Current login is invalid. Please sign in again."
                        )
                    }
                } catch let error as IMRealtimeMessageError {
                    channel.eventLoop.execute {
                        self.writePacket(
                            type: .ack,
                            requestID: requestID,
                            payload: IMTCPAckPayload(
                                messageID: payload.clientMessageID ?? requestID?.uuidString ?? UUID().uuidString,
                                conversationID: payload.conversationID,
                                status: error.ackStatus
                            ),
                            channel: channel
                        )
                    }
                } catch {
                    self.application.logger.error(
                        "IM TCP message persistence failed",
                        metadata: [
                            "error": .string(String(describing: error)),
                            "debugError": .string(String(reflecting: error)),
                            "conversationID": .string(payload.conversationID),
                            "clientMessageID": .string(payload.clientMessageID ?? ""),
                            "senderUserID": .string(connection.userID.uuidString)
                        ]
                    )
                    channel.eventLoop.execute {
                        self.writePacket(
                            type: .ack,
                            requestID: requestID,
                            payload: IMTCPAckPayload(
                                messageID: payload.clientMessageID ?? requestID?.uuidString ?? UUID().uuidString,
                                conversationID: payload.conversationID,
                                status: "internal_error"
                            ),
                            channel: channel
                        )
                    }
                }
            }

        case .conversationActivity:
            guard
                let payload = try? packet.payload.decodePayload(IMTCPConversationActivityPayload.self),
                let conversationID = UUID(uuidString: payload.conversationID),
                case .authenticated(let connection) = state
            else {
                sendKickAndClose(
                    channel: channel,
                    reason: .protocolError,
                    message: "Invalid conversation activity payload."
                )
                return
            }

            Task {
                let didUpdate = await self.application.connectionRoutingService.updateConversationActivity(
                    connectionID: connection.connectionID,
                    conversationID: conversationID,
                    isActive: payload.isActive
                )
                self.application.logger.debug(
                    "IM TCP conversation activity updated",
                    metadata: [
                        "connectionID": .string(connection.connectionID.uuidString),
                        "userID": .string(connection.userID.uuidString),
                        "conversationID": .string(conversationID.uuidString),
                        "isActive": .stringConvertible(payload.isActive),
                        "didUpdate": .stringConvertible(didUpdate)
                    ]
                )
            }

        case .ack:
            return

        case .authOK, .authError, .heartbeatAck, .domainEvent, .streamSignal, .kick:
            sendKickAndClose(
                channel: channel,
                reason: .protocolError,
                message: IMTCPProtocolError.unsupportedPacketType.localizedDescription
            )
        }
    }

    private func writePacket<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        channel: any Channel
    ) {
        IMTCPChannelWriter.writePacket(
            type: type,
            requestID: requestID,
            payload: payload,
            on: channel,
            metrics: application.routingMetrics
        )
    }

    private func sendAuthErrorAndClose(
        channel: any Channel,
        requestID: UUID?,
        code: String,
        message: String
    ) {
        closeReason = "auth_error"
        Task {
            await self.application.routingMetrics.recordTCPAuthErrorSent()
        }
        application.logger.info(
            "IM TCP auth error sent",
            metadata: logMetadata(channel: channel, extra: [
                "requestID": .string(requestID?.uuidString ?? ""),
                "code": .string(code),
                "message": .string(message)
            ])
        )
        state = .closing
        writePacket(
            type: .authError,
            requestID: requestID,
            payload: IMTCPAuthErrorPayload(code: code, message: message),
            channel: channel
        )
        channel.close(promise: nil)
    }

    private func sendKickAndClose(
        channel: any Channel,
        reason: IMTCPKickReason,
        message: String,
        closeReason: String? = nil
    ) {
        guard case .closing = state else {
            self.closeReason = closeReason ?? "kick:\(reason.rawValue)"
            Task {
                await self.application.routingMetrics.recordTCPKickSent()
            }
            application.logger.info(
                "IM TCP kick sent",
                metadata: logMetadata(channel: channel, extra: [
                    "kick_reason": .string(reason.rawValue),
                    "close_reason": .string(self.closeReason ?? ""),
                    "message": .string(message)
                ])
            )
            removeAuthenticatedConnectionIfNeeded()
            state = .closing
            IMTCPChannelWriter.sendKickAndClose(
                on: channel,
                reason: reason,
                message: message,
                metrics: application.routingMetrics
            )
            return
        }
    }

    private func removeAuthenticatedConnectionIfNeeded() {
        guard case .authenticated(let connection) = state else {
            return
        }
        Task {
            await self.application.connectionRoutingService.remove(connectionID: connection.connectionID)
        }
    }

    private func logMetadata(context: ChannelHandlerContext, extra: Logger.Metadata = [:]) -> Logger.Metadata {
        logMetadata(channel: context.channel, extra: extra)
    }

    private func logMetadata(channel: any Channel, extra: Logger.Metadata = [:]) -> Logger.Metadata {
        var metadata = extra
        metadata["traceID"] = .string(traceID.uuidString)
        metadata["state"] = .string(stateName)
        metadata["remote"] = .string(channel.remoteAddress.map(String.init(describing:)) ?? "")
        if let closeReason {
            metadata["close_reason"] = .string(closeReason)
        }
        if case .authenticated(let connection) = state {
            metadata["connectionID"] = .string(connection.connectionID.uuidString)
            metadata["userID"] = .string(connection.userID.uuidString)
            metadata["sessionID"] = .string(connection.sessionID.uuidString)
        }
        return metadata
    }

    private static func closeReason(
        for error: any Error,
        errorText: String,
        debugErrorText: String
    ) -> String {
        let combined = "\(errorText) \(debugErrorText)".lowercased()
        if combined.contains("connection reset") || combined.contains("econnreset") {
            return "error:connection_reset"
        }
        return "error:\(String(reflecting: type(of: error)))"
    }

    private var stateName: String {
        switch state {
        case .waitingForAuth:
            return "waitingForAuth"
        case .authenticating:
            return "authenticating"
        case .authenticated:
            return "authenticated"
        case .closing:
            return "closing"
        }
    }
}
