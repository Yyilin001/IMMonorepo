import SwiftUI
import IMClientKit

extension IMConversationDetailView {
    var composerBar: some View {
        VStack(spacing: 12) {
            if let directMessagingStatusMessage {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(directMessagingStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            if isDirectPeerBlocked, let peer = directPeer {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.red)

                    Text("已屏蔽对方，当前私聊输入已停用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button("解除") {
                        Task {
                            _ = await runtimeStore.unblockUser(peer.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.top, directMessagingStatusMessage == nil ? 12 : 0)
            }

            if let directRelationshipPresentation {
                DirectPeerRelationshipActionPanel(
                    presentation: directRelationshipPresentation,
                    actionMessage: directConversationRelationshipActionMessage,
                    onSendRequest: {
                        Task {
                            await runtimeStore.sendDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onAccept: {
                        Task {
                            await runtimeStore.acceptDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onDecline: {
                        Task {
                            await runtimeStore.declineDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    },
                    onCancelRequest: {
                        Task {
                            await runtimeStore.cancelDirectConversationFriendRequest(conversationID: conversationID)
                        }
                    }
                )
                .padding(.horizontal, 16)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 12) {
                Button {
                    isPresentingMediaImporter = true
                } label: {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSendMessages ? Color.accentColor : .secondary)
                .disabled(!canSendMessages)

                VStack(alignment: .leading, spacing: 8) {
                    if let editingTarget {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("编辑消息")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(MessagePresentation(aggregate: editingTarget.aggregate).textValue ?? "消息内容不可编辑")
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
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    } else if let replyTarget {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("回复消息")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(replyComposerPreviewText(for: replyTarget))
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
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                    }

                    if let composerDisabledReason {
                        Label(composerDisabledReason, systemImage: "lock.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, (replyTarget == nil && editingTarget == nil) ? 12 : 0)
                    }

                    TextField(composerDisabledReason ?? "输入消息", text: $composerText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                        .disabled(!canSendMessages)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .padding(.top, (replyTarget == nil && editingTarget == nil && composerDisabledReason == nil) ? 12 : 0)
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Button {
                    Task {
                        let didSend: Bool
                        if let editingTarget {
                            didSend = await runtimeStore.editMessage(
                                messageID: editingTarget.serverMessageID ?? editingTarget.id,
                                text: composerText,
                                in: conversationID
                            )
                        } else if let replyTarget,
                           let reference = replyReference(from: replyTarget) {
                            didSend = await runtimeStore.sendReply(
                                reference: reference,
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
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSendMessages || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.thinMaterial)
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
        if let serverMessageID = message.serverMessageID,
           UUID(uuidString: serverMessageID) != nil {
            return serverMessageID
        }
        if UUID(uuidString: message.id) != nil {
            return message.id
        }
        return nil
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
