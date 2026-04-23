import Foundation
import NIOCore
import NIOPosix
import Vapor

enum IMTCPChannelWriter {
    static func writePacket<Payload: Codable & Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        on channel: any Channel
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let envelope = IMTCPPacketEnvelope(type: type, requestID: requestID, payload: payload)
            let data = try encoder.encode(envelope)
            var buffer = channel.allocator.buffer(capacity: data.count + 1)
            buffer.writeBytes(data)
            buffer.writeInteger(UInt8(ascii: "\n"))
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

final class IMTCPLineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = String

    private let newline = UInt8(ascii: "\n")
    private let maxFrameBytes: Int

    init(maxFrameBytes: Int) {
        self.maxFrameBytes = maxFrameBytes
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readableBytes = buffer.readableBytesView

        if readableBytes.count > maxFrameBytes {
            throw IMTCPProtocolError.frameTooLarge
        }

        if let firstLine = readableBytes.firstIndex(of: self.newline).map({ readableBytes[..<$0] }) {
            buffer.moveReaderIndex(forwardBy: firstLine.count + 1)
            context.fireChannelRead(Self.wrapInboundOut(String(buffer: ByteBuffer(firstLine))))
            return .continue
        }

        return .needMoreData
    }
}

final class IMTCPConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = String

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
                await self.application.imConnectionRegistry.remove(connectionID: connection.connectionID)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = unwrapInboundIn(data)

        do {
            let packet = try decodePacket(from: line)
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

                await application.imConnectionRegistry.bind(connection, control: control)

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
            let service = IMRealtimeMessageService(db: application.db)

            Task {
                do {
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

                    await self.application.imConnectionRegistry.sendMessage(
                        result.message,
                        toUserIDs: result.recipientUserIDs
                    )
                    if result.didCreateMessage {
                        await IMConversationEventService(app: self.application, db: self.application.db).publish(
                            eventType: IMTCPConversationEventType.summaryUpdated,
                            conversationID: result.conversationID,
                            recipientUserIDs: result.recipientUserIDs,
                            actorUserID: connection.userID
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
                        metadata: ["error": .string(String(describing: error))]
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

        case .authOK, .authError, .heartbeatAck, .conversationEvent, .kick:
            sendKickAndClose(
                channel: channel,
                reason: .protocolError,
                message: IMTCPProtocolError.unsupportedPacketType.localizedDescription
            )
        }
    }

    private func decodePacket(from line: String) throws -> IMTCPInboundPacket {
        guard let data = line.data(using: .utf8) else {
            throw IMTCPProtocolError.invalidEnvelope
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IMTCPInboundPacket.self, from: data)
    }

    private func writePacket<Payload: Codable & Sendable>(
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
            state = .closing
            IMTCPChannelWriter.sendKickAndClose(on: channel, reason: reason, message: message)
            return
        }
    }
}
