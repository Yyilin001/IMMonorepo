import SwiftUI
import IMClientKit
import OSLog
import UniformTypeIdentifiers

/// Scroll geometry reduced to the fields needed for bottom-stickiness and history restore.
private struct IMChatScrollGeometrySnapshot: Equatable {
    let contentOffsetY: Double
    let isNearBottom: Bool
}

struct IMConversationDetailObservedState: Equatable, Sendable {
    let conversationID: String
    let conversationSignature: IMConversationDetailSignature?
    let statusMessage: String?

    @MainActor
    init(conversationStore: IMConversationStore, conversationID: String) {
        self.conversationID = conversationID
        self.conversationSignature = conversationStore.conversations
            .first { $0.id == conversationID }
            .map(IMConversationDetailSignature.init)
        self.statusMessage = conversationStore.statusMessage
    }

    var debugSummary: String {
        guard let conversationSignature else {
            return "missing"
        }
        return "pending=\(conversationSignature.pendingMessageCount) messages=\(conversationSignature.messageCount) timeline=\(conversationSignature.timelineItemCount)"
    }
}

struct IMConversationDetailAuxiliaryObservedState: Equatable, Sendable {
    let conversationID: String
    let isLoadingMessages: Bool
    let isLoadingMembers: Bool
    let receiptSummary: IMConversationReceiptSummaryResponseBody?
    let currentUserID: UUID?
    let blockedUserIDs: Set<UUID>

    init(
        conversationID: String,
        isLoadingMessages: Bool,
        isLoadingMembers: Bool,
        receiptSummary: IMConversationReceiptSummaryResponseBody?,
        currentUserID: UUID?,
        blockedUserIDs: Set<UUID>
    ) {
        self.conversationID = conversationID
        self.isLoadingMessages = isLoadingMessages
        self.isLoadingMembers = isLoadingMembers
        self.receiptSummary = receiptSummary
        self.currentUserID = currentUserID
        self.blockedUserIDs = blockedUserIDs
    }

    @MainActor
    init(
        conversationStore: IMConversationStore,
        runtimeStore: IMConversationRuntimeStore,
        conversationID: String
    ) {
        self.init(
            conversationID: conversationID,
            isLoadingMessages: conversationStore.isLoadingMessages,
            isLoadingMembers: conversationStore.isLoadingMembers,
            receiptSummary: conversationStore.receiptSummary(for: conversationID),
            currentUserID: runtimeStore.currentUserID,
            blockedUserIDs: runtimeStore.blockedUserIDs
        )
    }
}

struct IMConversationDetailSignature: Equatable, Sendable {
    let id: String
    let title: String
    let kind: IMConversationKind
    let directMessagingState: IMDirectMessagingState?
    let directPeer: IMDirectPeer?
    let notice: String?
    let avatarPreset: IMConversationAvatarPreset?
    let muteAll: Bool
    let memberCount: Int
    let members: [IMConversationMember]
    let messages: [IMConversationMessageSignature]
    let pendingMessages: [IMPendingConversationMessageSignature]
    let notices: [IMTimelineNotice]
    let hasMoreHistory: Bool
    let updatedAt: Date

    init(_ conversation: IMConversation) {
        self.id = conversation.id
        self.title = conversation.title
        self.kind = conversation.kind
        self.directMessagingState = conversation.directMessagingState
        self.directPeer = conversation.directPeer
        self.notice = conversation.notice
        self.avatarPreset = conversation.avatarPreset
        self.muteAll = conversation.muteAll
        self.memberCount = conversation.memberCount
        self.members = conversation.members
        self.messages = conversation.messages.map(IMConversationMessageSignature.init)
        self.pendingMessages = conversation.pendingMessages.map(IMPendingConversationMessageSignature.init)
        self.notices = conversation.notices
        self.hasMoreHistory = conversation.hasMoreHistory
        self.updatedAt = conversation.updatedAt
    }

    var messageCount: Int {
        messages.count
    }

    var pendingMessageCount: Int {
        pendingMessages.count
    }

    var timelineItemCount: Int {
        messages.count + notices.count + pendingMessages.count
    }
}

struct IMConversationMessageSignature: Equatable, Sendable {
    let id: String
    let clientMessageID: String?
    let serverMessageID: String
    let senderUserID: UUID
    let serverSequence: UInt64
    let timelineSequence: UInt64
    let content: IMMessageContent
    let derivedState: MessageDerivedState
    let direction: IMMessageDirection
    let createdAt: Date
    let deliveryState: IMMessageDeliveryState
    let transferTaskID: TransferTaskID?
    let localTransferState: IMMessageLocalTransferState?
    let localDownloadState: IMMessageLocalDownloadState?

    init(_ message: IMConversationMessage) {
        self.id = message.id
        self.clientMessageID = message.clientMessageID
        self.serverMessageID = message.serverMessageID
        self.senderUserID = message.senderUserID
        self.serverSequence = message.serverSequence
        self.timelineSequence = message.timelineSequence
        self.content = message.content
        self.derivedState = message.derivedState
        self.direction = message.direction
        self.createdAt = message.createdAt
        self.deliveryState = message.deliveryState
        self.transferTaskID = message.transferTaskID
        self.localTransferState = message.localTransferState
        self.localDownloadState = message.localDownloadState
    }
}

struct IMPendingConversationMessageSignature: Equatable, Sendable {
    let id: String
    let localMessageID: String
    let clientMessageID: String
    let serverMessageID: String?
    let senderUserID: UUID
    let content: IMMessageContent
    let createdAt: Date
    let deliveryState: IMMessageDeliveryState
    let transferTaskID: TransferTaskID?
    let localTransferState: IMMessageLocalTransferState?
    let localDownloadState: IMMessageLocalDownloadState?

    init(_ message: IMPendingConversationMessage) {
        self.id = message.id
        self.localMessageID = message.localMessageID
        self.clientMessageID = message.clientMessageID
        self.serverMessageID = message.serverMessageID
        self.senderUserID = message.senderUserID
        self.content = message.content
        self.createdAt = message.createdAt
        self.deliveryState = message.deliveryState
        self.transferTaskID = message.transferTaskID
        self.localTransferState = message.localTransferState
        self.localDownloadState = message.localDownloadState
    }
}

extension IMConversationDetailView {
    var conversationDetailObservedState: IMConversationDetailObservedState {
        IMConversationDetailObservedState(
            conversationStore: conversationStore,
            conversationID: conversationID
        )
    }

    var conversationDetailAuxiliaryObservedState: IMConversationDetailAuxiliaryObservedState {
        IMConversationDetailAuxiliaryObservedState(
            conversationStore: conversationStore,
            runtimeStore: runtimeStore,
            conversationID: conversationID
        )
    }

    func applyingScrollStateHandlers<Content: View>(
        to content: Content,
        proxy: ScrollViewProxy
    ) -> some View {
        content
            .onScrollGeometryChange(for: IMChatScrollGeometrySnapshot.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return IMChatScrollGeometrySnapshot(
                    contentOffsetY: geometry.contentOffset.y,
                    isNearBottom: distanceFromBottom < 120
                )
            } action: { _, newValue in
                detailScrollContentOffsetY = newValue.contentOffsetY
                isNearBottom = newValue.isNearBottom
                if newValue.isNearBottom {
                    unseenNewMessageCount = 0
                }
            }
            .task(id: conversationID) {
                IMAppLog.imUI.debug(
                    "Conversation detail opened conversationID=\(conversationID, privacy: .public) generation=\(chatPageSnapshot.generation, privacy: .public) pending=\(chatPageSnapshot.metrics.pendingMessageCount, privacy: .public) messages=\(chatPageSnapshot.metrics.messageCount, privacy: .public) timeline=\(chatPageSnapshot.metrics.timelineItemCount, privacy: .public)"
                )
                lastObservedMessageID = latestMessageID
                unseenNewMessageCount = 0
                isNearBottom = true
                await scrollToLatestMessage(proxy: proxy, animated: false)
            }
            .onChange(of: latestMessageID) { _, latestMessageID in
                IMAppLog.imUI.debug(
                    "Conversation latest item changed conversationID=\(conversationID, privacy: .public) latestID=\(latestMessageID ?? "nil", privacy: .public) pending=\(chatPageSnapshot.metrics.pendingMessageCount, privacy: .public) messages=\(chatPageSnapshot.metrics.messageCount, privacy: .public) timeline=\(chatPageSnapshot.metrics.timelineItemCount, privacy: .public) isNearBottom=\(isNearBottom, privacy: .public) latestIsCurrentUserOutgoing=\(latestTimelineItemIsCurrentUserOutgoing, privacy: .public)"
                )
                guard latestMessageID != nil else {
                    return
                }

                Task {
                    if isNearBottom || latestTimelineItemIsCurrentUserOutgoing {
                        await scrollToLatestMessage(proxy: proxy, animated: true)
                        unseenNewMessageCount = 0
                    } else if latestMessageID != lastObservedMessageID {
                        unseenNewMessageCount += 1
                    }
                    lastObservedMessageID = latestMessageID
                }
            }
            .onChange(of: chatPageSnapshot.generation) { _, _ in
                restorePendingHistoryScrollAnchor(proxy: proxy)
            }
            .onChange(of: timelineRowOffsetsFromTop) { _, _ in
                restorePendingHistoryScrollAnchor(proxy: proxy)
            }
            .onChange(of: conversationDetailObservedState) { _, state in
                refreshChatPageSnapshot(invalidation: .conversationDetailChanged(state.conversationID))
                IMAppLog.imUI.debug(
                    "Conversation detail observed state changed conversationID=\(conversationID, privacy: .public) state=\(state.debugSummary, privacy: .public) latestID=\(latestMessageID ?? "nil", privacy: .public) isNearBottom=\(isNearBottom, privacy: .public)"
                )
            }
            .onChange(of: conversationDetailAuxiliaryObservedState) { _, state in
                refreshChatPageSnapshot(invalidation: .conversationDetailAuxiliaryChanged(state.conversationID))
            }
            .onChange(of: conversationStore.replyJumpMatchedMessageID) { _, matchedMessageID in
                guard conversationStore.replyJumpConversationID == conversationID,
                      let matchedMessageID
                else {
                    return
                }

                highlightedMessageID = matchedMessageID
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(matchedMessageID, anchor: .center)
                }

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if highlightedMessageID == matchedMessageID {
                        highlightedMessageID = nil
                    }
                }
            }
    }

    /// Restores the saved history anchor once its row has been remeasured after pagination.
    ///
    /// If the anchor row exists but does not have geometry yet, the row is first
    /// scrolled into view so SwiftUI can report its offset on the next pass.
    func restorePendingHistoryScrollAnchor(proxy: ScrollViewProxy) {
        guard let anchor = pendingHistoryScrollAnchor,
              chatPageSnapshot.timelineRows.contains(where: { $0.id == anchor.itemID })
        else {
            return
        }

        guard let measuredOffsetFromTop = timelineRowOffsetsFromTop[anchor.itemID] else {
            Task { @MainActor in
                await Task.yield()
                detailScrollPosition.scrollTo(id: anchor.itemID, anchor: .top)
            }
            return
        }

        let restoration = IMChatHistoryScrollAnchorRestorer().restoration(
            anchor: anchor,
            measuredOffsetFromTop: measuredOffsetFromTop,
            currentContentOffsetY: detailScrollContentOffsetY
        )

        pendingHistoryScrollAnchor = nil
        Task { @MainActor in
            await Task.yield()
            detailScrollPosition.scrollTo(y: restoration.targetContentOffsetY)
            IMAppLog.imUI.debug(
                "Conversation restored history scroll anchor conversationID=\(conversationID, privacy: .public) anchor=\(anchor.itemID, privacy: .public) savedOffset=\(anchor.offsetFromTop, privacy: .public) measuredOffset=\(measuredOffsetFromTop, privacy: .public) targetY=\(restoration.targetContentOffsetY, privacy: .public)"
            )
        }
    }

    @MainActor
    func scrollToLatestMessage(proxy: ScrollViewProxy, animated: Bool) async {
        guard let latestMessageID else {
            return
        }

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(latestMessageID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(latestMessageID, anchor: .bottom)
        }
        IMAppLog.imUI.debug(
            "Conversation scrolled to latest conversationID=\(conversationID, privacy: .public) latestID=\(latestMessageID, privacy: .public) animated=\(animated, privacy: .public)"
        )
    }

    func applyingPresentationModifiers<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $isPresentingAddMembers) {
                NavigationStack {
                    IMAddConversationMembersSheet(
                        conversationStore: conversationStore,
                        runtimeStore: runtimeStore,
                        conversationID: conversationID
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingSearch) {
                NavigationStack {
                    IMConversationMessageSearchSheet(
                        runtimeStore: runtimeStore,
                        conversationID: conversationID,
                        onSelect: { messageID in
                            Task {
                                await runtimeStore.jumpToMessage(messageID, in: conversationID)
                            }
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingBatchSender) {
                NavigationStack {
                    IMBatchMessageSendSheet(
                        senderName: runtimeStore.currentUserDisplayName,
                        canSendMessages: canSendMessages,
                        onSendMessage: { text in
                            await runtimeStore.sendText(text, to: conversationID)
                        }
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingGroupSettings) {
                NavigationStack {
                    GroupSettingsView(
                        context: chatPageSnapshot.contextSnapshot,
                        identity: conversationIdentity,
                        currentRole: currentGroupRole,
                        canRenameConversation: canRenameConversation,
                        canAddMembers: canAddMembers,
                        canManageMembers: canManageMembers,
                        onRename: { isPresentingRenameGroup = true },
                        onEditMetadata: { isPresentingEditMetadata = true },
                        onInvites: { isPresentingInvites = true },
                        onMemberNickname: { isPresentingMemberNickname = true },
                        onAddMembers: { isPresentingAddMembers = true },
                        onManageMembers: { isPresentingManageMembers = true },
                        onLeave: { isPresentingLeaveConfirmation = true },
                        onTogglePinned: {
                            Task {
                                _ = await runtimeStore.updateConversationPreferences(
                                    conversationID,
                                    isPinned: !chatPageSnapshot.contextSnapshot.isPinned
                                )
                            }
                        },
                        onToggleMuted: {
                            Task {
                                _ = await runtimeStore.updateConversationPreferences(
                                    conversationID,
                                    isMuted: !chatPageSnapshot.contextSnapshot.isMuted
                                )
                            }
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingForwardPicker) {
                NavigationStack {
                    IMForwardMessagePickerSheet(
                        conversationStore: conversationStore,
                        sourceConversationID: conversationID,
                        messageCount: pendingForwardMessageIDs.count,
                        onForward: { targetConversationIDs in
                            selectionActionState = .forwarding
                            defer { selectionActionState = .idle }
                            let didForward = await runtimeStore.forwardMessages(
                                messageIDs: pendingForwardMessageIDs,
                                from: conversationID,
                                to: targetConversationIDs
                            )
                            if didForward {
                                isPresentingForwardPicker = false
                                resetSelection()
                                pendingForwardMessageIDs = []
                            }
                            return didForward
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $previewedMediaItem) { item in
                IMDownloadedMediaQuickLookSheet(item: item)
            }
            .sheet(isPresented: $isPresentingRenameGroup) {
                NavigationStack {
                    IMRenameConversationSheet(
                        initialTitle: chatPageSnapshot.metadata.title,
                        onSubmit: { title in
                            await runtimeStore.renameConversation(conversationID, title: title)
                        }
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingEditMetadata) {
                NavigationStack {
                    IMEditConversationMetadataSheet(
                        initialTitle: chatPageSnapshot.metadata.title,
                        initialNotice: chatPageSnapshot.metadata.notice,
                        initialAvatarPreset: chatPageSnapshot.metadata.avatarPreset,
                        initialMuteAll: chatPageSnapshot.metadata.muteAll,
                        onSubmit: { title, notice, avatarPreset, muteAll in
                            await runtimeStore.updateConversationMetadata(
                                conversationID,
                                title: title,
                                notice: notice,
                                avatarPreset: avatarPreset,
                                muteAll: muteAll
                            )
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingInvites) {
                NavigationStack {
                    IMGroupInviteManagementSheet(
                        conversationID: conversationID,
                        loadInvites: {
                            await runtimeStore.fetchGroupInvites(conversationID: conversationID)
                        },
                        createInvite: {
                            await runtimeStore.createGroupInvite(conversationID: conversationID)
                        },
                        revokeInvite: { token in
                            await runtimeStore.revokeGroupInvite(conversationID: conversationID, token: token)
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingMemberNickname) {
                NavigationStack {
                    IMMemberNicknameSheet(
                        initialNickname: currentMemberNickname ?? "",
                        onSubmit: { nickname in
                            await runtimeStore.updateMyMemberNickname(conversationID, memberNickname: nickname)
                        }
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingManageMembers) {
                NavigationStack {
                    IMManageConversationMembersSheet(
                        conversationStore: conversationStore,
                        conversationID: conversationID,
                        currentUserID: runtimeStore.currentUserID,
                        onPromoteAdmin: { memberUserID in
                            await runtimeStore.updateConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .admin,
                                in: conversationID
                            )
                        },
                        onDemoteAdmin: { memberUserID in
                            await runtimeStore.updateConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .member,
                                in: conversationID
                            )
                        },
                        onTransferOwner: { memberUserID in
                            await runtimeStore.updateConversationMemberRole(
                                memberUserID: memberUserID,
                                role: .owner,
                                in: conversationID
                            )
                        },
                        onRemoveMember: { memberUserID in
                            await runtimeStore.removeConversationMember(
                                memberUserID: memberUserID,
                                from: conversationID
                            )
                        },
                        onSearchMembers: { query in
                            await runtimeStore.loadConversationMembers(conversationID, query: query)
                        },
                        onLoadMoreMembers: {
                            await runtimeStore.loadMoreConversationMembers(conversationID)
                        }
                    )
                }
                .presentationDetents([.medium, .large])
            }
            .fileImporter(
                isPresented: $isPresentingMediaImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleMediaImport(result)
            }
            .confirmationDialog(
                "退出会话后将不再出现在你的列表中。",
                isPresented: $isPresentingLeaveConfirmation,
                titleVisibility: .visible
            ) {
                Button("退出会话", role: .destructive) {
                    Task {
                        let didLeave = await runtimeStore.leaveConversation(conversationID)
                        if didLeave {
                            dismiss()
                        }
                    }
                }
            }
    }

    func applyingDraftStateHandlers<Content: View>(to content: Content) -> some View {
        content
            .task(id: conversationID) {
                composerText = conversationStore.draftText(for: conversationID)
            }
            .onChange(of: composerText) { _, newValue in
                conversationStore.updateDraft(newValue, for: conversationID)
            }
    }

    var chatPageSnapshot: IMChatPageSnapshot {
        observedChatPageSnapshot ?? .empty(conversationID: conversationID)
    }

    @MainActor
    func observeChatPageSnapshotEvents() async {
        let currentEvent = await snapshotStore.currentChatPageSnapshotEvent(for: conversationID)
        observedChatPageSnapshot = currentEvent.snapshot
        observedChatPageRevision = currentEvent.revision

        for await event in await snapshotStore.chatPageSnapshotEvents(for: conversationID) {
            observedChatPageSnapshot = event.snapshot
            observedChatPageRevision = event.revision
            IMAppLog.imUI.debug(
                "Conversation detail snapshot event conversationID=\(event.conversationID, privacy: .public) revision=\(event.revision, privacy: .public) generation=\(event.snapshot.generation, privacy: .public) latestID=\(event.snapshot.latestItemID ?? "nil", privacy: .public)"
            )
        }
    }

    func refreshChatPageSnapshot(invalidation: IMConversationSnapshotInvalidation) {
        Task { @MainActor in
            await snapshotCommitPipeline.scheduleChatCommit(
                IMConversationSnapshotCommitEvent(
                    invalidation,
                    chatPages: [
                        IMChatPageSnapshotCommitRequest(
                            conversationID: conversationID,
                            currentUserID: runtimeStore.currentUserID,
                            blockedUserIDs: runtimeStore.blockedUserIDs
                        )
                    ]
                ),
                from: conversationStore,
                to: snapshotStore,
                didCommit: { execution in
                    let commit = execution.batchCommit.chatPages[conversationID] ?? IMConversationSnapshotCommitResult(
                        didCommit: false,
                        revision: observedChatPageRevision
                    )
                    let snapshot = execution.chatPageSnapshots[conversationID] ?? chatPageSnapshot
                    IMAppLog.imUI.debug(
                        "Conversation detail snapshot refreshed reason=\(execution.plan.reasonSummary, privacy: .public) committed=\(commit.didCommit, privacy: .public) revision=\(commit.revision, privacy: .public) conversationID=\(conversationID, privacy: .public) generation=\(snapshot.generation, privacy: .public) latestID=\(snapshot.latestItemID ?? "nil", privacy: .public)"
                    )
                }
            )
        }
    }

    var latestTimelineItemIsCurrentUserOutgoing: Bool {
        chatPageSnapshot.latestTimelineItemIsCurrentUserOutgoing
    }

    var latestMessageID: String? {
        chatPageSnapshot.latestItemID
    }

    var shouldShowLoadingState: Bool {
        chatPageSnapshot.shouldShowLoadingState
    }

    var queueSummary: IMConversationQueueSummary {
        chatPageSnapshot.queueSummary
    }

    @ViewBuilder
    var conversationContextStrip: some View {
        let context = chatPageSnapshot.contextSnapshot
        if context.shouldShow {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.small) {
                        conversationContextBadge(
                            title: context.kindText,
                            systemImage: context.kindIcon,
                            tint: .secondary
                        )

                        conversationContextBadge(
                            title: "成员 \(context.memberCount)",
                            systemImage: "person.2",
                            tint: .secondary
                        )

                        if let currentGroupRole = context.currentGroupRole {
                            conversationContextBadge(
                                title: currentGroupRole.displayName,
                                systemImage: "person.badge.shield.checkmark",
                                tint: .secondary
                            )
                        }

                        if context.isPinned {
                            conversationContextBadge(title: "已置顶", systemImage: "pin.fill", tint: .orange)
                        }

                        if context.isMuted {
                            conversationContextBadge(title: "免打扰", systemImage: "bell.slash.fill", tint: .secondary)
                        }

                        if context.isMuteAll {
                            conversationContextBadge(title: "全员禁言", systemImage: "mic.slash.fill", tint: .orange)
                        }

                        if context.showsLoadingIndicator {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let notice = context.notice, !notice.isEmpty {
                    AppStatusBanner(message: notice, tone: .info, systemImage: "text.quote")
                        .accessibilityIdentifier("conversation.notice")
                }

                if let directMessagingStatusMessage = context.directMessagingStatusMessage {
                    AppStatusBanner(message: directMessagingStatusMessage, tone: .warning, systemImage: "lock.fill")
                        .accessibilityIdentifier("conversation.directMessagingStatus")
                }
            }
        }
    }

    var shouldShowConversationContextStrip: Bool {
        chatPageSnapshot.contextSnapshot.shouldShow
    }

    func conversationContextBadge(title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10), in: Capsule())
    }

    @ViewBuilder
    func conversationAvatar(size: CGFloat) -> some View {
        if chatPageSnapshot.contextSnapshot.kind == .direct {
            UserAvatarView(
                displayName: conversationIdentity.title,
                email: directPeer?.email,
                avatarPreset: directPeer?.avatarPreset,
                size: size
            )
        } else {
            Text(conversationInitials)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.accentColor))
        }
    }
}
