import Foundation
import IMClientKit

@MainActor
final class ConversationRuntimeController {
    let sessionClient: SessionClient
    private let openIMConnection: @Sendable () async throws -> IMTCPConnection
    let imConversationStore: IMConversationStore
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
    let scheduleConversationCachePersist: () -> Void
    private let flushConversationCache: () async -> Void
    private let flushContactStateCache: () async -> Void
    private let applyContactEvent: (IMTCPContactEventPayload) -> Void
    private let setConnectionStatus: (AuthManager.IMConnectionStatus) -> Void
    private let setQueuedFlushActive: (Bool) -> Void
    let backgroundTransferMonitor: any BackgroundTransferMonitoring
    let transferProjectionState = TransferProjectionState()

    private var imConnection: IMTCPConnection?
    private var imConnectionConnectTask: Task<Void, Never>?
    private var imConnectionEventTask: Task<Void, Never>?
    private var imConnectionReconnectTask: Task<Void, Never>?
    private var imConnectionGeneration: UInt64 = 0
    private var imConnectionReconnectAttempt = 0
    private var imConversationGapSyncBackfillTask: Task<Void, Never>?
    private var queuedIMTextMessageFlushTask: Task<Void, Never>?
    private var imMessageStreamSnapshotWorkerTask: Task<Void, Never>?
    private var pendingMessageStreamSnapshotTargets: Set<IMActiveMessageStreamTarget> = []
    private var messageStreamSnapshotRetryDelays: [IMActiveMessageStreamTarget: UInt64] = [:]
    private var imConversationReadReportTasks: [String: Task<Void, Never>] = [:]
    private var pendingIMConversationReadSequences: [String: UInt64] = [:]
    private var imConversationGapSyncQueue: [String] = []
    private var imConversationGapSyncActiveConversationID: String?
    private var imConversationMembersTask: Task<Void, Never>?
    private var imConversationMessagesTask: Task<Void, Never>?
    private var imConversationRefreshTask: Task<Void, Never>?
    private var mediaUploadRecoveryTasks: [String: Task<Void, Never>] = [:]
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

    private func handleIMConnectionFailure(_ error: Error, generation: UInt64) async {
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

    private func scheduleIMConnectionReconnectIfNeeded(generation: UInt64) {
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

            await self?.startScheduledIMReconnect(generation: generation)
        }
    }

    private func startScheduledIMReconnect(generation: UInt64) {
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

    private func nextReconnectDelayNanoseconds() -> UInt64 {
        imConnectionReconnectAttempt += 1
        let shift = min(imConnectionReconnectAttempt - 1, 5)
        let multiplier = UInt64(1 << shift)
        return min(
            HistoryConfig.reconnectInitialDelayNanoseconds * multiplier,
            HistoryConfig.reconnectMaxDelayNanoseconds
        )
    }

    private func reconnectingStatusMessage(_ message: String) -> String {
        "\(message) 正在自动重连。"
    }

    private func syncConversationGap(
        for conversationID: String,
        currentUserID: UUID
    ) async -> ConversationGapSyncResult {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              imConversationStore.containsConversation(id: trimmedConversationID),
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
                guard imConversationStore.containsConversation(id: trimmedConversationID) else {
                    return .completed
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
        syncActiveMessageStreamSnapshots()
    }

    func syncActiveMessageStreamSnapshots() {
        let targets = imConversationStore.activeMessageStreamTargets()
        guard !targets.isEmpty else {
            return
        }
        enqueueMessageStreamSnapshotTargets(targets)
    }

    private func syncPendingMessageStreamSnapshotsIfNeeded() {
        let targets = imConversationStore.consumePendingStreamSnapshotTargets()
        guard !targets.isEmpty else {
            return
        }
        enqueueMessageStreamSnapshotTargets(targets)
    }

    private func enqueueMessageStreamSnapshotTargets(_ targets: [IMActiveMessageStreamTarget]) {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        pendingMessageStreamSnapshotTargets.formUnion(targets)
        startMessageStreamSnapshotWorkerIfNeeded(currentUserID: currentUserID)
    }

    private func startMessageStreamSnapshotWorkerIfNeeded(currentUserID: UUID) {
        guard imMessageStreamSnapshotWorkerTask == nil else {
            return
        }

        imMessageStreamSnapshotWorkerTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                guard self.currentUserProvider()?.id == currentUserID else {
                    return
                }
                guard let target = self.pendingMessageStreamSnapshotTargets.first else {
                    self.imMessageStreamSnapshotWorkerTask = nil
                    if !self.pendingMessageStreamSnapshotTargets.isEmpty {
                        self.startMessageStreamSnapshotWorkerIfNeeded(currentUserID: currentUserID)
                    }
                    return
                }
                self.pendingMessageStreamSnapshotTargets.remove(target)

                do {
                    let retryDelay = self.messageStreamSnapshotRetryDelays[target] ?? 0
                    if retryDelay > 0 {
                        try await Task.sleep(nanoseconds: retryDelay)
                    }
                    try Task.checkCancellation()
                    let response = try await self.sessionClient.fetchMessageStreamSnapshot(
                        conversationID: target.conversationID,
                        messageID: target.messageID
                    )
                    guard self.currentUserProvider()?.id == currentUserID else {
                        return
                    }
                    self.markServerOnline()
                    self.imConversationStore.applyMessageStreamSnapshot(
                        response,
                        currentUserID: currentUserID
                    )
                    self.scheduleConversationCachePersist()
                    self.messageStreamSnapshotRetryDelays.removeValue(forKey: target)
                } catch is CancellationError {
                    return
                } catch {
                    // Snapshot recovery is a compensation path; keep the local partial and retry with bounded backoff.
                    self.pendingMessageStreamSnapshotTargets.insert(target)
                    self.messageStreamSnapshotRetryDelays[target] = self.nextMessageStreamSnapshotRetryDelay(
                        after: self.messageStreamSnapshotRetryDelays[target]
                    )
                }
            }
        }
    }

    private func cancelMessageStreamSnapshotSync() {
        imMessageStreamSnapshotWorkerTask?.cancel()
        imMessageStreamSnapshotWorkerTask = nil
        pendingMessageStreamSnapshotTargets.removeAll()
        messageStreamSnapshotRetryDelays.removeAll()
    }

    private func nextMessageStreamSnapshotRetryDelay(after current: UInt64?) -> UInt64 {
        switch current {
        case nil, 0:
            1_000_000_000
        case 1_000_000_000:
            2_000_000_000
        case 2_000_000_000:
            5_000_000_000
        case 5_000_000_000:
            10_000_000_000
        default:
            30_000_000_000
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
    private func reconcileConversationSummaryReadModel(
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

    private func fetchAndApplyConversationSummaries(
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

    private func fetchAndReplaceConversationSummaries(
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

    private func resolveReplyJumpIfPossible(
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

    private func resumeRecoverableMediaUpload(
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

    private func resolvedMediaFilename(for fileURL: URL, filename: String?) -> String {
        let provided = filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !provided.isEmpty {
            return provided
        }
        return fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedMediaByteSize(for fileURL: URL, byteSize: Int64?) throws -> Int64 {
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
