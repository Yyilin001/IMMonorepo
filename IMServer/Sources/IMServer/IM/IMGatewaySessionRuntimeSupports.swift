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
}

struct HTTPGatewaySessionTransport: GatewaySessionTransport {
    let app: Application
    let configuration: IMGatewayRelayConfiguration

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        try? await post(
            path: "/internal/gateway/realtime/message",
            payload: GatewayRelayMessageRequest(
                payload: payload,
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
        try? await post(
            path: "/internal/gateway/realtime/conversation-event",
            payload: GatewayRelayConversationEventRequest(
                payload: payload,
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
        try? await post(
            path: "/internal/gateway/realtime/contact-event",
            payload: GatewayRelayContactEventRequest(
                payload: payload,
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
        try? await post(
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
        try? await post(
            path: "/internal/gateway/realtime/kick-user",
            payload: GatewayRelayKickUserRequest(
                userID: userID,
                reason: reason,
                message: message
            )
        )
    }

    private func post<Payload: Content>(path: String, payload: Payload) async throws {
        guard let baseURL = configuration.baseURL else {
            return
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
                    "path": .string(path),
                    "status": .string(response.status.code.description)
                ]
            )
            return
        }
    }
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
