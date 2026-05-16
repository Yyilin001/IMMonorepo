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

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await app.routingMetrics.recordUserFanout(targetUserCount: Set(userIDs).count)
        await app.imConnectionRegistry.sendMessage(payload, toUserIDs: userIDs, requestID: requestID)
        let envelope = try? encodePacketEnvelope(
            action: .message,
            packetType: .message,
            requestID: requestID,
            payload: payload,
            targetUserIDs: userIDs
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: userIDs)
    }

    func sendConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await app.imConnectionRegistry.sendConversationEvent(payload, toUserID: userID, requestID: requestID)
        let envelope = try? encodePacketEnvelope(
            action: .conversationEvent,
            packetType: .conversationEvent,
            requestID: requestID,
            payload: payload,
            targetUserIDs: [userID]
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID])
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        await app.imConnectionRegistry.sendContactEvent(payload, toUserID: userID, requestID: requestID)
        let envelope = try? encodePacketEnvelope(
            action: .contactEvent,
            packetType: .contactEvent,
            requestID: requestID,
            payload: payload,
            targetUserIDs: [userID]
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID])
    }

    func kickConnections(
        forSessionID sessionID: UUID,
        reason: IMTCPKickReason,
        message: String
    ) async {
        await app.routingMetrics.recordSessionKick(targetSessionCount: 1)
        await app.imConnectionRegistry.kickConnections(forSessionID: sessionID, reason: reason, message: message)
        let envelope = NodeMessageDispatchEnvelope(
            action: .kickSession,
            packetType: nil,
            requestID: nil,
            payloadJSON: nil,
            targetUserIDs: [],
            sessionID: sessionID,
            kickReason: reason,
            kickMessage: message
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
        let sessionCount = await app.imConnectionRegistry.connectionIDs(forUserID: userID).count
        await app.routingMetrics.recordSessionKick(targetSessionCount: max(sessionCount, 1))
        await app.imConnectionRegistry.kickConnections(forUserID: userID, reason: reason, message: message)
        let envelope = NodeMessageDispatchEnvelope(
            action: .kickUser,
            packetType: nil,
            requestID: nil,
            payloadJSON: nil,
            targetUserIDs: [userID],
            sessionID: nil,
            kickReason: reason,
            kickMessage: message
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID], includeLocalNode: false)
    }

    func handleRemoteDispatch(_ envelope: NodeMessageDispatchEnvelope) async {
        switch envelope.action {
        case .message:
            guard let payload: IMTCPMessagePayload = decodePayload(from: envelope) else { return }
            await app.imConnectionRegistry.sendMessage(
                payload,
                toUserIDs: envelope.targetUserIDs,
                requestID: envelope.requestID
            )
        case .conversationEvent:
            guard let userID = envelope.targetUserIDs.first,
                  let payload: IMTCPConversationEventPayload = decodePayload(from: envelope)
            else { return }
            await app.imConnectionRegistry.sendConversationEvent(payload, toUserID: userID, requestID: envelope.requestID)
        case .contactEvent:
            guard let userID = envelope.targetUserIDs.first,
                  let payload: IMTCPContactEventPayload = decodePayload(from: envelope)
            else { return }
            await app.imConnectionRegistry.sendContactEvent(payload, toUserID: userID, requestID: envelope.requestID)
        case .kickSession:
            guard let sessionID = envelope.sessionID,
                  let reason = envelope.kickReason,
                  let message = envelope.kickMessage
            else { return }
            await app.imConnectionRegistry.kickConnections(forSessionID: sessionID, reason: reason, message: message)
        case .kickUser:
            guard let userID = envelope.targetUserIDs.first,
                  let reason = envelope.kickReason,
                  let message = envelope.kickMessage
            else { return }
            await app.imConnectionRegistry.kickConnections(forUserID: userID, reason: reason, message: message)
        }
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
                        let routedEnvelope = NodeMessageDispatchEnvelope(
                            action: envelope.action,
                            packetType: envelope.packetType,
                            requestID: envelope.requestID,
                            payloadJSON: envelope.payloadJSON,
                            targetUserIDs: envelope.targetUserIDs,
                            sessionID: targetSessionID,
                            kickReason: envelope.kickReason,
                            kickMessage: envelope.kickMessage
                        )
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

    private func encodePacketEnvelope<Payload: Codable & Sendable>(
        action: NodeMessageDispatchEnvelope.Action,
        packetType: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        targetUserIDs: [UUID]
    ) throws -> NodeMessageDispatchEnvelope {
        let data = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw RedisRoutingError.invalidDispatchPayload
        }
        return NodeMessageDispatchEnvelope(
            action: action,
            packetType: packetType,
            requestID: requestID,
            payloadJSON: payloadJSON,
            targetUserIDs: targetUserIDs,
            sessionID: nil,
            kickReason: nil,
            kickMessage: nil
        )
    }

    private func decodePayload<Payload: Decodable>(from envelope: NodeMessageDispatchEnvelope) -> Payload? {
        guard let payloadJSON = envelope.payloadJSON else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: Data(payloadJSON.utf8))
    }
}
