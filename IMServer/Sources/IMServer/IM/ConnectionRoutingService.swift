import Foundation
import Vapor

struct ConnectionRoutingService {
    private struct ReusableDomainEventPacketKey: Hashable, Sendable {
        let eventID: UUID
        let eventType: IMTCPChatDomainEventType
        let aggregateID: UUID
        let aggregateSequence: UInt64
        let bodyVariant: String
    }

    private actor DomainEventPacketEncodeCache {
        private var packetBase64ByKey: [ReusableDomainEventPacketKey: String] = [:]
        private var encodedPacketCount = 0
        private var encodeCacheHitCount = 0
        private var encodedPacketBytes = 0
        private var maxEncodedPacketBytes = 0

        func packetBase64(
            requestID: UUID?,
            payload: IMTCPChatDomainEventPayload,
            reusableKey: ReusableDomainEventPacketKey?
        ) throws -> String {
            if let reusableKey {
                if let cached = packetBase64ByKey[reusableKey] {
                    encodeCacheHitCount += 1
                    return cached
                }
                let data = try IMTCPProtobufCodec.encode(
                    type: .domainEvent,
                    requestID: requestID,
                    payload: payload
                )
                let packetBase64 = data.base64EncodedString()
                encodedPacketCount += 1
                encodedPacketBytes += data.count
                maxEncodedPacketBytes = max(maxEncodedPacketBytes, data.count)
                packetBase64ByKey[reusableKey] = packetBase64
                return packetBase64
            }

            let data = try IMTCPProtobufCodec.encode(
                type: .domainEvent,
                requestID: requestID,
                payload: payload
            )
            encodedPacketCount += 1
            encodedPacketBytes += data.count
            maxEncodedPacketBytes = max(maxEncodedPacketBytes, data.count)
            return data.base64EncodedString()
        }

        func snapshot() -> (
            encodedPacketCount: Int,
            encodeCacheHitCount: Int,
            encodedPacketBytes: Int,
            maxEncodedPacketBytes: Int
        ) {
            (
                encodedPacketCount: encodedPacketCount,
                encodeCacheHitCount: encodeCacheHitCount,
                encodedPacketBytes: encodedPacketBytes,
                maxEncodedPacketBytes: maxEncodedPacketBytes
            )
        }
    }

    private struct RemoteDispatchWorkItem: Sendable {
        let remoteNodeID: String
        let targetCount: Int
        let envelope: NodeMessageDispatchEnvelope
    }

    private struct RemoteDispatchResult: Sendable {
        let remoteNodeID: String
        let targetCount: Int
        let latencyMilliseconds: Int
        let error: (any Error)?
    }

    private struct RemoteActiveConversationFanoutPlan: Sendable {
        let activeFullUserIDs: [UUID]
        let activeCompactUserIDs: [UUID]
        let inactiveHintUserIDs: [UUID]
        let downgradedActiveUserCount: Int
        let payloadBudget: IMActiveConversationFullFanoutBudget
        let activeCandidateCount: Int

        var payloadBudgetDowngradedRecipientCount: Int {
            payloadBudget.budgetDowngradedRecipientCount(candidateCount: activeCandidateCount)
        }
    }

    let app: Application
    let nodeID: String
    let backend: any ConnectionRoutingBackend

    init(app: Application, backend: any ConnectionRoutingBackend) {
        self.app = app
        self.nodeID = app.imNodeID
        self.backend = backend
    }

    var routeBackendName: String { backend.backendName }

    func bind(_ connection: IMAuthenticatedConnection, control: IMConnectionControl) async throws {
        await kickDuplicateSessionConnectionsIfNeeded(forSessionID: connection.sessionID)
        await app.imConnectionRegistry.bind(connection, control: control)
        await app.routingMetrics.recordCurrentTCPConnectionCount(await app.imConnectionRegistry.totalConnectionCount())
        if await app.imConnectionRegistry.localConnectionCount(forUserID: connection.userID) == 1 {
            try await backend.presenceStore.activatePresence(forUserID: connection.userID)
            await app.routingMetrics.recordPresenceRegistration()
        }
        if await app.imConnectionRegistry.localConnectionCount(forSessionID: connection.sessionID) == 1 {
            try await backend.presenceStore.activatePresence(forSessionID: connection.sessionID, userID: connection.userID)
            await app.routingMetrics.recordPresenceRegistration()
        }
    }

    private func kickDuplicateSessionConnectionsIfNeeded(forSessionID sessionID: UUID) async {
        let removedConnections = await kickLocalConnections(
            forSessionID: sessionID,
            reason: .duplicateConnection,
            message: "This session opened a new realtime connection."
        )
        if !removedConnections.isEmpty {
            await app.routingMetrics.recordSessionKick(targetSessionCount: removedConnections.count)
        }

        let envelope = NodeMessageDispatchEnvelope(
            requestID: nil,
            payload: .kickSession(
                sessionID: sessionID,
                reason: .duplicateConnection,
                message: "This session opened a new realtime connection."
            )
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forSessionIDs: [sessionID], includeLocalNode: false)
    }

    func remove(connectionID: UUID) async {
        guard let removed = await app.imConnectionRegistry.remove(connectionID: connectionID) else {
            return
        }

        await app.routingMetrics.recordCurrentTCPConnectionCount(await app.imConnectionRegistry.totalConnectionCount())
        if await app.imConnectionRegistry.localConnectionCount(forUserID: removed.connection.userID) == 0 {
            try? await backend.presenceStore.deactivatePresence(forUserID: removed.connection.userID)
        }
        if await app.imConnectionRegistry.localConnectionCount(forSessionID: removed.connection.sessionID) == 0 {
            try? await backend.presenceStore.deactivatePresence(
                forSessionID: removed.connection.sessionID,
                userID: removed.connection.userID
            )
        }
        for conversationID in removed.deactivatedConversationIDs {
            try? await backend.presenceStore.deactivateConversationPresence(
                conversationID: conversationID,
                userID: removed.connection.userID
            )
        }
    }

    func updateConversationActivity(
        connectionID: UUID,
        conversationID: UUID,
        isActive: Bool
    ) async -> Bool {
        guard let connection = await app.imConnectionRegistry.authenticatedConnection(for: connectionID) else {
            return false
        }
        let didUpdate = await app.imConnectionRegistry.updateConversationActivity(
            connectionID: connectionID,
            conversationID: conversationID,
            isActive: isActive
        )
        guard didUpdate else {
            return false
        }

        if isActive {
            try? await backend.presenceStore.activateConversationPresence(
                conversationID: conversationID,
                userID: connection.userID
            )
        } else {
            let activeConnectionCount = await app.imConnectionRegistry.localActiveConversationConnectionCount(
                forConversationID: conversationID,
                userID: connection.userID
            )
            if activeConnectionCount == 0 {
                try? await backend.presenceStore.deactivateConversationPresence(
                    conversationID: conversationID,
                    userID: connection.userID
                )
            }
        }

        return true
    }

    func refreshActiveConversationPresence(connectionID: UUID) async {
        guard let connection = await app.imConnectionRegistry.authenticatedConnection(for: connectionID) else {
            return
        }
        let activeConversationIDs = await app.imConnectionRegistry.activeConversationIDs(forConnectionID: connectionID)
        guard !activeConversationIDs.isEmpty else {
            return
        }

        for conversationID in activeConversationIDs {
            try? await backend.presenceStore.activateConversationPresence(
                conversationID: conversationID,
                userID: connection.userID
            )
        }
    }

    func sendDomainEventDelivery(
        ownerUserID: UUID,
        eventID: UUID,
        requestID: UUID? = UUID()
    ) async {
        let deliveryService = OwnerDomainEventDeliveryService(
            db: app.summaryShardRouter.database(forOwnerUserID: ownerUserID)
        )
        let canonicalDelivery: IMCanonicalDomainEventDelivery
        do {
            guard let delivery = try await deliveryService.find(ownerUserID: ownerUserID, eventID: eventID) else {
                await app.routingMetrics.recordRealtimeDeliveryMissingRow()
                app.logger.warning("Skipping realtime domain event because owner delivery row is missing.", metadata: [
                    "owner_user_id": .string(ownerUserID.uuidString),
                    "event_id": .string(eventID.uuidString),
                    "requestID": .string(requestID?.uuidString ?? "")
                ])
                return
            }
            canonicalDelivery = try deliveryService.canonicalDelivery(from: delivery)
        } catch {
            await app.routingMetrics.recordInvalidRealtimeDeliveryPayload()
            app.logger.warning("Skipping realtime domain event because owner delivery payload is invalid.", metadata: [
                "owner_user_id": .string(ownerUserID.uuidString),
                "event_id": .string(eventID.uuidString),
                "requestID": .string(requestID?.uuidString ?? ""),
                "error": .string(String(describing: error))
            ])
            return
        }
        await app.routingMetrics.recordUserFanout(targetUserCount: 1)
        await app.imConnectionRegistry.sendDomainEventDelivery(canonicalDelivery, requestID: requestID)
        let envelope = NodeMessageDispatchEnvelope(
            requestID: requestID,
            payload: .domainEvent(ownerUserID: ownerUserID, eventID: eventID)
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [ownerUserID])
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        ownerUserID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await sendDomainEventPayload(payload, toUserIDs: [ownerUserID], requestID: requestID)
    }

    func sendDomainEventPayload(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        guard !userIDs.isEmpty else {
            return
        }

        let startedAt = Date()
        let uniqueUserCount = Set(userIDs).count
        await app.routingMetrics.recordUserFanout(targetUserCount: uniqueUserCount)
        let registryStartedAt = Date()
        await app.imConnectionRegistry.sendDomainEventPayload(payload, toUserIDs: userIDs, requestID: requestID)
        let registryMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: registryStartedAt)

        let remoteDispatchStartedAt = Date()
        do {
            let envelope = try encodeDomainEventPacketEnvelope(
                requestID: requestID,
                payload: payload,
                targetUserIDs: userIDs
            )
            await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: userIDs)
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning("Domain-event packet dispatch encode failed.", metadata: [
                "requestID": .string(requestID?.uuidString ?? ""),
                "target_user_count": .stringConvertible(uniqueUserCount),
                "error": .string(String(describing: error))
            ])
        }
        let remoteDispatchMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: remoteDispatchStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [registryMilliseconds, remoteDispatchMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Connection routing domain-event payload slow.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "event_id": .string(payload.eventID.uuidString),
                "target_user_count": .stringConvertible(uniqueUserCount),
                "registry_send_ms": .stringConvertible(registryMilliseconds),
                "remote_dispatch_ms": .stringConvertible(remoteDispatchMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds)
            ])
        }
    }

    func sendDomainEventPayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID? = UUID()
    ) async {
        let nonEmptyBatches = batches.filter { !$0.recipientUserIDs.isEmpty }
        guard !nonEmptyBatches.isEmpty else {
            return
        }

        let startedAt = Date()
        let targetUserCount = nonEmptyBatches.reduce(0) { partial, batch in
            partial + Set(batch.recipientUserIDs).count
        }
        await app.routingMetrics.recordUserFanout(targetUserCount: targetUserCount)
        let registryStartedAt = Date()
        await app.imConnectionRegistry.sendDomainEventPayloadBatches(nonEmptyBatches, requestID: requestID)
        let registryMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: registryStartedAt)

        let remoteDispatchStartedAt = Date()
        await dispatchRemotePayloadBatches(nonEmptyBatches, requestID: requestID)
        let remoteDispatchMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: remoteDispatchStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [registryMilliseconds, remoteDispatchMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Connection routing domain-event payload batch slow.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "payload_batch_count": .stringConvertible(nonEmptyBatches.count),
                "target_user_count": .stringConvertible(targetUserCount),
                "registry_send_ms": .stringConvertible(registryMilliseconds),
                "remote_dispatch_ms": .stringConvertible(remoteDispatchMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds)
            ])
        }
    }

    func sendDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery],
        requestID: UUID? = UUID()
    ) async {
        guard !deliveries.isEmpty else {
            return
        }

        let startedAt = Date()
        let uniqueUserCount = Set(deliveries.map(\.ownerUserID)).count
        await app.routingMetrics.recordUserFanout(targetUserCount: uniqueUserCount)
        let registryStartedAt = Date()
        await app.imConnectionRegistry.sendDomainEventDeliveries(deliveries, requestID: requestID)
        let registryMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: registryStartedAt)

        let remoteDispatchStartedAt = Date()
        let remoteDispatchGroups = groupReusableDomainEventPayloads(deliveries)
        await withTaskGroup(of: Void.self) { group in
            for groupedDelivery in remoteDispatchGroups.reusable {
                group.addTask {
                    do {
                        let envelope = try encodeDomainEventPacketEnvelope(
                            requestID: requestID,
                            payload: groupedDelivery.payload,
                            targetUserIDs: groupedDelivery.userIDs
                        )
                        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: groupedDelivery.userIDs)
                    } catch {
                        await app.routingMetrics.recordCrossNodeDispatchFailed()
                        app.logger.warning("Domain-event reusable packet dispatch encode failed.", metadata: [
                            "requestID": .string(requestID?.uuidString ?? ""),
                            "event_id": .string(groupedDelivery.payload.eventID.uuidString),
                            "target_user_count": .stringConvertible(groupedDelivery.userIDs.count),
                            "error": .string(String(describing: error))
                        ])
                    }
                }
            }
            for delivery in remoteDispatchGroups.fallback {
                group.addTask {
                    let envelope = NodeMessageDispatchEnvelope(
                        requestID: requestID,
                        payload: .domainEvent(ownerUserID: delivery.ownerUserID, eventID: delivery.eventID)
                    )
                    await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [delivery.ownerUserID])
                }
            }
        }
        let remoteDispatchMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: remoteDispatchStartedAt)
        let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
        let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
        if IMRealtimeDeliveryDiagnostics.shouldLogAny(
            [registryMilliseconds, remoteDispatchMilliseconds, totalMilliseconds],
            thresholdMilliseconds: slowLogMilliseconds
        ) {
            app.logger.info("Connection routing domain-event delivery batch slow.", metadata: [
                "request_id": .string(requestID?.uuidString ?? ""),
                "delivery_count": .stringConvertible(deliveries.count),
                "target_user_count": .stringConvertible(uniqueUserCount),
                "reusable_remote_packet_count": .stringConvertible(remoteDispatchGroups.reusable.count),
                "fallback_remote_delivery_count": .stringConvertible(remoteDispatchGroups.fallback.count),
                "registry_send_ms": .stringConvertible(registryMilliseconds),
                "remote_dispatch_ms": .stringConvertible(remoteDispatchMilliseconds),
                "total_ms": .stringConvertible(totalMilliseconds)
            ])
        }
    }

    func sendStreamSignal(
        _ payload: IMTCPMessageStreamSignalPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await app.routingMetrics.recordUserFanout(targetUserCount: Set(userIDs).count)
        await app.imConnectionRegistry.sendStreamSignal(payload, toUserIDs: userIDs, requestID: requestID)
        do {
            let envelope = try encodePacketEnvelope(
                requestID: requestID,
                payload: payload,
                targetUserIDs: userIDs
            )
            await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: userIDs)
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning("Stream-signal dispatch encode failed.", metadata: [
                "requestID": .string(requestID?.uuidString ?? ""),
                "target_user_count": .stringConvertible(Set(userIDs).count),
                "error": .string(String(describing: error))
            ])
        }
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await app.routingMetrics.recordSessionKick(targetSessionCount: 1)
        await kickLocalConnections(
            forSessionID: sessionID,
            reason: reason,
            message: message
        )
        let envelope = NodeMessageDispatchEnvelope(
            requestID: nil,
            payload: .kickSession(sessionID: sessionID, reason: reason, message: message)
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forSessionIDs: [sessionID], includeLocalNode: false)
    }

    func activeConnectionCounts(forSessionIDs sessionIDs: [UUID]) async -> [UUID: Int] {
        await app.imConnectionRegistry.activeConnectionCounts(forSessionIDs: sessionIDs)
    }

    func kickConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        let removedConnections = await kickLocalConnections(forUserID: userID, reason: reason, message: message)
        await app.routingMetrics.recordSessionKick(targetSessionCount: max(removedConnections.count, 1))
        let envelope = NodeMessageDispatchEnvelope(
            requestID: nil,
            payload: .kickUser(userID: userID, reason: reason, message: message)
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID], includeLocalNode: false)
    }

    func handleRemoteDispatch(_ envelope: NodeMessageDispatchEnvelope) async {
        switch envelope.payload {
        case .domainEvent(let ownerUserID, let eventID):
            let deliveryService = OwnerDomainEventDeliveryService(
                db: app.summaryShardRouter.database(forOwnerUserID: ownerUserID)
            )
            let canonicalDelivery: IMCanonicalDomainEventDelivery
            do {
                guard let delivery = try await deliveryService.find(ownerUserID: ownerUserID, eventID: eventID) else {
                    await app.routingMetrics.recordRealtimeDeliveryMissingRow()
                    app.logger.warning("Remote domain-event dispatch skipped missing owner delivery row.", metadata: [
                        "ownerUserID": .string(ownerUserID.uuidString),
                        "eventID": .string(eventID.uuidString),
                        "requestID": .string(envelope.requestID?.uuidString ?? "")
                    ])
                    return
                }
                canonicalDelivery = try deliveryService.canonicalDelivery(from: delivery)
            } catch {
                await app.routingMetrics.recordInvalidRealtimeDeliveryPayload()
                app.logger.warning("Remote domain-event dispatch failed to decode owner delivery payload.", metadata: [
                    "ownerUserID": .string(ownerUserID.uuidString),
                    "eventID": .string(eventID.uuidString),
                    "requestID": .string(envelope.requestID?.uuidString ?? ""),
                    "error": .string(String(describing: error))
                ])
                return
            }
            await app.imConnectionRegistry.sendDomainEventDelivery(canonicalDelivery, requestID: envelope.requestID)
        case .activeConversationDomainEventPacket(_, let conversationID, let allowedUserIDs, let fanoutIntent):
            guard let payload = decodeDomainEventPacketPayload(from: envelope) else {
                await app.routingMetrics.recordCrossNodeDispatchFailed()
                app.logger.warning("Remote active-conversation domain-event packet dispatch failed to decode payload.", metadata: [
                    "requestID": .string(envelope.requestID?.uuidString ?? ""),
                    "conversationID": .string(conversationID.uuidString),
                    "targetUserIDs": .array(allowedUserIDs.map { .string($0.uuidString) })
                ])
                return
            }
            await app.imConnectionRegistry.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: allowedUserIDs,
                        fanoutIntent: fanoutIntent ?? .preSplitActiveFull
                    )
                ],
                requestID: envelope.requestID
            )
        case .domainEventPacket(_, _, let fanoutIntent):
            guard let payload = decodeDomainEventPacketPayload(from: envelope) else {
                await app.routingMetrics.recordCrossNodeDispatchFailed()
                app.logger.warning("Remote domain-event packet dispatch failed to decode payload.", metadata: [
                    "requestID": .string(envelope.requestID?.uuidString ?? ""),
                    "targetUserIDs": .array(envelope.targetUserIDs.map { .string($0.uuidString) })
                ])
                return
            }
            await app.imConnectionRegistry.sendDomainEventPayloadBatches(
                [
                    IMGatewayDomainEventPayloadBatch(
                        payload: payload,
                        recipientUserIDs: envelope.targetUserIDs,
                        fanoutIntent: fanoutIntent ?? .unspecified
                    )
                ],
                requestID: envelope.requestID
            )
        case .streamSignal:
            guard let payload: IMTCPMessageStreamSignalPayload = decodePayload(from: envelope) else {
                await app.routingMetrics.recordCrossNodeDispatchFailed()
                app.logger.warning("Remote stream-signal dispatch failed to decode payload.", metadata: [
                    "requestID": .string(envelope.requestID?.uuidString ?? ""),
                    "targetUserIDs": .array(envelope.targetUserIDs.map { .string($0.uuidString) })
                ])
                return
            }
            await app.imConnectionRegistry.sendStreamSignal(
                payload,
                toUserIDs: envelope.targetUserIDs,
                requestID: envelope.requestID
            )
        case .kickSession(let sessionID, let reason, let message):
            await kickLocalConnections(forSessionID: sessionID, reason: reason, message: message)
        case .kickUser(let userID, let reason, let message):
            await kickLocalConnections(forUserID: userID, reason: reason, message: message)
        }
    }

    @discardableResult
    private func kickLocalConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async -> [IMAuthenticatedConnection] {
        let removals = await app.imConnectionRegistry.kickExistingConnections(
            forSessionID: sessionID,
            reason: reason,
            message: message
        )
        await cleanupPresenceAfterLocalKick(removals)
        return removals.map(\.connection)
    }

    @discardableResult
    private func kickLocalConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async -> [IMAuthenticatedConnection] {
        let removals = await app.imConnectionRegistry.kickExistingConnections(
            forUserID: userID,
            reason: reason,
            message: message
        )
        await cleanupPresenceAfterLocalKick(removals)
        return removals.map(\.connection)
    }

    private func cleanupPresenceAfterLocalKick(_ removals: [IMConnectionRemoval]) async {
        guard !removals.isEmpty else {
            return
        }

        await app.routingMetrics.recordCurrentTCPConnectionCount(await app.imConnectionRegistry.totalConnectionCount())

        let removedConnections = removals.map(\.connection)
        let sessionUserPairs = Set(removedConnections.map { SessionPresenceKey(sessionID: $0.sessionID, userID: $0.userID) })
        for pair in sessionUserPairs {
            if await app.imConnectionRegistry.localConnectionCount(forSessionID: pair.sessionID) == 0 {
                try? await backend.presenceStore.deactivatePresence(forSessionID: pair.sessionID, userID: pair.userID)
            }
        }

        let userIDs = Set(removedConnections.map(\.userID))
        for userID in userIDs {
            if await app.imConnectionRegistry.localConnectionCount(forUserID: userID) == 0 {
                try? await backend.presenceStore.deactivatePresence(forUserID: userID)
            }
        }

        for removal in removals {
            for conversationID in removal.deactivatedConversationIDs {
                try? await backend.presenceStore.deactivateConversationPresence(
                    conversationID: conversationID,
                    userID: removal.connection.userID
                )
            }
        }
    }

    private struct SessionPresenceKey: Hashable, Sendable {
        let sessionID: UUID
        let userID: UUID
    }

    private func broadcastToAllNodes(_ envelope: NodeMessageDispatchEnvelope) async {
        let nodeIDs = (try? await backend.presenceStore.activeNodeIDs())?.filter { $0 != nodeID } ?? []
        await withTaskGroup(of: (String, (any Error)?).self) { group in
            for remoteNodeID in nodeIDs {
                group.addTask {
                    do {
                        try await dispatchWithTimeout(envelope, toNodeID: remoteNodeID, using: backend.dispatchService)
                        return (remoteNodeID, nil)
                    } catch {
                        return (remoteNodeID, error)
                    }
                }
            }

            for await (remoteNodeID, error) in group {
                if let error {
                    await app.routingMetrics.recordCrossNodeDispatchFailed()
                    app.logger.warning(
                        "Cross-node IM kick dispatch failed",
                        metadata: [
                            "node_id": .string(nodeID),
                            "route_backend": .string(routeBackendName),
                            "target_node_id": .string(remoteNodeID),
                            "error": .string(String(describing: error))
                        ]
                    )
                } else {
                    await app.routingMetrics.recordCrossNodeDispatchSucceeded()
                }
            }
        }
    }

    private func dispatchWithTimeout(
        _ envelope: NodeMessageDispatchEnvelope,
        toNodeID remoteNodeID: String,
        using dispatchService: any NodeMessageDispatchService,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await dispatchService.dispatch(envelope, toNodeID: remoteNodeID)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ConnectionRoutingDispatchError.timeout(remoteNodeID)
            }

            try await group.next()
            group.cancelAll()
        }
    }

    private func dispatchRemoteEnvelopeIfNeeded(
        _ envelope: NodeMessageDispatchEnvelope?,
        forUserIDs userIDs: [UUID],
        includeLocalNode: Bool = false
    ) async {
        guard let envelope else { return }
        let startedAt = Date()
        let uniqueUserCount = Set(userIDs).count
        do {
            let activeNodeIDs = try await backend.presenceStore.activeNodeIDs()
            let remoteNodeIDs = activeNodeIDs.filter { includeLocalNode || $0 != nodeID }
            guard !remoteNodeIDs.isEmpty else {
                return
            }

            let routeStartedAt = Date()
            let routes = try await backend.presenceStore.routeNodeIDs(forUserIDs: userIDs)
            let routeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: routeStartedAt)
            let targetUserIDsByNodeID = targetUserIDsByNodeID(from: routes, includeLocalNode: includeLocalNode)
            let workItems = remoteDispatchWorkItems(
                envelope: envelope,
                targetUserIDsByNodeID: targetUserIDsByNodeID
            )
            let dispatchStartedAt = Date()
            await dispatchRemoteWorkItems(
                workItems,
                failureLogMessage: "Cross-node IM dispatch failed",
                targetMetadataKey: "target_user_count"
            )
            let dispatchMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: dispatchStartedAt)
            let totalMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
            let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
            if IMRealtimeDeliveryDiagnostics.shouldLogAny(
                [routeMilliseconds, dispatchMilliseconds, totalMilliseconds],
                thresholdMilliseconds: slowLogMilliseconds
            ) {
                app.logger.info("Cross-node IM dispatch slow.", metadata: [
                    "node_id": .string(nodeID),
                    "route_backend": .string(routeBackendName),
                    "target_user_count": .stringConvertible(uniqueUserCount),
                    "remote_node_count": .stringConvertible(targetUserIDsByNodeID.count),
                    "work_item_count": .stringConvertible(workItems.count),
                    "user_batch_size": .stringConvertible(
                        app.streamConsumerConfiguration.realtimeRemoteDispatchUserBatchSize
                    ),
                    "max_in_flight": .stringConvertible(app.streamConsumerConfiguration.realtimeRemoteDispatchMaxInFlight),
                    "route_ms": .stringConvertible(routeMilliseconds),
                    "dispatch_ms": .stringConvertible(dispatchMilliseconds),
                    "total_ms": .stringConvertible(totalMilliseconds)
                ])
            }
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning(
                "Cross-node IM dispatch failed",
                metadata: [
                    "node_id": .string(nodeID),
                    "route_backend": .string(routeBackendName),
                    "target_user_count": .stringConvertible(uniqueUserCount),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    private func dispatchRemoteEnvelopeIfNeeded(
        _ envelope: NodeMessageDispatchEnvelope?,
        forSessionIDs sessionIDs: [UUID],
        includeLocalNode: Bool = false
    ) async {
        guard let envelope else { return }
        do {
            let activeNodeIDs = try await backend.presenceStore.activeNodeIDs()
            let remoteNodeIDs = activeNodeIDs.filter { includeLocalNode || $0 != nodeID }
            guard !remoteNodeIDs.isEmpty else {
                return
            }

            let routes = try await backend.presenceStore.routeNodeIDs(forSessionIDs: sessionIDs)
            var targetSessionIDsByNodeID: [String: Set<UUID>] = [:]
            for (sessionID, nodeIDs) in routes {
                for remoteNodeID in nodeIDs where includeLocalNode || remoteNodeID != nodeID {
                    targetSessionIDsByNodeID[remoteNodeID, default: []].insert(sessionID)
                }
            }

            let workItems = targetSessionIDsByNodeID
                .sorted { $0.key < $1.key }
                .flatMap { remoteNodeID, targetSessionIDs in
                    targetSessionIDs
                        .sorted { $0.uuidString < $1.uuidString }
                        .map { targetSessionID in
                            RemoteDispatchWorkItem(
                                remoteNodeID: remoteNodeID,
                                targetCount: 1,
                                envelope: envelope.withSessionID(targetSessionID)
                            )
                        }
                }
            await dispatchRemoteWorkItems(
                workItems,
                failureLogMessage: "Cross-node IM session dispatch failed",
                targetMetadataKey: "target_session_count"
            )
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning(
                "Cross-node IM session dispatch failed",
                metadata: [
                    "node_id": .string(nodeID),
                    "route_backend": .string(routeBackendName),
                    "target_session_count": .stringConvertible(Set(sessionIDs).count),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    private func dispatchRemotePayloadBatches(
        _ batches: [IMGatewayDomainEventPayloadBatch],
        requestID: UUID?
    ) async {
        guard !batches.isEmpty else {
            return
        }

        let remoteNodeIDs: Set<String>
        do {
            remoteNodeIDs = Set((try await backend.presenceStore.activeNodeIDs()).filter { $0 != nodeID })
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning("Cross-node IM active-node lookup failed.", metadata: [
                "node_id": .string(nodeID),
                "route_backend": .string(routeBackendName),
                "payload_batch_count": .stringConvertible(batches.count),
                "error": .string(String(describing: error))
            ])
            return
        }
        guard !remoteNodeIDs.isEmpty else {
            return
        }

        let maxInFlight = app.streamConsumerConfiguration.realtimeRemoteDispatchMaxInFlight
        let encodeCache = DomainEventPacketEncodeCache()
        var nextIndex = batches.startIndex
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0

            while nextIndex < batches.endIndex && inFlight < maxInFlight {
                let batch = batches[nextIndex]
                nextIndex = batches.index(after: nextIndex)
                inFlight += 1
                group.addTask {
                    await dispatchRemotePayloadBatch(
                        batch,
                        requestID: requestID,
                        remoteNodeIDs: remoteNodeIDs,
                        encodeCache: encodeCache
                    )
                }
            }

            while await group.next() != nil {
                inFlight -= 1
                guard nextIndex < batches.endIndex else {
                    continue
                }
                let batch = batches[nextIndex]
                nextIndex = batches.index(after: nextIndex)
                inFlight += 1
                group.addTask {
                    await dispatchRemotePayloadBatch(
                        batch,
                        requestID: requestID,
                        remoteNodeIDs: remoteNodeIDs,
                        encodeCache: encodeCache
                    )
                }
            }
        }
        let encodeSnapshot = await encodeCache.snapshot()
        await app.routingMetrics.recordRemoteDomainEventPacketEncoding(
            encodedPacketCount: encodeSnapshot.encodedPacketCount,
            encodeCacheHitCount: encodeSnapshot.encodeCacheHitCount,
            encodedPacketBytes: encodeSnapshot.encodedPacketBytes,
            maxEncodedPacketBytes: encodeSnapshot.maxEncodedPacketBytes
        )
    }

    private func dispatchRemotePayloadBatch(
        _ batch: IMGatewayDomainEventPayloadBatch,
        requestID: UUID?,
        remoteNodeIDs: Set<String>,
        encodeCache: DomainEventPacketEncodeCache
    ) async {
        if shouldSplitRemoteActiveConversationFanout(batch),
           await dispatchRemoteActiveConversationPayloadBatch(
               batch,
               requestID: requestID,
               remoteNodeIDs: remoteNodeIDs,
               encodeCache: encodeCache
           ) {
            return
        }

        do {
            let routeStartedAt = Date()
            let routes = try await backend.presenceStore.routeNodeIDs(forUserIDs: batch.recipientUserIDs)
            let routeMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: routeStartedAt)
            let targetUserIDsByNodeID = targetUserIDsByNodeID(from: routes).filter { remoteNodeIDs.contains($0.key) }
            guard !targetUserIDsByNodeID.isEmpty else {
                return
            }
            let envelope = try await encodeDomainEventPacketEnvelope(
                requestID: requestID,
                payload: batch.payload,
                targetUserIDs: batch.recipientUserIDs,
                fanoutIntent: batch.fanoutIntent,
                encodeCache: encodeCache
            )
            let workItems = remoteDispatchWorkItems(
                envelope: envelope,
                targetUserIDsByNodeID: targetUserIDsByNodeID
            )
            let dispatchStartedAt = Date()
            await dispatchRemoteWorkItems(
                workItems,
                failureLogMessage: "Cross-node IM dispatch failed",
                targetMetadataKey: "target_user_count"
            )
            let dispatchMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: dispatchStartedAt)
            let totalMilliseconds = routeMilliseconds + dispatchMilliseconds
            let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
            if IMRealtimeDeliveryDiagnostics.shouldLogAny(
                [routeMilliseconds, dispatchMilliseconds, totalMilliseconds],
                thresholdMilliseconds: slowLogMilliseconds
            ) {
                app.logger.info("Cross-node IM payload batch dispatch slow.", metadata: [
                    "node_id": .string(nodeID),
                    "route_backend": .string(routeBackendName),
                    "request_id": .string(requestID?.uuidString ?? ""),
                    "event_id": .string(batch.payload.eventID.uuidString),
                    "target_user_count": .stringConvertible(Set(batch.recipientUserIDs).count),
                    "remote_node_count": .stringConvertible(targetUserIDsByNodeID.count),
                    "work_item_count": .stringConvertible(workItems.count),
                    "route_ms": .stringConvertible(routeMilliseconds),
                    "dispatch_ms": .stringConvertible(dispatchMilliseconds),
                    "total_ms": .stringConvertible(totalMilliseconds)
                ])
            }
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning("Domain-event payload batch dispatch encode failed.", metadata: [
                "requestID": .string(requestID?.uuidString ?? ""),
                "event_id": .string(batch.payload.eventID.uuidString),
                "target_user_count": .stringConvertible(Set(batch.recipientUserIDs).count),
                "error": .string(String(describing: error))
            ])
        }
    }

    private func dispatchRemoteActiveConversationPayloadBatch(
        _ batch: IMGatewayDomainEventPayloadBatch,
        requestID: UUID?,
        remoteNodeIDs: Set<String>,
        encodeCache: DomainEventPacketEncodeCache
    ) async -> Bool {
        do {
            guard !remoteNodeIDs.isEmpty else {
                return true
            }

            let routeStartedAt = Date()
            let activeRoutes = try await backend.presenceStore.routeNodeIDs(
                forActiveConversationID: batch.payload.aggregateID,
                amongUserIDs: batch.recipientUserIDs
            )
            let activeRouteMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: routeStartedAt)
            let plan = remoteActiveConversationFanoutPlan(
                for: batch,
                activeRoutes: activeRoutes
            )
            await app.routingMetrics.recordRemoteActiveConversationFanoutSplit(
                fullRecipientCount: plan.activeFullUserIDs.count,
                compactRecipientCount: plan.activeCompactUserIDs.count,
                inactiveHintRecipientCount: plan.inactiveHintUserIDs.count,
                downgradedActiveRecipientCount: plan.downgradedActiveUserCount
            )
            if plan.payloadBudgetDowngradedRecipientCount > 0 {
                await app.routingMetrics.recordActiveConversationFanoutPayloadBudgetApplied(
                    payloadByteCount: plan.payloadBudget.payloadByteCount,
                    effectiveFullFanoutLimit: plan.payloadBudget.limit,
                    downgradedActiveRecipientCount: plan.payloadBudgetDowngradedRecipientCount
                )
            }

            var workItems: [RemoteDispatchWorkItem] = []
            var encodedPayloadCount = 0
            if !plan.activeFullUserIDs.isEmpty {
                let envelope = try await encodeActiveConversationDomainEventPacketEnvelope(
                    requestID: requestID,
                    payload: batch.payload,
                    conversationID: batch.payload.aggregateID,
                    allowedUserIDs: plan.activeFullUserIDs,
                    fanoutIntent: .preSplitActiveFull,
                    encodeCache: encodeCache
                )
                let fullRoutes = filteredRoutes(activeRoutes, forUserIDs: plan.activeFullUserIDs)
                workItems += remoteDispatchWorkItems(
                    envelope: envelope,
                    targetUserIDsByNodeID: targetUserIDsByNodeID(from: fullRoutes)
                )
                encodedPayloadCount += 1
            }
            if !plan.activeCompactUserIDs.isEmpty {
                let compactPayload = batch.payload.activeCompactHintForRemoteActiveRecipient(
                    body: app.streamConsumerConfiguration.realtimeActiveCompactHintBody,
                    maxPreviewCharacters: app.streamConsumerConfiguration.realtimeActiveCompactHintPreviewMaxCharacters,
                    eventID: imLightweightMessageCreatedHintEventID(for: batch.payload.eventID)
                ) ?? batch.payload
                let envelope = try await encodeActiveConversationDomainEventPacketEnvelope(
                    requestID: requestID,
                    payload: compactPayload,
                    conversationID: batch.payload.aggregateID,
                    allowedUserIDs: plan.activeCompactUserIDs,
                    fanoutIntent: .preSplitActiveCompact,
                    encodeCache: encodeCache
                )
                let compactRoutes = filteredRoutes(activeRoutes, forUserIDs: plan.activeCompactUserIDs)
                workItems += remoteDispatchWorkItems(
                    envelope: envelope,
                    targetUserIDsByNodeID: targetUserIDsByNodeID(from: compactRoutes)
                )
                encodedPayloadCount += 1
            }

            var hintRouteMilliseconds = 0
            if !plan.inactiveHintUserIDs.isEmpty,
               let hintPayload = batch.payload.conversationActivityHintForRemoteInactiveRecipient(
                   maxPreviewCharacters: app.streamConsumerConfiguration.realtimeMessageCreatedLightweightPreviewMaxCharacters,
                   eventID: imLightweightMessageCreatedHintEventID(for: batch.payload.eventID)
               ) {
                let hintRouteStartedAt = Date()
                let hintRoutes = try await backend.presenceStore.routeNodeIDs(forUserIDs: plan.inactiveHintUserIDs)
                hintRouteMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: hintRouteStartedAt)
                let envelope = try await encodeDomainEventPacketEnvelope(
                    requestID: requestID,
                    payload: hintPayload,
                    targetUserIDs: plan.inactiveHintUserIDs,
                    fanoutIntent: .preSplitInactiveHint,
                    encodeCache: encodeCache
                )
                workItems += remoteDispatchWorkItems(
                    envelope: envelope,
                    targetUserIDsByNodeID: targetUserIDsByNodeID(from: hintRoutes)
                )
                encodedPayloadCount += 1
            }

            let dispatchStartedAt = Date()
            await dispatchRemoteWorkItems(
                workItems,
                failureLogMessage: "Cross-node active conversation IM dispatch failed",
                targetMetadataKey: "target_user_count"
            )
            let dispatchMilliseconds = IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: dispatchStartedAt)
            let totalMilliseconds = activeRouteMilliseconds + hintRouteMilliseconds + dispatchMilliseconds
            let slowLogMilliseconds = app.streamConsumerConfiguration.realtimeDeliverySlowLogMilliseconds
            if IMRealtimeDeliveryDiagnostics.shouldLogAny(
                [activeRouteMilliseconds, hintRouteMilliseconds, dispatchMilliseconds, totalMilliseconds],
                thresholdMilliseconds: slowLogMilliseconds
            ) {
                app.logger.info("Cross-node active conversation fanout slow.", metadata: [
                    "node_id": .string(nodeID),
                    "route_backend": .string(routeBackendName),
                    "request_id": .string(requestID?.uuidString ?? ""),
                    "event_id": .string(batch.payload.eventID.uuidString),
                    "conversation_id": .string(batch.payload.aggregateID.uuidString),
                    "recipient_count": .stringConvertible(Set(batch.recipientUserIDs).count),
                    "active_full_user_count": .stringConvertible(plan.activeFullUserIDs.count),
                    "inactive_hint_user_count": .stringConvertible(plan.inactiveHintUserIDs.count),
                    "work_item_count": .stringConvertible(workItems.count),
                    "encoded_payload_count": .stringConvertible(encodedPayloadCount),
                    "active_route_ms": .stringConvertible(activeRouteMilliseconds),
                    "hint_route_ms": .stringConvertible(hintRouteMilliseconds),
                    "dispatch_ms": .stringConvertible(dispatchMilliseconds),
                    "total_ms": .stringConvertible(totalMilliseconds)
                ])
            }
            return true
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            if !app.streamConsumerConfiguration.realtimeActiveConversationUnsplitFallbackEnabled {
                let targetUserCount = Set(batch.recipientUserIDs).count
                await app.routingMetrics.recordRemoteActiveConversationFanoutDroppedFallback(
                    recipientCount: targetUserCount
                )
                app.logger.warning("Cross-node active conversation fanout failed; dropping unsplit fallback.", metadata: [
                    "requestID": .string(requestID?.uuidString ?? ""),
                    "event_id": .string(batch.payload.eventID.uuidString),
                    "conversation_id": .string(batch.payload.aggregateID.uuidString),
                    "target_user_count": .stringConvertible(targetUserCount),
                    "error": .string(String(describing: error))
                ])
                return true
            }
            await app.routingMetrics.recordRemoteActiveConversationFanoutFallback()
            app.logger.warning("Cross-node active conversation fanout failed; falling back to full remote dispatch.", metadata: [
                "requestID": .string(requestID?.uuidString ?? ""),
                "event_id": .string(batch.payload.eventID.uuidString),
                "conversation_id": .string(batch.payload.aggregateID.uuidString),
                "target_user_count": .stringConvertible(Set(batch.recipientUserIDs).count),
                "error": .string(String(describing: error))
            ])
            return false
        }
    }

    private func shouldSplitRemoteActiveConversationFanout(_ batch: IMGatewayDomainEventPayloadBatch) -> Bool {
        let configuration = app.gatewayLocalFanoutConfiguration
        guard batch.fanoutIntent == .unspecified,
              configuration.activeConversationFanoutEnabled,
              batch.payload.eventType == .messageCreated
        else {
            return false
        }

        if let conversation = batch.payload.conversation {
            guard conversation.kind == IMConversationKind.group.rawValue else {
                return false
            }
            return conversation.memberCount >= configuration.activeConversationFanoutRecipientThreshold
        }

        return Set(batch.recipientUserIDs).count >= configuration.activeConversationFanoutRecipientThreshold
    }

    private func remoteActiveConversationFanoutPlan(
        for batch: IMGatewayDomainEventPayloadBatch,
        activeRoutes: [UUID: Set<String>]
    ) -> RemoteActiveConversationFanoutPlan {
        var seenUserIDs = Set<UUID>()
        let orderedUserIDs = batch.recipientUserIDs.filter { seenUserIDs.insert($0).inserted }
        let activeUserIDs = orderedUserIDs.filter { userID in
            guard let nodeIDs = activeRoutes[userID] else {
                return false
            }
            return nodeIDs.contains(where: { $0 != nodeID })
        }
        let fanoutConfiguration = app.gatewayLocalFanoutConfiguration
        let budget = IMActiveConversationFullFanoutBudget.effectiveLimit(
            baseLimit: fanoutConfiguration.activeConversationFullFanoutRecipientLimit,
            payloadByteBudget: fanoutConfiguration.activeConversationFullFanoutPayloadByteBudget,
            payload: batch.payload
        )
        let activeSelection: IMActiveConversationFullFanoutSelector
        if fanoutConfiguration.usesCompactOnlyActiveConversationFanout {
            activeSelection = IMActiveConversationFullFanoutSelector(
                fullUserIDs: [],
                downgradedUserIDs: activeUserIDs
            )
        } else {
            activeSelection = IMActiveConversationFullFanoutSelector.select(
                from: activeUserIDs,
                limit: budget.limit,
                aggregateSequence: batch.payload.aggregateSequence
            )
        }
        let fullActiveUserIDSet = Set(activeSelection.fullUserIDs)
        let activeUserIDSet = Set(activeUserIDs)
        return RemoteActiveConversationFanoutPlan(
            activeFullUserIDs: activeSelection.fullUserIDs,
            activeCompactUserIDs: activeSelection.downgradedUserIDs,
            inactiveHintUserIDs: fanoutConfiguration.relaysInactiveConversationHints ? orderedUserIDs.filter {
                !fullActiveUserIDSet.contains($0) && !activeUserIDSet.contains($0)
            } : [],
            downgradedActiveUserCount: activeSelection.downgradedUserIDs.count,
            payloadBudget: budget,
            activeCandidateCount: activeUserIDs.count
        )
    }

    private func dispatchRemoteWorkItems(
        _ workItems: [RemoteDispatchWorkItem],
        failureLogMessage: String,
        targetMetadataKey: String
    ) async {
        guard !workItems.isEmpty else {
            return
        }

        let maxInFlight = app.streamConsumerConfiguration.realtimeRemoteDispatchMaxInFlight
        var nextIndex = workItems.startIndex
        await withTaskGroup(of: RemoteDispatchResult.self) { group in
            var inFlight = 0

            while nextIndex < workItems.endIndex && inFlight < maxInFlight {
                let item = workItems[nextIndex]
                nextIndex = workItems.index(after: nextIndex)
                inFlight += 1
                enqueueRemoteDispatch(item, in: &group)
            }

            while let result = await group.next() {
                inFlight -= 1
                await recordRemoteDispatchResult(
                    result,
                    failureLogMessage: failureLogMessage,
                    targetMetadataKey: targetMetadataKey
                )

                guard nextIndex < workItems.endIndex else {
                    continue
                }
                let item = workItems[nextIndex]
                nextIndex = workItems.index(after: nextIndex)
                inFlight += 1
                enqueueRemoteDispatch(item, in: &group)
            }
        }
    }

    private func remoteDispatchWorkItems(
        envelope: NodeMessageDispatchEnvelope,
        targetUserIDsByNodeID: [String: Set<UUID>]
    ) -> [RemoteDispatchWorkItem] {
        let userBatchSize = app.streamConsumerConfiguration.realtimeRemoteDispatchUserBatchSize
        return targetUserIDsByNodeID
            .sorted { $0.key < $1.key }
            .flatMap { remoteNodeID, targetUserIDs in
                Self.sortedUUIDChunks(Array(targetUserIDs), batchSize: userBatchSize).map { chunk in
                    RemoteDispatchWorkItem(
                        remoteNodeID: remoteNodeID,
                        targetCount: chunk.count,
                        envelope: envelope.withTargetUserIDs(chunk)
                    )
                }
            }
    }

    private func targetUserIDsByNodeID(
        from routes: [UUID: Set<String>],
        includeLocalNode: Bool = false
    ) -> [String: Set<UUID>] {
        var targetUserIDsByNodeID: [String: Set<UUID>] = [:]
        for (userID, nodeIDs) in routes {
            for remoteNodeID in nodeIDs where includeLocalNode || remoteNodeID != nodeID {
                targetUserIDsByNodeID[remoteNodeID, default: []].insert(userID)
            }
        }
        return targetUserIDsByNodeID
    }

    private func filteredRoutes(
        _ routes: [UUID: Set<String>],
        forUserIDs userIDs: [UUID]
    ) -> [UUID: Set<String>] {
        Dictionary(uniqueKeysWithValues: userIDs.map { userID in
            (userID, routes[userID] ?? [])
        })
    }

    private func enqueueRemoteDispatch(
        _ item: RemoteDispatchWorkItem,
        in group: inout TaskGroup<RemoteDispatchResult>
    ) {
        group.addTask {
            await app.routingMetrics.recordCrossNodeDispatchAttempt(targetCount: item.targetCount)
            let startedAt = Date()
            do {
                try await dispatchWithTimeout(
                    item.envelope,
                    toNodeID: item.remoteNodeID,
                    using: backend.dispatchService
                )
                return RemoteDispatchResult(
                    remoteNodeID: item.remoteNodeID,
                    targetCount: item.targetCount,
                    latencyMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt),
                    error: nil
                )
            } catch {
                return RemoteDispatchResult(
                    remoteNodeID: item.remoteNodeID,
                    targetCount: item.targetCount,
                    latencyMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt),
                    error: error
                )
            }
        }
    }

    private func recordRemoteDispatchResult(
        _ result: RemoteDispatchResult,
        failureLogMessage: String,
        targetMetadataKey: String
    ) async {
        if let error = result.error {
            await app.routingMetrics.recordCrossNodeDispatchFailed(latencyMilliseconds: result.latencyMilliseconds)
            var metadata: Logger.Metadata = [
                "node_id": .string(nodeID),
                "route_backend": .string(routeBackendName),
                "target_node_id": .string(result.remoteNodeID),
                "latency_ms": .stringConvertible(result.latencyMilliseconds),
                "error": .string(String(describing: error))
            ]
            metadata[targetMetadataKey] = .stringConvertible(result.targetCount)
            app.logger.warning(Logger.Message(stringLiteral: failureLogMessage), metadata: metadata)
        } else {
            await app.routingMetrics.recordCrossNodeDispatchSucceeded(latencyMilliseconds: result.latencyMilliseconds)
        }
    }

    private static func sortedUUIDChunks(_ ids: [UUID], batchSize: Int) -> [[UUID]] {
        let sortedIDs = ids.sorted { $0.uuidString < $1.uuidString }
        let size = max(1, batchSize)
        var chunks: [[UUID]] = []
        chunks.reserveCapacity((sortedIDs.count + size - 1) / size)

        var startIndex = sortedIDs.startIndex
        while startIndex < sortedIDs.endIndex {
            let endIndex = sortedIDs.index(
                startIndex,
                offsetBy: size,
                limitedBy: sortedIDs.endIndex
            ) ?? sortedIDs.endIndex
            chunks.append(Array(sortedIDs[startIndex..<endIndex]))
            startIndex = endIndex
        }
        return chunks
    }

    private enum ConnectionRoutingDispatchError: Error {
        case timeout(String)
    }

    private func encodePacketEnvelope<Payload: Sendable>(
        requestID: UUID?,
        payload: Payload,
        targetUserIDs: [UUID]
    ) throws -> NodeMessageDispatchEnvelope {
        let data = try IMTCPProtobufCodec.encode(type: .streamSignal, requestID: requestID, payload: payload)
        return NodeMessageDispatchEnvelope(
            requestID: requestID,
            payload: .streamSignal(packetBase64: data.base64EncodedString(), targetUserIDs: targetUserIDs)
        )
    }

    private func encodeDomainEventPacketEnvelope(
        requestID: UUID?,
        payload: IMTCPChatDomainEventPayload,
        targetUserIDs: [UUID],
        fanoutIntent: IMGatewayDomainEventFanoutIntent = .unspecified
    ) throws -> NodeMessageDispatchEnvelope {
        let data = try IMTCPProtobufCodec.encode(type: .domainEvent, requestID: requestID, payload: payload)
        return NodeMessageDispatchEnvelope(
            requestID: requestID,
            payload: .domainEventPacket(
                packetBase64: data.base64EncodedString(),
                targetUserIDs: targetUserIDs,
                fanoutIntent: fanoutIntent == .unspecified ? nil : fanoutIntent
            )
        )
    }

    private func encodeActiveConversationDomainEventPacketEnvelope(
        requestID: UUID?,
        payload: IMTCPChatDomainEventPayload,
        conversationID: UUID,
        allowedUserIDs: [UUID],
        fanoutIntent: IMGatewayDomainEventFanoutIntent,
        encodeCache: DomainEventPacketEncodeCache
    ) async throws -> NodeMessageDispatchEnvelope {
        let packetBase64 = try await encodeCache.packetBase64(
            requestID: requestID,
            payload: payload,
            reusableKey: reusablePacketKey(for: payload)
        )
        return NodeMessageDispatchEnvelope(
            requestID: requestID,
            payload: .activeConversationDomainEventPacket(
                packetBase64: packetBase64,
                conversationID: conversationID,
                allowedUserIDs: allowedUserIDs,
                fanoutIntent: fanoutIntent
            )
        )
    }

    private func encodeDomainEventPacketEnvelope(
        requestID: UUID?,
        payload: IMTCPChatDomainEventPayload,
        targetUserIDs: [UUID],
        fanoutIntent: IMGatewayDomainEventFanoutIntent = .unspecified,
        encodeCache: DomainEventPacketEncodeCache
    ) async throws -> NodeMessageDispatchEnvelope {
        let packetBase64 = try await encodeCache.packetBase64(
            requestID: requestID,
            payload: payload,
            reusableKey: reusablePacketKey(for: payload)
        )
        return NodeMessageDispatchEnvelope(
            requestID: requestID,
            payload: .domainEventPacket(
                packetBase64: packetBase64,
                targetUserIDs: targetUserIDs,
                fanoutIntent: fanoutIntent == .unspecified ? nil : fanoutIntent
            )
        )
    }

    private func groupReusableDomainEventPayloads(
        _ deliveries: [IMCanonicalDomainEventDelivery]
    ) -> (
        reusable: [(payload: IMTCPChatDomainEventPayload, userIDs: [UUID])],
        fallback: [IMCanonicalDomainEventDelivery]
    ) {
        var reusableGroups: [ReusableDomainEventPacketKey: (payload: IMTCPChatDomainEventPayload, userIDs: [UUID])] = [:]
        var fallback: [IMCanonicalDomainEventDelivery] = []
        fallback.reserveCapacity(deliveries.count)

        for delivery in deliveries {
            guard let key = reusablePacketKey(for: delivery.payload) else {
                fallback.append(delivery)
                continue
            }
            if reusableGroups[key] == nil {
                reusableGroups[key] = (payload: delivery.payload, userIDs: [])
            }
            reusableGroups[key]?.userIDs.append(delivery.ownerUserID)
        }

        return (
            reusable: Array(reusableGroups.values),
            fallback: fallback
        )
    }

    private func reusablePacketKey(for payload: IMTCPChatDomainEventPayload) -> ReusableDomainEventPacketKey? {
        guard payload.timelineNotice == nil,
              payload.requiresTimelineNotice == false,
              payload.ownerCursor == nil,
              payload.ownerAggregateSequence == nil
        else {
            return nil
        }

        let bodyVariant: String
        switch payload.eventType {
        case .messageCreated:
            guard payload.conversation == nil else {
                return nil
            }
            bodyVariant = "messageCreated"
        case .conversationUpdated:
            guard payload.conversation != nil,
                  case .conversationChanged = payload.body
            else {
                return nil
            }
            bodyVariant = "conversationChanged"
        case .conversationActivityHint:
            guard payload.conversation == nil,
                  case .conversationActivityHint(let hint) = payload.body
            else {
                return nil
            }
            bodyVariant = [
                "conversationActivityHint",
                hint.messageID.uuidString,
                "\(hint.serverSequence)",
                "\(hint.timelineSequence)",
                hint.previewText,
                hint.messageCreatedAt.map { "\($0.timeIntervalSince1970)" } ?? "",
                "\(hint.updatedAt.timeIntervalSince1970)"
            ].joined(separator: "|")
        case .timelineGapHint:
            guard payload.conversation == nil,
                  case .timelineGapHint(let hint) = payload.body
            else {
                return nil
            }
            bodyVariant = [
                "timelineGapHint",
                hint.messageID.uuidString,
                "\(hint.serverSequence)",
                "\(hint.timelineSequence)",
                "\(hint.updatedAt.timeIntervalSince1970)"
            ].joined(separator: "|")
        case .conversationCreated,
             .conversationSettingsChanged,
             .conversationRemovedForSelf,
             .messageEdited,
             .messageRevoked,
             .messageStreamStarted,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled,
             .messageVisibilityChanged,
             .messageFavoriteChanged,
             .memberAdded,
             .memberRemoved,
             .memberRoleUpdated,
             .contactRequestCreated,
             .contactRequestAccepted,
             .contactRequestUpdated,
             .conversationVisibilityChanged:
            return nil
        }

        return ReusableDomainEventPacketKey(
            eventID: payload.eventID,
            eventType: payload.eventType,
            aggregateID: payload.aggregateID,
            aggregateSequence: payload.aggregateSequence,
            bodyVariant: bodyVariant
        )
    }

    private func decodeDomainEventPacketPayload(from envelope: NodeMessageDispatchEnvelope) -> IMTCPChatDomainEventPayload? {
        let packetBase64: String
        switch envelope.payload {
        case .domainEventPacket(let encoded, _, _),
             .activeConversationDomainEventPacket(let encoded, _, _, _):
            packetBase64 = encoded
        case .domainEvent,
             .streamSignal,
             .kickSession,
             .kickUser:
            return nil
        }
        guard let packetData = Data(base64Encoded: packetBase64),
              let packet = try? IMTCPProtobufCodec.decode(packetData)
        else {
            return nil
        }
        return try? packet.payload.decodePayload(IMTCPChatDomainEventPayload.self)
    }

    private func decodePayload<Payload: Sendable>(from envelope: NodeMessageDispatchEnvelope) -> Payload? {
        guard case .streamSignal(let packetBase64, _) = envelope.payload,
              let packetData = Data(base64Encoded: packetBase64)
        else {
            return nil
        }
        guard let packet = try? IMTCPProtobufCodec.decode(packetData) else {
            return nil
        }
        return try? packet.payload.decodePayload(Payload.self)
    }
}

private extension IMTCPChatDomainEventPayload {
    func activeCompactHintForRemoteActiveRecipient(
        body: IMStreamConsumerConfiguration.ActiveCompactHintBody,
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        switch body {
        case .conversationActivity:
            return conversationActivityHintForRemoteActiveRecipient(
                maxPreviewCharacters: maxPreviewCharacters,
                eventID: hintEventID
            )
        case .timelineGap:
            return timelineGapHintForRemoteActiveRecipient(eventID: hintEventID)
        }
    }

    func timelineGapHintForRemoteActiveRecipient(
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        guard eventType == .messageCreated else {
            return nil
        }
        guard let timelineGapHint = remoteActiveConversationTimelineGapHint() else {
            return nil
        }
        return IMTCPChatDomainEventPayload(
            eventID: hintEventID ?? eventID,
            eventType: .timelineGapHint,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .timelineGapHint(timelineGapHint)
        )
    }

    func conversationActivityHintForRemoteActiveRecipient(
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        guard eventType == .messageCreated else {
            return nil
        }
        guard let activityHint = remoteConversationActivityHint(maxPreviewCharacters: maxPreviewCharacters) else {
            return nil
        }
        return IMTCPChatDomainEventPayload(
            eventID: hintEventID ?? eventID,
            eventType: .conversationActivityHint,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .conversationActivityHint(activityHint)
        )
    }

    func conversationActivityHintForRemoteInactiveRecipient(
        maxPreviewCharacters: Int,
        eventID hintEventID: UUID? = nil
    ) -> IMTCPChatDomainEventPayload? {
        guard eventType == .messageCreated else {
            return nil
        }
        guard let activityHint = remoteConversationActivityHint(maxPreviewCharacters: maxPreviewCharacters) else {
            return nil
        }
        return IMTCPChatDomainEventPayload(
            eventID: hintEventID ?? eventID,
            eventType: .conversationActivityHint,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            aggregateSequence: aggregateSequence,
            occurredAt: occurredAt,
            actorUserID: actorUserID,
            conversation: nil,
            timelineNotice: nil,
            requiresTimelineNotice: false,
            ownerCursor: nil,
            ownerAggregateSequence: nil,
            body: .conversationActivityHint(activityHint)
        )
    }

    private func remoteActiveConversationTimelineGapHint() -> IMTimelineGapHint? {
        guard case .messageCreated(let message, _) = body else {
            return nil
        }
        return IMTimelineGapHint(
            messageID: message.id,
            senderUserID: message.senderUserID,
            serverSequence: message.serverSequence,
            timelineSequence: message.timelineSequence,
            updatedAt: message.createdAt ?? occurredAt
        )
    }

    private func remoteConversationActivityHint(maxPreviewCharacters: Int) -> IMConversationActivityHint? {
        guard case .messageCreated(let message, _) = body else {
            return nil
        }
        let preview = Self.truncatedPreview(
            message.content.previewText,
            maxCharacters: maxPreviewCharacters
        )
        return IMConversationActivityHint(
            messageID: message.id,
            senderUserID: message.senderUserID,
            serverSequence: message.serverSequence,
            timelineSequence: message.timelineSequence,
            previewText: preview,
            messageCreatedAt: preview.isEmpty ? nil : message.createdAt,
            updatedAt: message.createdAt ?? occurredAt
        )
    }

    private static func truncatedPreview(_ preview: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else {
            return ""
        }
        guard maxCharacters > 0, preview.count > maxCharacters else {
            return preview
        }
        return String(preview.prefix(maxCharacters))
    }
}
