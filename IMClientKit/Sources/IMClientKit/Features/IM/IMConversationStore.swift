import Combine
import Foundation

public struct IMActiveMessageStreamTarget: Equatable, Hashable, Sendable {
    public let conversationID: String
    public let messageID: String
    public let streamID: String

    public init(conversationID: String, messageID: String, streamID: String) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.streamID = streamID
    }
}

@MainActor
public final class IMConversationStore: ObservableObject {
    @Published public internal(set) var conversations: [IMConversation] = []
    @Published public internal(set) var selectedConversationID: String?
    @Published public internal(set) var statusMessage: String?
    @Published public internal(set) var isLoadingConversations = false
    @Published public internal(set) var conversationSummaryNextCursor: String?
    @Published public internal(set) var hasMoreConversationSummaries = false
    @Published public internal(set) var isLoadingMoreConversationSummaries = false
    @Published public internal(set) var isLoadingMembers = false
    @Published public internal(set) var memberPageStates: [String: IMConversationMemberPageState] = [:]
    @Published public internal(set) var receiptSummaries: [String: IMConversationReceiptSummaryResponseBody] = [:]
    @Published public internal(set) var isLoadingMessages = false
    @Published public internal(set) var searchText = ""
    @Published public internal(set) var replyJumpConversationID: String?
    @Published public internal(set) var replyJumpTargetMessageID: String?
    @Published public internal(set) var replyJumpMatchedMessageID: String?
    @Published public internal(set) var replyJumpState: IMReplyJumpState = .idle

    let listReadModel = ConversationListReadModel()
    private let conversationListStore = ConversationListStore()
    var detailState = ConversationDetailState()
    var outgoingQueueState = OutgoingQueueState()
    var conversationSearchState = ConversationSearchState()
    private let messageTimelineState = MessageTimelineState()
    private let conversationTimelineStore = ConversationTimelineStore()
    private let messageDerivedStateReducer = MessageDerivedStateReducer()
    private var pendingStreamSnapshotTargets: Set<IMActiveMessageStreamTarget> = []

    public init() { }

    public func openConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return
        }

        _ = ensureConversationIndex(for: trimmedID)
        selectedConversationID = trimmedID
        statusMessage = nil
        sortConversations()
    }

    public func replaceConversationSummaries(_ responses: [IMConversationSummaryResponseBody]) {
        applyConversationSummaryContents(responses)
    }

    public func applyConversationSummaryPage(_ responses: [IMConversationSummaryResponseBody]) {
        for response in responses {
            upsertConversationSummaryContent(response)
        }
    }

    public func applyConversationSummaryChanges(
        upserts: [IMConversationSummaryResponseBody],
        removedConversationIDs: [UUID]
    ) {
        conversationListStore.applySummaryChanges(
            upserts: upserts,
            removedConversationIDs: removedConversationIDs,
            conversations: &conversations,
            selectedConversationID: &selectedConversationID
        ) { response, conversations in
            upsertConversationSummaryContent(response, conversations: &conversations)
        }
        let remainingConversationIDs = Set(conversations.map(\.id))
        for removedConversationID in removedConversationIDs.map(\.uuidString)
            where !remainingConversationIDs.contains(removedConversationID) {
            detailState.removeConversation(id: removedConversationID)
        }
        syncReplyJumpState()
        statusMessage = nil
        sortConversations()
    }

    public func replaceConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        let pagination = conversationListStore.replaceSummaryWindow(
            responses,
            conversations: &conversations,
            selectedConversationID: &selectedConversationID,
            nextCursor: nextCursor,
            hasMore: hasMore
        ) { response, existing in
            conversationSummary(from: response, existing: existing)
        }

        conversationSummaryNextCursor = pagination.nextCursor
        hasMoreConversationSummaries = pagination.hasMore
        isLoadingMoreConversationSummaries = false
        statusMessage = nil
        sortConversations()
    }

    public func appendConversationSummaryWindow(
        _ responses: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool
    ) {
        let pagination = conversationListStore.appendSummaryWindow(
            responses,
            conversations: &conversations,
            nextCursor: nextCursor,
            hasMore: hasMore
        ) { response, conversations in
            upsertConversationSummaryContent(response, conversations: &conversations)
        }

        conversationSummaryNextCursor = pagination.nextCursor
        hasMoreConversationSummaries = pagination.hasMore
        isLoadingMoreConversationSummaries = false
        statusMessage = nil
        sortConversations()
    }

    public func removeConversationSummaries(notIn conversationIDs: Set<String>) {
        let trimmedIDs = Set(
            conversationIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        conversations.removeAll { !trimmedIDs.contains($0.id) }

        if let selectedConversationID, !trimmedIDs.contains(selectedConversationID) {
            self.selectedConversationID = conversations.first?.id
        }
    }

    public func applyConversationSummaryContents(_ responses: [IMConversationSummaryResponseBody]) {
        let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let serverIDs = Set(responses.map { $0.id.uuidString })
        let previousSelectedConversationID = selectedConversationID

        var merged = responses.map { response in
            let conversationID = response.id.uuidString
            let existing = existingByID[conversationID]
            let conversationKind = IMConversationKind(rawValue: response.kind) ?? .group
            let directPeer = directPeer(from: response, conversationKind: conversationKind)
            let previewText = messageDerivedStateReducer.mergedSummaryPreviewText(
                existing: existing,
                responseLastMessage: response.lastMessage
            )

            return IMConversation(
                id: conversationID,
                title: normalizedTitle(
                    response.title,
                    conversationID: conversationID,
                    conversationKind: conversationKind,
                    directPeer: directPeer
                ),
                kind: conversationKind,
                directMessagingState: directMessagingState(
                    from: response.directMessagingState,
                    conversationKind: conversationKind
                ),
                directPeer: directPeer,
                notice: response.notice,
                avatarPreset: response.avatarPreset,
                muteAll: response.muteAll,
                memberCount: response.memberCount,
                memberUserIDs: response.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
                members: existing?.members ?? [],
                messages: existing?.messages ?? [],
                lastMessagePreviewText: previewText,
                hasMoreHistory: existing?.hasMoreHistory ?? false,
                serverLastReadSequence: UInt64(response.lastReadSequence),
                serverUnreadCount: response.unreadCount,
                localUnreadDelta: existing?.localUnreadDelta ?? 0,
                isPinned: response.isPinned,
                pinnedAt: response.pinnedAt,
                isMuted: response.isMuted,
                draftText: existing?.draftText ?? "",
                draftUpdatedAt: existing?.draftUpdatedAt,
                updatedAt: response.updatedAt
            )
        }

        merged.append(contentsOf: conversations.filter { !serverIDs.contains($0.id) })
        conversations = merged

        if let previousSelectedConversationID,
           conversations.contains(where: { $0.id == previousSelectedConversationID }) {
            selectedConversationID = previousSelectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        statusMessage = nil
        sortConversations()
    }

    public func applyConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        upsertConversationSummaryContent(response)
    }

    public func removeConversation(id: String) {
        let previousConversationIDs = Set(conversations.map(\.id))
        conversationListStore.removeConversation(
            id: id,
            conversations: &conversations,
            selectedConversationID: &selectedConversationID
        )
        let removedConversationIDs = previousConversationIDs.subtracting(Set(conversations.map(\.id)))
        for removedConversationID in removedConversationIDs {
            detailState.removeConversation(id: removedConversationID)
        }
        syncReplyJumpState()
        sortConversations()
    }

    public func markConversationRead(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedID })
        else {
            return
        }

        if let latestLoadedSequence = latestLoadedServerSequence(for: trimmedID) {
            conversations[index].serverLastReadSequence = latestLoadedSequence
        }
        resetUnreadState(for: index)
    }

    public func applyServerSummaryReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        conversationListStore.applyServerSummaryReadState(
            lastReadSequence: lastReadSequence,
            unreadCount: unreadCount,
            for: conversationID,
            conversations: &conversations
        ) { conversationID, previousLastRead, previousUnread, previousDelta, updatedLastRead, updatedUnread in
            reconciledLocalUnreadDelta(
                for: conversationID,
                previousServerLastReadSequence: previousLastRead,
                previousServerUnreadCount: previousUnread,
                previousLocalUnreadDelta: previousDelta,
                updatedServerLastReadSequence: updatedLastRead,
                updatedServerUnreadCount: updatedUnread
            )
        }
    }

    public func removeMessages(ids messageIDs: Set<String>, from conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
              !messageIDs.isEmpty
        else {
            return
        }
        conversations[index].messages.removeAll { message in
            messageIDs.contains(message.id) ||
                message.serverMessageID.map(messageIDs.contains) == true
        }
        conversations[index].lastMessagePreviewText = messageTimelineState.latestPreviewText(
            in: conversations[index].messages,
            fallback: ""
        )
        conversations[index].updatedAt = messageTimelineState.latestUpdatedAt(
            in: conversations[index].messages,
            fallback: conversations[index].updatedAt
        )
    }

    public func clearMessages(in conversationID: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        conversations[index].messages.removeAll()
        conversations[index].lastMessagePreviewText = ""
        conversations[index].serverUnreadCount = 0
        conversations[index].localUnreadDelta = 0
    }

    public func applyServerSummaryReadStates(_ responses: [IMConversationSummaryResponseBody]) {
        for response in responses {
            applyServerSummaryReadState(response)
        }
    }

    public func applyServerSummaryReadState(_ response: IMConversationSummaryResponseBody) {
        applyServerSummaryReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.id.uuidString
        )
    }

    public func applyServerExplicitReadResponse(_ response: IMConversationReadResponseBody) {
        applyServerReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.conversationID.uuidString
        )
    }

    public func applyServerReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverLastReadSequence = lastReadSequence
        conversations[index].serverUnreadCount = max(0, unreadCount)
        conversations[index].localUnreadDelta = 0
    }

    public func applyRealtimeUnreadIncrement(for conversationID: String) {
        conversationListStore.applyRealtimeUnreadIncrement(
            for: conversationID,
            conversations: &conversations,
            selectedConversationID: selectedConversationID
        ) { index, conversations in
            resetUnreadState(for: index, conversations: &conversations)
        }
    }

    public func applyServerUnreadCount(_ unreadCount: Int, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverUnreadCount = max(0, unreadCount)
    }

    public func applyConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        currentUserID: UUID
    ) -> IMConversationEventApplyOutcome {
        let conversationID = payload.conversation.id.uuidString
        let selectedConversationIDBeforeApply = selectedConversationID

        switch payload.eventType {
        case .conversationCreated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil
            )

        case .membersAdded, .memberLeft, .membersUpdated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil
            )

        case .conversationRemovedForSelf:
            removeConversation(id: conversationID)
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .messageStreamStarted,
             .messageStreamChunk,
             .messageStreamCompleted,
             .messageStreamFailed,
             .messageStreamCancelled:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            applyMessageStreamEvent(payload, currentUserID: currentUserID)
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .summaryUpdated, .conversationSettingsChanged, .inviteChanged:
            // summary 与 timeline 允许短暂错位；这里只收敛列表权威字段，不假设消息窗口同步刷新。
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .messageFavoriteChanged:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            if payload.favoriteChangedMessageID != nil || payload.isFavorited != nil {
                statusMessage = nil
            }
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .messageVisibilityChanged:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            var eventMessageIDs = Set(payload.messageIDs.map(\.uuidString))
            if let message = payload.message {
                eventMessageIDs.insert(message.id.uuidString)
            }
            if !eventMessageIDs.isEmpty {
                removeMessages(
                    ids: eventMessageIDs,
                    from: conversationID
                )
            }
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .conversationVisibilityChanged:
            switch payload.visibilityAction {
            case .conversationCleared:
                applyConversationSummaryContent(payload.conversation)
                applyServerSummaryReadState(payload.conversation)
                clearMessages(in: conversationID)
            case .conversationDeleted:
                removeConversation(id: conversationID)
            case .messageHidden, .none:
                removeConversation(id: conversationID)
            }
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .messageUpdated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            if let message = payload.message {
                applyUpdatedMessage(message, currentUserID: currentUserID)
            }
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .messageRecalled:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            if let message = payload.message {
                applyRecalledMessage(message, currentUserID: currentUserID)
            }
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)
        }
    }

    public func replaceMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        conversationTimelineStore.replaceMessages(
            in: conversationID,
            messages: responses,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            mergeMessages: mergeMessages,
            hasOlderHistory: hasOlderHistory,
            refreshLoadedMessageCursors: refreshLoadedMessageCursors
        )
        statusMessage = nil
        sortConversations()
    }

    public func appendMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        conversationTimelineStore.appendMessages(
            in: conversationID,
            messages: responses,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            mergeMessages: mergeMessages,
            refreshLatestSyncedCursor: refreshLatestSyncedCursor
        )
        statusMessage = nil
        sortConversations()
    }

    public func replaceMembers(
        in conversationID: String,
        members responses: [IMConversationMemberResponseBody]
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let members = Self.members(from: responses)
            .sorted(by: sortMembers)

        conversations[index].members = members
        conversations[index].memberUserIDs = members.map(\.id).sorted { $0.uuidString < $1.uuidString }
        conversations[index].memberCount = members.count
        statusMessage = nil
    }

    public func applyMemberPage(
        _ response: IMConversationMemberPageResponseBody,
        in conversationID: String,
        query: String,
        appending: Bool
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let newMembers = Self.members(from: response.items)
        let previousItems = appending ? memberPageStates[trimmedConversationID]?.items ?? [] : []
        let mergedMembers = Self.uniqueMembers(previousItems + newMembers)

        memberPageStates[trimmedConversationID] = IMConversationMemberPageState(
            items: mergedMembers,
            query: query,
            nextCursor: response.nextCursor,
            total: response.total,
            limit: response.limit,
            isLoading: false,
            isLoadingMore: false
        )

        let index = ensureConversationIndex(for: trimmedConversationID)
        let sortedMembers = mergedMembers.sorted(by: sortMembers)
        conversations[index].members = sortedMembers
        conversations[index].memberUserIDs = sortedMembers.map(\.id).sorted { $0.uuidString < $1.uuidString }
        conversations[index].memberCount = response.total
        statusMessage = nil
    }

    public func setMemberPageLoading(
        conversationID: String,
        query: String,
        isLoading: Bool,
        isLoadingMore: Bool = false
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        var state = memberPageStates[trimmedConversationID] ?? IMConversationMemberPageState(query: query)
        state.query = query
        state.isLoading = isLoading
        state.isLoadingMore = isLoadingMore
        memberPageStates[trimmedConversationID] = state
        setLoadingMembers(isLoading || isLoadingMore)
    }

    public func memberPageState(for conversationID: String) -> IMConversationMemberPageState {
        memberPageStates[conversationID] ?? IMConversationMemberPageState()
    }

    public func setReceiptSummary(
        _ summary: IMConversationReceiptSummaryResponseBody,
        for conversationID: String
    ) {
        receiptSummaries[conversationID] = summary
    }

    public func receiptSummary(for conversationID: String) -> IMConversationReceiptSummaryResponseBody? {
        receiptSummaries[conversationID]
    }

    public func updateDraft(_ text: String, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].draftText = text
        conversations[index].draftUpdatedAt = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Date()
    }

    public func draftText(for conversationID: String) -> String {
        conversations.first(where: { $0.id == conversationID })?.draftText ?? ""
    }

    public func applyConversationPreferences(
        conversationID: String,
        isPinned: Bool,
        pinnedAt: Date?,
        isMuted: Bool
    ) {
        conversationListStore.applyConversationPreferences(
            conversationID: conversationID,
            isPinned: isPinned,
            pinnedAt: pinnedAt,
            isMuted: isMuted,
            conversations: &conversations
        )
        sortConversations()
    }

    public func applyConversationMetadata(
        conversationID: String,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?
    ) {
        conversationListStore.applyConversationMetadata(
            conversationID: conversationID,
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            conversations: &conversations
        )
        sortConversations()
    }

    public func prependMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        conversationTimelineStore.prependMessages(
            in: conversationID,
            messages: responses,
            currentUserID: currentUserID,
            conversations: &conversations,
            ensureConversationIndex: ensureConversationIndex,
            makeMessages: makeMessages,
            mergeMessages: mergeMessages,
            hasOlderHistory: hasOlderHistory,
            refreshLoadedMessageCursors: refreshLoadedMessageCursors
        )
        statusMessage = nil
        sortConversations()
    }

    public func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID
    ) -> IMOutgoingMessageRequest? {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        ).request
    }

    @discardableResult
    public func queueOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ).placeholder != nil
    }

    public func prepareOutgoingReply(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID
    ) -> IMOutgoingMessageRequest? {
        prepareOutgoingMessage(
            .reply(
                reference: reference,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        ).request
    }

    @discardableResult
    public func queueOutgoingReply(
        reference: IMReplyReference,
        text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        prepareOutgoingMessage(
            .reply(
                reference: reference,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ).placeholder != nil
    }

    public func stageOutgoingMediaUpload(
        asset: IMMediaAsset,
        conversationID: String,
        senderUserID: UUID,
        sourceFileURL: URL
    ) -> IMOutgoingMediaPlaceholder? {
        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return nil
        }

        return appendOutgoingMessage(
            content,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .preparing(message: "正在准备上传附件。"),
            shouldRegisterPendingRequest: false,
            localTransferState: IMMessageLocalTransferState(sourceFilePath: sourceFileURL.path)
        ).placeholder
    }

    public func markOutgoingPreparing(localMessageID: String, message: String, uploadID: String? = nil) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .preparing(message: message)
            if let uploadID, let transferState = item.localTransferState {
                item.localTransferState = transferState.withUploadID(uploadID)
            }
        }
    }

    public func markOutgoingUploading(localMessageID: String, message: String, uploadID: String? = nil) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .uploading(message: message)
            if let uploadID, let transferState = item.localTransferState {
                item.localTransferState = transferState.withUploadID(uploadID)
            }
        }
    }

    public func markOutgoingUploadFailed(localMessageID: String, message: String) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
        }
        statusMessage = message
    }

    public func abandonRecoverableOutgoingMediaUpload(localMessageID: String, message: String) {
        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
            item.localTransferState = nil
        }
        statusMessage = message
    }

    public func updateLocalDownloadState(
        messageID: String,
        state: IMMessageLocalDownloadState?
    ) {
        mutateMessage(id: messageID) { item in
            item.localDownloadState = state
            if let taskID = state?.taskID {
                item.transferTaskID = taskID
            }
        }
    }

    public func prepareUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        updateUploadedOutgoingMedia(
            asset: asset,
            localMessageID: localMessageID,
            conversationID: conversationID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        ).request
    }

    @discardableResult
    public func queueUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        updateUploadedOutgoingMedia(
            asset: asset,
            localMessageID: localMessageID,
            conversationID: conversationID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ).didUpdate
    }

    public func recoverableOutgoingMediaUploads() -> [IMRecoverableOutgoingMediaUpload] {
        conversations.flatMap { conversation in
            conversation.messages.compactMap { message in
                guard let transferState = message.localTransferState,
                      let asset = message.mediaAsset,
                      message.isRecoverableOutgoingMediaUpload,
                      message.serverMessageID == nil,
                      message.serverSequence == nil
                else {
                    return nil
                }

                return IMRecoverableOutgoingMediaUpload(
                    localMessageID: message.id,
                    conversationID: conversation.id,
                    asset: asset,
                    transferState: transferState,
                    deliveryState: message.deliveryState
                )
            }
        }
    }

    private func prepareOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        appendOutgoingMessage(
            content,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: deliveryState,
            shouldRegisterPendingRequest: shouldRegisterPendingRequest,
            localTransferState: localTransferState
        )
    }

    private func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            statusMessage = "消息内容不能为空。"
            return (nil, nil)
        }

        return prepareOutgoingMessage(
            .text(trimmedText),
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: deliveryState,
            shouldRegisterPendingRequest: shouldRegisterPendingRequest
        )
    }

    public func retryOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息重试失败：会话或消息无效。"
            return nil
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息重试失败：本地消息不存在。"
            return nil
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable else {
            statusMessage = "只能重试自己发送的消息。"
            return nil
        }

        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可重试。"
            return nil
        }

        let clientMessageID = message.clientMessageID ?? message.id
        let requestID = UUID()
        message.deliveryState = .sending
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: message.content
            )
        )
    }

    @discardableResult
    public func queueRetryableOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        message queueMessage: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息排队失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息排队失败：本地消息不存在。"
            return false
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可排队重试。"
            return false
        }

        outgoingQueueState.removePendingRequests(for: message.id)
        message.deliveryState = .queued(message: queueMessage)
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    @discardableResult
    public func cancelQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "取消发送失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "取消发送失败：本地消息不存在。"
            return false
        }

        let message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.content.isUserComposable, message.isQueued else {
            statusMessage = "只能取消尚未发送的消息。"
            return false
        }

        outgoingQueueState.removePendingRequests(for: message.id)
        conversations[conversationIndex].messages.remove(at: messageIndex)
        refreshConversationPresentationAfterLocalMessageRemoval(at: conversationIndex)
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    public func queuedOutgoingMessageRequests(limit: Int) -> [IMOutgoingMessageRequest] {
        let limitedCount = max(0, limit)
        guard limitedCount > 0 else {
            return []
        }

        var queuedMessages: [(conversationID: String, message: IMConversationMessage)] = []
        for conversation in conversations {
            for message in conversation.messages
                where message.direction == .outgoing && message.content.isUserComposable && message.isQueued {
                queuedMessages.append((conversation.id, message))
            }
        }

        queuedMessages.sort { left, right in
            if left.message.createdAt == right.message.createdAt {
                return left.message.id < right.message.id
            }
            return left.message.createdAt < right.message.createdAt
        }

        var requests: [IMOutgoingMessageRequest] = []
        for (conversationID, queuedMessage) in queuedMessages.prefix(limitedCount) {
            guard let request = startQueuedOutgoingMessage(
                localMessageID: queuedMessage.id,
                conversationID: conversationID
            ) else {
                continue
            }
            requests.append(request)
        }

        return requests
    }

    public func markOutgoingQueued(requestID: UUID, message: String) {
        guard let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            return
        }

        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .queued(message: message)
            item.serverMessageID = nil
            item.serverSequence = nil
        }
    }

    public func isRetryableFailure(_ message: IMConversationMessage) -> Bool {
        guard message.direction == .outgoing else {
            return false
        }

        switch message.deliveryState {
        case .preparing, .uploading, .uploaded:
            return false
        case .queued, .unknown:
            return true
        case .failed(let failureMessage):
            return !Self.nonRetryableOutgoingFailureMessages.contains(failureMessage)
        case .sending, .sent, .received:
            return false
        }
    }

    func queueSummary(for messages: [IMConversationMessage]) -> IMConversationQueueSummary {
        var queuedCount = 0
        var sendingCount = 0
        var retryableIssueCount = 0

        for message in messages where message.direction == .outgoing {
            switch message.deliveryState {
            case .preparing, .uploading, .uploaded:
                sendingCount += 1
            case .queued:
                queuedCount += 1
            case .sending:
                sendingCount += 1
            case .unknown:
                retryableIssueCount += 1
            case .failed:
                if isRetryableFailure(message) {
                    retryableIssueCount += 1
                }
            case .sent, .received:
                break
            }
        }

        return IMConversationQueueSummary(
            queuedCount: queuedCount,
            sendingCount: sendingCount,
            retryableIssueCount: retryableIssueCount
        )
    }

    public func applyOutgoingAcknowledgement(requestID: UUID?, payload: IMTCPAckPayload) {
        guard let requestID, let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            return
        }

        mutateMessage(id: localMessageID) { message in
            message.serverMessageID = payload.messageID
            if payload.status == "accepted" {
                message.deliveryState = .sent
            } else {
                let failureMessage = outgoingAcknowledgementFailureMessage(for: payload.status)
                message.deliveryState = .failed(message: failureMessage)
                statusMessage = failureMessage
            }
        }
    }

    public func markOutgoingFailure(requestID: UUID, message: String) {
        guard let localMessageID = outgoingQueueState.removePendingRequest(requestID) else {
            statusMessage = message
            return
        }

        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
        }
        statusMessage = message
    }

    public func markAllPendingMessagesFailed(message: String) {
        let pendingMessageIDs = outgoingQueueState.drainPendingMessageIDs()

        for localMessageID in pendingMessageIDs {
            mutateMessage(id: localMessageID) { item in
                item.deliveryState = .failed(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    public func markAllPendingMessagesUnknown(message: String) {
        let pendingMessageIDs = outgoingQueueState.drainPendingMessageIDs()

        for localMessageID in pendingMessageIDs {
            mutateMessage(id: localMessageID) { item in
                item.deliveryState = .unknown(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    public func receiveIncomingMessage(_ payload: IMTCPMessagePayload, currentUserID: UUID) {
        let index = ensureConversationIndex(for: payload.conversationID)
        let stableMessageID = payload.messageID ?? payload.clientMessageID ?? UUID().uuidString
        let effectiveTimestamp = payload.serverTimestamp ?? Date()

        if payload.senderUserID == currentUserID,
           let clientMessageID = payload.clientMessageID,
           let existingIndex = conversations[index].messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) {
            conversations[index].messages[existingIndex].serverMessageID = payload.messageID
            conversations[index].messages[existingIndex].serverSequence = payload.serverSequence
            conversations[index].messages[existingIndex].createdAt = effectiveTimestamp
            conversations[index].messages[existingIndex].deliveryState = .sent
            conversations[index].updatedAt = effectiveTimestamp
            conversations[index].lastMessagePreviewText = conversations[index].messages[existingIndex].text
            refreshLatestSyncedCursor(
                for: payload.conversationID,
                messages: conversations[index].messages
            )
            sortConversations()
            return
        }

        let alreadyExists = conversations[index].messages.contains {
            $0.id == stableMessageID
                || ($0.serverMessageID != nil && $0.serverMessageID == payload.messageID)
                || ($0.clientMessageID != nil && $0.clientMessageID == payload.clientMessageID)
        }
        guard !alreadyExists else {
            return
        }

        let message = IMConversationMessage(
            id: stableMessageID,
            conversationID: payload.conversationID,
            clientMessageID: payload.clientMessageID,
            serverMessageID: payload.messageID,
            senderUserID: payload.senderUserID,
            serverSequence: payload.serverSequence,
            content: payload.content,
            derivedState: payload.derivedState,
            direction: payload.senderUserID == currentUserID ? .outgoing : .incoming,
            createdAt: effectiveTimestamp,
            deliveryState: payload.senderUserID == currentUserID ? .sent : .received
        )

        conversations[index].messages.append(message)
        conversations[index].lastMessagePreviewText = message.text
        conversations[index].updatedAt = message.createdAt
        refreshLatestSyncedCursor(
            for: payload.conversationID,
            messages: conversations[index].messages
        )

        applyIncomingMessageUnreadState(for: payload.conversationID)

        statusMessage = nil
        sortConversations()
    }

    public func applyRecalledMessage(
        _ response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) {
        applyUpdatedMessage(response, currentUserID: currentUserID)
    }

    public func applyUpdatedMessage(
        _ response: IMConversationMessageResponseBody,
        currentUserID: UUID
    ) {
        let conversationID = response.conversationID.uuidString
        let stableMessageID = response.id.uuidString
        let effectiveTimestamp = response.createdAt ?? Date()
        let index = ensureConversationIndex(for: conversationID)

        if let messageIndex = conversations[index].messages.firstIndex(where: {
            $0.id == stableMessageID || $0.serverMessageID == stableMessageID
        }) {
            conversations[index].messages[messageIndex].serverMessageID = stableMessageID
            conversations[index].messages[messageIndex].serverSequence = UInt64(response.serverSequence)
            conversations[index].messages[messageIndex].senderUserID = response.senderUserID
            conversations[index].messages[messageIndex].content = response.content
            conversations[index].messages[messageIndex].derivedState = response.derivedState
            conversations[index].messages[messageIndex].createdAt = effectiveTimestamp
            conversations[index].messages[messageIndex].deliveryState =
                conversations[index].messages[messageIndex].direction == .outgoing ? .sent : .received
        } else {
            conversations[index].messages.append(
                IMConversationMessage(
                    id: stableMessageID,
                    conversationID: conversationID,
                    clientMessageID: response.clientMessageID,
                    serverMessageID: stableMessageID,
                    senderUserID: response.senderUserID,
                    serverSequence: UInt64(response.serverSequence),
                    content: response.content,
                    derivedState: response.derivedState,
                    direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                    createdAt: effectiveTimestamp,
                    deliveryState: response.senderUserID == currentUserID ? .sent : .received
                )
            )
        }

        conversations[index].messages.sort(by: Self.messageComparator)
        conversations[index].lastMessagePreviewText = conversations[index].messages.last?.text
            ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = max(conversations[index].updatedAt, effectiveTimestamp)
        sortConversations()
    }

    public func applyMessageStreamEvent(
        _ payload: IMTCPConversationEventPayload,
        currentUserID: UUID
    ) {
        if let message = payload.message {
            applyUpdatedMessage(message, currentUserID: currentUserID)
        }

        guard let stream = payload.stream else {
            return
        }

        let conversationID = stream.conversationID
        let index = ensureConversationIndex(for: conversationID)
        guard let messageIndex = conversations[index].messages.firstIndex(where: { message in
            message.serverMessageID == stream.messageID ||
                message.id == stream.messageID ||
                message.derivedState.streamState?.streamID == stream.streamID
        }) else {
            return
        }

        var message = conversations[index].messages[messageIndex]
        let existingStreamState = message.derivedState.streamState
        if existingStreamState?.state.isTerminal == true, stream.state == .streaming {
            return
        }
        if let existingStreamState,
           stream.state == .streaming,
           stream.chunkIndex <= existingStreamState.lastChunkIndex {
            return
        }
        if let existingStreamState,
           stream.state == .streaming,
           stream.chunkIndex > existingStreamState.lastChunkIndex + 1 {
            pendingStreamSnapshotTargets.insert(
                IMActiveMessageStreamTarget(
                    conversationID: conversationID,
                    messageID: stream.messageID,
                    streamID: stream.streamID
                )
            )
            return
        }
        if existingStreamState == nil,
           stream.state == .streaming,
           stream.chunkIndex > 1 {
            pendingStreamSnapshotTargets.insert(
                IMActiveMessageStreamTarget(
                    conversationID: conversationID,
                    messageID: stream.messageID,
                    streamID: stream.streamID
                )
            )
            return
        }

        let existingText = message.content.presentation(derivedState: message.derivedState).textValue ?? ""
        let nextText: String
        if let deltaText = stream.deltaText, stream.state == .streaming {
            nextText = existingText + deltaText
        } else {
            nextText = existingText
        }

        message.content = .text(nextText)
        message.derivedState = MessageDerivedState(
            recallState: message.derivedState.recallState,
            edits: message.derivedState.edits,
            reactions: message.derivedState.reactions,
            streamState: MessageStreamState(
                streamID: stream.streamID,
                state: stream.state,
                lastChunkIndex: stream.chunkIndex,
                partialText: nextText,
                updatedAt: stream.serverTimestamp
            )
        )
        conversations[index].messages[messageIndex] = message
        conversations[index].lastMessagePreviewText = message.text
        conversations[index].updatedAt = max(conversations[index].updatedAt, stream.serverTimestamp)
        sortConversations()
    }

    public func applyMessageStreamSnapshot(
        _ response: IMMessageStreamResponseBody,
        currentUserID: UUID
    ) {
        applyUpdatedMessage(response.message, currentUserID: currentUserID)
        pendingStreamSnapshotTargets.remove(
            IMActiveMessageStreamTarget(
                conversationID: response.message.conversationID.uuidString,
                messageID: response.message.id.uuidString,
                streamID: response.stream.streamID
            )
        )
    }

    public func activeMessageStreamTargets() -> [IMActiveMessageStreamTarget] {
        conversations.flatMap { conversation in
            conversation.messages.compactMap { message in
                guard let streamState = message.derivedState.streamState,
                      streamState.state == .streaming
                else {
                    return nil
                }
                return IMActiveMessageStreamTarget(
                    conversationID: conversation.id,
                    messageID: message.serverMessageID ?? message.id,
                    streamID: streamState.streamID
                )
            }
        }
    }

    public func consumePendingStreamSnapshotTargets() -> [IMActiveMessageStreamTarget] {
        let targets = Array(pendingStreamSnapshotTargets)
        pendingStreamSnapshotTargets.removeAll()
        return targets
    }

    public func hasLoadedMessages(for conversationID: String) -> Bool {
        detailState.hasLoadedMessages(for: conversationID)
    }

    public func canLoadOlderMessages(for conversationID: String) -> Bool {
        conversations.first(where: { $0.id == conversationID })?.hasMoreHistory ?? false
    }

    public func oldestLoadedServerSequence(for conversationID: String) -> UInt64? {
        detailState.oldestLoadedServerSequence(
            for: conversationID,
            conversations: conversations
        )
    }

    public func syncCursor(for conversationID: String) -> IMSyncCursorState? {
        detailState.syncCursor(
            for: conversationID,
            conversations: conversations
        )
    }

    public func setLatestSyncedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        detailState.setLatestSyncedServerSequence(sequence, for: trimmedConversationID)
    }

    public func setOldestLoadedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        detailState.setOldestLoadedServerSequence(sequence, for: trimmedConversationID)
    }

    public func trimCachedMessageWindow(limit: Int = IMConversationCacheSnapshot.cachedMessageLimit) {
        let effectiveLimit = max(0, limit)
        for index in conversations.indices {
            conversations[index].messages = trimmedCachedMessages(
                conversations[index].messages,
                limit: effectiveLimit
            )
            refreshLoadedMessageCursors(
                for: conversations[index].id,
                messages: conversations[index].messages
            )
        }
    }

    public func latestLoadedServerSequence(for conversationID: String) -> UInt64? {
        detailState.latestLoadedServerSequence(
            for: conversationID,
            conversations: conversations
        )
    }

    public func gapSyncTargets(from summaries: [IMConversationSummaryResponseBody]) -> [String] {
        summaries.compactMap { summary in
            let conversationID = summary.id.uuidString
            let serverLatestSequence = UInt64(max(0, summary.lastMessage?.serverSequence ?? 0))
            guard
                let localLatestSequence = latestLoadedServerSequence(for: conversationID),
                serverLatestSequence > localLatestSequence
            else {
                return nil
            }

            return conversationID
        }
    }

    public func serverLastReadSequence(for conversationID: String) -> UInt64? {
        conversations.first(where: { $0.id == conversationID })?.serverLastReadSequence
    }

    public func setLoadingConversations(_ isLoading: Bool) {
        isLoadingConversations = isLoading
    }

    public func setLoadingMoreConversationSummaries(_ isLoading: Bool) {
        isLoadingMoreConversationSummaries = isLoading
    }

    public func setLoadingMembers(_ isLoading: Bool) {
        detailState.isLoadingMembers = isLoading
        isLoadingMembers = isLoading
    }

    public func setLoadingMessages(_ isLoading: Bool) {
        detailState.isLoadingMessages = isLoading
        isLoadingMessages = isLoading
    }

    public func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    public func containsConversation(id conversationID: String) -> Bool {
        conversations.contains { $0.id == conversationID }
    }

    public func localMessageID(
        matchingReferencedMessageID targetMessageID: String,
        in conversationID: String
    ) -> String? {
        conversationTimelineStore.localMessageID(
            matchingReferencedMessageID: targetMessageID,
            in: conversationID,
            conversations: conversations,
            readModel: messageTimelineState
        )
    }

    public func beginReplyJump(
        to targetMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedTargetMessageID.isEmpty else {
            return
        }

        detailState.startReplyJump(in: trimmedConversationID, targetMessageID: trimmedTargetMessageID)
        syncReplyJumpState()
    }

    public func resolveReplyJump(
        matchedMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMatchedMessageID = matchedMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMatchedMessageID.isEmpty else {
            return
        }

        detailState.resolveReplyJump(matchedMessageID: trimmedMatchedMessageID, in: trimmedConversationID)
        syncReplyJumpState()
    }

    public func exhaustReplyJump(
        to targetMessageID: String,
        in conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTargetMessageID = targetMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedTargetMessageID.isEmpty else {
            return
        }

        detailState.exhaustReplyJump(in: trimmedConversationID, targetMessageID: trimmedTargetMessageID)
        syncReplyJumpState()
    }

    public func clearReplyJump() {
        detailState.clearReplyJump()
        syncReplyJumpState()
    }

    public func makeCacheSnapshot(
        lastSummaryRefreshAt: Date?,
        summarySyncToken: String? = nil,
        transferSnapshots: [IMTransferSnapshot] = []
    ) -> IMConversationCacheSnapshot {
        ConversationCacheSnapshotMapper.makeSnapshot(
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            detailState: detailState,
            lastSummaryRefreshAt: lastSummaryRefreshAt,
            summarySyncToken: summarySyncToken,
            summaryNextCursor: conversationSummaryNextCursor,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            transferSnapshots: transferSnapshots,
            trimMessages: { messages, limit in
                trimmedCachedMessages(messages, limit: limit)
            }
        )
    }

    public func restoreCacheSnapshot(_ snapshot: IMConversationCacheSnapshot) {
        let restoredState = ConversationCacheSnapshotMapper.restore(
            from: snapshot,
            restoreDeliveryState: Self.restoredDeliveryState(_:)
        )
        conversations = restoredState.conversations
        selectedConversationID = restoredState.selectedConversationID
        detailState = restoredState.detailState
        conversationSummaryNextCursor = snapshot.metadata.summaryNextCursor
        hasMoreConversationSummaries = snapshot.metadata.hasMoreConversationSummaries
        isLoadingMoreConversationSummaries = false
        isLoadingMembers = detailState.isLoadingMembers
        isLoadingMessages = detailState.isLoadingMessages

        statusMessage = nil
        syncReplyJumpState()
        sortConversations()
    }

    private func ensureConversationIndex(for conversationID: String) -> Int {
        ensureConversationIndex(for: conversationID, conversations: &conversations)
    }

    private func ensureConversationIndex(
        for conversationID: String,
        conversations: inout [IMConversation]
    ) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }

        let conversation = IMConversation(
            id: conversationID,
            title: fallbackTitle(for: conversationID),
            kind: .group,
            directMessagingState: nil,
            directPeer: nil,
            notice: nil,
            avatarPreset: nil,
            memberCount: 0,
            memberUserIDs: [],
            members: [],
            messages: [],
            lastMessagePreviewText: "暂无消息",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            isPinned: false,
            pinnedAt: nil,
            isMuted: false,
            draftText: "",
            draftUpdatedAt: nil,
            updatedAt: .distantPast
        )
        conversations.append(conversation)
        return conversations.count - 1
    }

    private func upsertConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        upsertConversationSummaryContent(response, conversations: &conversations)
        statusMessage = nil
        sortConversations()
    }

    private func upsertConversationSummaryContent(
        _ response: IMConversationSummaryResponseBody,
        conversations: inout [IMConversation]
    ) {
        let conversationID = response.id.uuidString
        let index = ensureConversationIndex(for: conversationID, conversations: &conversations)
        conversations[index] = conversationSummary(
            from: response,
            existing: conversations[index]
        )
    }

    private func conversationSummary(
        from response: IMConversationSummaryResponseBody,
        existing: IMConversation?
    ) -> IMConversation {
        let conversationID = response.id.uuidString
        let conversationKind = IMConversationKind(rawValue: response.kind) ?? .group
        let directPeer = directPeer(from: response, conversationKind: conversationKind)
        let previewText = messageDerivedStateReducer.mergedSummaryPreviewText(
            existing: existing,
            responseLastMessage: response.lastMessage
        )

        return IMConversation(
            id: conversationID,
            title: normalizedTitle(
                response.title,
                conversationID: conversationID,
                conversationKind: conversationKind,
                directPeer: directPeer
            ),
            kind: conversationKind,
            directMessagingState: directMessagingState(
                from: response.directMessagingState,
                conversationKind: conversationKind
            ),
            directPeer: directPeer,
            notice: response.notice,
            avatarPreset: response.avatarPreset,
            muteAll: response.muteAll,
            memberCount: response.memberCount,
            memberUserIDs: response.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            members: (existing?.members ?? []).filter { response.memberUserIDs.contains($0.id) },
            messages: existing?.messages ?? [],
            lastMessagePreviewText: previewText,
            hasMoreHistory: existing?.hasMoreHistory ?? false,
            serverLastReadSequence: UInt64(response.lastReadSequence),
            serverUnreadCount: response.unreadCount,
            localUnreadDelta: existing?.localUnreadDelta ?? 0,
            isPinned: response.isPinned,
            pinnedAt: response.pinnedAt,
            isMuted: response.isMuted,
            draftText: existing?.draftText ?? "",
            draftUpdatedAt: existing?.draftUpdatedAt,
            updatedAt: response.updatedAt
        )
    }

    private func applyIncomingMessageUnreadState(for conversationID: String) {
        if selectedConversationID == nil {
            selectedConversationID = conversationID
        }

        applyRealtimeUnreadIncrement(for: conversationID)
    }

    private func refreshLoadedMessageCursors(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        detailState.refreshLoadedMessageCursors(for: conversationID, messages: messages)
    }

    private func refreshLatestSyncedCursor(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        detailState.refreshLatestSyncedCursor(for: conversationID, messages: messages)
    }

    private func trimmedCachedMessages(
        _ messages: [IMConversationMessage],
        limit: Int
    ) -> [IMConversationMessage] {
        guard limit > 0, messages.count > limit else {
            return limit == 0 ? [] : messages
        }

        return Array(messages.suffix(limit))
    }

    private func resetUnreadState(for conversationIndex: Int) {
        resetUnreadState(for: conversationIndex, conversations: &conversations)
    }

    private func resetUnreadState(
        for conversationIndex: Int,
        conversations: inout [IMConversation]
    ) {
        conversations[conversationIndex].serverUnreadCount = 0
        conversations[conversationIndex].localUnreadDelta = 0
    }

    func syncReplyJumpState() {
        replyJumpConversationID = detailState.replyJumpConversationID
        replyJumpTargetMessageID = detailState.replyJumpTargetMessageID
        replyJumpMatchedMessageID = detailState.replyJumpMatchedMessageID
        replyJumpState = detailState.replyJumpState
    }

    private func reconciledLocalUnreadDelta(
        for conversationID: String,
        previousServerLastReadSequence: UInt64,
        previousServerUnreadCount: Int,
        previousLocalUnreadDelta: Int,
        updatedServerLastReadSequence: UInt64,
        updatedServerUnreadCount: Int
    ) -> Int {
        guard previousLocalUnreadDelta > 0 else {
            return 0
        }

        guard updatedServerUnreadCount > 0 else {
            return 0
        }

        guard latestLoadedServerSequence(for: conversationID) != nil else {
            return previousLocalUnreadDelta
        }

        let previousTotalUnreadCount = previousServerUnreadCount + previousLocalUnreadDelta
        if updatedServerLastReadSequence > previousServerLastReadSequence
            || updatedServerUnreadCount >= previousTotalUnreadCount {
            return 0
        }

        return previousLocalUnreadDelta
    }

    private func mutateMessage(id: String, update: (inout IMConversationMessage) -> Void) {
        for conversationIndex in conversations.indices {
            guard let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == id }) else {
                continue
            }

            update(&conversations[conversationIndex].messages[messageIndex])
            conversations[conversationIndex].updatedAt = messageTimelineState.latestUpdatedAt(
                in: conversations[conversationIndex].messages,
                fallback: conversations[conversationIndex].messages[messageIndex].createdAt
            )
            conversations[conversationIndex].lastMessagePreviewText = messageTimelineState.latestPreviewText(
                in: conversations[conversationIndex].messages,
                fallback: conversations[conversationIndex].lastMessagePreviewText
            )
            sortConversations()
            return
        }
    }

    private func refreshConversationPresentationAfterLocalMessageRemoval(at conversationIndex: Int) {
        guard conversations.indices.contains(conversationIndex) else {
            return
        }

        if let latestMessage = conversations[conversationIndex].messages.last {
            conversations[conversationIndex].lastMessagePreviewText = messageTimelineState.latestPreviewText(
                in: conversations[conversationIndex].messages,
                fallback: latestMessage.text
            )
            conversations[conversationIndex].updatedAt = messageTimelineState.latestUpdatedAt(
                in: conversations[conversationIndex].messages,
                fallback: latestMessage.createdAt
            )
        } else {
            conversations[conversationIndex].lastMessagePreviewText = ""
        }
    }

    private func sortConversations() {
        conversations.sort { left, right in
            if left.isPinned != right.isPinned {
                return left.isPinned && !right.isPinned
            }

            if left.isPinned && right.isPinned {
                switch (left.pinnedAt, right.pinnedAt) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs > rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }

            if left.updatedAt == right.updatedAt {
                return left.id < right.id
            }
            return left.updatedAt > right.updatedAt
        }
    }

    private func normalizedTitle(
        _ title: String?,
        conversationID: String,
        conversationKind: IMConversationKind,
        directPeer: IMDirectPeer?
    ) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        if conversationKind == .direct,
           let directPeer,
           !directPeer.email.isEmpty {
            return directPeer.email
        }
        return fallbackTitle(for: conversationID)
    }

    private func makeMessages(
        from responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) -> [IMConversationMessage] {
        responses.map { response in
            IMConversationMessage(
                id: response.id.uuidString,
                conversationID: response.conversationID.uuidString,
                clientMessageID: response.clientMessageID,
                serverMessageID: response.id.uuidString,
                senderUserID: response.senderUserID,
                serverSequence: UInt64(response.serverSequence),
                content: response.content,
                derivedState: response.derivedState,
                direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                createdAt: response.createdAt ?? .distantPast,
                deliveryState: response.senderUserID == currentUserID ? .sent : .received
            )
        }
    }

    private func mergeMessages(
        existing: [IMConversationMessage],
        serverMessages: [IMConversationMessage],
        preserveExistingServerMessages: Bool
    ) -> [IMConversationMessage] {
        var merged = preserveExistingServerMessages
            ? existing
            : existing.filter { message in
                message.serverMessageID == nil && message.serverSequence == nil
            }

        for serverMessage in serverMessages {
            if let existingIndex = merged.firstIndex(where: { Self.matches($0, serverMessage) }) {
                merged[existingIndex] = serverMessage
            } else {
                merged.append(serverMessage)
            }
        }

        return merged.sorted(by: Self.messageComparator)
    }

    private func hasOlderHistory(in serverMessages: [IMConversationMessage]) -> Bool {
        guard let oldestSequence = serverMessages.compactMap(\.serverSequence).min() else {
            return false
        }

        return oldestSequence > 1
    }

    private func sortMembers(lhs: IMConversationMember, rhs: IMConversationMember) -> Bool {
        let lhsPriority = memberRolePriority(lhs.role)
        let rhsPriority = memberRolePriority(rhs.role)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        return lhs.email < rhs.email
    }

    private static func members(from responses: [IMConversationMemberResponseBody]) -> [IMConversationMember] {
        responses.map {
            IMConversationMember(
                id: $0.id,
                email: $0.email,
                displayName: $0.displayName,
                avatarPreset: $0.avatarPreset,
                role: $0.role,
                memberNickname: $0.memberNickname,
                displayTitle: $0.displayTitle
            )
        }
    }

    private static func uniqueMembers(_ members: [IMConversationMember]) -> [IMConversationMember] {
        var seenIDs = Set<UUID>()
        var result: [IMConversationMember] = []
        for member in members where seenIDs.insert(member.id).inserted {
            result.append(member)
        }
        return result
    }

    private func memberRolePriority(_ role: IMConversationMemberRole) -> Int {
        switch role {
        case .owner:
            return 0
        case .admin:
            return 1
        case .member:
            return 2
        }
    }

    private func fallbackTitle(for conversationID: String) -> String {
        "会话 \(conversationID.prefix(8).lowercased())"
    }

    private func directMessagingState(
        from rawValue: String?,
        conversationKind: IMConversationKind
    ) -> IMDirectMessagingState? {
        guard conversationKind == .direct else {
            return nil
        }

        guard let rawValue,
              let state = IMDirectMessagingState(rawValue: rawValue)
        else {
            return .active
        }

        return state
    }

    private func directPeer(
        from response: IMConversationSummaryResponseBody,
        conversationKind: IMConversationKind
    ) -> IMDirectPeer? {
        guard conversationKind == .direct,
              let directPeer = response.directPeer
        else {
            return nil
        }

        return IMDirectPeer(
            id: directPeer.id,
            email: directPeer.email,
            displayName: directPeer.displayName,
            avatarPreset: directPeer.avatarPreset
        )
    }

    private func outgoingAcknowledgementFailureMessage(for status: String) -> String {
        switch status {
        case "direct_conversation_frozen":
            return "你们已不是好友，当前会话不能继续发送消息。"
        case "stranger_direct_message_limit_reached":
            return "你们还不是好友，对方回复前只能发送一条消息。"
        case "invalid_conversation_id":
            return "会话 ID 无效。"
        case "conversation_unavailable":
            return "会话不存在或你已不在该会话中。"
        case "unsupported_message_content":
            return "当前消息类型不支持发送。"
        case "empty_text_body":
            return "消息内容不能为空。"
        case "internal_error":
            return "消息发送失败，请稍后重试。"
        default:
            return "消息发送失败：\(status)"
        }
    }

    private static func restoredDeliveryState(_ state: IMMessageDeliveryState) -> IMMessageDeliveryState {
        switch state {
        case .sending:
            return .unknown(message: "发送状态未确认，请重试。")
        case .preparing, .uploading, .uploaded:
            return state
        case .queued, .sent, .received, .unknown, .failed:
            return state
        }
    }

    private func startQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == localMessageID })
        else {
            return nil
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.isQueued else {
            return nil
        }

        let clientMessageID = message.clientMessageID ?? message.id
        let requestID = UUID()
        message.deliveryState = .sending
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: conversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: message.content
            )
        )
    }

    private static let nonRetryableOutgoingFailureMessages: Set<String> = [
        "你们已不是好友，当前会话不能继续发送消息。",
        "你们还不是好友，对方回复前只能发送一条消息。",
        "会话 ID 无效。",
        "会话不存在或你已不在该会话中。",
        "当前消息类型不支持发送。",
        "消息内容不能为空。",
        "附件上传失败，请稍后重试。"
    ]

    private func appendOutgoingMessage(
        _ content: IMMessageContent,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool,
        localTransferState: IMMessageLocalTransferState? = nil
    ) -> (placeholder: IMOutgoingMediaPlaceholder?, request: IMOutgoingMessageRequest?) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return (nil, nil)
        }

        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return (nil, nil)
        }

        guard !content.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "消息内容不能为空。"
            return (nil, nil)
        }

        let requestID = UUID()
        let clientMessageID = UUID().uuidString
        let localMessageID = clientMessageID
        let createdAt = Date()
        let index = ensureConversationIndex(for: trimmedConversationID)
        let message = IMConversationMessage(
            id: localMessageID,
            conversationID: trimmedConversationID,
            clientMessageID: clientMessageID,
            serverMessageID: nil,
            senderUserID: senderUserID,
            serverSequence: nil,
            content: content,
            direction: .outgoing,
            createdAt: createdAt,
            deliveryState: deliveryState,
            localTransferState: localTransferState
        )

        conversations[index].messages.append(message)
        conversations[index].lastMessagePreviewText = content.previewText
        conversations[index].updatedAt = createdAt
        conversations[index].draftText = ""
        conversations[index].draftUpdatedAt = nil
        resetUnreadState(for: index)
        selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            outgoingQueueState.registerPendingRequest(requestID, localMessageID: localMessageID)
        }
        statusMessage = nil
        sortConversations()

        let payload = IMTCPMessagePayload(
            clientMessageID: clientMessageID,
            messageID: nil,
            conversationID: trimmedConversationID,
            senderUserID: nil,
            serverSequence: nil,
            serverTimestamp: nil,
            content: content
        )
        let request = shouldRegisterPendingRequest
            ? IMOutgoingMessageRequest(
                requestID: requestID,
                localMessageID: localMessageID,
                payload: payload
            )
            : nil
        return (
            IMOutgoingMediaPlaceholder(localMessageID: localMessageID, clientMessageID: clientMessageID),
            request
        )
    }

    private func updateUploadedOutgoingMedia(
        asset: IMMediaAsset,
        localMessageID: String,
        conversationID: String,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) -> (didUpdate: Bool, request: IMOutgoingMessageRequest?) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocalMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedLocalMessageID.isEmpty else {
            return (false, nil)
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedLocalMessageID })
        else {
            statusMessage = "附件消息不存在。"
            return (false, nil)
        }

        let content = mediaContent(for: asset)
        guard content.isUserComposable else {
            statusMessage = "当前消息类型不支持发送。"
            return (false, nil)
        }

        let requestID = UUID()
        var message = conversations[conversationIndex].messages[messageIndex]
        message.content = content
        message.deliveryState = deliveryState
        message.serverMessageID = nil
        message.serverSequence = nil
        message.localTransferState = nil
        conversations[conversationIndex].messages[messageIndex] = message
        conversations[conversationIndex].lastMessagePreviewText = content.previewText
        conversations[conversationIndex].updatedAt = message.createdAt
        selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            outgoingQueueState.registerPendingRequest(requestID, localMessageID: message.id)
        }
        statusMessage = nil
        sortConversations()

        guard shouldRegisterPendingRequest else {
            return (true, nil)
        }

        let request = IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: message.clientMessageID ?? message.id,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                content: content
            )
        )
        return (true, request)
    }

    private func mediaContent(for asset: IMMediaAsset) -> IMMessageContent {
        switch asset.kind {
        case .image:
            return .image(asset)
        case .audio:
            return .audio(asset)
        case .file:
            return .file(asset)
        }
    }

    private static func matches(_ left: IMConversationMessage, _ right: IMConversationMessage) -> Bool {
        if let leftServerMessageID = left.serverMessageID,
           let rightServerMessageID = right.serverMessageID,
           leftServerMessageID == rightServerMessageID {
            return true
        }

        if let leftClientMessageID = left.clientMessageID,
           let rightClientMessageID = right.clientMessageID,
           leftClientMessageID == rightClientMessageID {
            return true
        }

        if let leftServerSequence = left.serverSequence,
           let rightServerSequence = right.serverSequence,
           leftServerSequence == rightServerSequence,
           left.conversationID == right.conversationID {
            return true
        }

        return false
    }

    private static let messageComparator: (IMConversationMessage, IMConversationMessage) -> Bool = { left, right in
        switch (left.serverSequence, right.serverSequence) {
        case let (leftSequence?, rightSequence?):
            if leftSequence == rightSequence {
                if left.createdAt == right.createdAt {
                    return left.id < right.id
                }
                return left.createdAt < right.createdAt
            }
            return leftSequence < rightSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
    }
}

private extension IMConversationMessage {
    var isQueued: Bool {
        if case .queued = deliveryState {
            return true
        }

        return false
    }
}
