import Foundation
import IMClientKit

@MainActor
final class IMConnectionCoordinator {
    private weak var runtime: ConversationRuntimeController?
    private(set) var connection: IMTCPConnection?
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
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
        runtime?.cancelConversationGapSyncBackfill()
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

        runtime.cancelConversationGapSyncBackfill()
        runtime.cancelQueuedTextMessageFlush()
        for task in runtime.mediaUploadRecoveryTasks.values {
            task.cancel()
        }
        runtime.mediaUploadRecoveryTasks = [:]
        connectTask = nil
        eventTask = nil
        connection = nil

        if error is CancellationError {
            runtime.setConnectionStatus(.disconnected)
            return
        }

        if let tcpError = error as? IMTCPClientError {
            switch tcpError {
            case .authRejected(_, let message):
                await runtime.clearSession(message)
            case .kicked(_, let message):
                await runtime.clearSession(message)
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
        await runtime.syncConversationGapsAfterConnection()
        await runtime.syncContactStateAfterConnection()
        await runtime.flushQueuedTextMessagesAfterConnection(limit: ConversationRuntimeController.HistoryConfig.queuedFlushLimit)
        runtime.startConversationGapSyncBackfillIfNeeded()
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
            runtime.imConversationStore.applyOutgoingAcknowledgement(requestID: requestID, payload: payload)
            if let conversationID = payload.conversationID,
               conversationID == runtime.imConversationStore.selectedConversationID {
                await runtime.loadReceiptSummary(for: conversationID)
            }
            runtime.scheduleConversationCachePersist()
        case .message(let requestID, let payload):
            guard let currentUserID = runtime.currentUserProvider()?.id else {
                return
            }

            runtime.imConversationStore.receiveIncomingMessage(payload, currentUserID: currentUserID)
            runtime.scheduleConversationCachePersist()

            if let messageID = payload.messageID, let connection {
                do {
                    try await connection.sendAcknowledgement(
                        IMTCPAckPayload(
                            messageID: messageID,
                            conversationID: payload.conversationID,
                            status: "received"
                        ),
                        requestID: requestID
                    )
                } catch {
                    await handleFailure(error, generation: targetGeneration)
                    return
                }
            }

            guard payload.senderUserID != currentUserID,
                  payload.conversationID == runtime.imConversationStore.selectedConversationID,
                  let readSequence = payload.serverSequence
            else {
                return
            }

            await runtime.markConversationReadInternal(
                conversationID: payload.conversationID,
                readSequence: readSequence
            )
        case .conversationEvent(_, let payload):
            guard let currentUserID = runtime.currentUserProvider()?.id else {
                return
            }

            let outcome = runtime.imConversationStore.applyConversationEvent(payload, currentUserID: currentUserID)
            if let conversationID = outcome.shouldReloadMembersForConversationID,
               runtime.imConversationStore.conversations.contains(where: { $0.id == conversationID }) {
                await runtime.loadConversationMembers(for: conversationID)
            }
            if payload.conversation.id.uuidString == runtime.imConversationStore.selectedConversationID {
                await runtime.loadReceiptSummary(for: payload.conversation.id.uuidString)
            }
            runtime.syncPendingMessageStreamSnapshotsIfNeeded()
            runtime.scheduleConversationCachePersist()
        case .contactEvent(_, let payload):
            runtime.applyContactEvent(payload)
        case .kick(let payload):
            await runtime.clearSession(payload.message)
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
