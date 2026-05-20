import Foundation
import IMClientKit

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
    let applyContactEvent: (IMTCPContactEventPayload) -> Void
    let setConnectionStatus: (AuthManager.IMConnectionStatus) -> Void
    let setQueuedFlushActive: (Bool) -> Void
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
    let transferProjectionState = TransferProjectionState()

    var imConnection: IMTCPConnection?
    var imConnectionConnectTask: Task<Void, Never>?
    var imConnectionEventTask: Task<Void, Never>?
    var imConnectionReconnectTask: Task<Void, Never>?
    var imConnectionGeneration: UInt64 = 0
    var imConnectionReconnectAttempt = 0
    var imConversationGapSyncBackfillTask: Task<Void, Never>?
    var queuedIMTextMessageFlushTask: Task<Void, Never>?
    lazy var messageStreamSnapshotRecoveryQueue = MessageStreamSnapshotRecoveryQueue(
        sessionClient: sessionClient,
        imConversationStore: imConversationStore,
        currentUserProvider: currentUserProvider,
        markServerOnline: markServerOnline,
        scheduleConversationCachePersist: scheduleConversationCachePersist
    )
    var imConversationReadReportTasks: [String: Task<Void, Never>] = [:]
    var pendingIMConversationReadSequences: [String: UInt64] = [:]
    var imConversationGapSyncQueue: [String] = []
    var imConversationGapSyncActiveConversationID: String?
    var imConversationMembersTask: Task<Void, Never>?
    var imConversationMessagesTask: Task<Void, Never>?
    var imConversationRefreshTask: Task<Void, Never>?
    var mediaUploadRecoveryTasks: [String: Task<Void, Never>] = [:]
    var mediaDownloadBackgroundObserveTask: Task<Void, Never>?
    var mediaTransferStore = TransferStore()

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
        setQueuedFlushActive: @escaping (Bool) -> Void,
        backgroundTransferMonitor: any BackgroundTransferMonitoring
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
        self.backgroundTransferMonitor = backgroundTransferMonitor
        startObservingBackgroundMediaDownloads()
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

    func sendMedia(
        fileURL: URL,
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String? = nil,
        byteSize: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMillis: Int? = nil,
        previewAssetID: String? = nil,
        to conversationID: String
    ) async -> Bool {
        guard let user = currentUserProvider() else {
            return false
        }

        let resolvedFilename = resolvedMediaFilename(for: fileURL, filename: filename)
        guard !resolvedFilename.isEmpty else {
            imConversationStore.setStatusMessage("附件文件名不能为空。")
            return false
        }

        let resolvedByteSize: Int64
        do {
            resolvedByteSize = try resolvedMediaByteSize(for: fileURL, byteSize: byteSize)
        } catch {
            imConversationStore.setStatusMessage("无法读取附件大小。")
            return false
        }

        let placeholderAsset = IMMediaAsset(
            assetID: "local-\(UUID().uuidString.lowercased())",
            kind: kind,
            mimeType: mimeType,
            byteSize: resolvedByteSize,
            filename: resolvedFilename,
            width: width,
            height: height,
            durationMillis: durationMillis,
            previewAssetID: previewAssetID
        )

        guard let placeholder = imConversationStore.stageOutgoingMediaUpload(
            asset: placeholderAsset,
            conversationID: conversationID,
            senderUserID: user.id,
            sourceFileURL: fileURL
        ) else {
            return false
        }
        scheduleConversationCachePersist()

        do {
            imConversationStore.markOutgoingPreparing(
                localMessageID: placeholder.localMessageID,
                message: "正在创建上传会话。"
            )
            let session = try await sessionClient.createMediaUploadSession(
                kind: kind,
                mimeType: mimeType,
                byteSize: resolvedByteSize,
                filename: resolvedFilename,
                width: width,
                height: height,
                durationMillis: durationMillis,
                previewAssetID: previewAssetID
            )
            markServerOnline()

            imConversationStore.markOutgoingUploading(
                localMessageID: placeholder.localMessageID,
                message: "正在上传附件。",
                uploadID: session.uploadID
            )
            try await sessionClient.uploadMediaChunk(
                uploadID: session.uploadID,
                uploadBody: .file(fileURL, contentType: mimeType)
            )
            let uploadedAsset = try await sessionClient.completeMediaUpload(uploadID: session.uploadID)
            markServerOnline()

            if let connection = imConnection {
                guard let request = imConversationStore.prepareUploadedOutgoingMedia(
                    asset: uploadedAsset,
                    localMessageID: placeholder.localMessageID,
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

            let didQueue = imConversationStore.queueUploadedOutgoingMedia(
                asset: uploadedAsset,
                localMessageID: placeholder.localMessageID,
                conversationID: conversationID
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
            return didQueue
        } catch {
            imConversationStore.markOutgoingUploadFailed(
                localMessageID: placeholder.localMessageID,
                message: "附件上传失败，请稍后重试。"
            )
            scheduleConversationCachePersist()
            await handleIMDataRequestError(error)
            return false
        }
    }

    func resumeRecoverableMediaUploadsIfNeeded() {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        for pendingUpload in imConversationStore.recoverableOutgoingMediaUploads() {
            guard mediaUploadRecoveryTasks[pendingUpload.localMessageID] == nil else {
                continue
            }

            mediaUploadRecoveryTasks[pendingUpload.localMessageID] = Task { [weak self] in
                await self?.resumeRecoverableMediaUpload(
                    pendingUpload,
                    expectedUserID: currentUserID
                )
            }
        }
    }

    func downloadMedia(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        try await sessionClient.downloadMediaAssetWithProgress(
            assetID: asset.assetID,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    func downloadMediaToFile(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> URL {
        let operation = try await downloadMedia(
            asset,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )

        var completedURL: URL?
        for try await event in operation.events {
            if case .completed(let finalURL) = event {
                completedURL = finalURL
            }
        }

        return completedURL ?? destinationURL
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

    func editMessage(messageID: String, text: String, in conversationID: String) async -> Bool {
        guard let currentUserID = currentUserProvider()?.id else {
            return false
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty, !trimmedText.isEmpty else {
            return false
        }

        do {
            let response = try await sessionClient.editIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID,
                text: trimmedText
            )
            markServerOnline()
            imConversationStore.applyUpdatedMessage(response, currentUserID: currentUserID)
            _ = await reconcileConversationSummaryReadModel(force: true)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func toggleMessageReaction(messageID: String, emoji: String, in conversationID: String) async -> Bool {
        guard let currentUserID = currentUserProvider()?.id else {
            return false
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty, !trimmedEmoji.isEmpty else {
            return false
        }

        do {
            let response = try await sessionClient.toggleIMMessageReaction(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID,
                emoji: trimmedEmoji
            )
            markServerOnline()
            imConversationStore.applyUpdatedMessage(response, currentUserID: currentUserID)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func favoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.favoriteIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID
            )
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func unfavoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.unfavoriteIMMessage(
                conversationID: trimmedConversationID,
                messageID: trimmedMessageID
            )
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func deleteMessagesForSelf(messageIDs: [String], in conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = messageIDs.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !trimmedConversationID.isEmpty, !ids.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.deleteIMMessagesForSelf(
                conversationID: trimmedConversationID,
                messageIDs: ids
            )
            markServerOnline()
            imConversationStore.removeMessages(
                ids: Set(ids.map(\.uuidString) + messageIDs),
                from: trimmedConversationID
            )
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func clearConversationForSelf(_ conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.clearIMConversationForSelf(conversationID: trimmedConversationID)
            markServerOnline()
            if let conversation = imConversationStore.conversations.first(where: { $0.id == trimmedConversationID }) {
                let ids = Set(conversation.messages.map(\.id) + conversation.messages.compactMap(\.serverMessageID))
                imConversationStore.removeMessages(ids: ids, from: trimmedConversationID)
            }
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func deleteConversationForSelf(_ conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.deleteIMConversationForSelf(conversationID: trimmedConversationID)
            markServerOnline()
            imConversationStore.removeConversation(id: trimmedConversationID)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func forwardMessages(messageIDs: [String], from conversationID: String, to targetConversationIDs: [String]) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIDs = messageIDs.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let targetIDs = targetConversationIDs.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !trimmedConversationID.isEmpty, !sourceIDs.isEmpty, !targetIDs.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.forwardIMMessages(
                conversationID: trimmedConversationID,
                messageIDs: sourceIDs,
                targetConversationIDs: targetIDs
            )
            markServerOnline()
            _ = await reconcileConversationSummaryReadModel(force: true)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func createGroupInvite(conversationID: String, expiresInSeconds: Int? = nil) async -> IMGroupInviteResponseBody? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return nil
        }

        do {
            let invite = try await sessionClient.createIMGroupInvite(
                conversationID: trimmedConversationID,
                expiresInSeconds: expiresInSeconds
            )
            markServerOnline()
            return invite
        } catch {
            await handleIMDataRequestError(error)
            return nil
        }
    }

    func updateMyMemberNickname(conversationID: String, memberNickname: String?) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        do {
            let conversation = try await sessionClient.updateIMMyMemberProfile(
                conversationID: trimmedConversationID,
                memberNickname: memberNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            markServerOnline()
            applyConversationSummaryReadModel([conversation])
            await loadConversationMembers(for: trimmedConversationID)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func fetchGroupInvites(conversationID: String) async -> [IMGroupInviteResponseBody] {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return []
        }

        do {
            let invites = try await sessionClient.fetchIMGroupInvites(conversationID: trimmedConversationID)
            markServerOnline()
            return invites
        } catch {
            await handleIMDataRequestError(error)
            return []
        }
    }

    func revokeGroupInvite(conversationID: String, token: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedToken.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.revokeIMGroupInvite(conversationID: trimmedConversationID, token: trimmedToken)
            markServerOnline()
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
            syncActiveMessageStreamSnapshots()
        case .incomplete:
            enqueueConversationGapSyncBackfill(for: conversationID, prioritize: true)
            await markConversationReadIfSelectedUpToLatestLoadedSequence(for: conversationID)
            syncActiveMessageStreamSnapshots()
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

        imConversationStore.setLoadingMoreConversationSummaries(true)
        defer {
            imConversationStore.setLoadingMoreConversationSummaries(false)
        }

        do {
            let response = try await sessionClient.fetchIMConversationSummaries(
                cursor: nextCursor,
                limit: HistoryConfig.summaryPageLimit,
                kind: kind
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
                self.imConversationStore.applyMemberPage(
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
            imConversationStore.applyMemberPage(
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
            .filter { $0.serverSequence != nil }
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
              let beforeSequence = imConversationStore.oldestLoadedServerSequence(for: trimmedConversationID)
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

            let currentOldestSequence = imConversationStore.oldestLoadedServerSequence(for: trimmedConversationID)
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

    @discardableResult
    func reconcileConversationSummaryReadModel(
        force: Bool = true,
        kind: IMConversationKind? = nil
    ) async -> Bool {
        if kind == nil,
           !force,
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

        imConversationStore.setLoadingConversations(true)
        defer {
            imConversationStore.setLoadingConversations(false)
        }

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
        imConversationStore.replaceConversationSummaryWindow(
            response.items,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore
        )
        imConversationStore.applyServerSummaryReadStates(response.items)
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
                guard self.imConversationStore.containsConversation(id: conversationID) else {
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

    func resumeRecoverableMediaUpload(
        _ pendingUpload: IMRecoverableOutgoingMediaUpload,
        expectedUserID: UUID
    ) async {
        defer {
            mediaUploadRecoveryTasks[pendingUpload.localMessageID] = nil
        }

        guard currentUserProvider()?.id == expectedUserID else {
            return
        }

        guard imConversationStore.containsConversation(id: pendingUpload.conversationID) else {
            return
        }

        let sourceFileURL = pendingUpload.transferState.sourceFileURL
        guard FileManager.default.fileExists(atPath: sourceFileURL.path) else {
            imConversationStore.abandonRecoverableOutgoingMediaUpload(
                localMessageID: pendingUpload.localMessageID,
                message: "附件原文件不存在，无法继续上传。"
            )
            scheduleConversationCachePersist()
            return
        }

        do {
            var uploadID = pendingUpload.transferState.uploadID
            if uploadID == nil {
                imConversationStore.markOutgoingPreparing(
                    localMessageID: pendingUpload.localMessageID,
                    message: "正在恢复附件上传。"
                )
                let session = try await sessionClient.createMediaUploadSession(
                    kind: pendingUpload.asset.kind,
                    mimeType: pendingUpload.asset.mimeType,
                    byteSize: pendingUpload.asset.byteSize,
                    filename: pendingUpload.asset.filename,
                    width: pendingUpload.asset.width,
                    height: pendingUpload.asset.height,
                    durationMillis: pendingUpload.asset.durationMillis,
                    previewAssetID: pendingUpload.asset.previewAssetID
                )
                uploadID = session.uploadID
                markServerOnline()
            }

            guard let uploadID else {
                imConversationStore.abandonRecoverableOutgoingMediaUpload(
                    localMessageID: pendingUpload.localMessageID,
                    message: "附件上传会话无效，无法恢复。"
                )
                scheduleConversationCachePersist()
                return
            }

            imConversationStore.markOutgoingUploading(
                localMessageID: pendingUpload.localMessageID,
                message: "正在恢复上传附件。",
                uploadID: uploadID
            )
            scheduleConversationCachePersist()

            try await sessionClient.uploadMediaChunk(
                uploadID: uploadID,
                uploadBody: .file(sourceFileURL, contentType: pendingUpload.asset.mimeType)
            )
            let uploadedAsset = try await sessionClient.completeMediaUpload(uploadID: uploadID)
            markServerOnline()

            if let connection = imConnection {
                guard let request = imConversationStore.prepareUploadedOutgoingMedia(
                    asset: uploadedAsset,
                    localMessageID: pendingUpload.localMessageID,
                    conversationID: pendingUpload.conversationID
                ) else {
                    scheduleConversationCachePersist()
                    return
                }
                scheduleConversationCachePersist()

                let generation = imConnectionGeneration
                do {
                    try await connection.sendMessage(request.payload, requestID: request.requestID)
                } catch {
                    await handleIMConnectionFailure(error, generation: generation)
                }
                return
            }

            let didQueue = imConversationStore.queueUploadedOutgoingMedia(
                asset: uploadedAsset,
                localMessageID: pendingUpload.localMessageID,
                conversationID: pendingUpload.conversationID
            )
            if didQueue {
                scheduleConversationCachePersist()
                scheduleConnectionIfNeeded()
            }
        } catch {
            imConversationStore.markOutgoingUploadFailed(
                localMessageID: pendingUpload.localMessageID,
                message: "附件上传失败，请稍后重试。"
            )
            scheduleConversationCachePersist()
            await handleIMDataRequestError(error)
        }
    }

    func resolvedMediaFilename(for fileURL: URL, filename: String?) -> String {
        let provided = filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !provided.isEmpty {
            return provided
        }
        return fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolvedMediaByteSize(for fileURL: URL, byteSize: Int64?) throws -> Int64 {
        if let byteSize, byteSize > 0 {
            return byteSize
        }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > 0 {
            return Int64(fileSize)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let fileSize = attributes[.size] as? NSNumber, fileSize.int64Value > 0 {
            return fileSize.int64Value
        }

        throw CocoaError(.fileReadUnknown)
    }

}
