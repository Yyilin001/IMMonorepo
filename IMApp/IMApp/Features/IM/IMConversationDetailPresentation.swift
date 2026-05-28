import SwiftUI
import IMClientKit
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
                lastObservedMessageID = latestMessageID
                unseenNewMessageCount = 0
                isNearBottom = true
                await scrollToLatestMessage(proxy: proxy, animated: false)
            }
            .onChange(of: latestMessageID) { _, latestMessageID in
                guard latestMessageID != nil else {
                    return
                }

                Task {
                    if isNearBottom {
                        await scrollToLatestMessage(proxy: proxy, animated: true)
                        unseenNewMessageCount = 0
                    } else if latestMessageID != lastObservedMessageID {
                        unseenNewMessageCount += 1
                    }
                    lastObservedMessageID = latestMessageID
                }
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

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(latestMessageID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(latestMessageID, anchor: .bottom)
        }
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
                        conversation: conversation,
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
                                    isPinned: !(conversation?.isPinned ?? false)
                                )
                            }
                        },
                        onToggleMuted: {
                            Task {
                                _ = await runtimeStore.updateConversationPreferences(
                                    conversationID,
                                    isMuted: !(conversation?.isMuted ?? false)
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
                        initialNickname: currentMember?.memberNickname ?? "",
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

    var conversation: IMConversation? {
        conversationStore.conversations.first { $0.id == conversationID }
    }

    var messages: [IMConversationMessage] {
        conversation?.messages ?? []
    }

    var timelineItems: [IMConversationTimelineItem] {
        conversation?.timelineItems ?? []
    }

    func deliveryOverrideText(for message: IMConversationMessage) -> String? {
        guard message.direction == .outgoing,
              message.deliveryState == .sent
        else {
            return nil
        }

        let sequence = message.serverSequence
        guard let summary = conversationStore.receiptSummary(for: conversationID)
        else {
            return "已发送"
        }

        if summary.readThroughSequence >= sequence {
            return "已读"
        }
        if conversation?.kind == .group, summary.deliveredThroughSequence >= sequence {
            return summary.readThroughSequence > 0 ? "部分已读" : "已送达"
        }
        if summary.deliveredThroughSequence >= sequence {
            return "已送达"
        }
        return "已发送"
    }

    var latestMessageID: String? {
        messages.last?.id
    }

    var shouldShowLoadingState: Bool {
        messages.isEmpty && conversationStore.isLoadingMessages
    }

    var queueSummary: IMConversationQueueSummary {
        conversationStore.queueSummary(for: conversationID)
    }

    @ViewBuilder
    var conversationContextStrip: some View {
        if shouldShowConversationContextStrip {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.small) {
                        conversationContextBadge(
                            title: conversationKindText,
                            systemImage: conversationKindIcon,
                            tint: .secondary
                        )

                        conversationContextBadge(
                            title: "成员 \(conversation?.memberCount ?? conversation?.memberUserIDs.count ?? 0)",
                            systemImage: "person.2",
                            tint: .secondary
                        )

                        if let currentGroupRole {
                            conversationContextBadge(
                                title: currentGroupRole.displayName,
                                systemImage: "person.badge.shield.checkmark",
                                tint: .secondary
                            )
                        }

                        if conversation?.isPinned == true {
                            conversationContextBadge(title: "已置顶", systemImage: "pin.fill", tint: .orange)
                        }

                        if conversation?.isMuted == true {
                            conversationContextBadge(title: "免打扰", systemImage: "bell.slash.fill", tint: .secondary)
                        }

                        if conversation?.muteAll == true {
                            conversationContextBadge(title: "全员禁言", systemImage: "mic.slash.fill", tint: .orange)
                        }

                        if conversationStore.isLoadingMembers || conversationStore.isLoadingMessages {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let notice = conversation?.notice, !notice.isEmpty {
                    AppStatusBanner(message: notice, tone: .info, systemImage: "text.quote")
                        .accessibilityIdentifier("conversation.notice")
                }

                if let directMessagingStatusMessage {
                    AppStatusBanner(message: directMessagingStatusMessage, tone: .warning, systemImage: "lock.fill")
                        .accessibilityIdentifier("conversation.directMessagingStatus")
                }
            }
        }
    }

    var shouldShowConversationContextStrip: Bool {
        conversation?.kind == .group
            || conversation?.notice?.isEmpty == false
            || directMessagingStatusMessage != nil
            || conversation?.isPinned == true
            || conversation?.isMuted == true
            || conversation?.muteAll == true
            || conversationStore.isLoadingMembers
            || conversationStore.isLoadingMessages
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
        if conversation?.kind == .direct {
            UserAvatarView(
                displayName: conversationIdentity.title,
                email: conversation?.directPeer?.email,
                avatarPreset: conversation?.directPeer?.avatarPreset,
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
