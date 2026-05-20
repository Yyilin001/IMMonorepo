import Foundation
import IMClientKit

@MainActor
extension ConversationRuntimeController {
    func scheduleConnectionIfNeeded() {
        guard isSignedInProvider() else {
            return
        }

        guard imConnection == nil, imConnectionConnectTask == nil else {
            return
        }

        imConnectionReconnectTask?.cancel()
        imConnectionReconnectTask = nil

        let generation = imConnectionGeneration
        setConnectionStatus(.connecting)
        imConnectionConnectTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let connection = try await self.openIMConnection()
                await self.applyIMConnection(connection, generation: generation)
            } catch {
                await self.handleIMConnectionFailure(error, generation: generation)
            }
        }
    }

    func reconnectConnection() async {
        guard isSignedInProvider() else {
            return
        }

        await disconnect(flushCache: true)
        scheduleConnectionIfNeeded()
    }

    func disconnect(flushCache: Bool = true) async {
        imConnectionGeneration &+= 1
        cancelConversationGapSyncBackfill()
        cancelQueuedTextMessageFlush()
        cancelMessageStreamSnapshotSync()

        let connection = imConnection
        imConnection = nil

        let connectTask = imConnectionConnectTask
        imConnectionConnectTask = nil
        connectTask?.cancel()

        let eventTask = imConnectionEventTask
        imConnectionEventTask = nil
        eventTask?.cancel()

        let reconnectTask = imConnectionReconnectTask
        imConnectionReconnectTask = nil
        reconnectTask?.cancel()
        imConnectionReconnectAttempt = 0

        if let connection {
            await connection.disconnect()
        }

        setConnectionStatus(.disconnected)

        if flushCache {
            await flushConversationCache()
            await flushContactStateCache()
        }
    }

    func resetForSignedOut(flushCache: Bool) async {
        imConversationMembersTask?.cancel()
        imConversationMembersTask = nil
        imConversationMessagesTask?.cancel()
        imConversationMessagesTask = nil
        imConversationRefreshTask?.cancel()
        imConversationRefreshTask = nil
        cancelMessageStreamSnapshotSync()
        for task in mediaUploadRecoveryTasks.values {
            task.cancel()
        }
        mediaUploadRecoveryTasks = [:]
        for task in imConversationReadReportTasks.values {
            task.cancel()
        }
        imConversationReadReportTasks = [:]
        pendingIMConversationReadSequences = [:]
        await disconnect(flushCache: flushCache)
    }

    func appDidBecomeActive() {
        scheduleConnectionIfNeeded()
        syncActiveMessageStreamSnapshots()
    }

    func applyIMConnection(_ connection: IMTCPConnection, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            await connection.disconnect()
            return
        }

        guard isSignedInProvider() else {
            await connection.disconnect()
            return
        }

        imConnectionConnectTask = nil
        imConnection = connection
        imConnectionReconnectTask?.cancel()
        imConnectionReconnectTask = nil
        imConnectionReconnectAttempt = 0
        setConnectionStatus(.connected)
        startIMConnectionEventLoop(connection, generation: generation)
        await syncConversationGapsAfterConnection()
        await syncContactStateAfterConnection()
        await flushQueuedTextMessagesAfterConnection(limit: HistoryConfig.queuedFlushLimit)
        startConversationGapSyncBackfillIfNeeded()
        syncActiveMessageStreamSnapshots()
        scheduleConversationCachePersist()
    }

    func startIMConnectionEventLoop(_ connection: IMTCPConnection, generation: UInt64) {
        imConnectionEventTask?.cancel()
        imConnectionEventTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await event in connection.events {
                    await self.handleIMConnectionEvent(event, generation: generation)
                }

                await self.handleIMConnectionFailure(
                    IMTCPClientError.connectionClosed,
                    generation: generation
                )
            } catch {
                await self.handleIMConnectionFailure(error, generation: generation)
            }
        }
    }

    func handleIMConnectionEvent(_ event: IMTCPConnectionEvent, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            return
        }

        switch event {
        case .heartbeatAck:
            return
        case .ack(let requestID, let payload):
            imConversationStore.applyOutgoingAcknowledgement(requestID: requestID, payload: payload)
            if let conversationID = payload.conversationID,
               conversationID == imConversationStore.selectedConversationID {
                await loadReceiptSummary(for: conversationID)
            }
            scheduleConversationCachePersist()
        case .message(let requestID, let payload):
            guard let currentUserID = currentUserProvider()?.id else {
                return
            }

            imConversationStore.receiveIncomingMessage(payload, currentUserID: currentUserID)
            scheduleConversationCachePersist()

            if let messageID = payload.messageID, let connection = imConnection {
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
                    await handleIMConnectionFailure(error, generation: generation)
                    return
                }
            }

            guard payload.senderUserID != currentUserID,
                  payload.conversationID == imConversationStore.selectedConversationID,
                  let readSequence = payload.serverSequence
            else {
                return
            }

            await markConversationReadInternal(
                conversationID: payload.conversationID,
                readSequence: readSequence
            )
        case .conversationEvent(_, let payload):
            guard let currentUserID = currentUserProvider()?.id else {
                return
            }

            let outcome = imConversationStore.applyConversationEvent(payload, currentUserID: currentUserID)
            if let conversationID = outcome.shouldReloadMembersForConversationID,
               imConversationStore.conversations.contains(where: { $0.id == conversationID }) {
                await loadConversationMembers(for: conversationID)
            }
            if payload.conversation.id.uuidString == imConversationStore.selectedConversationID {
                await loadReceiptSummary(for: payload.conversation.id.uuidString)
            }
            syncPendingMessageStreamSnapshotsIfNeeded()
            scheduleConversationCachePersist()
        case .contactEvent(_, let payload):
            applyContactEvent(payload)
        case .kick(let payload):
            await clearSession(payload.message)
        }
    }

    func handleIMConnectionFailure(_ error: Error, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            return
        }

        cancelConversationGapSyncBackfill()
        cancelQueuedTextMessageFlush()
        for task in mediaUploadRecoveryTasks.values {
            task.cancel()
        }
        mediaUploadRecoveryTasks = [:]
        imConnectionConnectTask = nil
        imConnectionEventTask = nil
        imConnection = nil

        if error is CancellationError {
            setConnectionStatus(.disconnected)
            return
        }

        if let tcpError = error as? IMTCPClientError {
            switch tcpError {
            case .authRejected(_, let message):
                await clearSession(message)
            case .kicked(_, let message):
                await clearSession(message)
            case .connectionClosed:
                imConversationStore.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")
                setConnectionStatus(.failed(message: reconnectingStatusMessage("IM 连接已断开。")))
                scheduleConversationCachePersist()
                scheduleIMConnectionReconnectIfNeeded(generation: generation)
            default:
                imConversationStore.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")
                setConnectionStatus(.failed(message: reconnectingStatusMessage(tcpError.localizedDescription)))
                scheduleConversationCachePersist()
                scheduleIMConnectionReconnectIfNeeded(generation: generation)
            }
            return
        }

        imConversationStore.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")
        setConnectionStatus(.failed(message: reconnectingStatusMessage(error.localizedDescription)))
        scheduleConversationCachePersist()
        scheduleIMConnectionReconnectIfNeeded(generation: generation)
    }

    func scheduleIMConnectionReconnectIfNeeded(generation: UInt64) {
        guard isSignedInProvider(),
              generation == imConnectionGeneration,
              imConnection == nil,
              imConnectionConnectTask == nil,
              imConnectionReconnectTask == nil
        else {
            return
        }

        let delay = nextReconnectDelayNanoseconds()
        imConnectionReconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            self?.startScheduledIMReconnect(generation: generation)
        }
    }

    func startScheduledIMReconnect(generation: UInt64) {
        guard generation == imConnectionGeneration,
              isSignedInProvider(),
              imConnection == nil
        else {
            imConnectionReconnectTask = nil
            return
        }

        imConnectionReconnectTask = nil
        scheduleConnectionIfNeeded()
    }

    func nextReconnectDelayNanoseconds() -> UInt64 {
        imConnectionReconnectAttempt += 1
        let shift = min(imConnectionReconnectAttempt - 1, 5)
        let multiplier = UInt64(1 << shift)
        return min(
            HistoryConfig.reconnectInitialDelayNanoseconds * multiplier,
            HistoryConfig.reconnectMaxDelayNanoseconds
        )
    }

    func reconnectingStatusMessage(_ message: String) -> String {
        "\(message) 正在自动重连。"
    }
}
