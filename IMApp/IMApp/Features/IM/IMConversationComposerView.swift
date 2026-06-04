import SwiftUI
import IMClientKit

extension IMConversationDetailView {
    var composerBar: some View {
        VStack(spacing: 0) {
            if let directMessagingStatusMessage {
                AppStatusBanner(message: directMessagingStatusMessage, tone: .warning)
                    .padding(.horizontal, AppSpacing.large)
                    .padding(.top, AppSpacing.medium)
            }

            if isDirectPeerBlocked, let peer = directPeer {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.red)

                    Text("已屏蔽对方，当前私聊输入已停用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button {
                        runRelationshipAction(.unblock(peer.id)) {
                            await runtimeStore.unblockUser(peer.id)
                        }
                    } label: {
                        if relationshipActionIsRunning(.unblock(peer.id)) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("解除")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(relationshipActionIsRunning(.unblock(peer.id)))
                }
                .padding(.horizontal, AppSpacing.large)
                .padding(.top, AppSpacing.small)
            }

            if let directRelationshipPresentation {
                DirectPeerRelationshipActionPanel(
                    presentation: directRelationshipPresentation,
                    notice: directRelationshipNotice,
                    isSendRequestRunning: relationshipActionIsRunning(.sendRequest(conversationID)),
                    isAcceptRunning: relationshipActionIsRunning(.accept(conversationID)),
                    isDeclineRunning: relationshipActionIsRunning(.decline(conversationID)),
                    isCancelRunning: relationshipActionIsRunning(.cancel(conversationID)),
                    onSendRequest: {
                        runRelationshipAction(.sendRequest(conversationID)) {
                            await runtimeStore.sendDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onAccept: {
                        runRelationshipAction(.accept(conversationID)) {
                            await runtimeStore.acceptDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onDecline: {
                        runRelationshipAction(.decline(conversationID)) {
                            await runtimeStore.declineDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onCancelRequest: {
                        runRelationshipAction(.cancel(conversationID)) {
                            await runtimeStore.cancelDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    }
                )
                .padding(.horizontal, AppSpacing.large)
                .padding(.top, AppSpacing.small)
            }

            Divider()

            ConversationComposerSurface {
                Button {
                    isPresentingMediaImporter = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 27))
                        .frame(width: 34, height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSendMessages ? Color.accentColor : .secondary)
                .disabled(!canSendMessages)
                .accessibilityLabel("添加附件")
                .accessibilityIdentifier("conversation.composer.attachButton")
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    if let editingTarget {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("编辑消息")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(editingTarget.previewText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            Button {
                                self.editingTarget = nil
                                self.composerText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("取消编辑")
                            .accessibilityIdentifier("conversation.editBar.cancel")
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                    } else if let replyTarget {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("回复消息")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(replyTarget.reference.previewText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            Button {
                                self.replyTarget = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("取消回复")
                            .accessibilityIdentifier("conversation.replyBar.cancel")
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                    }

                    if let composerDisabledReason {
                        Label(composerDisabledReason, systemImage: "lock.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, (replyTarget == nil && editingTarget == nil) ? 10 : 0)
                    }

                    TextField(composerDisabledReason ?? "输入消息", text: $composerText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                        .disabled(!canSendMessages)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .padding(.top, (replyTarget == nil && editingTarget == nil && composerDisabledReason == nil) ? 10 : 0)
                        .accessibilityIdentifier("conversation.composer.textEditor")
                }
                .background(AppSurface.primaryGrouped, in: RoundedRectangle(cornerRadius: AppCornerRadius.large))
            } trailing: {
                Button {
                    Task {
                        let didSend: Bool
                        if let editingTarget {
                            didSend = await runtimeStore.editMessage(
                                messageID: editingTarget.serverMessageID,
                                text: composerText,
                                in: conversationID
                            )
                        } else if let replyTarget {
                            didSend = await runtimeStore.sendReply(
                                reference: replyTarget.reference,
                                text: composerText,
                                to: conversationID
                            )
                        } else {
                            didSend = await runtimeStore.sendText(composerText, to: conversationID)
                        }
                        if didSend {
                            composerText = ""
                            replyTarget = nil
                            editingTarget = nil
                        }
                    }
                } label: {
                    Image(systemName: editingTarget == nil ? "paperplane.fill" : "square.and.arrow.down.fill")
                        .font(.headline)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 21))
                .disabled(!canSendMessages || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(editingTarget == nil ? "发送消息" : "保存编辑")
                .accessibilityIdentifier("conversation.composer.sendButton")
            }
        }
    }

    func relationshipActionIsRunning(_ key: IMConversationRelationshipActionKey) -> Bool {
        runningRelationshipActions.contains(key)
    }

    func runRelationshipAction(
        _ key: IMConversationRelationshipActionKey,
        operation: @escaping @MainActor () async -> ContactOperationResult
    ) {
        guard !runningRelationshipActions.contains(key) else {
            return
        }
        runningRelationshipActions.insert(key)

        Task { @MainActor in
            let result = await operation()
            guard !Task.isCancelled else {
                return
            }
            runningRelationshipActions.remove(key)
            runtimeStore.setDirectRelationshipNotice(result, conversationID: conversationID)
        }
    }

    var selectionToolbar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                Text("已选择 \(selectedMessageIDs.count) 条")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    pendingForwardMessageIDs = Array(selectedMessageIDs)
                    isPresentingForwardPicker = true
                } label: {
                    Label("转发", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(selectedMessageIDs.isEmpty || selectionActionState != .idle)

                Button {
                    Task {
                        await favoriteSelectedMessages()
                    }
                } label: {
                    Label("收藏", systemImage: "star")
                }
                .disabled(selectedMessageIDs.isEmpty || selectionActionState != .idle)

                Button(role: .destructive) {
                    Task {
                        await deleteSelectedMessages()
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selectedMessageIDs.isEmpty || selectionActionState != .idle)

                Button {
                    resetSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("退出多选")
            }
            .font(.caption)
            .labelStyle(.iconOnly)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.thinMaterial)
        }
    }

    func selectableMessageID(for message: IMConversationMessage) -> String? {
        if UUID(uuidString: message.serverMessageID) != nil {
            return message.serverMessageID
        }
        return UUID(uuidString: message.id) == nil ? nil : message.id
    }

    func toggleSelectedMessage(_ messageID: String) {
        if selectedMessageIDs.contains(messageID) {
            selectedMessageIDs.remove(messageID)
        } else {
            selectedMessageIDs.insert(messageID)
        }

        if selectedMessageIDs.isEmpty {
            isSelectionMode = false
        }
    }

    func resetSelection() {
        isSelectionMode = false
        selectedMessageIDs.removeAll()
        pendingForwardMessageIDs.removeAll()
        selectionActionState = .idle
    }

    func loadConversationFavoriteCache() async {
        guard let conversationUUID = UUID(uuidString: conversationID),
              let page = await runtimeStore.fetchFavorites(conversationID: conversationUUID, limit: 200)
        else {
            favoritedMessageIDs = []
            return
        }

        favoritedMessageIDs = Set(page.items.map { $0.id.uuidString })
    }

    func toggleFavorite(messageID: String) async {
        let wasFavorited = favoritedMessageIDs.contains(messageID)
        let didUpdate = wasFavorited
            ? await runtimeStore.unfavoriteMessage(messageID: messageID, in: conversationID)
            : await runtimeStore.favoriteMessage(messageID: messageID, in: conversationID)

        guard didUpdate else {
            return
        }

        if wasFavorited {
            favoritedMessageIDs.remove(messageID)
        } else {
            favoritedMessageIDs.insert(messageID)
        }
    }

    func favoriteSelectedMessages() async {
        let selectedIDs = selectedMessageIDs
        guard !selectedIDs.isEmpty else {
            return
        }

        selectionActionState = .favoriting
        defer { selectionActionState = .idle }

        for messageID in selectedIDs where !favoritedMessageIDs.contains(messageID) {
            if await runtimeStore.favoriteMessage(messageID: messageID, in: conversationID) {
                favoritedMessageIDs.insert(messageID)
            }
        }
    }

    func deleteSelectedMessages() async {
        let selectedIDs = Array(selectedMessageIDs)
        guard !selectedIDs.isEmpty else {
            return
        }

        selectionActionState = .deleting
        defer { selectionActionState = .idle }

        if await runtimeStore.deleteMessagesForSelf(messageIDs: selectedIDs, in: conversationID) {
            resetSelection()
        }
    }
}
