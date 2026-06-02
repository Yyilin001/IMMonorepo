import Foundation
import IMClientKit
import OSLog

@MainActor
final class IMConnectionCoordinator {
    private weak var runtime: ConversationRuntimeController?
    private(set) var connection: IMTCPConnection?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private(set) var generation: UInt64 = 0
    private var reconnectAttempt = 0

    init(runtime: ConversationRuntimeController) {
        self.runtime = runtime
    }

    func scheduleIfNeeded() {
        guard let runtime,
              runtime.isSignedInProvider()
        else {
            return
        }

        guard connection == nil, connectTask == nil else {
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil

        let targetGeneration = generation
        runtime.setConnectionStatus(.connecting)
        connectTask = Task { [weak self] in
            guard let self, let runtime = self.runtime else {
                return
            }

            do {
                let connection = try await runtime.openIMConnection()
                await self.applyConnection(connection, generation: targetGeneration)
            } catch {
                await self.handleFailure(error, generation: targetGeneration)
            }
        }
    }

    func reconnect() async {
        guard runtime?.isSignedInProvider() == true else {
            return
        }

        await disconnect(flushCache: true)
        scheduleIfNeeded()
    }

    func disconnect(flushCache: Bool = true) async {
        generation &+= 1
        runtime?.cancelConversationGapSyncCatchUp()
        runtime?.cancelQueuedTextMessageFlush()
        runtime?.cancelMessageStreamSnapshotSync()

        let currentConnection = connection
        connection = nil

        let currentConnectTask = connectTask
        connectTask = nil
        currentConnectTask?.cancel()

        let currentEventTask = eventTask
        eventTask = nil
        currentEventTask?.cancel()

        let currentHeartbeatTask = heartbeatTask
        heartbeatTask = nil
        currentHeartbeatTask?.cancel()

        let currentReconnectTask = reconnectTask
        reconnectTask = nil
        currentReconnectTask?.cancel()
        reconnectAttempt = 0

        if let currentConnection {
            await currentConnection.disconnect()
        }

        runtime?.setConnectionStatus(.disconnected)

        if flushCache, let runtime {
            await runtime.flushConversationCache()
            await runtime.flushContactStateCache()
        }
    }

    func resetForSignedOut(flushCache: Bool) async {
        guard let runtime else {
            return
        }

        runtime.imConversationMembersTask?.cancel()
        runtime.imConversationMembersTask = nil
        runtime.imConversationMessagesTask?.cancel()
        runtime.imConversationMessagesTask = nil
        runtime.imConversationRefreshTask?.cancel()
        runtime.imConversationRefreshTask = nil
        runtime.cancelMessageStreamSnapshotSync()
        for task in runtime.mediaUploadRecoveryTasks.values {
            task.cancel()
        }
        runtime.mediaUploadRecoveryTasks = [:]
        runtime.cancelConversationReadReports()
        await disconnect(flushCache: flushCache)
    }

    func appDidBecomeActive() {
        scheduleIfNeeded()
        runtime?.syncActiveMessageStreamSnapshots()
    }

    func handleFailure(_ error: Error, generation targetGeneration: UInt64) async {
        guard let runtime,
              targetGeneration == generation
        else {
            return
        }

        runtime.cancelConversationGapSyncCatchUp()
        runtime.cancelQueuedTextMessageFlush()
        for task in runtime.mediaUploadRecoveryTasks.values {
            task.cancel()
        }
        runtime.mediaUploadRecoveryTasks = [:]
        connectTask = nil
        eventTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connection = nil

        if error is CancellationError {
            runtime.setConnectionStatus(.disconnected)
            return
        }

        if let tcpError = error as? IMTCPClientError {
            switch tcpError {
            case .authRejected(_, let message):
                await runtime.clearSession(message)
            case .kicked(let reason, let message):
                if isSessionInvalidatingKick(reason) {
                    await runtime.clearSession(message)
                } else {
                    markPendingMessagesUnknownAndReconnect(
                        message: message,
                        generation: targetGeneration
                    )
                }
            case .connectionClosed:
                markPendingMessagesUnknownAndReconnect(
                    message: "IM 连接已断开。",
                    generation: targetGeneration
                )
            default:
                markPendingMessagesUnknownAndReconnect(
                    message: tcpError.localizedDescription,
                    generation: targetGeneration
                )
            }
            return
        }

        markPendingMessagesUnknownAndReconnect(
            message: error.localizedDescription,
            generation: targetGeneration
        )
    }

    private func applyConnection(_ newConnection: IMTCPConnection, generation targetGeneration: UInt64) async {
        guard let runtime else {
            await newConnection.disconnect()
            return
        }

        guard targetGeneration == generation else {
            await newConnection.disconnect()
            return
        }

        guard runtime.isSignedInProvider() else {
            await newConnection.disconnect()
            return
        }

        connectTask = nil
        connection = newConnection
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        runtime.setConnectionStatus(.connected)
        startEventLoop(newConnection, generation: targetGeneration)
        startHeartbeatLoop(newConnection, generation: targetGeneration)
        await runtime.syncDomainEventsAfterConnection()
        await runtime.syncConversationGapsAfterConnection()
        await runtime.syncContactStateAfterConnection()
        await runtime.flushQueuedTextMessagesAfterConnection(limit: ConversationRuntimeController.HistoryConfig.queuedFlushLimit)
        runtime.startConversationGapSyncCatchUpIfNeeded()
        runtime.syncActiveMessageStreamSnapshots()
        runtime.scheduleConversationCachePersist()
    }

    private func startEventLoop(_ connection: IMTCPConnection, generation targetGeneration: UInt64) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await event in connection.events {
                    await self.handleEvent(event, generation: targetGeneration)
                }

                await self.handleFailure(
                    IMTCPClientError.connectionClosed,
                    generation: targetGeneration
                )
            } catch {
                await self.handleFailure(error, generation: targetGeneration)
            }
        }
    }

    private func startHeartbeatLoop(_ connection: IMTCPConnection, generation targetGeneration: UInt64) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            let intervalSeconds = max(connection.authentication.heartbeatIntervalSeconds, 1)
            let intervalNanoseconds = UInt64(intervalSeconds) * 1_000_000_000
            var sequence = 0

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                    try Task.checkCancellation()
                    sequence &+= 1
                    try await connection.sendHeartbeat(sequence: sequence)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.handleFailure(error, generation: targetGeneration)
                    return
                }
            }
        }
    }

    private func handleEvent(_ event: IMTCPConnectionEvent, generation targetGeneration: UInt64) async {
        guard let runtime,
              targetGeneration == generation
        else {
            return
        }

        switch event {
        case .heartbeatAck:
            return
        case .ack(let requestID, let payload):
            IMAppLog.imRuntime.debug(
                "TCP ACK event requestID=\(requestID?.uuidString ?? "nil", privacy: .public) status=\(payload.status, privacy: .public) messageID=\(payload.messageID, privacy: .public) conversationID=\(payload.conversationID ?? "nil", privacy: .public) generation=\(targetGeneration, privacy: .public)"
            )
            runtime.imConversationStore.applyOutgoingAcknowledgement(requestID: requestID, payload: payload)
            if payload.status == "accepted",
               let conversationID = payload.conversationID {
                let selectedConversationID = runtime.imConversationStore.selectedConversationID ?? "nil"
                IMAppLog.imRuntime.debug(
                    "ACK accepted scheduling conversation gap catch-up conversationID=\(conversationID, privacy: .public) serverMessageID=\(payload.messageID, privacy: .public) selectedConversationID=\(selectedConversationID, privacy: .public)"
                )
                runtime.enqueueConversationGapSyncCatchUp(
                    for: conversationID,
                    prioritize: conversationID == runtime.imConversationStore.selectedConversationID
                )
            }
            if let conversationID = payload.conversationID,
               conversationID == runtime.imConversationStore.selectedConversationID {
                await runtime.loadReceiptSummary(for: conversationID)
            }
            runtime.scheduleConversationCachePersist()
        case .domainEvent(let requestID, let payload):
            guard let currentUserID = runtime.currentUserProvider()?.id else {
                return
            }

            if case .contactChanged = payload.body {
                runtime.applyContactDomainEvent(payload)
                _ = runtime.imConversationStore.applyDomainEvent(payload, currentUserID: currentUserID)
                return
            }

            let outcome = runtime.imConversationStore.applyDomainEvent(payload, currentUserID: currentUserID)
            IMAppLog.imRuntime.debug(
                "TCP domain event applied eventType=\(payload.eventType.rawValue, privacy: .public) aggregateID=\(payload.aggregateID.uuidString, privacy: .public) shouldFetchDomainEvents=\(outcome.shouldFetchDomainEvents, privacy: .public) didConsumeEvent=\(outcome.didConsumeEvent, privacy: .public)"
            )
            if case .messageCreated(let message, _) = payload.body,
               outcome.shouldFetchDomainEvents || !outcome.didConsumeEvent {
                let conversationID = message.conversationID.uuidString
                IMAppLog.imRuntime.debug(
                    "Message created event deferred; scheduling timeline catch-up conversationID=\(conversationID, privacy: .public) messageID=\(message.id.uuidString, privacy: .public) didConsumeEvent=\(outcome.didConsumeEvent, privacy: .public)"
                )
                runtime.enqueueConversationGapSyncCatchUp(
                    for: conversationID,
                    prioritize: conversationID == runtime.imConversationStore.selectedConversationID
                )
                runtime.scheduleConversationSummaryReadModelCorrection(force: true)
            }
            if outcome.shouldFetchDomainEvents {
                await runtime.syncDomainEventsAfterConnection()
            }
            if let conversationID = outcome.shouldReloadMembersForConversationID,
               runtime.imConversationStore.conversations.contains(where: { $0.id == conversationID }) {
                await runtime.loadConversationMembers(for: conversationID)
            }
            if payload.aggregateID.uuidString == runtime.imConversationStore.selectedConversationID {
                await runtime.loadReceiptSummary(for: payload.aggregateID.uuidString)
            }
            runtime.syncPendingMessageStreamSnapshotsIfNeeded()
            runtime.scheduleConversationCachePersist()

            if case .messageCreated(let message, _) = payload.body,
               message.senderUserID != currentUserID,
               message.conversationID.uuidString == runtime.imConversationStore.selectedConversationID,
               let connection {
                IMAppLog.imRuntime.debug(
                    "TCP domain messageCreated incoming selected conversationID=\(message.conversationID.uuidString, privacy: .public) messageID=\(message.id.uuidString, privacy: .public) serverSequence=\(message.serverSequence, privacy: .public)"
                )
                do {
                    try await connection.sendAcknowledgement(
                        IMTCPAckPayload(
                            messageID: message.id.uuidString,
                            conversationID: message.conversationID.uuidString,
                            status: "received"
                        ),
                        requestID: requestID
                    )
                    await runtime.markConversationReadInternal(
                        conversationID: message.conversationID.uuidString,
                        readSequence: UInt64(message.serverSequence)
                    )
                } catch {
                    await handleFailure(error, generation: targetGeneration)
                }
            }
        case .streamSignal(_, let payload):
            guard let currentUserID = runtime.currentUserProvider()?.id else {
                return
            }
            runtime.imConversationStore.applyStreamSignal(payload, currentUserID: currentUserID)
            runtime.syncPendingMessageStreamSnapshotsIfNeeded()
            runtime.scheduleConversationCachePersist()
        case .kick(let payload):
            if isSessionInvalidatingKick(payload.reason) {
                await runtime.clearSession(payload.message)
            } else {
                await handleFailure(
                    IMTCPClientError.kicked(reason: payload.reason, message: payload.message),
                    generation: targetGeneration
                )
            }
        }
    }

    private func isSessionInvalidatingKick(_ reason: IMTCPKickReason) -> Bool {
        switch reason {
        case .sessionRevoked, .logoutCurrent, .logoutAll:
            return true
        case .duplicateConnection, .serverShutdown, .protocolError:
            return false
        }
    }

    private func markPendingMessagesUnknownAndReconnect(message: String, generation targetGeneration: UInt64) {
        guard let runtime else {
            return
        }

        runtime.imConversationStore.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")
        runtime.setConnectionStatus(.failed(message: reconnectingStatusMessage(message)))
        runtime.scheduleConversationCachePersist()
        scheduleReconnectIfNeeded(generation: targetGeneration)
    }

    private func scheduleReconnectIfNeeded(generation targetGeneration: UInt64) {
        guard let runtime,
              runtime.isSignedInProvider(),
              targetGeneration == generation,
              connection == nil,
              connectTask == nil,
              reconnectTask == nil
        else {
            return
        }

        let delay = nextReconnectDelayNanoseconds()
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            self?.startScheduledReconnect(generation: targetGeneration)
        }
    }

    private func startScheduledReconnect(generation targetGeneration: UInt64) {
        guard let runtime,
              targetGeneration == generation,
              runtime.isSignedInProvider(),
              connection == nil
        else {
            reconnectTask = nil
            return
        }

        reconnectTask = nil
        scheduleIfNeeded()
    }

    private func nextReconnectDelayNanoseconds() -> UInt64 {
        reconnectAttempt += 1
        let shift = min(reconnectAttempt - 1, 5)
        let multiplier = UInt64(1 << shift)
        return min(
            ConversationRuntimeController.HistoryConfig.reconnectInitialDelayNanoseconds * multiplier,
            ConversationRuntimeController.HistoryConfig.reconnectMaxDelayNanoseconds
        )
    }

    private func reconnectingStatusMessage(_ message: String) -> String {
        "\(message) 正在自动重连。"
    }

}

@MainActor
extension ConversationRuntimeController {
    func scheduleConnectionIfNeeded() {
        connectionCoordinator.scheduleIfNeeded()
    }

    func reconnectConnection() async {
        await connectionCoordinator.reconnect()
    }

    func disconnect(flushCache: Bool = true) async {
        await connectionCoordinator.disconnect(flushCache: flushCache)
    }

    func resetForSignedOut(flushCache: Bool) async {
        await connectionCoordinator.resetForSignedOut(flushCache: flushCache)
    }

    func appDidBecomeActive() {
        connectionCoordinator.appDidBecomeActive()
    }

    func handleIMConnectionFailure(_ error: Error, generation: UInt64) async {
        await connectionCoordinator.handleFailure(error, generation: generation)
    }
}
