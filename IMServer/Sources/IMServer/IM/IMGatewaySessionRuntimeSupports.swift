import Fluent
import Foundation
import Kafka
import NIOCore
import Vapor


protocol GatewaySessionTransport: Sendable {
    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async
    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async
    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async
    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async
    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
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

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventDelivery(ownerUserID: ownerUserID, eventID: eventID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventPayload(payload, ownerUserID: ownerUserID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventPayload(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async {
        await routingService.sendDomainEventPayloads(deliveries, requestID: requestID)
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        await routingService.sendStreamSignal(payload, toUserIDs: userIDs, requestID: requestID)
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
    private struct ReusableDomainEventPacketKey: Hashable, Sendable {
        let eventID: UUID
        let eventType: IMTCPChatDomainEventType
        let aggregateID: UUID
        let aggregateSequence: UInt64
    }

    private struct ReusableDomainEventPayloadGroup: Sendable {
        var payload: IMTCPChatDomainEventPayload
        var userIDs: [UUID]
    }

    let app: Application
    let configuration: IMGatewayRelayConfiguration

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async {
        await postOrLog(
            path: "/internal/gateway/realtime/domain-event",
            payload: GatewayRelayDomainEventDeliveryRequest(
                ownerUserID: ownerUserID,
                eventID: eventID,
                requestID: requestID
            )
        )
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async {
        await sendDomainEventPayload(payload, toUserIDs: [ownerUserID], requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        guard !userIDs.isEmpty,
              let payloadData = domainEventPayloadData(payload)
        else {
            return
        }
        await relayDomainEventPayloadWorkItem(
            .groupedBinary(
                payloadData: payloadData,
                recipientUserIDs: userIDs
            ),
            requestID: requestID
        )
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async {
        let startedAt = Date()
        var encodedPayloadBytes = 0
        var skippedEncodeCount = 0
        let groupedDeliveries = groupReusableDomainEventPayloads(deliveries)
        guard !groupedDeliveries.reusable.isEmpty || !groupedDeliveries.fallback.isEmpty else {
            return
        }

        let batchSize = max(1, app.streamConsumerConfiguration.domainDeliveryRelayBatchSize)
        let groupedRecipientBatchSize = max(batchSize, batchSize * 64)
        let relayConcurrency = max(1, app.streamConsumerConfiguration.domainDeliveryFanoutConcurrency)

        var workItems: [GatewayRelayDomainEventPayloadWorkItem] = []
        var singleEntries: [GatewayRelayDomainEventPayloadBatchEntry] = []
        var groupedRequestCount = 0
        for group in groupedDeliveries.reusable {
            guard let payloadData = domainEventPayloadData(group.payload) else {
                skippedEncodeCount += group.userIDs.count
                continue
            }
            encodedPayloadBytes += payloadData.count

            var startIndex = group.userIDs.startIndex
            while startIndex < group.userIDs.endIndex {
                let endIndex = group.userIDs.index(
                    startIndex,
                    offsetBy: groupedRecipientBatchSize,
                    limitedBy: group.userIDs.endIndex
                ) ?? group.userIDs.endIndex
                workItems.append(
                    .groupedBinary(
                        payloadData: payloadData,
                        recipientUserIDs: Array(group.userIDs[startIndex..<endIndex])
                    )
                )
                groupedRequestCount += 1
                startIndex = endIndex
            }
        }

        for delivery in groupedDeliveries.fallback {
            guard let payloadBase64 = domainEventPayloadBase64(delivery.payload) else {
                skippedEncodeCount += 1
                continue
            }
            encodedPayloadBytes += payloadBase64.utf8.count
            singleEntries.append(
                GatewayRelayDomainEventPayloadBatchEntry(
                    ownerUserID: delivery.ownerUserID,
                    payloadBase64: payloadBase64
                )
            )
        }

        var startIndex = singleEntries.startIndex
        while startIndex < singleEntries.endIndex {
            let endIndex = singleEntries.index(
                startIndex,
                offsetBy: batchSize,
                limitedBy: singleEntries.endIndex
            ) ?? singleEntries.endIndex
            workItems.append(.batch(Array(singleEntries[startIndex..<endIndex])))
            startIndex = endIndex
        }

        let prepareMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let relayStartedAt = Date()
        await relayDomainEventPayloadWorkItems(workItems, requestID: requestID, concurrency: relayConcurrency)
        let relayMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: relayStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [prepareMilliseconds, relayMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Gateway HTTP relay payload batch slow.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "delivery_count": .stringConvertible(deliveries.count),
                "unique_payload_count": .stringConvertible(groupedDeliveries.reusable.count + singleEntries.count),
                "work_item_count": .stringConvertible(workItems.count),
                "grouped_request_count": .stringConvertible(groupedRequestCount),
                "single_entry_count": .stringConvertible(singleEntries.count),
                "skipped_encode_count": .stringConvertible(skippedEncodeCount),
                "encoded_payload_base64_bytes": .stringConvertible(encodedPayloadBytes),
                "prepare_ms": .stringConvertible(prepareMilliseconds),
                "relay_ms": .stringConvertible(relayMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds),
                "relay_concurrency": .stringConvertible(relayConcurrency),
                "batch_size": .stringConvertible(batchSize)
            ])
        }
    }

    private func relayDomainEventPayloadWorkItems(
        _ workItems: [GatewayRelayDomainEventPayloadWorkItem],
        requestID: UUID?,
        concurrency: Int
    ) async {
        guard !workItems.isEmpty else {
            return
        }
        guard concurrency > 1, workItems.count > 1 else {
            for workItem in workItems {
                await relayDomainEventPayloadWorkItem(workItem, requestID: requestID)
            }
            return
        }

        await withTaskGroup(of: Void.self) { group in
            var nextIndex = workItems.startIndex
            let initialCount = min(concurrency, workItems.count)
            for _ in 0..<initialCount {
                let workItem = workItems[nextIndex]
                group.addTask {
                    await relayDomainEventPayloadWorkItem(workItem, requestID: requestID)
                }
                nextIndex += 1
            }

            while await group.next() != nil {
                guard nextIndex < workItems.endIndex else {
                    continue
                }
                let workItem = workItems[nextIndex]
                group.addTask {
                    await relayDomainEventPayloadWorkItem(workItem, requestID: requestID)
                }
                nextIndex += 1
            }
        }
    }

    private func relayDomainEventPayloadWorkItem(
        _ workItem: GatewayRelayDomainEventPayloadWorkItem,
        requestID: UUID?
    ) async {
        switch workItem {
        case .groupedBinary(let payloadData, let recipientUserIDs):
            do {
                let body = try IMGatewayRelayBinaryCodec.encodeDomainEventPacket(
                    payloadData: payloadData,
                    recipientUserIDs: recipientUserIDs,
                    requestID: requestID
                )
                try await postRaw(path: "/internal/gateway/realtime/domain-event-packet-bin", body: body)
            } catch {
                await app.routingMetrics.recordCrossNodeDispatchFailed()
                app.logger.warning(
                    "Gateway binary relay failed; falling back to JSON relay.",
                    metadata: [
                        "node_id": .string(app.imNodeID),
                        "recipient_count": .stringConvertible(recipientUserIDs.count),
                        "error": .string(String(describing: error))
                    ]
                )
                await postOrLog(
                    path: "/internal/gateway/realtime/domain-event-packet",
                    payload: GatewayRelayDomainEventPayloadRequest(
                        payloadBase64: payloadData.base64EncodedString(),
                        recipientUserIDs: recipientUserIDs,
                        requestID: requestID
                    )
                )
            }
        case .batch(let batch):
            await relayDomainEventPayloadBatch(batch, requestID: requestID)
        }
    }

    private func relayDomainEventPayloadBatch(
        _ batch: [GatewayRelayDomainEventPayloadBatchEntry],
        requestID: UUID?
    ) async {
        guard !batch.isEmpty else {
            return
        }
        if batch.count == 1, let entry = batch.first {
            await postOrLog(
                path: "/internal/gateway/realtime/domain-event-packet",
                payload: GatewayRelayDomainEventPayloadRequest(
                    payloadBase64: entry.payloadBase64,
                    recipientUserIDs: [entry.ownerUserID],
                    requestID: requestID
                )
            )
        } else {
            await postOrLog(
                path: "/internal/gateway/realtime/domain-event-packets",
                payload: GatewayRelayDomainEventPayloadBatchRequest(
                    deliveries: batch,
                    requestID: requestID
                )
            )
        }
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        guard let packetBase64 = packetBase64(type: .streamSignal, requestID: requestID, payload: payload) else {
            return
        }
        await postOrLog(
            path: "/internal/gateway/realtime/stream-signal",
            payload: GatewayRelayMessageRequest(
                packetBase64: packetBase64,
                recipientUserIDs: userIDs,
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

        let startedAt = Date()
        let response = try await app.client.post(URI(string: "\(baseURL)\(path)")) { request in
            if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
                request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
            }
            try request.content.encode(payload)
        }
        let postMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLog(
            durationMilliseconds: postMilliseconds,
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Gateway HTTP relay POST slow.", metadata: [
                "node_id": .string(app.imNodeID),
                "path": .string(path),
                "status": .string(response.status.code.description),
                "duration_ms": .stringConvertible(postMilliseconds)
            ])
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

    private func postRaw(path: String, body: Data) async throws {
        guard let baseURL = configuration.baseURL else {
            throw GatewayRelayTransportError.missingBaseURL
        }

        let startedAt = Date()
        let response = try await app.client.post(URI(string: "\(baseURL)\(path)")) { request in
            if let sharedSecret = configuration.sharedSecret, !sharedSecret.isEmpty {
                request.headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
            }
            request.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
            request.body = .init(data: body)
        }
        let postMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLog(
            durationMilliseconds: postMilliseconds,
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Gateway HTTP binary relay POST slow.", metadata: [
                "node_id": .string(app.imNodeID),
                "path": .string(path),
                "status": .string(response.status.code.description),
                "duration_ms": .stringConvertible(postMilliseconds),
                "body_bytes": .stringConvertible(body.count)
            ])
        }

        guard response.status == .ok else {
            throw GatewayRelayTransportError.unexpectedStatus(response.status)
        }
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

    private func domainEventPayloadBase64(_ payload: IMTCPChatDomainEventPayload) -> String? {
        domainEventPayloadData(payload)?.base64EncodedString()
    }

    private func domainEventPayloadData(_ payload: IMTCPChatDomainEventPayload) -> Data? {
        do {
            return try IMTCPProtobufCodec.encodeDomainEvent(
                payload,
                requireDeliveryMetadata: false
            )
        } catch {
            app.logger.warning(
                "Gateway relay domain-event payload encode failed",
                metadata: [
                    "node_id": .string(app.imNodeID),
                    "event_id": .string(payload.eventID.uuidString),
                    "error": .string(String(describing: error))
                ]
            )
            return nil
        }
    }

    private func groupReusableDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery]
    ) -> (reusable: [ReusableDomainEventPayloadGroup], fallback: [IMCanonicalDomainEventDelivery]) {
        var reusableGroups: [ReusableDomainEventPacketKey: ReusableDomainEventPayloadGroup] = [:]
        var fallbackDeliveries: [IMCanonicalDomainEventDelivery] = []
        fallbackDeliveries.reserveCapacity(deliveries.count)

        for delivery in deliveries {
            guard let key = reusablePacketKey(for: delivery.payload) else {
                fallbackDeliveries.append(delivery)
                continue
            }
            if reusableGroups[key] == nil {
                reusableGroups[key] = ReusableDomainEventPayloadGroup(payload: delivery.payload, userIDs: [])
            }
            reusableGroups[key]?.userIDs.append(delivery.ownerUserID)
        }

        return (Array(reusableGroups.values), fallbackDeliveries)
    }

    private func reusablePacketKey(for payload: IMTCPChatDomainEventPayload) -> ReusableDomainEventPacketKey? {
        guard payload.eventType == .messageCreated,
              payload.conversation == nil,
              payload.timelineNotice == nil,
              payload.requiresTimelineNotice == false,
              payload.ownerCursor == nil,
              payload.ownerAggregateSequence == nil
        else {
            return nil
        }

        return ReusableDomainEventPacketKey(
            eventID: payload.eventID,
            eventType: payload.eventType,
            aggregateID: payload.aggregateID,
            aggregateSequence: payload.aggregateSequence
        )
    }
}

private struct EmptyGatewayRelayResponse: Content {}

private enum GatewayRelayDomainEventPayloadWorkItem: Sendable {
    case groupedBinary(payloadData: Data, recipientUserIDs: [UUID])
    case batch([GatewayRelayDomainEventPayloadBatchEntry])
}

private enum GatewayRelayTransportError: Error {
    case missingBaseURL
    case unexpectedStatus(HTTPResponseStatus)
}

struct LoggingUnavailableGatewaySessionTransport: GatewaySessionTransport {
    let logger: Logger
    let role: IMRuntimeRole

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID?
    ) async {
        logUnavailable()
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
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

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await transport.sendDomainEventDelivery(ownerUserID: ownerUserID, eventID: eventID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await transport.sendDomainEventPayload(payload, ownerUserID: ownerUserID, requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await transport.sendDomainEventPayload(payload, toUserIDs: userIDs, requestID: requestID)
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID? = UUID()
    ) async {
        await transport.sendDomainEventPayloads(deliveries, requestID: requestID)
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await transport.sendStreamSignal(payload, toUserIDs: userIDs, requestID: requestID)
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
        actorUserID: UUID?,
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
