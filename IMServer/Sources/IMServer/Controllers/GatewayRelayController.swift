import NIOCore
import Vapor

struct GatewayRelayController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let relayRoutes = routes.grouped("internal", "gateway", "realtime")
            .grouped(InternalGatewayRelaySecretMiddleware())

        relayRoutes.post("domain-event", use: relayDomainEvent)
        relayRoutes.on(
            .POST,
            "domain-event-packet",
            body: .collect(maxSize: "1mb"),
            use: relayDomainEventPacket
        )
        relayRoutes.on(
            .POST,
            "domain-event-packet-bin",
            body: .collect(maxSize: "1mb"),
            use: relayDomainEventPacketBinary
        )
        relayRoutes.on(
            .POST,
            "domain-event-packets",
            body: .collect(maxSize: "256kb"),
            use: relayDomainEventPackets
        )
        relayRoutes.post("stream-signal", use: relayStreamSignal)
        relayRoutes.post("kick-session", use: relayKickSession)
        relayRoutes.post("kick-user", use: relayKickUser)
        relayRoutes.post("session-counts", use: relaySessionCounts)
    }

    func relayDomainEvent(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayDomainEventDeliveryRequest.self)
        let db = req.application.summaryShardRouter.database(forOwnerUserID: body.ownerUserID)
        guard let delivery = try await OwnerDomainEventDeliveryService(db: db).find(
            ownerUserID: body.ownerUserID,
            eventID: body.eventID
        ) else {
            req.application.logger.warning("Gateway relay skipped missing owner delivery row.", metadata: [
                "owner_user_id": .string(body.ownerUserID.uuidString),
                "event_id": .string(body.eventID.uuidString)
            ])
            return .ok
        }
        _ = try OwnerDomainEventDeliveryService(db: db).canonicalDelivery(from: delivery)
        await req.application.gatewaySessionService.sendDomainEventDelivery(
            ownerUserID: body.ownerUserID,
            eventID: body.eventID,
            requestID: body.requestID ?? body.eventID
        )
        return .ok
    }

    func relayStreamSignal(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayMessageRequest.self)
        let packet = try packet(from: body.packetBase64)
        await req.application.gatewaySessionService.sendStreamSignal(
            try packet.payload.decodePayload(IMTCPMessageStreamSignalPayload.self),
            toUserIDs: body.recipientUserIDs,
            requestID: packet.requestID ?? body.requestID
        )
        return .ok
    }

    func relayDomainEventPacket(req: Request) async throws -> HTTPStatus {
        let startedAt = Date()
        let body = try req.content.decode(GatewayRelayDomainEventPayloadRequest.self)
        let requestDecodeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        guard !body.recipientUserIDs.isEmpty else {
            return .ok
        }
        let payloadDecodeStartedAt = Date()
        guard let payloadData = Data(base64Encoded: body.payloadBase64) else {
            throw Abort(.badRequest, reason: "Invalid domain event payload.")
        }
        let payload = try IMTCPProtobufCodec.decodeDomainEvent(payloadData)
        let payloadDecodeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: payloadDecodeStartedAt)
        let localSendStartedAt = Date()
        await req.application.gatewaySessionService.sendDomainEventPayload(
            payload,
            toUserIDs: body.recipientUserIDs,
            requestID: body.requestID ?? payload.eventID
        )
        let localSendMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: localSendStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = req.application.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [requestDecodeMilliseconds, payloadDecodeMilliseconds, localSendMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            req.application.logger.info("Gateway relay domain-event packet slow.", metadata: [
                "request_id": .string((body.requestID ?? payload.eventID).uuidString),
                "event_id": .string(payload.eventID.uuidString),
                "recipient_count": .stringConvertible(body.recipientUserIDs.count),
                "payload_base64_bytes": .stringConvertible(body.payloadBase64.utf8.count),
                "request_decode_ms": .stringConvertible(requestDecodeMilliseconds),
                "payload_decode_ms": .stringConvertible(payloadDecodeMilliseconds),
                "local_send_ms": .stringConvertible(localSendMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds)
            ])
        }
        return .ok
    }

    func relayDomainEventPacketBinary(req: Request) async throws -> HTTPStatus {
        let startedAt = Date()
        guard let body = req.body.data,
              body.readableBytes > 0
        else {
            throw Abort(.badRequest, reason: "Binary domain event payload is empty.")
        }

        let requestDecodeStartedAt = Date()
        let packet = try IMGatewayRelayBinaryCodec.decodeDomainEventPacket(Data(buffer: body))
        let requestDecodeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: requestDecodeStartedAt)

        let payloadDecodeStartedAt = Date()
        let payload = try IMTCPProtobufCodec.decodeDomainEvent(packet.payloadData)
        let payloadDecodeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: payloadDecodeStartedAt)

        let localSendStartedAt = Date()
        await req.application.gatewaySessionService.sendDomainEventPayload(
            payload,
            toUserIDs: packet.recipientUserIDs,
            requestID: packet.requestID ?? payload.eventID
        )
        let localSendMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: localSendStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = req.application.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [requestDecodeMilliseconds, payloadDecodeMilliseconds, localSendMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            req.application.logger.info("Gateway relay binary domain-event packet slow.", metadata: [
                "request_id": .string((packet.requestID ?? payload.eventID).uuidString),
                "event_id": .string(payload.eventID.uuidString),
                "recipient_count": .stringConvertible(packet.recipientUserIDs.count),
                "body_bytes": .stringConvertible(body.readableBytes),
                "payload_bytes": .stringConvertible(packet.payloadData.count),
                "request_decode_ms": .stringConvertible(requestDecodeMilliseconds),
                "payload_decode_ms": .stringConvertible(payloadDecodeMilliseconds),
                "local_send_ms": .stringConvertible(localSendMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds)
            ])
        }
        return .ok
    }

    func relayDomainEventPackets(req: Request) async throws -> HTTPStatus {
        let startedAt = Date()
        let body = try req.content.decode(GatewayRelayDomainEventPayloadBatchRequest.self)
        let requestDecodeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        guard !body.deliveries.isEmpty else {
            return .ok
        }

        let payloadDecodeStartedAt = Date()
        var payloadBase64Bytes = 0
        let deliveries = try body.deliveries.map { entry in
            payloadBase64Bytes += entry.payloadBase64.utf8.count
            guard let payloadData = Data(base64Encoded: entry.payloadBase64) else {
                throw Abort(.badRequest, reason: "Invalid domain event payload.")
            }
            let payload = try IMTCPProtobufCodec.decodeDomainEvent(payloadData)
            return IMCanonicalDomainEventDelivery(
                ownerUserID: entry.ownerUserID,
                eventID: payload.eventID,
                payload: payload
            )
        }
        let payloadDecodeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: payloadDecodeStartedAt)
        let localSendStartedAt = Date()
        await req.application.gatewaySessionService.sendDomainEventPayloads(
            deliveries,
            requestID: body.requestID ?? deliveries.first?.eventID
        )
        let localSendMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: localSendStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = req.application.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [requestDecodeMilliseconds, payloadDecodeMilliseconds, localSendMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            req.application.logger.info("Gateway relay domain-event packet batch slow.", metadata: [
                "request_id": .string((body.requestID ?? deliveries.first?.eventID)?.uuidString ?? ""),
                "delivery_count": .stringConvertible(deliveries.count),
                "unique_recipient_count": .stringConvertible(Set(deliveries.map(\.ownerUserID)).count),
                "payload_base64_bytes": .stringConvertible(payloadBase64Bytes),
                "request_decode_ms": .stringConvertible(requestDecodeMilliseconds),
                "payload_decode_ms": .stringConvertible(payloadDecodeMilliseconds),
                "local_send_ms": .stringConvertible(localSendMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds)
            ])
        }
        return .ok
    }

    func relayKickSession(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayKickSessionRequest.self)
        await req.application.gatewaySessionService.kickConnections(
            forSessionID: body.sessionID,
            reason: body.reason,
            message: body.message
        )
        return .ok
    }

    func relayKickUser(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(GatewayRelayKickUserRequest.self)
        await req.application.gatewaySessionService.kickConnections(
            forUserID: body.userID,
            reason: body.reason,
            message: body.message
        )
        return .ok
    }

    func relaySessionCounts(req: Request) async throws -> GatewayRelaySessionCountsResponse {
        let body = try req.content.decode(GatewayRelaySessionCountsRequest.self)
        let counts = await req.application.gatewaySessionService.activeConnectionCounts(forSessionIDs: body.sessionIDs)
        return GatewayRelaySessionCountsResponse(counts: counts)
    }

    private func packet(from packetBase64: String) throws -> IMTCPInboundPacket {
        guard let data = Data(base64Encoded: packetBase64) else {
            throw Abort(.badRequest, reason: "Invalid realtime packet.")
        }
        do {
            return try IMTCPProtobufCodec.decode(data)
        } catch {
            throw Abort(.badRequest, reason: "Invalid realtime packet.")
        }
    }
}

struct InternalGatewayRelaySecretMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let configuration = request.application.gatewayRelayConfiguration
        if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
            let actualSecret = request.headers.first(name: "X-IM-Internal-Secret")
            guard actualSecret == sharedSecret else {
                throw Abort(.unauthorized, reason: "Invalid internal relay secret.")
            }
        } else if request.application.environment == .production {
            throw Abort(.internalServerError, reason: "IM_INTERNAL_SHARED_SECRET is required for gateway relay in production.")
        }
        return try await next.respond(to: request)
    }
}
