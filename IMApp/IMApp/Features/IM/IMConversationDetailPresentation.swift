import SwiftUI
import IMClientKit
import OSLog
import UniformTypeIdentifiers

extension IMConversationDetailView {
    func applyingScrollStateHandlers<Content: View>(
        to content: Content,
        proxy: ScrollViewProxy
    ) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height
                    - geometry.containerSize.height
                    - geometry.contentOffset.y
                return distanceFromBottom < 120
            } action: { _, newValue in
                isNearBottom = newValue
                if newValue {
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
            .onChange(of: conversationStore.conversationMutationGeneration) { _, generation in
                refreshChatPageSnapshot(reason: "generationChanged:\(generation)")
                IMAppLog.imUI.debug(
                    "Conversation store generation changed conversationID=\(conversationID, privacy: .public) generation=\(generation, privacy: .public) pending=\(chatPageSnapshot.metrics.pendingMessageCount, privacy: .public) messages=\(chatPageSnapshot.metrics.messageCount, privacy: .public) timeline=\(chatPageSnapshot.metrics.timelineItemCount, privacy: .public) latestID=\(latestMessageID ?? "nil", privacy: .public) isNearBottom=\(isNearBottom, privacy: .public)"
                )
            }
            .onChange(of: conversationStore.isLoadingMessages) { _, isLoading in
                refreshChatPageSnapshot(reason: "messagesLoadingChanged:\(isLoading)")
            }
            .onChange(of: conversationStore.isLoadingMembers) { _, isLoading in
                refreshChatPageSnapshot(reason: "membersLoadingChanged:\(isLoading)")
            }
            .onChange(of: conversationStore.receiptSummary(for: conversationID)) { _, _ in
                refreshChatPageSnapshot(reason: "receiptChanged")
            }
            .onChange(of: runtimeStore.currentUserID) { _, currentUserID in
                refreshChatPageSnapshot(reason: "currentUserChanged:\(currentUserID?.uuidString ?? "nil")")
            }
            .onChange(of: runtimeStore.blockedUserIDs) { _, _ in
                refreshChatPageSnapshot(reason: "blockedUsersChanged")
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
                        initialTitle: conversation?.title ?? "",
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
                        initialTitle: conversation?.title ?? "",
                        initialNotice: conversation?.notice ?? "",
                        initialAvatarPreset: conversation?.avatarPreset ?? .ocean,
                        initialMuteAll: conversation?.muteAll ?? false,
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
        snapshotStore.chatPageSnapshot(for: conversationID)
    }

    func refreshChatPageSnapshot(reason: String) {
        let commit = snapshotStore.commitChatPageSnapshot(
            from: conversationStore,
            conversationID: conversationID,
            currentUserID: runtimeStore.currentUserID,
            blockedUserIDs: runtimeStore.blockedUserIDs
        )
        IMAppLog.imUI.debug(
            "Conversation detail snapshot refreshed reason=\(reason, privacy: .public) committed=\(commit.didCommit, privacy: .public) revision=\(commit.revision, privacy: .public) conversationID=\(conversationID, privacy: .public) generation=\(chatPageSnapshot.generation, privacy: .public) latestID=\(chatPageSnapshot.latestItemID ?? "nil", privacy: .public)"
        )
    }

    var conversation: IMConversation? {
        chatPageSnapshot.conversation
    }

    var latestTimelineItemIsCurrentUserOutgoing: Bool {
        chatPageSnapshot.latestTimelineItemIsCurrentUserOutgoing
    }

    func deliveryOverrideText(for message: IMConversationMessage) -> String? {
        chatPageSnapshot.deliveryOverrideText(for: message)
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
