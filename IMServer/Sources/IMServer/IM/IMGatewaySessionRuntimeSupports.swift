import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor


protocol GatewaySessionTransport: Sendable {
    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async
    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async
    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async
    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async
    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async
    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int]
}

protocol SessionDirectory: Sendable {
    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>]
    func activeNodeIDs() async throws -> Set<String>
}

protocol GatewayDispatchBus: Sendable {
    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws
}

struct ConnectionRoutingSessionDirectory: SessionDirectory {
    let presenceStore: any PresenceStore

    func routeNodeIDs(forUserIDs userIDs: [UUID]) async throws -> [UUID: Set<String>] {
        try await presenceStore.routeNodeIDs(forUserIDs: userIDs)
    }

    func activeNodeIDs() async throws -> Set<String> {
        try await presenceStore.activeNodeIDs()
    }
}

struct ConnectionRoutingGatewayDispatchBus: GatewayDispatchBus {
    let dispatchService: any NodeMessageDispatchService

    func dispatch(_ envelope: NodeMessageDispatchEnvelope, toNodeID nodeID: String) async throws {
        try await dispatchService.dispatch(envelope, toNodeID: nodeID)
    }
}

struct LocalGatewaySessionTransport: GatewaySessionTransport {
    let routingService: ConnectionRoutingService

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        await routingService.sendMessage(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendConversationEvent(payload, toUserID: userID, requestID: requestID)
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendContactEvent(payload, toUserID: userID, requestID: requestID)
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await routingService.kickConnections(forSessionID: sessionID, reason: reason, message: message)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await routingService.kickConnections(forUserID: userID, reason: reason, message: message)
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        await routingService.activeConnectionCounts(forSessionIDs: sessionIDs)
    }
}

struct HTTPGatewaySessionTransport: GatewaySessionTransport {
    let app: Application
    let configuration: IMGatewayRelayConfiguration

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        guard let packetBase64 = packetBase64(type: .message, requestID: requestID, payload: payload) else {
            return
        }
        await postOrLog(
            path: "/internal/gateway/realtime/message",
            payload: GatewayRelayMessageRequest(
                packetBase64: packetBase64,
                recipientUserIDs: userIDs,
                requestID: requestID
            )
        )
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        guard let packetBase64 = packetBase64(type: .conversationEvent, requestID: requestID, payload: payload) else {
            return
        }
        await postOrLog(
            path: "/internal/gateway/realtime/conversation-event",
            payload: GatewayRelayConversationEventRequest(
                packetBase64: packetBase64,
                recipientUserID: userID,
                requestID: requestID
            )
        )
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        guard let packetBase64 = packetBase64(type: .contactEvent, requestID: requestID, payload: payload) else {
            return
        }
        await postOrLog(
            path: "/internal/gateway/realtime/contact-event",
            payload: GatewayRelayContactEventRequest(
                packetBase64: packetBase64,
                recipientUserID: userID,
                requestID: requestID
            )
        )
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await postOrLog(
            path: "/internal/gateway/realtime/kick-session",
            payload: GatewayRelayKickSessionRequest(
                sessionID: sessionID,
                reason: reason,
                message: message
            )
        )
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await postOrLog(
            path: "/internal/gateway/realtime/kick-user",
            payload: GatewayRelayKickUserRequest(
                userID: userID,
                reason: reason,
                message: message
            )
        )
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        guard !sessionIDs.isEmpty else { return [:] }

        do {
            let response: GatewayRelaySessionCountsResponse = try await post(
                path: "/internal/gateway/realtime/session-counts",
                payload: GatewayRelaySessionCountsRequest(sessionIDs: sessionIDs)
            )
            return response.counts
        } catch {
            await app.routingMetrics.recordSessionCountQueryFailed()
            app.logger.warning(
                "Gateway relay session count request failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "path": .string("/internal/gateway/realtime/session-counts"),
                    "session_count": .stringConvertible(sessionIDs.count),
                    "error": .string(String(describing: error))
                ]
            )
            return [:]
        }
    }

    private func post<Payload: Content>(path: String, payload: Payload) async throws {
        let _: EmptyGatewayRelayResponse = try await post(path: path, payload: payload)
    }

    private func postOrLog<Payload: Content>(path: String, payload: Payload) async {
        do {
            try await post(path: path, payload: payload)
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning(
                "Gateway relay request failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "path": .string(path),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    private func post<Payload: Content, Response: Content>(path: String, payload: Payload) async throws -> Response {
        guard let baseURL = configuration.baseURL else {
            throw GatewayRelayTransportError.missingBaseURL
        }

        let response = try await app.client.post(URI(string: "\(baseURL)\(path)")) { request in
            if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
                request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
            }
            try request.content.encode(payload)
        }

        guard response.status == .ok else {
            app.logger.warning(
                "Gateway relay request failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "path": .string(path),
                    "status": .string(response.status.code.description)
                ]
            )
            throw GatewayRelayTransportError.unexpectedStatus(response.status)
        }

        if Response.self == EmptyGatewayRelayResponse.self {
            return EmptyGatewayRelayResponse() as! Response
        }

        return try response.content.decode(Response.self)
    }

    private func packetBase64<Payload: Sendable>(
        type: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload
    ) -> String? {
        do {
            return try IMTCPProtobufCodec.encode(type: type, requestID: requestID, payload: payload)
                .base64EncodedString()
        } catch {
            app.logger.warning(
                "Gateway relay packet encode failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "packet_type": .string(type.rawValue),
                    "error": .string(String(describing: error))
                ]
            )
            return nil
        }
    }
}

private struct EmptyGatewayRelayResponse: Content {}

private enum GatewayRelayTransportError: Error {
    case missingBaseURL
    case unexpectedStatus(HTTPResponseStatus)
}

struct LoggingUnavailableGatewaySessionTransport: GatewaySessionTransport {
    let logger: Logger
    let role: IMRuntimeRole

    func sendMessage(_ payload: IMTCPMessagePayload, toUserIDs userIDs: [UUID], requestID: UUID?) async {
        logUnavailable()
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        logUnavailable()
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        logUnavailable()
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        [:]
    }

    private func logUnavailable() {
        logger.warning(
            "Gateway session transport unavailable; realtime relay skipped",
            metadata: ["role": .string(role.rawValue)]
        )
    }
}

struct GatewaySessionService {
    let transport: any GatewaySessionTransport

    func bind(_ connection: IMAuthenticatedConnection, control: IMConnectionControl) async throws {
        if let transport = transport as? LocalGatewaySessionTransport {
            try await transport.routingService.bind(connection, control: control)
        }
    }

    func remove(connectionID: UUID) async {
        if let transport = transport as? LocalGatewaySessionTransport {
            await transport.routingService.remove(connectionID: connectionID)
        }
    }

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await transport.sendMessage(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await transport.sendConversationEvent(payload, toUserID: userID, requestID: requestID)
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await transport.sendContactEvent(payload, toUserID: userID, requestID: requestID)
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await transport.kickConnections(forSessionID: sessionID, reason: reason, message: message)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await transport.kickConnections(forUserID: userID, reason: reason, message: message)
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        await transport.activeConnectionCounts(forSessionIDs: sessionIDs)
    }
}

protocol ConversationEventBus: Sendable {
    func publish(
        type: ConversationDomainEventType,
        conversationID: UUID,
        payload: ConversationDomainEventPayload,
        on database: (any Database)?
    ) async throws
}

protocol ConversationEventStreamProducer: Sendable {
    var driverName: String { get }
    func publish(_ envelope: ConversationEventStreamEnvelope) async throws
    func shutdown() async
}

extension ConversationEventStreamProducer {
    func shutdown() async {}
}
