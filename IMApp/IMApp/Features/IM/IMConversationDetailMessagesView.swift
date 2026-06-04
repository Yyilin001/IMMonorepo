import SwiftUI
import IMClientKit

struct ConversationNewMessagePill: View {
    let unseenCount: Int
    let showsJumpOnly: Bool
    let onTap: () -> Void

    var body: some View {
        if unseenCount > 0 || showsJumpOnly {
            Button {
                onTap()
            } label: {
                Label(title, systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .shadow(radius: 8, y: 3)
            .accessibilityIdentifier(unseenCount > 0 ? "conversation.newMessagePill" : "conversation.jumpLatestButton")
        }
    }

    private var title: String {
        if unseenCount > 0 {
            return unseenCount == 1 ? "1 条新消息" : "\(unseenCount) 条新消息"
        }
        return "回到底部"
    }
}

extension IMConversationDetailView {
    var detailScrollView: some View {
        ScrollView {
            detailMessageStack
        }
        .defaultScrollAnchor(.bottom)
        .background(AppSurface.groupedBackground)
    }

    var detailMessageStack: some View {
        let snapshot = chatPageSnapshot
        return LazyVStack(alignment: .leading, spacing: 14) {
            conversationContextStrip

            if snapshot.queueSummary.hasPendingWork {
                IMConversationQueueBanner(
                    summary: snapshot.queueSummary,
                    isFlushing: runtimeStore.isFlushingQueuedTextMessages
                )
            }

            if let message = conversationStore.statusMessage, !message.isEmpty {
                AppStatusBanner(message: message, tone: .info)
                    .accessibilityIdentifier("conversation.status")
            }

            detailMessagesContent(snapshot: snapshot)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    func detailMessagesContent(snapshot: IMChatPageSnapshot) -> some View {
        if snapshot.shouldShowLoadingState {
            ProgressView("正在拉取消息…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
        } else if snapshot.timelineRows.isEmpty {
            IMDetailEmptyState()
        } else {
            if snapshot.hasMoreHistory {
                Button {
                    conversationStore.openConversation(id: conversationID)
                    Task {
                        await runtimeStore.loadOlderMessages()
                    }
                } label: {
                    Label("加载更早消息", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(conversationStore.isLoadingMessages)
                .accessibilityIdentifier("conversation.loadOlderMessagesButton")
            }

            ForEach(snapshot.timelineRows) { row in
                switch row {
                case .message(let rowSnapshot):
                    detailMessageRow(rowSnapshot, snapshot: snapshot)
                        .id(row.id)
                case .notice(let rowSnapshot):
                    timelineNoticeRow(rowSnapshot)
                        .id(row.id)
                case .pendingMessage(let rowSnapshot):
                    pendingMessageRow(rowSnapshot)
                        .id(row.id)
                }
            }
        }
    }

    func timelineNoticeRow(_ notice: IMChatNoticeRowSnapshot) -> some View {
        Text(notice.displayText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppSurface.secondaryGrouped, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("conversation.timelineNotice.\(notice.id)")
    }

    func detailMessageRow(_ rowSnapshot: IMChatMessageRowSnapshot, snapshot: IMChatPageSnapshot) -> some View {
        let mediaAsset = rowSnapshot.content.mediaAsset
        let selectableID = rowSnapshot.selectableID
        let localMessageID = rowSnapshot.localMessageID
        let serverMessageID = rowSnapshot.serverMessageID
        return IMMessageBubble(
            rowSnapshot: rowSnapshot,
            isHighlighted: highlightedMessageID == localMessageID,
            isSelectionMode: isSelectionMode,
            isSelected: selectableID.map(selectedMessageIDs.contains) ?? false,
            canSelect: selectableID != nil,
            canRetry: rowSnapshot.canRetry,
            canCancel: rowSnapshot.canCancel,
            canReply: rowSnapshot.canReply,
            canRecall: rowSnapshot.canRecall,
            canEdit: rowSnapshot.canEdit,
            canReact: rowSnapshot.canReact,
            isFavorited: selectableID.map(favoritedMessageIDs.contains) ?? false,
            mediaDownloadState: resolvedMediaDownloadState(for: rowSnapshot.mediaDownload),
            currentUserID: snapshot.currentUserID,
            onToggleSelection: {
                guard let selectableID else {
                    return
                }
                toggleSelectedMessage(selectableID)
            },
            onEnterSelection: {
                guard let selectableID else {
                    return
                }
                isSelectionMode = true
                selectedMessageIDs.insert(selectableID)
            },
            onJumpToReplyReference: {
                guard let referenceMessageID = rowSnapshot.content.replyReferenceMessageID else {
                    return
                }

                Task {
                    await runtimeStore.jumpToReferencedMessage(
                        referenceMessageID,
                        in: conversationID
                    )
                }
            },
            onCancel: {
                _ = runtimeStore.cancelQueuedTextMessage(
                    localMessageID: localMessageID,
                    in: conversationID
                )
            },
            onReply: {
                editingTarget = nil
                replyTarget = rowSnapshot.replyTarget
            },
            onEdit: {
                replyTarget = nil
                editingTarget = rowSnapshot.editingTarget
                composerText = rowSnapshot.editingTarget?.initialComposerText ?? ""
            },
            onRecall: {
                Task {
                    let didRecall = await runtimeStore.recallMessage(
                        messageID: serverMessageID,
                        in: conversationID
                    )
                    if didRecall, replyTarget?.localMessageID == localMessageID {
                        replyTarget = nil
                    }
                }
            },
            onRetry: {
                Task {
                    await runtimeStore.retryTextMessage(
                        localMessageID: localMessageID,
                        in: conversationID
                    )
                }
            },
            onForward: {
                guard let selectableID else {
                    return
                }
                pendingForwardMessageIDs = [selectableID]
                isPresentingForwardPicker = true
            },
            onToggleFavorite: {
                guard let selectableID else {
                    return
                }
                Task {
                    await toggleFavorite(messageID: selectableID)
                }
            },
            onDelete: {
                guard let selectableID else {
                    return
                }
                Task {
                    _ = await runtimeStore.deleteMessagesForSelf(messageIDs: [selectableID], in: conversationID)
                }
            },
            onToggleReaction: { emoji in
                Task {
                    _ = await runtimeStore.toggleMessageReaction(
                        messageID: serverMessageID,
                        emoji: emoji,
                        in: conversationID
                    )
                }
            },
            onDownloadMedia: {
                guard let mediaAsset else {
                    return
                }
                startMediaDownload(mediaAsset)
            },
            onCancelMediaDownload: {
                guard let assetID = mediaAsset?.assetID else {
                    return
                }
                pauseMediaDownload(for: assetID)
            },
            onRetryMediaDownload: {
                guard let mediaAsset else {
                    return
                }
                startMediaDownload(mediaAsset)
            },
            onOpenDownloadedMedia: { fileURL in
                previewedMediaItem = IMDownloadedMediaPreviewItem(
                    url: fileURL,
                    title: mediaAsset?.filename ?? fileURL.lastPathComponent
                )
            },
            onDeleteDownloadedMedia: {
                guard let mediaAsset else {
                    return
                }
                deleteDownloadedMedia(mediaAsset)
            }
        )
    }

    func pendingMessageRow(_ rowSnapshot: IMChatPendingMessageRowSnapshot) -> some View {
        return HStack {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(rowSnapshot.text)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(rowSnapshot.createdAtText)
                    let display = IMMessageDeliveryDisplay(snapshot: rowSnapshot.deliveryDisplay)
                    Label(display.text, systemImage: display.icon)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(display.tint)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if rowSnapshot.canCancel {
                    Button {
                        _ = runtimeStore.cancelQueuedTextMessage(
                            localMessageID: rowSnapshot.localMessageID,
                            in: conversationID
                        )
                    } label: {
                        Label("取消发送", systemImage: "xmark.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("conversation.message.cancelSend")
                } else if rowSnapshot.canRetry {
                    Button {
                        Task {
                            await runtimeStore.retryTextMessage(
                                localMessageID: rowSnapshot.localMessageID,
                                in: conversationID
                            )
                        }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("conversation.message.retry")
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityIdentifier("conversation.pendingMessage.\(rowSnapshot.localMessageID)")
    }

}
