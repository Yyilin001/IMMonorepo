import Foundation
import Vapor

struct ConnectionRoutingService {
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
        if await app.imConnectionRegistry.localConnectionCount(forUserID: removed.userID) == 0 {
            try? await backend.presenceStore.deactivatePresence(forUserID: removed.userID)
        }
        if await app.imConnectionRegistry.localConnectionCount(forSessionID: removed.sessionID) == 0 {
            try? await backend.presenceStore.deactivatePresence(forSessionID: removed.sessionID, userID: removed.userID)
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
        let removedConnections = await app.imConnectionRegistry.kickExistingConnections(
            forSessionID: sessionID,
            reason: reason,
            message: message
        )
        await cleanupPresenceAfterLocalKick(removedConnections)
        return removedConnections
    }

    @discardableResult
    private func kickLocalConnections(
        forUserID userID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async -> [IMAuthenticatedConnection] {
        let removedConnections = await app.imConnectionRegistry.kickExistingConnections(
            forUserID: userID,
            reason: reason,
            message: message
        )
        await cleanupPresenceAfterLocalKick(removedConnections)
        return removedConnections
    }

    private func cleanupPresenceAfterLocalKick(_ removedConnections: [IMAuthenticatedConnection]) async {
        guard !removedConnections.isEmpty else {
            return
        }

        await app.routingMetrics.recordCurrentTCPConnectionCount(await app.imConnectionRegistry.totalConnectionCount())

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
        do {
            let routes = try await backend.presenceStore.routeNodeIDs(forUserIDs: userIDs)
            var targetUserIDsByNodeID: [String: Set<UUID>] = [:]
            for (userID, nodeIDs) in routes {
                for remoteNodeID in nodeIDs where includeLocalNode || remoteNodeID != nodeID {
                    targetUserIDsByNodeID[remoteNodeID, default: []].insert(userID)
                }
            }

            await withTaskGroup(of: (String, Int, (any Error)?).self) { group in
                for (remoteNodeID, targetUserIDs) in targetUserIDsByNodeID {
                    let routedEnvelope = envelope.withTargetUserIDs(
                        targetUserIDs.sorted { $0.uuidString < $1.uuidString }
                    )
                    group.addTask {
                        do {
                            try await dispatchWithTimeout(
                                routedEnvelope,
                                toNodeID: remoteNodeID,
                                using: backend.dispatchService
                            )
                            return (remoteNodeID, targetUserIDs.count, nil)
                        } catch {
                            return (remoteNodeID, targetUserIDs.count, error)
                        }
                    }
                }

                for await (remoteNodeID, targetUserCount, error) in group {
                    if let error {
                        await app.routingMetrics.recordCrossNodeDispatchFailed()
                        app.logger.warning(
                            "Cross-node IM dispatch failed",
                            metadata: [
                                "node_id": .string(nodeID),
                                "route_backend": .string(routeBackendName),
                                "target_node_id": .string(remoteNodeID),
                                "target_user_count": .stringConvertible(targetUserCount),
                                "error": .string(String(describing: error))
                            ]
                        )
                    } else {
                        await app.routingMetrics.recordCrossNodeDispatchSucceeded()
                    }
                }
            }
        } catch {
            await app.routingMetrics.recordCrossNodeDispatchFailed()
            app.logger.warning(
                "Cross-node IM dispatch failed",
                metadata: [
                    "node_id": .string(nodeID),
                    "route_backend": .string(routeBackendName),
                    "target_user_count": .stringConvertible(Set(userIDs).count),
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
            let routes = try await backend.presenceStore.routeNodeIDs(forSessionIDs: sessionIDs)
            var targetSessionIDsByNodeID: [String: Set<UUID>] = [:]
            for (sessionID, nodeIDs) in routes {
                for remoteNodeID in nodeIDs where includeLocalNode || remoteNodeID != nodeID {
                    targetSessionIDsByNodeID[remoteNodeID, default: []].insert(sessionID)
                }
            }

            await withTaskGroup(of: (String, Int, (any Error)?).self) { group in
                for (remoteNodeID, targetSessionIDs) in targetSessionIDsByNodeID {
                    for targetSessionID in targetSessionIDs {
                        let routedEnvelope = envelope.withSessionID(targetSessionID)
                        group.addTask {
                            do {
                                try await dispatchWithTimeout(
                                    routedEnvelope,
                                    toNodeID: remoteNodeID,
                                    using: backend.dispatchService
                                )
                                return (remoteNodeID, 1, nil)
                            } catch {
                                return (remoteNodeID, 1, error)
                            }
                        }
                    }
                }

                for await (remoteNodeID, targetSessionCount, error) in group {
                    if let error {
                        await app.routingMetrics.recordCrossNodeDispatchFailed()
                        app.logger.warning(
                            "Cross-node IM session dispatch failed",
                            metadata: [
                                "node_id": .string(nodeID),
                                "route_backend": .string(routeBackendName),
                                "target_node_id": .string(remoteNodeID),
                                "target_session_count": .stringConvertible(targetSessionCount),
                                "error": .string(String(describing: error))
                            ]
                        )
                    } else {
                        await app.routingMetrics.recordCrossNodeDispatchSucceeded()
                    }
                }
            }
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
