import SwiftUI
import IMClientKit
import UniformTypeIdentifiers

extension IMConversationDetailView {
    func applyingScrollStateHandlers<Content: View>(
        to content: Content,
        proxy: ScrollViewProxy
    ) -> some View {
        content
            .task(id: conversationID) {
                await scrollToLatestMessage(proxy: proxy, animated: false)
            }
            .onChange(of: latestMessageID) { _, latestMessageID in
                guard latestMessageID != nil else {
                    return
                }

                Task {
                    await scrollToLatestMessage(proxy: proxy, animated: true)
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
                        conversationID: conversationID
                    )
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingSearch) {
                NavigationStack {
                    IMConversationMessageSearchSheet(
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

    func deliveryOverrideText(for message: IMConversationMessage) -> String? {
        guard message.direction == .outgoing,
              message.serverSequence != nil,
              message.deliveryState == .sent
        else {
            return nil
        }

        guard let sequence = message.serverSequence,
              let summary = conversationStore.receiptSummary(for: conversationID)
        else {
            return "已发送"
        }

        let sequenceValue = Int(sequence)
        if summary.readThroughSequence >= sequenceValue {
            return "已读"
        }
        if conversation?.kind == .group, summary.deliveredThroughSequence >= sequenceValue {
            return summary.readThroughSequence > 0 ? "部分已读" : "已送达"
        }
        if summary.deliveredThroughSequence >= sequenceValue {
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

    var conversationSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                conversationAvatar(size: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(conversationIdentity.title)
                        .font(.headline)

                    Text(conversationIdentity.detailSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if conversationStore.isLoadingMembers || conversationStore.isLoadingMessages {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Label(conversationKindText, systemImage: conversationKindIcon)
                Text("成员 \(conversation?.memberCount ?? conversation?.memberUserIDs.count ?? 0) 人")
                if let currentGroupRole {
                    Text(currentGroupRole.displayName)
                }
                if conversation?.isPinned == true {
                    Text("已置顶")
                }
                if conversation?.isMuted == true {
                    Text("免打扰")
                }
                if conversation?.muteAll == true {
                    Text("全员禁言")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let notice = conversation?.notice, !notice.isEmpty {
                Label(notice, systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let directMessagingStatusMessage {
                Label(directMessagingStatusMessage, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Label(connectionStatusText, systemImage: connectionStatusIcon)
                .font(.caption)
                .foregroundStyle(connectionStatusColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
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
