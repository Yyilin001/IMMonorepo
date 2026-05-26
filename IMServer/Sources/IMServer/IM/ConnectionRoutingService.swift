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
            action: .kickSession,
            packetType: nil,
            requestID: nil,
            packetBase64: nil,
            targetUserIDs: [],
            sessionID: sessionID,
            kickReason: .duplicateConnection,
            kickMessage: "This session opened a new realtime connection."
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

    func sendMessage(
        _ payload: IMTCPMessagePayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        return
    }

    func sendDomainEvent(
        _ payload: IMTCPChatDomainEventPayload,
        toUserIDs userIDs: [UUID],
        requestID: UUID? = UUID()
    ) async {
        await app.routingMetrics.recordUserFanout(targetUserCount: Set(userIDs).count)
        await app.imConnectionRegistry.sendDomainEvent(payload, toUserIDs: userIDs, requestID: requestID)
        let envelope = try? encodePacketEnvelope(
            action: .domainEvent,
            packetType: .domainEvent,
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
        return
    }

    func sendContactEvent(
        _ payload: IMTCPContactEventPayload,
        toUserID userID: UUID,
        requestID: UUID? = UUID()
    ) async {
        return
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
            action: .kickSession,
            packetType: nil,
            requestID: nil,
            packetBase64: nil,
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
        let removedConnections = await kickLocalConnections(forUserID: userID, reason: reason, message: message)
        await app.routingMetrics.recordSessionKick(targetSessionCount: max(removedConnections.count, 1))
        let envelope = NodeMessageDispatchEnvelope(
            action: .kickUser,
            packetType: nil,
            requestID: nil,
            packetBase64: nil,
            targetUserIDs: [userID],
            sessionID: nil,
            kickReason: reason,
            kickMessage: message
        )
        await dispatchRemoteEnvelopeIfNeeded(envelope, forUserIDs: [userID], includeLocalNode: false)
    }

    func handleRemoteDispatch(_ envelope: NodeMessageDispatchEnvelope) async {
        switch envelope.action {
        case .domainEvent:
            guard let payload: IMTCPChatDomainEventPayload = decodePayload(from: envelope) else { return }
            await app.imConnectionRegistry.sendDomainEvent(
                payload,
                toUserIDs: envelope.targetUserIDs,
                requestID: envelope.requestID
            )
        case .message, .conversationEvent, .contactEvent:
            return
        case .kickSession:
            guard let sessionID = envelope.sessionID,
                  let reason = envelope.kickReason,
                  let message = envelope.kickMessage
            else { return }
            await kickLocalConnections(forSessionID: sessionID, reason: reason, message: message)
        case .kickUser:
            guard let userID = envelope.targetUserIDs.first,
                  let reason = envelope.kickReason,
                  let message = envelope.kickMessage
            else { return }
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
                        let routedEnvelope = NodeMessageDispatchEnvelope(
                            action: envelope.action,
                            packetType: envelope.packetType,
                            requestID: envelope.requestID,
                            packetBase64: envelope.packetBase64,
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

    private func encodePacketEnvelope<Payload: Sendable>(
        action: NodeMessageDispatchEnvelope.Action,
        packetType: IMTCPPacketType,
        requestID: UUID?,
        payload: Payload,
        targetUserIDs: [UUID]
    ) throws -> NodeMessageDispatchEnvelope {
        let data = try IMTCPProtobufCodec.encode(type: packetType, requestID: requestID, payload: payload)
        return NodeMessageDispatchEnvelope(
            action: action,
            packetType: packetType,
            requestID: requestID,
            packetBase64: data.base64EncodedString(),
            targetUserIDs: targetUserIDs,
            sessionID: nil,
            kickReason: nil,
            kickMessage: nil
        )
    }

    private func decodePayload<Payload: Sendable>(from envelope: NodeMessageDispatchEnvelope) -> Payload? {
        guard let packetBase64 = envelope.packetBase64,
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
