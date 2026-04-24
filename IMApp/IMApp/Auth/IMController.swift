import Foundation
import IMClientKit

@MainActor
final class IMController {
    private enum HistoryConfig {
        static let latestHistoryLimit = 40
        static let gapSyncLimit = 100
        static let gapSyncMaxIterations = 10
        static let queuedFlushLimit = 20
        static let readReportDebounceNanoseconds: UInt64 = 250_000_000
        static let summaryRefreshDebounceNanoseconds: UInt64 = 400_000_000
        static let minimumSummaryRefreshInterval: TimeInterval = 5
        static let summaryPageLimit = 50
    }

    private enum ConversationGapSyncResult {
        case completed
        case incomplete
        case failed
    }

    private enum QueuedTextMessageFlushBatchResult {
        case drained
        case hasMore
        case failed
    }

    private let sessionClient: SessionClient
    private let openIMConnection: @Sendable () async throws -> IMTCPConnection
    private let imConversationStore: IMConversationStore
    private let currentUserProvider: () -> AuthUser?
    private let isSignedInProvider: () -> Bool
    private let latestConversationSummariesProvider: () -> [IMConversationSummaryResponseBody]
    private let setLatestConversationSummaries: ([IMConversationSummaryResponseBody]) -> Void
    private let conversationSummaryRefreshAtProvider: () -> Date?
    private let setConversationSummaryRefreshAt: (Date?) -> Void
    private let conversationSummarySyncTokenProvider: () -> String?
    private let setConversationSummarySyncToken: (String?) -> Void
    private let markServerOnline: () -> Void
    private let clearSession: (String?) async -> Void
    private let handleIMDataRequestError: (Error) async -> Void
    private let syncContactStateAfterConnection: () async -> Void
    private let scheduleConversationCachePersist: () -> Void
    private let flushConversationCache: () async -> Void
    private let flushContactStateCache: () async -> Void
    private let applyContactEvent: (IMTCPContactEventPayload) -> Void
    private let setConnectionStatus: (AuthManager.IMConnectionStatus) -> Void
    private let setQueuedFlushActive: (Bool) -> Void

    private var imConnection: IMTCPConnection?
    private var imConnectionConnectTask: Task<Void, Never>?
    private var imConnectionEventTask: Task<Void, Never>?
    private var imConnectionGeneration: UInt64 = 0
    private var imConversationGapSyncBackfillTask: Task<Void, Never>?
    private var queuedIMTextMessageFlushTask: Task<Void, Never>?
    private var imConversationReadReportTasks: [String: Task<Void, Never>] = [:]
    private var pendingIMConversationReadSequences: [String: UInt64] = [:]
    private var imConversationGapSyncQueue: [String] = []
    private var imConversationGapSyncActiveConversationID: String?
    private var imConversationMembersTask: Task<Void, Never>?
    private var imConversationMessagesTask: Task<Void, Never>?
    private var imConversationRefreshTask: Task<Void, Never>?

    private enum HistoryMergeMode {
        case replace
        case prepend
    }

    init(
        sessionClient: SessionClient,
        openIMConnection: @escaping @Sendable () async throws -> IMTCPConnection,
        imConversationStore: IMConversationStore,
        currentUserProvider: @escaping () -> AuthUser?,
        isSignedInProvider: @escaping () -> Bool,
        latestConversationSummariesProvider: @escaping () -> [IMConversationSummaryResponseBody],
        setLatestConversationSummaries: @escaping ([IMConversationSummaryResponseBody]) -> Void,
        conversationSummaryRefreshAtProvider: @escaping () -> Date?,
        setConversationSummaryRefreshAt: @escaping (Date?) -> Void,
        conversationSummarySyncTokenProvider: @escaping () -> String?,
        setConversationSummarySyncToken: @escaping (String?) -> Void,
        markServerOnline: @escaping () -> Void,
        clearSession: @escaping (String?) async -> Void,
        handleIMDataRequestError: @escaping (Error) async -> Void,
        syncContactStateAfterConnection: @escaping () async -> Void,
        scheduleConversationCachePersist: @escaping () -> Void,
        flushConversationCache: @escaping () async -> Void,
        flushContactStateCache: @escaping () async -> Void,
        applyContactEvent: @escaping (IMTCPContactEventPayload) -> Void,
        setConnectionStatus: @escaping (AuthManager.IMConnectionStatus) -> Void,
        setQueuedFlushActive: @escaping (Bool) -> Void
    ) {
        self.sessionClient = sessionClient
        self.openIMConnection = openIMConnection
        self.imConversationStore = imConversationStore
        self.currentUserProvider = currentUserProvider
        self.isSignedInProvider = isSignedInProvider
        self.latestConversationSummariesProvider = latestConversationSummariesProvider
        self.setLatestConversationSummaries = setLatestConversationSummaries
        self.conversationSummaryRefreshAtProvider = conversationSummaryRefreshAtProvider
        self.setConversationSummaryRefreshAt = setConversationSummaryRefreshAt
        self.conversationSummarySyncTokenProvider = conversationSummarySyncTokenProvider
        self.setConversationSummarySyncToken = setConversationSummarySyncToken
        self.markServerOnline = markServerOnline
        self.clearSession = clearSession
        self.handleIMDataRequestError = handleIMDataRequestError
        self.syncContactStateAfterConnection = syncContactStateAfterConnection
        self.scheduleConversationCachePersist = scheduleConversationCachePersist
        self.flushConversationCache = flushConversationCache
        self.flushContactStateCache = flushContactStateCache
        self.applyContactEvent = applyContactEvent
        self.setConnectionStatus = setConnectionStatus
        self.setQueuedFlushActive = setQueuedFlushActive
    }

    func scheduleConnectionIfNeeded() {
        guard isSignedInProvider() else {
            return
        }

        guard imConnection == nil, imConnectionConnectTask == nil else {
            return
        }

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

        let connection = imConnection
        imConnection = nil

        let connectTask = imConnectionConnectTask
        imConnectionConnectTask = nil
        connectTask?.cancel()

        let eventTask = imConnectionEventTask
        imConnectionEventTask = nil
        eventTask?.cancel()

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
        for task in imConversationReadReportTasks.values {
            task.cancel()
        }
        imConversationReadReportTasks = [:]
        pendingIMConversationReadSequences = [:]
        await disconnect(flushCache: flushCache)
    }

    func appDidBecomeActive() {
        scheduleConnectionIfNeeded()
    }

    func sendText(_ text: String, to conversationID: String) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        guard let connection = imConnection else {
            let didQueue = imConversationStore.queueOutgoingText(
                text,
                conversationID: conversationID,
                senderUserID: user.id
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        }

        guard let request = imConversationStore.prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: user.id
        ) else {
            return false
        }
        scheduleConversationCachePersist()

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            return true
        } catch {
            await handleIMConnectionFailure(error, generation: generation)
            return false
        }
    }

    func sendReply(
        reference: IMReplyReference,
        text: String,
        to conversationID: String
    ) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        guard let connection = imConnection else {
            let didQueue = imConversationStore.queueOutgoingReply(
                reference: reference,
                text: text,
                conversationID: conversationID,
                senderUserID: user.id
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        }

        guard let request = imConversationStore.prepareOutgoingReply(
            reference: reference,
            text: text,
            conversationID: conversationID,
            senderUserID: user.id
        ) else {
            return false
        }
        scheduleConversationCachePersist()

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            return true
        } catch {
            await handleIMConnectionFailure(error, generation: generation)
            return false
        }
    }

    func recallMessage(messageID: String, in conversationID: String) async -> Bool {
        guard let currentUserID = currentUserProvider()?.id else {
            return false
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            return false
        }

        do {
            let response = try await sessionClient.recallIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID
            )
            markServerOnline()
            imConversationStore.applyRecalledMessage(response, currentUserID: currentUserID)
            _ = await reconcileConversationSummaryReadModel(force: true)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func retryTextMessage(localMessageID: String, in conversationID: String) async -> Bool {
        guard currentUserProvider() != nil else {
            return false
        }

        guard let connection = imConnection else {
            let didQueue = imConversationStore.queueRetryableOutgoingMessage(
                localMessageID: localMessageID,
                conversationID: conversationID
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        }

        guard let request = imConversationStore.retryOutgoingMessage(
            localMessageID: localMessageID,
            conversationID: conversationID
        ) else {
            scheduleConversationCachePersist()
            return false
        }
        scheduleConversationCachePersist()

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            return true
        } catch {
            await handleIMConnectionFailure(error, generation: generation)
            return false
        }
    }

    func syncConversationAfterOpen(_ conversationID: String) async {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        switch await syncConversationGap(for: conversationID, currentUserID: currentUserID) {
        case .completed:
            await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
        case .incomplete:
            enqueueConversationGapSyncBackfill(for: conversationID, prioritize: true)
            await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
        case .failed:
            return
        }
    }

    func reloadConversations(force: Bool = true) async {
        guard let user = currentUserProvider() else {
            return
        }

        let didRefresh = await reconcileConversationSummaryReadModel(force: force)
        guard didRefresh,
              currentUserProvider()?.id == user.id,
              let selectedConversationID = imConversationStore.selectedConversationID ?? imConversationStore.conversations.first?.id
        else {
            return
        }

        imConversationStore.openConversation(id: selectedConversationID)
        scheduleConversationCachePersist()
        await loadConversationMembers(for: selectedConversationID)
        await loadMessagesIfNeeded(for: selectedConversationID)
        await markConversationReadUpToLatestLoadedSequence(for: selectedConversationID)
    }

    func loadMoreConversationSummariesIfNeeded(anchorConversationID: String?) async {
        guard let user = currentUserProvider(),
              imConversationStore.hasMoreConversationSummaries,
              !imConversationStore.isLoadingConversations,
              !imConversationStore.isLoadingMoreConversationSummaries,
              let nextCursor = imConversationStore.conversationSummaryNextCursor,
              let anchorConversationID,
              anchorConversationID == imConversationStore.conversationSummaryPaginationAnchorID
        else {
            return
        }

        imConversationStore.setLoadingMoreConversationSummaries(true)
        defer {
            imConversationStore.setLoadingMoreConversationSummaries(false)
        }

        do {
            let response = try await sessionClient.fetchIMConversationSummaries(
                cursor: nextCursor,
                limit: HistoryConfig.summaryPageLimit
            )
            guard currentUserProvider()?.id == user.id else {
                return
            }

            markServerOnline()
            imConversationStore.appendConversationSummaryWindow(
                response.items,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore
            )
            setLatestConversationSummaries(latestConversationSummariesProvider() + response.items)
            scheduleConversationCachePersist()
        } catch {
            await handleIMDataRequestError(error)
        }
    }

    func loadConversationMembers(for conversationID: String) async {
        guard let user = currentUserProvider() else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        imConversationMembersTask?.cancel()
        imConversationMembersTask = Task { [weak self] in
            guard let self else {
                return
            }

            self.imConversationStore.setLoadingMembers(true)
            defer {
                self.imConversationStore.setLoadingMembers(false)
                self.imConversationMembersTask = nil
            }

            do {
                let members = try await self.sessionClient.fetchIMConversationMembers(
                    conversationID: trimmedConversationID
                )
                guard self.currentUserProvider()?.id == user.id else {
                    return
                }

                self.markServerOnline()
                self.imConversationStore.replaceMembers(
                    in: trimmedConversationID,
                    members: members
                )
                self.scheduleConversationCachePersist()
            } catch {
                await self.handleIMDataRequestError(error)
            }
        }

        await imConversationMembersTask?.value
    }

    func loadMessagesIfNeeded(for conversationID: String, forceReload: Bool = false) async {
        guard let user = currentUserProvider() else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        guard forceReload || !imConversationStore.hasLoadedMessages(for: trimmedConversationID) else {
            return
        }

        await loadMessagesPage(
            for: trimmedConversationID,
            currentUserID: user.id,
            beforeSequence: nil,
            mergeMode: .replace
        )
    }

    func loadOlderMessages() async {
        guard let user = currentUserProvider(),
              let conversationID = imConversationStore.selectedConversationID,
              imConversationStore.canLoadOlderMessages(for: conversationID),
              let beforeSequence = imConversationStore.oldestLoadedServerSequence(for: conversationID)
        else {
            return
        }

        await loadMessagesPage(
            for: conversationID,
            currentUserID: user.id,
            beforeSequence: beforeSequence,
            mergeMode: .prepend
        )
    }

    func refreshConversationSummaryReadModelIfNeeded() async {
        _ = await reconcileConversationSummaryReadModel(force: false)
    }

    func scheduleConversationSummaryReadModelCorrection(force: Bool = false) {
        imConversationRefreshTask?.cancel()
        imConversationRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            if !force {
                try? await Task.sleep(nanoseconds: HistoryConfig.summaryRefreshDebounceNanoseconds)
            }

            guard !Task.isCancelled else {
                return
            }

            _ = await self.reconcileConversationSummaryReadModel(force: force)
            self.imConversationRefreshTask = nil
        }
    }

    func applyConversationSummaryReadModel(_ conversations: [IMConversationSummaryResponseBody]) {
        applyLatestConversationSummaryChanges(
            upserts: conversations,
            removedConversationIDs: []
        )
        imConversationStore.replaceConversationSummaries(conversations)
        imConversationStore.applyServerSummaryReadStates(conversations)
        scheduleConversationCachePersist()
    }

    func applyLatestConversationSummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID]
    ) {
        var summariesByID = Dictionary(
            uniqueKeysWithValues: latestConversationSummariesProvider().map { ($0.id, $0) }
        )

        for summary in upserts {
            summariesByID[summary.id] = summary
        }

        for conversationID in removedConversationIDs {
            summariesByID.removeValue(forKey: conversationID)
        }

        setLatestConversationSummaries(
            summariesByID.values.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }

                return lhs.id.uuidString > rhs.id.uuidString
            }
        )
    }

    func markConversationReadUpToLatestLoadedSequence(for conversationID: String) async {
        guard let readSequence = imConversationStore.latestLoadedServerSequence(for: conversationID) else {
            return
        }

        await markConversationReadInternal(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: 0
        )
    }

    func markConversationRead(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = HistoryConfig.readReportDebounceNanoseconds
    ) async {
        await markConversationReadInternal(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    private func applyIMConnection(_ connection: IMTCPConnection, generation: UInt64) async {
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
        setConnectionStatus(.connected)
        startIMConnectionEventLoop(connection, generation: generation)
        await syncConversationGapsAfterConnection()
        await syncContactStateAfterConnection()
        await flushQueuedTextMessagesAfterConnection(limit: HistoryConfig.queuedFlushLimit)
        startConversationGapSyncBackfillIfNeeded()
        scheduleConversationCachePersist()
    }

    private func startIMConnectionEventLoop(_ connection: IMTCPConnection, generation: UInt64) {
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

    private func handleIMConnectionEvent(_ event: IMTCPConnectionEvent, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            return
        }

        switch event {
        case .heartbeatAck:
            return
        case .ack(let requestID, let payload):
            imConversationStore.applyOutgoingAcknowledgement(requestID: requestID, payload: payload)
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
            scheduleConversationCachePersist()
        case .contactEvent(_, let payload):
            applyContactEvent(payload)
        case .kick(let payload):
            await clearSession(payload.message)
        }
    }

    private func handleIMConnectionFailure(_ error: Error, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            return
        }

        cancelConversationGapSyncBackfill()
        cancelQueuedTextMessageFlush()
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
                setConnectionStatus(.failed(message: "IM 连接已断开。"))
                scheduleConversationCachePersist()
            default:
                imConversationStore.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")
                setConnectionStatus(.failed(message: tcpError.localizedDescription))
                scheduleConversationCachePersist()
            }
            return
        }

        imConversationStore.markAllPendingMessagesUnknown(message: "发送状态未确认，请重试。")
        setConnectionStatus(.failed(message: error.localizedDescription))
        scheduleConversationCachePersist()
    }

    private func syncConversationGap(
        for conversationID: String,
        currentUserID: UUID
    ) async -> ConversationGapSyncResult {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let latestLoadedSequence = imConversationStore.latestLoadedServerSequence(for: trimmedConversationID)
        else {
            return .completed
        }

        do {
            var afterSequence = latestLoadedSequence
            var iterations = 0

            while iterations < HistoryConfig.gapSyncMaxIterations {
                let response = try await sessionClient.fetchIMMessagesSince(
                    conversationID: trimmedConversationID,
                    afterSequence: afterSequence,
                    limit: HistoryConfig.gapSyncLimit
                )
                guard currentUserProvider()?.id == currentUserID else {
                    return .failed
                }

                markServerOnline()
                imConversationStore.appendMessages(
                    in: trimmedConversationID,
                    messages: response.messages,
                    currentUserID: currentUserID
                )
                scheduleConversationCachePersist()

                guard response.hasMore else {
                    return .completed
                }

                guard let nextAfterSequence = response.nextAfterSequence,
                      nextAfterSequence > afterSequence
                else {
                    throw APIError.server(statusCode: 500, message: "IM 增量补洞响应无效。")
                }

                afterSequence = UInt64(nextAfterSequence)
                iterations += 1
            }
            return .incomplete
        } catch is CancellationError {
            return .failed
        } catch {
            await handleIMDataRequestError(error)
            return .failed
        }
    }

    private func syncConversationGapsAfterConnection() async {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        guard await fetchAndApplyConversationSummaries(force: false) else {
            return
        }

        let gapSyncTargets = prioritizedGapSyncTargets(
            imConversationStore.gapSyncTargets(from: latestConversationSummariesProvider())
        )

        for conversationID in gapSyncTargets {
            switch await syncConversationGap(for: conversationID, currentUserID: currentUserID) {
            case .completed:
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .incomplete:
                enqueueConversationGapSyncBackfill(for: conversationID)
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .failed:
                cancelConversationGapSyncBackfill()
                return
            }
        }
    }

    private func prioritizedGapSyncTargets(_ conversationIDs: [String]) -> [String] {
        guard let selectedConversationID = imConversationStore.selectedConversationID,
              conversationIDs.contains(selectedConversationID)
        else {
            return conversationIDs
        }

        return [selectedConversationID] + conversationIDs.filter { $0 != selectedConversationID }
    }

    private func enqueueConversationGapSyncBackfill(
        for conversationID: String,
        prioritize: Bool = false
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        imConversationGapSyncQueue.removeAll { $0 == trimmedConversationID }
        let shouldPrioritize = prioritize || trimmedConversationID == imConversationStore.selectedConversationID
        if shouldPrioritize {
            imConversationGapSyncQueue.insert(trimmedConversationID, at: 0)
        } else {
            imConversationGapSyncQueue.append(trimmedConversationID)
        }

        startConversationGapSyncBackfillIfNeeded()
    }

    private func startConversationGapSyncBackfillIfNeeded() {
        guard let currentUserID = currentUserProvider()?.id,
              imConnection != nil,
              imConversationGapSyncBackfillTask == nil,
              !imConversationGapSyncQueue.isEmpty
        else {
            return
        }

        let generation = imConnectionGeneration
        imConversationGapSyncBackfillTask = Task { [weak self] in
            await self?.runConversationGapSyncBackfillLoop(
                currentUserID: currentUserID,
                generation: generation
            )
        }
    }

    private func runConversationGapSyncBackfillLoop(
        currentUserID: UUID,
        generation: UInt64
    ) async {
        while !Task.isCancelled {
            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil
            else {
                clearConversationGapSyncBackfillState()
                return
            }

            guard let conversationID = dequeueNextConversationGapSyncBackfillConversationID() else {
                imConversationGapSyncBackfillTask = nil
                imConversationGapSyncActiveConversationID = nil
                return
            }

            imConversationGapSyncActiveConversationID = conversationID
            let result = await syncConversationGap(for: conversationID, currentUserID: currentUserID)

            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil,
                  !Task.isCancelled
            else {
                clearConversationGapSyncBackfillState()
                return
            }

            switch result {
            case .completed:
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            case .incomplete:
                await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
                enqueueConversationGapSyncBackfill(for: conversationID)
            case .failed:
                clearConversationGapSyncBackfillState()
                return
            }

            imConversationGapSyncActiveConversationID = nil
            await Task.yield()
        }

        imConversationGapSyncBackfillTask = nil
        imConversationGapSyncActiveConversationID = nil
    }

    private func dequeueNextConversationGapSyncBackfillConversationID() -> String? {
        if let selectedConversationID = imConversationStore.selectedConversationID,
           let selectedIndex = imConversationGapSyncQueue.firstIndex(of: selectedConversationID) {
            return imConversationGapSyncQueue.remove(at: selectedIndex)
        }

        guard !imConversationGapSyncQueue.isEmpty else {
            return nil
        }

        return imConversationGapSyncQueue.removeFirst()
    }

    private func cancelConversationGapSyncBackfill() {
        imConversationGapSyncBackfillTask?.cancel()
        clearConversationGapSyncBackfillState()
    }

    private func clearConversationGapSyncBackfillState() {
        imConversationGapSyncBackfillTask = nil
        imConversationGapSyncQueue = []
        imConversationGapSyncActiveConversationID = nil
    }

    private func flushQueuedTextMessagesAfterConnection(limit: Int) async {
        guard !hasQueuedFlushInProgress,
              hasQueuedTextMessages()
        else {
            return
        }

        setQueuedFlushActive(true)

        switch await flushQueuedTextMessages(limit: limit) {
        case .drained:
            finishQueuedTextMessageFlush()
        case .hasMore:
            startQueuedTextMessageFlushIfNeeded(limit: limit)
        case .failed:
            finishQueuedTextMessageFlush()
        }
    }

    private func startQueuedTextMessageFlushIfNeeded(limit: Int) {
        guard currentUserProvider() != nil,
              imConnection != nil,
              queuedIMTextMessageFlushTask == nil,
              hasQueuedTextMessages()
        else {
            return
        }

        setQueuedFlushActive(true)
        let generation = imConnectionGeneration
        let currentUserID = currentUserProvider()?.id
        queuedIMTextMessageFlushTask = Task { [weak self] in
            guard let self, let currentUserID else {
                return
            }
            await self.runQueuedTextMessageFlushLoop(
                currentUserID: currentUserID,
                generation: generation,
                limit: limit
            )
        }
    }

    private var hasQueuedFlushInProgress: Bool {
        queuedIMTextMessageFlushTask != nil
    }

    private func runQueuedTextMessageFlushLoop(
        currentUserID: UUID,
        generation: UInt64,
        limit: Int
    ) async {
        while !Task.isCancelled {
            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil
            else {
                finishQueuedTextMessageFlush()
                return
            }

            guard hasQueuedTextMessages() else {
                finishQueuedTextMessageFlush()
                return
            }

            let result = await flushQueuedTextMessages(limit: limit)

            guard generation == imConnectionGeneration,
                  currentUserProvider()?.id == currentUserID,
                  imConnection != nil,
                  !Task.isCancelled
            else {
                finishQueuedTextMessageFlush()
                return
            }

            switch result {
            case .drained:
                finishQueuedTextMessageFlush()
                return
            case .hasMore:
                await Task.yield()
            case .failed:
                finishQueuedTextMessageFlush()
                return
            }
        }

        finishQueuedTextMessageFlush()
    }

    private func flushQueuedTextMessages(limit: Int) async -> QueuedTextMessageFlushBatchResult {
        guard let connection = imConnection else {
            return .failed
        }

        let requests = imConversationStore.queuedOutgoingMessageRequests(limit: limit)
        guard !requests.isEmpty else {
            return .drained
        }

        scheduleConversationCachePersist()
        let generation = imConnectionGeneration

        for (index, request) in requests.enumerated() {
            do {
                try await connection.sendMessage(request.payload, requestID: request.requestID)
            } catch {
                for unsentRequest in requests.dropFirst(index + 1) {
                    imConversationStore.markOutgoingQueued(
                        requestID: unsentRequest.requestID,
                        message: "等待 IM 长连接恢复后发送。"
                    )
                }

                scheduleConversationCachePersist()
                await handleIMConnectionFailure(error, generation: generation)
                return .failed
            }
        }

        scheduleConversationCachePersist()
        return hasQueuedTextMessages() ? .hasMore : .drained
    }

    private func hasQueuedTextMessages() -> Bool {
        imConversationStore.conversations.contains { conversation in
            conversation.messages.contains { message in
                guard message.direction == .outgoing, message.content.isUserComposable else {
                    return false
                }

                if case .queued = message.deliveryState {
                    return true
                }
                return false
            }
        }
    }

    private func cancelQueuedTextMessageFlush() {
        queuedIMTextMessageFlushTask?.cancel()
        finishQueuedTextMessageFlush()
    }

    private func finishQueuedTextMessageFlush() {
        queuedIMTextMessageFlushTask = nil
        setQueuedFlushActive(false)
    }

    private func markConversationReadIfSelectedUpToLatestLoadedSequence(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              imConversationStore.selectedConversationID == trimmedConversationID
        else {
            return
        }

        await markConversationReadUpToLatestLoadedSequence(for: trimmedConversationID)
    }

    private func markConversationReadInternal(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = HistoryConfig.readReportDebounceNanoseconds
    ) async {
        guard let trimmedConversationID = enqueueConversationReadReport(
            for: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        ) else {
            return
        }

        guard debounceNanoseconds == 0 else {
            return
        }

        await flushConversationReadReport(for: trimmedConversationID)
    }

    private func enqueueConversationReadReport(
        for conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64
    ) -> String? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return nil
        }

        let currentServerReadSequence = imConversationStore.serverLastReadSequence(for: trimmedConversationID) ?? 0
        let nextReadSequence = max(
            readSequence,
            pendingIMConversationReadSequences[trimmedConversationID] ?? 0
        )
        guard nextReadSequence > currentServerReadSequence else {
            return nil
        }

        pendingIMConversationReadSequences[trimmedConversationID] = nextReadSequence
        imConversationReadReportTasks[trimmedConversationID]?.cancel()

        guard debounceNanoseconds > 0 else {
            imConversationReadReportTasks[trimmedConversationID] = nil
            return trimmedConversationID
        }

        imConversationReadReportTasks[trimmedConversationID] = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: debounceNanoseconds)

            guard !Task.isCancelled else {
                return
            }

            await self.flushConversationReadReport(for: trimmedConversationID)
        }

        return trimmedConversationID
    }

    private func flushConversationReadReport(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        imConversationReadReportTasks[trimmedConversationID] = nil

        guard let readSequence = pendingIMConversationReadSequences.removeValue(forKey: trimmedConversationID) else {
            return
        }

        do {
            let response = try await sessionClient.markIMConversationRead(
                conversationID: trimmedConversationID,
                readSequence: readSequence
            )
            markServerOnline()
            imConversationStore.applyServerExplicitReadResponse(response)
            scheduleConversationCachePersist()
        } catch {
            await handleIMDataRequestError(error)
        }
    }

    @discardableResult
    private func reconcileConversationSummaryReadModel(force: Bool = true) async -> Bool {
        if !force,
           let lastRefreshAt = conversationSummaryRefreshAtProvider(),
           !imConversationStore.conversations.isEmpty,
           Date().timeIntervalSince(lastRefreshAt) < HistoryConfig.minimumSummaryRefreshInterval {
            return false
        }

        return await fetchAndApplyConversationSummaries(force: force)
    }

    private func fetchAndApplyConversationSummaries(force: Bool) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        imConversationStore.setLoadingConversations(true)
        defer {
            imConversationStore.setLoadingConversations(false)
        }

        do {
            let didRefresh: Bool
            if !force, let summaryToken = conversationSummarySyncTokenProvider() {
                didRefresh = try await fetchAndApplyConversationSummaryChanges(
                    afterToken: summaryToken,
                    userID: user.id
                )
            } else {
                didRefresh = try await fetchAndReplaceConversationSummaries(userID: user.id)
            }

            guard currentUserProvider()?.id == user.id else {
                return false
            }
            markServerOnline()
            setConversationSummaryRefreshAt(Date())
            return didRefresh
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    private func fetchAndReplaceConversationSummaries(userID: UUID) async throws -> Bool {
        let response = try await sessionClient.fetchIMConversationSummaries(
            cursor: nil,
            limit: HistoryConfig.summaryPageLimit
        )
        guard currentUserProvider()?.id == userID else {
            return false
        }

        setConversationSummarySyncToken(response.snapshotToken)
        setLatestConversationSummaries(response.items)
        imConversationStore.replaceConversationSummaryWindow(
            response.items,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore
        )
        imConversationStore.applyServerSummaryReadStates(response.items)
        scheduleConversationCachePersist()
        return true
    }

    private func fetchAndApplyConversationSummaryChanges(
        afterToken: String,
        userID: UUID
    ) async throws -> Bool {
        var cursor: String?
        var targetToken = afterToken
        var upserts: [IMConversationSummaryResponseBody] = []
        var removedConversationIDs: [UUID] = []

        repeat {
            let response = try await sessionClient.fetchIMConversationSummaryChanges(
                afterToken: afterToken,
                cursor: cursor,
                limit: HistoryConfig.summaryPageLimit
            )
            guard currentUserProvider()?.id == userID else {
                return false
            }

            imConversationStore.applyConversationSummaryChanges(
                upserts: response.upserts,
                removedConversationIDs: response.removedConversationIDs
            )
            imConversationStore.applyServerSummaryReadStates(response.upserts)
            upserts.append(contentsOf: response.upserts)
            removedConversationIDs.append(contentsOf: response.removedConversationIDs)
            targetToken = response.targetToken
            cursor = response.nextCursor

            if !response.hasMore {
                break
            }
        } while cursor != nil

        setConversationSummarySyncToken(targetToken)
        applyLatestConversationSummaryChanges(
            upserts: upserts,
            removedConversationIDs: removedConversationIDs
        )
        scheduleConversationCachePersist()
        return true
    }

    private func loadMessagesPage(
        for conversationID: String,
        currentUserID: UUID,
        beforeSequence: UInt64?,
        mergeMode: HistoryMergeMode
    ) async {
        imConversationMessagesTask?.cancel()
        imConversationMessagesTask = Task { [weak self] in
            guard let self else {
                return
            }

            self.imConversationStore.setLoadingMessages(true)
            defer {
                self.imConversationStore.setLoadingMessages(false)
                self.imConversationMessagesTask = nil
            }

            do {
                let messages = try await self.sessionClient.fetchIMMessages(
                    conversationID: conversationID,
                    beforeSequence: beforeSequence,
                    limit: HistoryConfig.latestHistoryLimit
                )
                guard self.currentUserProvider()?.id == currentUserID else {
                    return
                }

                self.markServerOnline()

                switch mergeMode {
                case .replace:
                    self.imConversationStore.replaceMessages(
                        in: conversationID,
                        messages: messages,
                        currentUserID: currentUserID
                    )
                case .prepend:
                    self.imConversationStore.prependMessages(
                        in: conversationID,
                        messages: messages,
                        currentUserID: currentUserID
                    )
                }
                self.scheduleConversationCachePersist()
            } catch {
                await self.handleIMDataRequestError(error)
            }
        }

        await imConversationMessagesTask?.value
    }
}
