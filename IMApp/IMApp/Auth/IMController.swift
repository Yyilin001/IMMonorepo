import Foundation
import IMClientKit

// App-level IM facade. It preserves the SwiftUI-facing API while delegating
// connection, gap sync, read reporting, queued flush, media, and AI recovery to
// coordinators behind this boundary.
@MainActor
final class ConversationRuntimeController {
    let sessionClient: SessionClient
    let openIMConnection: @Sendable () async throws -> IMTCPConnection
    let imConversationStore: IMConversationStore
    let currentUserProvider: () -> AuthUser?
    let isSignedInProvider: () -> Bool
    let latestConversationSummariesProvider: () -> [IMConversationSummaryResponseBody]
    let setLatestConversationSummaries: ([IMConversationSummaryResponseBody]) -> Void
    let conversationSummaryRefreshAtProvider: () -> Date?
    let setConversationSummaryRefreshAt: (Date?) -> Void
    let conversationSummarySyncTokenProvider: () -> String?
    let setConversationSummarySyncToken: (String?) -> Void
    let markServerOnline: () -> Void
    let clearSession: (String?) async -> Void
    let handleIMDataRequestError: (Error) async -> Void
    let syncContactStateAfterConnection: () async -> Void
    let scheduleConversationCachePersist: () -> Void
    let flushConversationCache: () async -> Void
    let flushContactStateCache: () async -> Void
    let applyContactDomainEvent: (IMTCPChatDomainEventPayload) -> Void
    let setConnectionStatus: (AuthManager.IMConnectionStatus) -> Void
    let setQueuedFlushActive: (Bool) -> Void
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
    let foregroundSyncIntervals: ForegroundSyncIntervals
    let timelineCatchUpConfiguration: TimelineCatchUpConfiguration
    let transferProjectionState = TransferProjectionState()

    lazy var connectionCoordinator = IMConnectionCoordinator(runtime: self)
    lazy var gapSyncCoordinator = IMGapSyncCoordinator(runtime: self)
    lazy var readReportCoordinator = IMReadReportCoordinator(runtime: self)
    lazy var queuedMessageFlushCoordinator = QueuedMessageFlushCoordinator(runtime: self)
    lazy var messageStreamSnapshotRecoveryQueue = MessageStreamSnapshotRecoveryQueue(
        sessionClient: sessionClient,
        imConversationStore: imConversationStore,
        currentUserProvider: currentUserProvider,
        markServerOnline: markServerOnline,
        scheduleConversationCachePersist: scheduleConversationCachePersist
    )
    var imConversationMembersTask: Task<Void, Never>?
    var imConversationMessagesTask: Task<Void, Never>?
    var imConversationRefreshTask: Task<Void, Never>?
    var pendingConversationSummaryRefreshRequest: ConversationSummaryRefreshRequest?
    var mediaUploadRecoveryTasks: [String: Task<Void, Never>] = [:]
    var mediaDownloadBackgroundObserveTask: Task<Void, Never>?
    var mediaTransferStore = TransferStore()
    var lastClientHealthReportAt: Date?
    var lastTimelineCatchUpHealthReportAt: Date?

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
        applyContactDomainEvent: @escaping (IMTCPChatDomainEventPayload) -> Void,
        setConnectionStatus: @escaping (AuthManager.IMConnectionStatus) -> Void,
        setQueuedFlushActive: @escaping (Bool) -> Void,
        backgroundTransferMonitor: any BackgroundTransferMonitoring,
        foregroundSyncIntervals: ForegroundSyncIntervals = .production,
        timelineCatchUpConfiguration: TimelineCatchUpConfiguration = .production
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
        self.applyContactDomainEvent = applyContactDomainEvent
        self.setConnectionStatus = setConnectionStatus
        self.setQueuedFlushActive = setQueuedFlushActive
        self.backgroundTransferMonitor = backgroundTransferMonitor
        self.foregroundSyncIntervals = foregroundSyncIntervals
        self.timelineCatchUpConfiguration = timelineCatchUpConfiguration
        startObservingBackgroundMediaDownloads()
    }

    var imConnection: IMTCPConnection? {
        connectionCoordinator.connection
    }

    var imConnectionGeneration: UInt64 {
        connectionCoordinator.generation
    }

    func reportConversationActivity(conversationID: String, isActive: Bool) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let connection = imConnection
        else {
            return
        }

        do {
            try await connection.sendConversationActivity(
                conversationID: trimmedConversationID,
                isActive: isActive
            )
        } catch {
            await connectionCoordinator.handleFailure(error, generation: imConnectionGeneration)
        }
    }

    func reportSelectedConversationActivity(isActive: Bool) async {
        guard let selectedConversationID = imConversationStore.selectedConversationID else {
            return
        }

        await reportConversationActivity(
            conversationID: selectedConversationID,
            isActive: isActive
        )
    }

    func syncConversationAfterOpen(_ conversationID: String) async {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        switch await syncConversationGap(for: conversationID, currentUserID: currentUserID) {
        case .completed:
            await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            syncActiveMessageStreamSnapshots()
        case .incomplete:
            enqueueConversationGapSyncCatchUp(for: conversationID, prioritize: true)
            await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            syncActiveMessageStreamSnapshots()
        case .deferred:
            enqueueConversationGapSyncCatchUp(for: conversationID, prioritize: true)
        case .failed:
            return
        }
    }

    func reloadConversations(force: Bool = true, kind: IMConversationKind? = nil) async {
        guard let user = currentUserProvider() else {
            return
        }

        let didRefresh = await reconcileConversationSummaryReadModel(force: force, kind: kind)
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

    func loadMoreConversationSummariesIfNeeded(
        anchorConversationID: String?,
        kind: IMConversationKind? = nil
    ) async {
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

        await imConversationStore.setLoadingMoreConversationSummariesAsync(true)

        do {
            let response = try await sessionClient.fetchIMConversationSummaries(
                cursor: nextCursor,
                limit: HistoryConfig.summaryPageLimit,
                kind: kind
            )
            guard currentUserProvider()?.id == user.id else {
                await imConversationStore.setLoadingMoreConversationSummariesAsync(false)
                return
            }

            markServerOnline()
            await imConversationStore.appendConversationSummaryWindowAsync(
                response.items,
                nextCursor: response.nextCursor,
                hasMore: response.hasMore
            )
            setLatestConversationSummaries(latestConversationSummariesProvider() + response.items)
            scheduleConversationCachePersist()
            await imConversationStore.setLoadingMoreConversationSummariesAsync(false)
        } catch {
            await handleIMDataRequestError(error)
            await imConversationStore.setLoadingMoreConversationSummariesAsync(false)
        }
    }

    func loadConversationMembers(
        for conversationID: String,
        query: String = "",
        reset: Bool = true
    ) async {
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

            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            self.imConversationStore.setMemberPageLoading(
                conversationID: trimmedConversationID,
                query: normalizedQuery,
                isLoading: reset
            )
            defer {
                self.imConversationStore.setMemberPageLoading(
                    conversationID: trimmedConversationID,
                    query: normalizedQuery,
                    isLoading: false
                )
                self.imConversationMembersTask = nil
            }

            do {
                let membersPage = try await self.sessionClient.fetchIMConversationMembers(
                    conversationID: trimmedConversationID,
                    limit: 50,
                    query: normalizedQuery.isEmpty ? nil : normalizedQuery
                )
                guard self.currentUserProvider()?.id == user.id else {
                    return
                }

                self.markServerOnline()
                await self.imConversationStore.applyMemberPageAsync(
                    membersPage,
                    in: trimmedConversationID,
                    query: normalizedQuery,
                    appending: false
                )
                self.scheduleConversationCachePersist()
            } catch {
                await self.handleIMDataRequestError(error)
            }
        }

        await imConversationMembersTask?.value
    }

    func loadMoreConversationMembers(for conversationID: String) async {
        guard let user = currentUserProvider() else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let state = imConversationStore.memberPageState(for: trimmedConversationID)
        guard let nextCursor = state.nextCursor, !state.isLoadingMore else {
            return
        }

        let query = state.query
        imConversationStore.setMemberPageLoading(
            conversationID: trimmedConversationID,
            query: query,
            isLoading: false,
            isLoadingMore: true
        )
        defer {
            imConversationStore.setMemberPageLoading(
                conversationID: trimmedConversationID,
                query: query,
                isLoading: false,
                isLoadingMore: false
            )
        }

        do {
            let membersPage = try await sessionClient.fetchIMConversationMembers(
                conversationID: trimmedConversationID,
                cursor: nextCursor,
                limit: state.limit,
                query: query.isEmpty ? nil : query
            )
            guard currentUserProvider()?.id == user.id else {
                return
            }

            markServerOnline()
            await imConversationStore.applyMemberPageAsync(
                membersPage,
                in: trimmedConversationID,
                query: query,
                appending: true
            )
            scheduleConversationCachePersist()
        } catch {
            await handleIMDataRequestError(error)
        }
    }

    func loadReceiptSummary(for conversationID: String) async {
        guard currentUserProvider() != nil else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        do {
            let summary = try await sessionClient.fetchIMConversationReceiptSummary(
                conversationID: trimmedConversationID
            )
            markServerOnline()
            imConversationStore.setReceiptSummary(summary, for: trimmedConversationID)
        } catch {
            await handleIMDataRequestError(error)
        }
    }

    func loadMessagesIfNeeded(for conversationID: String, forceReload: Bool = false) async {
        guard let user = currentUserProvider() else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let cachedConversation = imConversationStore.conversations
            .first(where: { $0.id == trimmedConversationID })
        let loadedMessageCount = cachedConversation?
            .messages
            .count ?? 0
        let hasLoadedMessages = imConversationStore.hasLoadedMessages(for: trimmedConversationID)
        let shouldExpandCachedHistory = hasLoadedMessages
            && loadedMessageCount < HistoryConfig.latestHistoryLimit
            && cachedConversation?.hasMoreHistory == true

        guard forceReload
            || !hasLoadedMessages
            || shouldExpandCachedHistory
        else {
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
              let beforeSequence = imConversationStore.oldestLoadedTimelineSequence(for: conversationID)
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

    func jumpToReferencedMessage(
        _ targetMessageID: String,
        in conversationID: String
    ) async {
        guard let user = currentUserProvider() else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              !trimmedTargetMessageID.isEmpty,
              imConversationStore.containsConversation(id: trimmedConversationID)
        else {
            return
        }

        imConversationStore.beginReplyJump(to: trimmedTargetMessageID, in: trimmedConversationID)

        if resolveReplyJumpIfPossible(
            targetMessageID: trimmedTargetMessageID,
            conversationID: trimmedConversationID
        ) {
            return
        }

        while imConversationStore.canLoadOlderMessages(for: trimmedConversationID),
              let beforeSequence = imConversationStore.oldestLoadedTimelineSequence(for: trimmedConversationID)
        {
            let previousOldestSequence = beforeSequence
            await loadMessagesPage(
                for: trimmedConversationID,
                currentUserID: user.id,
                beforeSequence: previousOldestSequence,
                mergeMode: .prepend
            )

            guard imConversationStore.containsConversation(id: trimmedConversationID) else {
                return
            }

            if resolveReplyJumpIfPossible(
                targetMessageID: trimmedTargetMessageID,
                conversationID: trimmedConversationID
            ) {
                return
            }

            let currentOldestSequence = imConversationStore.oldestLoadedTimelineSequence(for: trimmedConversationID)
            if currentOldestSequence == previousOldestSequence {
                imConversationStore.clearReplyJump()
                return
            }
        }

        imConversationStore.exhaustReplyJump(
            to: trimmedTargetMessageID,
            in: trimmedConversationID
        )
    }

    func searchConversationMessages(
        in conversationID: String,
        query: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> IMConversationMessageSearchPageResponseBody? {
        guard currentUserProvider() != nil else {
            return nil
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedQuery.isEmpty else {
            return nil
        }

        do {
            let page = try await sessionClient.searchIMConversationMessages(
                conversationID: trimmedConversationID,
                query: trimmedQuery,
                cursor: cursor,
                limit: limit
            )
            markServerOnline()
            return page
        } catch {
            await handleIMDataRequestError(error)
            return nil
        }
    }

    func refreshConversationSummaryReadModelIfNeeded() async {
        _ = await reconcileConversationSummaryReadModel(force: false)
    }

    func scheduleConversationSummaryReadModelCorrection(force: Bool = false) {
        scheduleConversationSummaryReadModelCorrection(
            ConversationSummaryRefreshRequest(
                force: force,
                bypassMinimumInterval: force,
                debounceNanoseconds: force ? 0 : HistoryConfig.summaryRefreshDebounceNanoseconds
            )
        )
    }

    func scheduleLightweightConversationSummaryReadModelCorrection() {
        scheduleConversationSummaryReadModelCorrection(
            ConversationSummaryRefreshRequest(
                force: false,
                bypassMinimumInterval: true,
                debounceNanoseconds: HistoryConfig.summaryRefreshDebounceNanoseconds
            )
        )
    }

    private func scheduleConversationSummaryReadModelCorrection(_ request: ConversationSummaryRefreshRequest) {
        if var pending = pendingConversationSummaryRefreshRequest {
            pending.merge(request)
            pendingConversationSummaryRefreshRequest = pending
        } else {
            pendingConversationSummaryRefreshRequest = request
        }

        guard imConversationRefreshTask == nil else {
            return
        }

        imConversationRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            while true {
                guard let request = self.pendingConversationSummaryRefreshRequest else {
                    self.imConversationRefreshTask = nil
                    return
                }
                self.pendingConversationSummaryRefreshRequest = nil

                if request.debounceNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: request.debounceNanoseconds)
                }

                guard !Task.isCancelled else {
                    return
                }

                _ = await self.reconcileConversationSummaryReadModel(
                    force: request.force,
                    respectMinimumInterval: !request.bypassMinimumInterval
                )
            }
        }
    }

    func applyConversationSummaryReadModelAsync(_ conversations: [IMConversationSummaryResponseBody]) async {
        applyLatestConversationSummaryChanges(
            upserts: conversations,
            removedConversationIDs: []
        )
        imConversationStore.replaceConversationSummaries(conversations)
        await imConversationStore.applyServerSummaryReadStatesAsync(conversations)
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

    @discardableResult
    func reconcileConversationSummaryReadModel(
        force: Bool = true,
        kind: IMConversationKind? = nil,
        respectMinimumInterval: Bool = true
    ) async -> Bool {
        if kind == nil,
           !force,
           respectMinimumInterval,
           let lastRefreshAt = conversationSummaryRefreshAtProvider(),
           !imConversationStore.conversations.isEmpty,
           Date().timeIntervalSince(lastRefreshAt) < HistoryConfig.minimumSummaryRefreshInterval {
            return false
        }

        return await fetchAndApplyConversationSummaries(force: force, kind: kind)
    }

    func fetchAndApplyConversationSummaries(
        force: Bool,
        kind: IMConversationKind? = nil
    ) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        await imConversationStore.setLoadingConversationsAsync(true)

        do {
            let didRefresh: Bool
            if kind == nil, !force, let summaryToken = conversationSummarySyncTokenProvider() {
                didRefresh = try await fetchAndApplyConversationSummaryChanges(
                    afterToken: summaryToken,
                    userID: user.id
                )
            } else {
                didRefresh = try await fetchAndReplaceConversationSummaries(userID: user.id, kind: kind)
            }

            guard currentUserProvider()?.id == user.id else {
                await imConversationStore.setLoadingConversationsAsync(false)
                return false
            }
            markServerOnline()
            setConversationSummaryRefreshAt(Date())
            await imConversationStore.setLoadingConversationsAsync(false)
            return didRefresh
        } catch {
            await handleIMDataRequestError(error)
            await imConversationStore.setLoadingConversationsAsync(false)
            return false
        }
    }

    func fetchAndReplaceConversationSummaries(
        userID: UUID,
        kind: IMConversationKind? = nil
    ) async throws -> Bool {
        let response = try await sessionClient.fetchIMConversationSummaries(
            cursor: nil,
            limit: HistoryConfig.summaryPageLimit,
            kind: kind
        )
        guard currentUserProvider()?.id == userID else {
            return false
        }

        if kind == nil {
            setConversationSummarySyncToken(response.snapshotToken)
        }
        setLatestConversationSummaries(response.items)
        await imConversationStore.replaceConversationSummaryWindowAsync(
            response.items,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore
        )
        await imConversationStore.applyServerSummaryReadStatesAsync(response.items)
        scheduleConversationCachePersist()
        return true
    }

    func fetchAndApplyConversationSummaryChanges(
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
            await imConversationStore.applyServerSummaryReadStatesAsync(response.upserts)
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

    func loadMessagesPage(
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

            await self.imConversationStore.setLoadingMessagesAsync(true)

            do {
                let response = try await self.sessionClient.fetchIMTimeline(
                    conversationID: conversationID,
                    beforeSequence: beforeSequence,
                    limit: HistoryConfig.latestHistoryLimit
                )
                guard self.currentUserProvider()?.id == currentUserID else {
                    await self.imConversationStore.setLoadingMessagesAsync(false)
                    self.imConversationMessagesTask = nil
                    return
                }
                guard self.imConversationStore.containsConversation(id: conversationID) else {
                    await self.imConversationStore.setLoadingMessagesAsync(false)
                    self.imConversationMessagesTask = nil
                    return
                }

                self.markServerOnline()

                switch mergeMode {
                case .replace:
                    self.imConversationStore.mergeTimelinePage(
                        in: conversationID,
                        response: response,
                        currentUserID: currentUserID
                    )
                case .prepend:
                    self.imConversationStore.prependTimelinePage(
                        in: conversationID,
                        response: response,
                        currentUserID: currentUserID
                    )
                }
                self.scheduleConversationCachePersist()
                await self.imConversationStore.setLoadingMessagesAsync(false)
                self.imConversationMessagesTask = nil
            } catch {
                await self.handleIMDataRequestError(error)
                await self.imConversationStore.setLoadingMessagesAsync(false)
                self.imConversationMessagesTask = nil
            }
        }

        await imConversationMessagesTask?.value
    }

    func resolveReplyJumpIfPossible(
        targetMessageID: String,
        conversationID: String
    ) -> Bool {
        guard let matchedMessageID = imConversationStore.localMessageID(
            matchingReferencedMessageID: targetMessageID,
            in: conversationID
        ) else {
            return false
        }

        imConversationStore.resolveReplyJump(
            matchedMessageID: matchedMessageID,
            in: conversationID
        )
        return true
    }
}
