import Foundation
import NIOCore
import NIOPosix
import Vapor

enum IMTCPChannelWriter {
    static func writePacket<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        on channel: any Channel
    ) {
        do {
            let data = try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
            var buffer = channel.allocator.buffer(capacity: data.count + 4)
            buffer.writeInteger(UInt32(data.count), endianness: .big)
            buffer.writeBytes(data)
            channel.writeAndFlush(buffer, promise: nil)
        } catch {
            channel.close(promise: nil)
        }
    }

    static func sendKickAndClose(
        on channel: any Channel,
        reason: IMTCPKickReason,
        message: String
    ) {
        writePacket(
            type: .kick,
            requestID: nil,
            payload: IMTCPKickPayload(reason: reason, message: message),
            on: channel
        )
        channel.close(promise: nil)
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
    private var state: State = .waitingForAuth
    private var authTimeoutTask: Scheduled<Void>?

    init(application: Application) {
        self.application = application
    }

    func channelActive(context: ChannelHandlerContext) {
        let timeout = application.imTCPConfiguration.authTimeout
        let delay = TimeAmount.milliseconds(Int64(timeout * 1000))
        let channel = context.channel

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
                message: "Authentication timeout."
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
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        do {
            let packet = try IMTCPProtobufCodec.decode(frame)
            handle(packet: packet, channel: context.channel)
        } catch let error as IMTCPProtocolError {
            application.logger.debug(
                "IM TCP protocol error",
                metadata: ["error": .string(error.localizedDescription)]
            )
            sendKickAndClose(
                channel: context.channel,
                reason: .protocolError,
                message: error.localizedDescription
            )
        } catch {
            application.logger.debug(
                "IM TCP decode error",
                metadata: ["error": .string(String(describing: error))]
            )
            sendKickAndClose(
                channel: context.channel,
                reason: .protocolError,
                message: "Invalid packet."
            )
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        application.logger.debug(
            "IM TCP connection error",
            metadata: ["error": .string(String(describing: error))]
        )
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idleEvent = event as? IdleStateHandler.IdleStateEvent {
            switch idleEvent {
            case .read:
                sendKickAndClose(
                    channel: context.channel,
                    reason: .protocolError,
                    message: "Connection idle timeout."
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
        channel: any Channel
    ) throws {
        guard payload.protocolVersion == application.imTCPConfiguration.protocolVersion else {
            throw IMTCPProtocolError.unsupportedProtocolVersion(payload.protocolVersion)
        }

        state = .authenticating

        let remoteIPAddress = channel.remoteAddress?.ipAddress
        let authenticator = IMTCPAuthenticator(app: application, db: application.db)

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

                let control = IMConnectionControl(connectionID: connection.connectionID, channel: channel)

                try await application.connectionRoutingService.bind(connection, control: control)

                channel.eventLoop.execute {
                    self.authTimeoutTask?.cancel()
                    self.authTimeoutTask = nil
                    self.state = .authenticated(connection)

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
                }
            } catch {
                channel.eventLoop.execute {
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

        case .message:
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

                    try? await InlineOutboxProjectionRuntime(app: self.application).flushIfAllowed()

                    await self.application.connectionRoutingService.sendMessage(
                        result.message,
                        toUserIDs: result.recipientUserIDs
                    )
                    if result.didCreateMessage {
                        await IMConversationEventService(app: self.application).publish(
                            eventType: IMTCPConversationEventType.summaryUpdated,
                            conversationID: result.conversationID,
                            recipientUserIDs: result.recipientUserIDs,
                            actorUserID: connection.userID
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

        case .ack:
            return

        case .authOK, .authError, .heartbeatAck, .conversationEvent, .contactEvent, .kick:
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
        IMTCPChannelWriter.writePacket(type: type, requestID: requestID, payload: payload, on: channel)
    }

    private func sendAuthErrorAndClose(
        channel: any Channel,
        requestID: UUID?,
        code: String,
        message: String
    ) {
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
        message: String
    ) {
        guard case .closing = state else {
            removeAuthenticatedConnectionIfNeeded()
            state = .closing
            IMTCPChannelWriter.sendKickAndClose(on: channel, reason: reason, message: message)
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
}
